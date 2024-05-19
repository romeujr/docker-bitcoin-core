#!/bin/bash

VERSION=$1

set +e

echo ""
echo "Clean old images for version $VERSION."
docker image rm romeujr/bitcoin-core:$VERSION-amd64
docker image rm romeujr/bitcoin-core:$VERSION-arm64
echo "y" | docker builder prune

set -e

echo ""
echo "Build version $VERSION for amd64..."
docker buildx build --platform linux/amd64 --build-arg P_TARGETPLATFORM="linux/amd64" --build-arg P_BITCOIN_VERSION="$VERSION" -t romeujr/bitcoin-core:$VERSION-amd64 -f Dockerfile .

echo ""
echo "Build version $VERSION for arm64..."
docker buildx build --platform linux/arm64 --build-arg P_TARGETPLATFORM="linux/arm64" --build-arg P_BITCOIN_VERSION="$VERSION" -t romeujr/bitcoin-core:$VERSION-arm64 -f Dockerfile .

echo ""
echo "Push version $VERSION for arm64..."
docker push romeujr/bitcoin-core:$VERSION-arm64

echo ""
echo "Push version $VERSION for amd64..."
docker push romeujr/bitcoin-core:$VERSION-amd64

set +e

echo ""
echo "Clean manifest for version $VERSION."
docker manifest rm romeujr/bitcoin-core:$VERSION

set -e

echo ""
echo "Create manifest for version $VERSION."
docker manifest create romeujr/bitcoin-core:$VERSION romeujr/bitcoin-core:$VERSION-amd64 romeujr/bitcoin-core:$VERSION-arm64

echo ""
echo "Push manifest for version $VERSION."
docker manifest push romeujr/bitcoin-core:$VERSION
