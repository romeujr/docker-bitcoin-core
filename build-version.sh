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
#
# Requirements: docker buildx, git, QEMU for foreign platforms (see _setup.txt),
# and "docker login" to every registry in IMAGES.
#
# Tags produced for each repository:
#   <version>          multi-platform index (+ SBOM and provenance)
#   <version>-<arch>   one per platform (e.g. 32.1-amd64, 32.1-arm64)
#   latest             with --latest

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: $0 <version> [--latest]}"
LATEST=false
[ "${2:-}" = "--latest" ] && LATEST=true

IMAGES="${IMAGES:-docker.io/romeujr/bitcoin-core}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER="${BUILDER:-bitcoin-core-builder}"
SIGN="${SIGN:-false}"

step() { echo ""; echo "==> $*"; }

index_digest() {
  docker buildx --builder "${BUILDER}" imagetools inspect "$1" | awk '/^Digest:/ { print $2; exit }'
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

tags=()
for image in ${IMAGES}; do
  tags+=(--tag "${image}:${VERSION}")
done

step "Building Bitcoin Core ${VERSION} for ${PLATFORMS} (guix.sigs ${GUIX_SIGS_REF})"
docker buildx build \
  --builder "${BUILDER}" \
  --platform "${PLATFORMS}" \
  --build-arg P_BITCOIN_VERSION="${VERSION}" \
  --build-arg P_GUIX_SIGS_REF="${GUIX_SIGS_REF}" \
  --build-arg P_REVISION="${REVISION}" \
  --sbom=true \
  --provenance=mode=max \
  --pull \
  --push \
  "${tags[@]}" \
  .

published=()
for image in ${IMAGES}; do
  step "Tagging ${image}"
  published+=("${image}:${VERSION}")

  for platform in ${PLATFORMS//,/ }; do
    arch="${platform#*/}"
    arch="${arch%%/*}"
    digest="$(platform_digest "${image}:${VERSION}" "${arch}")"
    if [ -z "${digest}" ]; then
      echo "ERROR: no ${platform} image found in ${image}:${VERSION}." >&2
      exit 1
    fi
    docker buildx --builder "${BUILDER}" imagetools create --tag "${image}:${VERSION}-${arch}" "${image}@${digest}"
    published+=("${image}:${VERSION}-${arch}")
  done

  if ${LATEST}; then
    docker buildx --builder "${BUILDER}" imagetools create --tag "${image}:latest" "${image}:${VERSION}"
    published+=("${image}:latest")
  fi
done

if [ "${SIGN}" = "true" ]; then
  step "Signing with cosign"
  for ref in "${published[@]}"; do
    cosign sign --yes --recursive "${ref%:*}@$(index_digest "${ref}")"
  done
fi

step "Published"
for ref in "${published[@]}"; do
  echo "  ${ref}  $(index_digest "${ref}")"
done
