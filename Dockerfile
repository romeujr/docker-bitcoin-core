# syntax=docker/dockerfile:1
#
# romeujr/bitcoin-core
# Bitcoin Core (bitcoind) in a Docker container.
#
#   Docker Hub: https://hub.docker.com/r/romeujr/bitcoin-core
#   GitHub:     https://github.com/romeujr/docker-bitcoin-core
#
# This Dockerfile is intentionally self-contained: it needs no other file to be
# built, and everything happens in a single RUN instruction (a single layer), so
# it is easy to read, audit, copy and customize.
#
# Build (any platform supported by Bitcoin Core release binaries):
#
#   docker buildx build --build-arg P_BITCOIN_VERSION=30.0 -t bitcoin-core:30.0 .
#
# Build arguments:
#   P_BITCOIN_VERSION  (required) Bitcoin Core version, e.g. 30.0, 29.1, 24.0.1
#   P_TARGETPLATFORM   (optional) linux/amd64 | linux/arm64 | linux/arm/v7 |
#                      linux/ppc64le | linux/riscv64. Defaults to the platform
#                      being built (BuildKit's TARGETPLATFORM).
#   P_MIN_SIGNATURES   (optional) Minimum number of valid builder signatures
#                      required on SHA256SUMS (default: 3).
#
# NOTE: there is deliberately NO "VOLUME" instruction. A VOLUME would silently
# create an anonymous volume, defeating the entrypoint check that refuses to run
# bitcoind unless the data directory is explicitly mounted from the host.

FROM debian:trixie-slim

ARG TARGETPLATFORM
ARG P_TARGETPLATFORM
ARG P_BITCOIN_VERSION
ARG P_MIN_SIGNATURES=3

LABEL org.opencontainers.image.title="bitcoin-core" \
      org.opencontainers.image.description="Bitcoin Core (bitcoind) with GPG-verified release binaries, configurable UID/GID, mandatory persistent data directory and graceful shutdown." \
      org.opencontainers.image.version="${P_BITCOIN_VERSION}" \
      org.opencontainers.image.url="https://hub.docker.com/r/romeujr/bitcoin-core" \
      org.opencontainers.image.source="https://github.com/romeujr/docker-bitcoin-core" \
      org.opencontainers.image.documentation="https://github.com/romeujr/docker-bitcoin-core#readme" \
      org.opencontainers.image.base.name="docker.io/library/debian:trixie-slim"

ENV B_UID=1000 \
    B_GID=1000 \
    B_ALLOW_EPHEMERAL_DATA=false \
    BITCOIN_DATA=/home/bitcoin/.bitcoin \
    BITCOIN_VERSION=${P_BITCOIN_VERSION} \
    DEBIAN_FRONTEND=noninteractive \
    PATH=/opt/bitcoin/bin:${PATH}

RUN <<'EOF'
#!/bin/bash
set -euo pipefail

# --------------------------------------------------------------------------
# 1. Validate build arguments and map the Docker platform to the Bitcoin Core
#    release archive name.
# --------------------------------------------------------------------------
if [ -z "${P_BITCOIN_VERSION:-}" ]; then
  echo "ERROR: build argument P_BITCOIN_VERSION is required, e.g. --build-arg P_BITCOIN_VERSION=30.0" >&2
  exit 1
fi

PLATFORM="${P_TARGETPLATFORM:-${TARGETPLATFORM:-}}"
case "${PLATFORM}" in
  linux/amd64)              ARCH=x86_64-linux-gnu ;;
  linux/arm64|linux/arm64/*) ARCH=aarch64-linux-gnu ;;
  linux/arm/v7|linux/arm)   ARCH=arm-linux-gnueabihf ;;
  linux/ppc64le)            ARCH=powerpc64le-linux-gnu ;;
  linux/riscv64)            ARCH=riscv64-linux-gnu ;;
  *) echo "ERROR: unsupported platform '${PLATFORM}'." >&2; exit 1 ;;
esac

# --------------------------------------------------------------------------
# 2. Unprivileged "bitcoin" user (UID/GID can be remapped at runtime through
#    B_UID / B_GID, see the entrypoint below).
# --------------------------------------------------------------------------
useradd --create-home --no-log-init --uid 1000 --user-group --shell /bin/bash bitcoin
install -d -m 0700 -o bitcoin -g bitcoin "${BITCOIN_DATA}"

# --------------------------------------------------------------------------
# 3. Packages. curl and ca-certificates stay in the image (handy for
#    -blocknotify / -walletnotify scripts); gpg is only needed during the build.
# --------------------------------------------------------------------------
SAVED_APT_MARK="$(apt-mark showmanual)"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gpg

# --------------------------------------------------------------------------
# 4. Download the official release and verify it:
#    - SHA256SUMS must carry at least P_MIN_SIGNATURES valid signatures from
#      the Bitcoin Core builder keys (github.com/bitcoin-core/guix.sigs);
#    - the archive must match its checksum in SHA256SUMS.
# --------------------------------------------------------------------------
WORK="$(mktemp -d)"
cd "${WORK}"

BASE_URL="https://bitcoincore.org/bin/bitcoin-core-${P_BITCOIN_VERSION}"
ARCHIVE="bitcoin-${P_BITCOIN_VERSION}-${ARCH}.tar.gz"

curl -fsSL --remote-name-all "${BASE_URL}/${ARCHIVE}" "${BASE_URL}/SHA256SUMS" "${BASE_URL}/SHA256SUMS.asc"
curl -fsSL https://github.com/bitcoin-core/guix.sigs/archive/refs/heads/main.tar.gz \
  | tar -xz --wildcards --strip-components=1 '*/builder-keys/*'

export GNUPGHOME="${WORK}/gnupg"
install -d -m 0700 "${GNUPGHOME}"
gpg --batch --quiet --import builder-keys/*.gpg 2>/dev/null || true

gpg --batch --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS > gpg-status.txt 2>/dev/null || true
if grep -q '^\[GNUPG:\] BADSIG ' gpg-status.txt; then
  echo "ERROR: SHA256SUMS.asc contains an invalid signature." >&2
  cat gpg-status.txt >&2
  exit 1
fi
GOOD_SIGNATURES="$(grep -cE '^\[GNUPG:\] (GOODSIG|EXPKEYSIG) ' gpg-status.txt || true)"
echo "Valid builder signatures on SHA256SUMS: ${GOOD_SIGNATURES}"
grep -E '^\[GNUPG:\] (GOODSIG|EXPKEYSIG) ' gpg-status.txt | cut -d' ' -f4- | sed 's/^/  - /' || true
if [ "${GOOD_SIGNATURES}" -lt "${P_MIN_SIGNATURES}" ]; then
  echo "ERROR: expected at least ${P_MIN_SIGNATURES} valid signatures, found ${GOOD_SIGNATURES}." >&2
  exit 1
fi

awk -v f="${ARCHIVE}" '$2 == f || $2 == "*" f' SHA256SUMS > archive.sha256
if [ ! -s archive.sha256 ]; then
  echo "ERROR: ${ARCHIVE} is not listed in SHA256SUMS." >&2
  exit 1
fi
sha256sum -c archive.sha256

# --------------------------------------------------------------------------
# 5. Install under /opt/bitcoin (no GUI, no test binaries).
# --------------------------------------------------------------------------
tar -xzf "${ARCHIVE}" -C /opt
ln -s "/opt/bitcoin-${P_BITCOIN_VERSION}" /opt/bitcoin
rm -f /opt/bitcoin/bin/bitcoin-qt /opt/bitcoin/bin/test_bitcoin /opt/bitcoin/bin/test_bitcoin-qt \
      /opt/bitcoin/libexec/bitcoin-gui /opt/bitcoin/libexec/test_bitcoin \
      /opt/bitcoin/share/man/man1/bitcoin-qt.1
bitcoind -version | sed -n 1p

# --------------------------------------------------------------------------
# 6. Entrypoint.
# --------------------------------------------------------------------------
cat > /opt/entry-point.sh <<'SCRIPT'
#!/bin/bash
#
# Entrypoint of the romeujr/bitcoin-core image.
# https://github.com/romeujr/docker-bitcoin-core
#
# - Arguments starting with "-" (or no arguments at all) are passed to bitcoind.
#   bitcoin-cli, bitcoin-tx, bitcoin-util, bitcoin-wallet and bitcoin can also be
#   used as the command; anything else (e.g. bash) is executed as is.
# - Remaps the "bitcoin" user to B_UID / B_GID, so files written to a bind mount
#   belong to a real user of the host.
# - Refuses to start bitcoind unless its data directory is on a volume or bind
#   mount, so the blockchain and wallets never live only in the container layer.
# - Replaces itself with bitcoind ("exec"): bitcoind runs as PID 1 and receives
#   the SIGTERM sent by "docker stop" directly, then shuts down cleanly (flushes
#   its caches to disk and closes its databases).

set -euo pipefail

readonly DEFAULT_DATA=/home/bitcoin/.bitcoin
readonly REPO_URL=https://github.com/romeujr/docker-bitcoin-core
readonly HUB_URL=https://hub.docker.com/r/romeujr/bitcoin-core
readonly IMAGE=romeujr/bitcoin-core

B_UID="${B_UID:-1000}"
B_GID="${B_GID:-1000}"
BITCOIN_DATA="${BITCOIN_DATA:-${DEFAULT_DATA}}"
B_ALLOW_EPHEMERAL_DATA="${B_ALLOW_EPHEMERAL_DATA:-false}"

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] WARNING: $*" >&2; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

is_true() { case "${1,,}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }

# True when the directory, or one of its parents (except "/"), is a mount point.
is_persisted() {
  local dir="$1"
  while [ -n "${dir}" ] && [ "${dir}" != "/" ]; do
    if awk -v d="${dir}" '$5 == d { found = 1 } END { exit !found }' /proc/self/mountinfo; then
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  return 1
}

no_volume_error() {
  cat >&2 <<MSG

[entrypoint] ERROR: the data directory "$1" is not on a Docker volume or bind mount.

  bitcoind will NOT start: the blockchain, the wallets and all node state would
  be written to the container's writable layer and lost with the container.

  Bind mount a host directory:
    docker run -d --name bitcoind -v /path/on/host:$1 ${IMAGE}:${BITCOIN_VERSION:-latest} [bitcoind options]

  Or use a named volume:
    docker run -d --name bitcoind -v bitcoin-data:$1 ${IMAGE}:${BITCOIN_VERSION:-latest} [bitcoind options]

  For throwaway nodes only (e.g. -regtest in CI), opt out explicitly with:
    -e B_ALLOW_EPHEMERAL_DATA=true

  Image documentation:   ${REPO_URL}
                         ${HUB_URL}
  Docker run reference:  https://docs.docker.com/reference/cli/docker/container/run/
  Bitcoin Core options:  run this image with -help (add -help-debug for more)
  Release notes:         https://github.com/bitcoin/bitcoin/blob/master/doc/release-notes/release-notes-${BITCOIN_VERSION:-}.md

MSG
  exit 1
}

# ---------------------------------------------------------------------------
# What to run
# ---------------------------------------------------------------------------
if [ $# -eq 0 ] || [ "${1:0:1}" = "-" ]; then
  set -- bitcoind "$@"
fi

run_node=false
help_only=false
datadir_arg=""
case "$1" in
  bitcoind) run_node=true ;;
  bitcoin)  for arg in "${@:2}"; do [ "${arg}" = "node" ] && run_node=true; done ;;
esac

if ${run_node}; then
  for arg in "${@:2}"; do
    case "${arg}" in
      -\?|-h|-help|--help|-help=1|--help=1|-version|--version|-version=1|--version=1)
        help_only=true ;;
      -datadir=*|--datadir=*)
        datadir_arg="${arg#*=}" ;;
      -daemon|--daemon|-daemon=[1-9]*|--daemon=[1-9]*|-daemonwait|--daemonwait|-daemonwait=[1-9]*|--daemonwait=[1-9]*)
        die "\"${arg}\" is not supported in a container: bitcoind must stay in the foreground (it is the container's main process)." ;;
    esac
  done
fi

# ---------------------------------------------------------------------------
# User / group
# ---------------------------------------------------------------------------
run_as=()
if [ "$(id -u)" = "0" ]; then
  [[ "${B_UID}" =~ ^[0-9]+$ ]] || die "B_UID must be a numeric user id (got \"${B_UID}\")."
  [[ "${B_GID}" =~ ^[0-9]+$ ]] || die "B_GID must be a numeric group id (got \"${B_GID}\")."
  [ "${B_UID}" -ne 0 ] || die "running Bitcoin Core as root (B_UID=0) is not supported."

  if [ "$(id -u bitcoin)" != "${B_UID}" ] || [ "$(id -g bitcoin)" != "${B_GID}" ]; then
    # Edit passwd/group directly instead of usermod/groupmod: usermod would
    # recursively chown the home directory (including a mounted data directory
    # with hundreds of GB), and groupmod refuses GIDs already in use (e.g. 100).
    if sed -i -E "s/^bitcoin:([^:]*):[0-9]+:[0-9]+:/bitcoin:\1:${B_UID}:${B_GID}:/" /etc/passwd \
      && sed -i -E "s/^bitcoin:([^:]*):[0-9]+:/bitcoin:\1:${B_GID}:/" /etc/group; then
      chown "${B_UID}:${B_GID}" /home/bitcoin
      find /home/bitcoin -mindepth 1 -maxdepth 1 -type f -exec chown "${B_UID}:${B_GID}" {} +
    else
      warn "could not update /etc/passwd (read-only root filesystem?); continuing with uid=${B_UID} gid=${B_GID}."
    fi
  fi

  export HOME=/home/bitcoin USER=bitcoin LOGNAME=bitcoin
  run_as=(setpriv --reuid="${B_UID}" --regid="${B_GID}" --clear-groups)
else
  # Started with "docker run --user": run as that user, no remapping possible.
  B_UID="$(id -u)"
  B_GID="$(id -g)"
fi

# ---------------------------------------------------------------------------
# Tools and arbitrary commands
# ---------------------------------------------------------------------------
if ! ${run_node} || ${help_only}; then
  case "$1" in
    bitcoind|bitcoin|bitcoin-cli|bitcoin-tx|bitcoin-util|bitcoin-wallet) exec "${run_as[@]}" "$@" ;;
    *) exec "$@" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Node: data directory checks
# ---------------------------------------------------------------------------
DATA_DIR="$(realpath -m "${datadir_arg:-${BITCOIN_DATA}}")"

if ! is_persisted "${DATA_DIR}"; then
  if is_true "${B_ALLOW_EPHEMERAL_DATA}"; then
    warn "${DATA_DIR} is not on a volume (B_ALLOW_EPHEMERAL_DATA=${B_ALLOW_EPHEMERAL_DATA}): ALL DATA WILL BE LOST when the container is removed."
  else
    no_volume_error "${DATA_DIR}"
  fi
fi

if [ ! -d "${DATA_DIR}" ]; then
  "${run_as[@]}" mkdir -p "${DATA_DIR}" 2>/dev/null \
    || { [ "$(id -u)" = "0" ] && mkdir -p "${DATA_DIR}" && chown "${B_UID}:${B_GID}" "${DATA_DIR}"; } \
    || die "cannot create the data directory ${DATA_DIR}."
fi

if ! "${run_as[@]}" test -w "${DATA_DIR}" -a -x "${DATA_DIR}"; then
  if [ "$(id -u)" = "0" ] && [ -z "$(ls -A "${DATA_DIR}")" ]; then
    # Typically a host directory just created by Docker (owned by root).
    chown "${B_UID}:${B_GID}" "${DATA_DIR}"
    log "${DATA_DIR} was empty and not writable: its owner was set to ${B_UID}:${B_GID}."
  else
    die "the data directory ${DATA_DIR} (owner $(stat -c '%u:%g' "${DATA_DIR}"), mode $(stat -c '%a' "${DATA_DIR}")) is not writable by uid=${B_UID} gid=${B_GID}.
  Either run the container with the owner's ids:  -e B_UID=<uid> -e B_GID=<gid>  (or --user <uid>:<gid>)
  or change the owner on the host:                 sudo chown -R ${B_UID}:${B_GID} /path/on/host"
  fi
fi

DATA_OWNER="$(stat -c '%u:%g' "${DATA_DIR}")"
if [ "${DATA_OWNER}" != "${B_UID}:${B_GID}" ]; then
  warn "${DATA_DIR} is owned by ${DATA_OWNER}, but bitcoind runs as ${B_UID}:${B_GID}. Consider -e B_UID=${DATA_OWNER%:*} -e B_GID=${DATA_OWNER#*:}."
fi

if [ -r "${DATA_DIR}/bitcoin.conf" ] \
  && grep -qE '^[[:space:]]*daemon(wait)?[[:space:]]*=[[:space:]]*[1-9]' "${DATA_DIR}/bitcoin.conf"; then
  die "${DATA_DIR}/bitcoin.conf sets daemon=1, which is not supported in a container: remove that line."
fi

# Always tell bitcoind which directory was checked above.
if [ -z "${datadir_arg}" ]; then
  if [ "$1" = "bitcoind" ]; then
    set -- bitcoind "-datadir=${DATA_DIR}" "${@:2}"
  else
    set -- "$@" "-datadir=${DATA_DIR}"
  fi
fi

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
shown=()
for arg in "$@"; do
  case "${arg}" in
    -rpcpassword=*|--rpcpassword=*) shown+=("${arg%%=*}=******") ;;
    *) shown+=("${arg}") ;;
  esac
done

log "Bitcoin Core ${BITCOIN_VERSION:-} - ${REPO_URL}"
log "User:           uid=${B_UID} gid=${B_GID}"
log "Data directory: ${DATA_DIR}"
log "Command:        ${shown[*]}"
log "Stop it gracefully with enough time to flush its caches, e.g.: docker stop -t 600 <container>"
echo ""

exec "${run_as[@]}" "$@"
SCRIPT
chmod 0755 /opt/entry-point.sh
bash -n /opt/entry-point.sh

# --------------------------------------------------------------------------
# 7. Clean up: drop build-only packages, apt lists and temporary files.
# --------------------------------------------------------------------------
cd /
apt-mark auto '.*' > /dev/null
apt-mark manual ${SAVED_APT_MARK} ca-certificates curl > /dev/null
apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false
apt-get clean
rm -rf /var/lib/apt/lists/* "${WORK}" /tmp/* /var/tmp/* /root/.gnupg
EOF

# Mainnet, testnet3, testnet4, signet and regtest (RPC and P2P).
EXPOSE 8332 8333 18332 18333 48332 48333 38332 38333 18443 18444

# bitcoind handles SIGTERM by shutting down cleanly. Give it time with
# "docker stop -t 600" or "stop_grace_period: 10m" (Docker Compose).
STOPSIGNAL SIGTERM

ENTRYPOINT ["/opt/entry-point.sh"]
