#!/bin/bash
#
# Lists the Bitcoin Core versions published by this project (versions.txt).
#
# Usage: ./versions.sh [all|latest|oldest|supported] [--json]
#
#   all        every version (default)
#   latest     the newest version (the "latest" tag)
#   oldest     the oldest version (tested by CI, to catch incompatibilities)
#   supported  the newest release of each of the SUPPORTED_MAJORS (default 3)
#              newest major versions: rebuilt monthly for base image updates
#   --json     print a JSON array (for GitHub Actions matrices)

set -euo pipefail
cd "$(dirname "$0")"

mode="${1:-all}"
json=false
[ "${2:-}" = "--json" ] && json=true

mapfile -t all < <(sed -E 's/#.*//; s/[[:space:]]//g; /^$/d' versions.txt | sort -V -u)

case "${mode}" in
  all)
    list=("${all[@]}") ;;
  latest)
    list=("${all[-1]}") ;;
  oldest)
    list=("${all[0]}") ;;
  supported)
    list=()
    while read -r major; do
      list+=("$(printf '%s\n' "${all[@]}" | grep -E "^${major}\." | sort -V | tail -n 1)")
    done < <(printf '%s\n' "${all[@]}" | cut -d. -f1 | sort -n -u | tail -n "${SUPPORTED_MAJORS:-3}" | sort -rn)
    ;;
  *)
    echo "usage: $0 [all|latest|oldest|supported] [--json]" >&2
    exit 2 ;;
esac

if ${json}; then
  printf '['
  sep=""
  for version in "${list[@]}"; do
    printf '%s"%s"' "${sep}" "${version}"
    sep=","
  done
  printf ']\n'
else
  printf '%s\n' "${list[@]}"
fi
