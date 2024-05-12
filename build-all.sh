#!/bin/bash

set -e

VERSIONS=("22.0" "22.1" "23.0" "23.1" "23.2" "24.0" "24.0.1" "24.1" "24.2" "25.0" "25.1" "25.2" "26.0" "26.1" "27.0")

for STRING in "${VERSIONS[@]}"; do
    unset VERSION
    export VERSION="$STRING"
    ./build-version.sh $VERSION
done

echo ""
echo "Clean manifest for latest version."
docker manifest rm romeujr/bitcoin-core:latest

echo ""
echo "Create manifest for latest version."
docker manifest create romeujr/bitcoin-core:latest romeujr/bitcoin-core:$VERSION-amd64 romeujr/bitcoin-core:$VERSION-arm64

echo ""
echo "Push manifest for latest version."
docker manifest push romeujr/bitcoin-core:latest
