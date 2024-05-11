FROM debian:bookworm-slim

ARG P_UID=101
ARG P_GID=101
ARG P_TARGETPLATFORM
ARG P_BITCOIN_VERSION

ENV DEBIAN_FRONTEND=noninteractive
ENV BITCOIN_DATA=/home/bitcoin/.bitcoin

RUN groupadd --gid ${P_GID} bitcoin && \
    useradd --create-home --no-log-init -u ${P_UID} -g ${P_GID} bitcoin && \
    apt update -y && \
    apt install -y curl && \
    apt clean && \
    if [ "${P_TARGETPLATFORM}" = "linux/amd64" ]; then export TARGETPLATFORM=x86_64-linux-gnu; fi && \
    if [ "${P_TARGETPLATFORM}" = "linux/arm64" ]; then export TARGETPLATFORM=aarch64-linux-gnu; fi && \
    curl -SLO https://bitcoincore.org/bin/bitcoin-core-${P_BITCOIN_VERSION}/bitcoin-${P_BITCOIN_VERSION}-${TARGETPLATFORM}.tar.gz && \
    tar -xzf *.tar.gz -C /opt && \
    rm *.tar.gz && \
    rm -rf /tmp/* /var/tmp/* && \
    rm -rf /opt/bitcoin-${P_BITCOIN_VERSION}/bin/bitcoin-qt && \
    ln -s /opt/bitcoin-${P_BITCOIN_VERSION} /opt/bitcoin && \
    echo '#!/bin/bash' >> /opt/entry-point.sh && \
    echo '' >> /opt/entry-point.sh && \
    echo 'if ! grep -qs " $BITCOIN_DATA " /proc/mounts; then' >> /opt/entry-point.sh && \
    echo '  echo ""' >> /opt/entry-point.sh && \
    echo '  echo "Error: Mounting point not found \"$BITCOIN_DATA\"."' >> /opt/entry-point.sh && \
    echo '  echo "Try: docker run <YOUR_DOCKER_OPTIONS> -v <HOST_DATA_DIRECTORY>:$BITCOIN_DATA <THIS_IMAGE_NAME>"' >> /opt/entry-point.sh && \
    echo '  echo ""' >> /opt/entry-point.sh && \
    echo '  exit -1' >> /opt/entry-point.sh && \
    echo 'fi' >> /opt/entry-point.sh && \
    echo '' >> /opt/entry-point.sh && \
    echo 'su - bitcoin -c "/opt/bitcoin/bin/bitcoind $*"' >> /opt/entry-point.sh && \
    chmod 744 /opt/entry-point.sh

ENTRYPOINT ["/opt/entry-point.sh"]
