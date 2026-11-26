#!/bin/bash
#
# Publishes the versions listed in versions.txt with ./build-version.sh and
# points "latest" at the newest one.
#
# Usage: ./build-all.sh [all|supported]
#
#   all        every version (default)
#   supported  only the newest release of the 3 newest major versions
#              (what the monthly rebuild in GitHub Actions publishes)
#
# The environment variables of build-version.sh (IMAGES, PLATFORMS, ...) apply.

set -euo pipefail
cd "$(dirname "$0")"

mode="${1:-all}"
latest="$(bash ./versions.sh latest)"

for version in $(bash ./versions.sh "${mode}"); do
  if [ "${version}" = "${latest}" ]; then
    bash ./build-version.sh "${version}" --latest
  else
    bash ./build-version.sh "${version}"
  fi
done
