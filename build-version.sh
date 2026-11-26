#!/bin/bash
#
# Builds and publishes one Bitcoin Core version as a multi-platform image,
# with SBOM and provenance attestations, and optionally signs it with cosign.
# Used both locally (WSL) and by GitHub Actions (.github/workflows/publish.yml).
#
# Usage: ./build-version.sh <version> [--latest]
#
#   --latest   also point the "latest" tag at this version
#
# Environment:
#   IMAGES        Repositories to publish to, space separated.
#                 Default: "docker.io/romeujr/bitcoin-core"
#                 CI:      "docker.io/romeujr/bitcoin-core ghcr.io/romeujr/bitcoin-core"
#   PLATFORMS     Default: "linux/amd64,linux/arm64"
#   BUILDER       buildx builder to use. Created with the docker-container driver
#                 if it does not exist. Default: "bitcoin-core-builder"
#   BUILDER_OPTS  Extra "docker buildx create" options for a new builder.
#   SIGN          "true" to sign with cosign (keyless in GitHub Actions).
#   RETRIES       Attempts of each registry operation when the registry answers
#                 "429 Too Many Requests", waiting 1, 2, 4, 8... minutes in
#                 between. Default: 7 (1+2+4+8+16+32 = 63 minutes of waiting at
#                 most: more than Docker Hub's hourly window).
#
# Requirements: docker buildx, git, QEMU for foreign platforms (see _setup.txt),
# and "docker login" to every registry in IMAGES.
#
# Tags produced for each repository:
#   <version>          multi-platform index (+ SBOM and provenance)
#   <version>-<arch>   one per platform (e.g. 32.1-amd64, 32.1-arm64)
#   latest             with --latest
#
# Docker Hub limits how many manifests an account may read per hour. To stay
# well below it, digests are never read back from Docker Hub: the index digest
# comes from the build's metadata file, the platform digests are read once from
# another registry when there is one (GHCR in CI), and the digests of the
# "<version>-<arch>" tags from the output of the command that creates them.

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: $0 <version> [--latest]}"
LATEST=false
[ "${2:-}" = "--latest" ] && LATEST=true

IMAGES="${IMAGES:-docker.io/romeujr/bitcoin-core}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER="${BUILDER:-bitcoin-core-builder}"
SIGN="${SIGN:-false}"
RETRIES="${RETRIES:-7}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
LOG="${TMP}/registry.log"

step() { echo ""; echo "==> $*"; }

# Runs a command that talks to registries. When it fails because a registry
# rate limits us (HTTP 429), waits and runs it again. Its output is shown and
# also kept in ${LOG} for the caller.
with_retry() {
  local attempt=1 delay=60
  while true; do
    if "$@" 2>&1 | tee "${LOG}"; then
      return 0
    fi
    if [ "${attempt}" -ge "${RETRIES}" ] || ! grep -qiE 'too ?many ?requests' "${LOG}"; then
      return 1
    fi
    echo ""
    echo "==> Rate limited by the registry: retrying in $((delay / 60)) min (attempt $((attempt + 1)) of ${RETRIES})"
    sleep "${delay}"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# Digest of the image (index or manifest) a reference points to. Not piped into
# "awk ... exit": the reader quitting early killed buildx with SIGPIPE, and
# docker then exited 255 without a message. "{{with}}" is needed: a format
# starting with "{{.Manifest" prints the default text output instead.
read_digest() {
  local digest
  digest="$(docker buildx --builder "${BUILDER}" imagetools inspect "$1" --format '{{with .Manifest}}{{.Digest}}{{end}}')"
  if [ -z "${digest}" ]; then
    echo "ERROR: could not read the digest of $1." >&2
    return 1
  fi
  echo "${digest}"
}

platform_digest() {
  docker buildx --builder "${BUILDER}" imagetools inspect "$1" --format \
    "{{range .Manifest.Manifests}}{{if and (eq .Platform.OS \"linux\") (eq .Platform.Architecture \"$2\")}}{{.Digest}}{{end}}{{end}}"
}

if ! docker buildx inspect "${BUILDER}" > /dev/null 2>&1; then
  step "Creating buildx builder ${BUILDER}"
  # shellcheck disable=SC2086 # BUILDER_OPTS is a list of options
  docker buildx create --name "${BUILDER}" --driver docker-container ${BUILDER_OPTS:-} > /dev/null
fi

GUIX_SIGS_REF="$(git ls-remote https://github.com/bitcoin-core/guix.sigs refs/heads/main | cut -f1 || true)"
GUIX_SIGS_REF="${GUIX_SIGS_REF:-main}"
REVISION="$(git rev-parse HEAD 2> /dev/null || true)"

# Registry to read digests from: the first one that is not Docker Hub, if any.
READ_IMAGE=""
FIRST_IMAGE=""
tags=()
for image in ${IMAGES}; do
  tags+=(--tag "${image}:${VERSION}")
  FIRST_IMAGE="${FIRST_IMAGE:-${image}}"
  case "${image}" in
    docker.io/*|index.docker.io/*|registry-1.docker.io/*) ;;
    *) READ_IMAGE="${READ_IMAGE:-${image}}" ;;
  esac
done
READ_IMAGE="${READ_IMAGE:-${FIRST_IMAGE}}"

step "Building Bitcoin Core ${VERSION} for ${PLATFORMS} (guix.sigs ${GUIX_SIGS_REF})"
with_retry docker buildx build \
  --builder "${BUILDER}" \
  --platform "${PLATFORMS}" \
  --build-arg P_BITCOIN_VERSION="${VERSION}" \
  --build-arg P_GUIX_SIGS_REF="${GUIX_SIGS_REF}" \
  --build-arg P_REVISION="${REVISION}" \
  --sbom=true \
  --provenance=mode=max \
  --metadata-file "${TMP}/metadata.json" \
  --pull \
  --push \
  "${tags[@]}" \
  .

# The same index is pushed to every registry, so it has the same digest everywhere.
INDEX_DIGEST="$(grep -oE '"containerimage.digest": *"sha256:[0-9a-f]{64}"' "${TMP}/metadata.json" | grep -oE 'sha256:[0-9a-f]{64}' || true)"
if [ -z "${INDEX_DIGEST}" ]; then
  echo "ERROR: no image digest in the build metadata." >&2
  exit 1
fi

arches=()
declare -A arch_digest=()
for platform in ${PLATFORMS//,/ }; do
  arch="${platform#*/}"
  arch="${arch%%/*}"
  arches+=("${arch}")
  arch_digest["${arch}"]="$(platform_digest "${READ_IMAGE}@${INDEX_DIGEST}" "${arch}")"
  if [ -z "${arch_digest[${arch}]}" ]; then
    echo "ERROR: no ${platform} image found in ${READ_IMAGE}@${INDEX_DIGEST}." >&2
    exit 1
  fi
done

# "<reference> <digest>" of everything published, and the digests to sign
# ("latest" shares the digest of "<version>" and is signed with it).
published=()
to_sign=()
for image in ${IMAGES}; do
  step "Tagging ${image}"
  published+=("${image}:${VERSION} ${INDEX_DIGEST}")
  to_sign+=("${image}@${INDEX_DIGEST}")

  for arch in "${arches[@]}"; do
    tag="${image}:${VERSION}-${arch}"
    with_retry docker buildx --builder "${BUILDER}" imagetools create --progress plain \
      --tag "${tag}" "${image}@${arch_digest[${arch}]}"
    # The new tag is an index around the platform image and its attestations;
    # its digest differs from one registry to another, so take it from the
    # output ("pushing sha256:... to <tag>") instead of reading it back.
    digest="$(sed -nE 's/.*pushing (sha256:[0-9a-f]{64}) to .*/\1/p' "${LOG}" | tail -n 1)"
    if [ -z "${digest}" ]; then
      digest="$(read_digest "${tag}")"
    fi
    published+=("${tag} ${digest}")
    to_sign+=("${image}@${digest}")
  done

  if ${LATEST}; then
    with_retry docker buildx --builder "${BUILDER}" imagetools create --progress plain \
      --tag "${image}:latest" "${image}@${INDEX_DIGEST}"
    published+=("${image}:latest ${INDEX_DIGEST}")
  fi
done

if [ "${SIGN}" = "true" ]; then
  step "Signing with cosign"
  for target in "${to_sign[@]}"; do
    with_retry cosign sign --yes --recursive "${target}"
  done
fi

step "Published"
for entry in "${published[@]}"; do
  echo "  ${entry% *}  ${entry##* }"
done
