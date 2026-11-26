#!/bin/bash
#
# Smoke tests for a locally built image (used by CI, also handy locally).
#
# Usage: bash tests/smoke.sh <image>
#   e.g. docker buildx build --load --build-arg P_BITCOIN_VERSION=32.1 -t bitcoin-core:test .
#        bash tests/smoke.sh bitcoin-core:test
#
# Host directories are created under $RUNNER_TEMP or /var/tmp (on disk: /tmp
# is often tmpfs, which the image rightly refuses). Only containers and volumes
# created by this script are removed.

# SC2015: pass() never fails, so "test && pass || fail" is safe.
# SC2001: sed is clearer to indent multi-line output.
# shellcheck disable=SC2015,SC2001

set -uo pipefail

IMG="${1:?usage: $0 <image>}"
PREFIX="btc-smoke-$$"
WORK="$(mktemp -d "${RUNNER_TEMP:-/var/tmp}/${PREFIX}.XXXXXX")"
DATA=/home/bitcoin/.bitcoin
FAILURES=0

pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILURES=$((FAILURES + 1)); }
section() { echo ""; echo "== $*"; }

cleanup() {
  docker ps -aq --filter "name=${PREFIX}" | xargs -r docker rm -f > /dev/null
  docker volume ls -q --filter "name=${PREFIX}" | xargs -r docker volume rm > /dev/null
  # Files may belong to other uids: remove them from a container.
  docker run --rm -v "$(dirname "${WORK}"):/parent" "${IMG}" rm -rf "/parent/$(basename "${WORK}")"
}
trap cleanup EXIT

# expect_refused <description> <expected text> <docker run arguments...>
expect_refused() {
  local description="$1" expected="$2" output rc
  shift 2
  output="$(docker run --rm "$@" 2>&1)"
  rc=$?
  if [ "${rc}" -ne 0 ] && grep -qF -- "${expected}" <<< "${output}"; then
    pass "${description}"
  else
    fail "${description} (exit ${rc}, expected \"${expected}\")"
    sed 's/^/        /' <<< "${output}"
  fi
}

# wait_live <container>: waits until the RPC server answers.
wait_live() {
  local _
  for _ in $(seq 1 60); do
    docker exec "$1" /opt/healthcheck.sh liveness > /dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# start_node <name> <docker run arguments...>: starts a regtest node and waits for it.
start_node() {
  local name="$1"
  shift
  if docker run -d --name "${name}" "$@" > /dev/null && wait_live "${name}"; then
    pass "${name#"${PREFIX}"-} starts"
    return 0
  fi
  fail "${name#"${PREFIX}"-} starts"
  docker logs "${name}" 2>&1 | tail -n 20 | sed 's/^/        /'
  return 1
}

# stop_node <name>: docker stop must end with a clean bitcoind shutdown.
stop_node() {
  local name="$1" code
  docker stop -t 120 "${name}" > /dev/null
  code="$(docker inspect -f '{{.State.ExitCode}}' "${name}")"
  if [ "${code}" = "0" ] && docker logs "${name}" 2>&1 | tail -n 3 | grep -c "Shutdown done" > /dev/null; then
    pass "${name#"${PREFIX}"-} stops cleanly (exit 0, \"Shutdown done\")"
  else
    fail "${name#"${PREFIX}"-} stops cleanly (exit ${code})"
    docker logs "${name}" 2>&1 | tail -n 5 | sed 's/^/        /'
  fi
}

section "Image metadata"
ports="$(docker inspect -f '{{json .Config.ExposedPorts}}' "${IMG}")"
[ "${ports}" = "null" ] && pass "no EXPOSE" || fail "no EXPOSE (got ${ports})"
volumes="$(docker inspect -f '{{json .Config.Volumes}}' "${IMG}")"
[ "${volumes}" = "null" ] && pass "no VOLUME" || fail "no VOLUME (got ${volumes})"

section "Commands that need no data directory"
docker run --rm "${IMG}" -version | grep -c "Bitcoin Core" > /dev/null && pass "-version" || fail "-version"
docker run --rm "${IMG}" bitcoin-cli -version | grep -c "RPC client" > /dev/null && pass "bitcoin-cli -version" || fail "bitcoin-cli -version"
docker run --rm "${IMG}" bitcoin-tx -help | grep -c "bitcoin-tx" > /dev/null && pass "bitcoin-tx -help" || fail "bitcoin-tx -help"

section "Data directory protections"
mkdir -p "${WORK}/ro" "${WORK}/pods/uid/volumes/kubernetes.io~empty-dir/data"
# Created in a container with fixed owners: the host user is not always uid
# 1000 (GitHub runners use 1001), and these checks must not depend on it.
docker run --rm -v "${WORK}:/w" "${IMG}" bash -c '
  mkdir -p /w/foreign /w/daemon
  touch /w/foreign/blk && chown -R 4321:4321 /w/foreign && chmod 700 /w/foreign
  printf "daemon=1\n" > /w/daemon/bitcoin.conf && chown -R 1000:1000 /w/daemon'

expect_refused "no volume" "is not on a Docker volume or bind mount" "${IMG}" -regtest
expect_refused "anonymous volume" "ANONYMOUS Docker volume" -v "${DATA}" "${IMG}" -regtest
expect_refused "tmpfs without -regtest" "in-memory filesystem" --tmpfs "${DATA}" "${IMG}"
expect_refused "Kubernetes emptyDir" "Kubernetes emptyDir" -v "${WORK}/pods/uid/volumes/kubernetes.io~empty-dir/data:${DATA}" "${IMG}"
expect_refused "read-only mount" "mounted read-only" -v "${WORK}/ro:${DATA}:ro" "${IMG}" -regtest
expect_refused "data owned by another user" "is not writable by uid=1000 gid=1000" -v "${WORK}/foreign:${DATA}" "${IMG}" -regtest
expect_refused "-daemon" "is not supported in a container" -v "${WORK}/ro:${DATA}" "${IMG}" -regtest -daemon
expect_refused "daemon=1 in bitcoin.conf" "sets daemon=1" -v "${WORK}/daemon:${DATA}" "${IMG}" -regtest
expect_refused "B_UID=0" "as root (B_UID=0) is not supported" -e B_UID=0 -v "${WORK}/ro:${DATA}" "${IMG}" -regtest

section "Regtest node in memory, health checks"
node="${PREFIX}-tmpfs"
if start_node "${node}" --tmpfs "${DATA}" "${IMG}" -regtest; then
  if docker exec "${node}" /opt/healthcheck.sh readiness > /dev/null; then
    fail "readiness is false during initial block download"
  else
    pass "readiness is false during initial block download"
  fi
  cli=(docker exec -u bitcoin "${node}" bitcoin-cli -regtest)
  desc="$("${cli[@]}" getdescriptorinfo 'raw(51)' | sed -nE 's/.*"descriptor": "([^"]+)".*/\1/p')"
  "${cli[@]}" generatetodescriptor 1 "${desc}" > /dev/null
  docker exec "${node}" /opt/healthcheck.sh readiness > /dev/null \
    && pass "readiness is true after the initial block download" \
    || fail "readiness is true after the initial block download"
  [ "$(docker exec "${node}" cat /proc/1/comm)" = "bitcoind" ] && pass "bitcoind is PID 1" || fail "bitcoind is PID 1"
  stop_node "${node}"
fi

section "Bind mount with B_UID/B_GID (gid 100 already exists)"
node="${PREFIX}-bind"
if start_node "${node}" -e B_UID=1234 -e B_GID=100 -v "${WORK}/bind:${DATA}" "${IMG}" -regtest -rpcpassword=secret -rpcuser=alice; then
  [ "$(docker exec "${node}" awk '/^Uid:/ { print $2 }' /proc/1/status)" = "1234" ] && pass "bitcoind runs as uid 1234" || fail "bitcoind runs as uid 1234"
  [ "$(stat -c '%u:%g' "${WORK}/bind")" = "1234:100" ] && pass "host directory owned by 1234:100" || fail "host directory owned by 1234:100"
  docker logs "${node}" 2>&1 | grep -c "rpcpassword=\*\*\*\*\*\*" > /dev/null && pass "rpcpassword masked in the start-up summary" || fail "rpcpassword masked in the start-up summary"
  docker exec -u bitcoin "${node}" bitcoin-cli -regtest -rpcuser=alice -rpcpassword=secret getblockcount > /dev/null \
    && pass "docker exec -u bitcoin bitcoin-cli" || fail "docker exec -u bitcoin bitcoin-cli"
  stop_node "${node}"
fi

section "Restricted mode (like Kubernetes restricted: non-root, read-only root, no capabilities)"
node="${PREFIX}-restricted"
if start_node "${node}" --user 1000:1000 --read-only --cap-drop ALL --security-opt no-new-privileges \
  -v "${PREFIX}-vol:${DATA}" "${IMG}" -regtest; then
  docker exec "${node}" /opt/healthcheck.sh liveness > /dev/null && pass "healthcheck as non-root" || fail "healthcheck as non-root"
  stop_node "${node}"
fi

section "Memory limit warning"
node="${PREFIX}-memory"
if start_node "${node}" --memory 600m --tmpfs "${DATA}" "${IMG}" -regtest -dbcache=1000; then
  docker logs "${node}" 2>&1 | grep -c "container memory limit is 600 MiB" > /dev/null && pass "warns about -dbcache above the memory limit" || fail "warns about -dbcache above the memory limit"
  stop_node "${node}"
fi

echo ""
if [ "${FAILURES}" -eq 0 ]; then
  echo "All smoke tests passed."
else
  echo "${FAILURES} smoke test(s) FAILED."
  exit 1
fi
