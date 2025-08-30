FROM debian:trixie-slim

ARG P_TARGETPLATFORM
ARG P_BITCOIN_VERSION

ENV B_UID=1000
ENV B_GID=1000
ENV DEBIAN_FRONTEND=noninteractive
ENV BITCOIN_DATA=/home/bitcoin/.bitcoin

RUN useradd --create-home --no-log-init bitcoin && \
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
    echo 'echo ""' >> /opt/entry-point.sh && \
    echo 'if [ "$(id -u bitcoin)" -ne "${B_UID}" ]; then' >> /opt/entry-point.sh && \
    echo '  usermod -u ${B_UID} bitcoin' >> /opt/entry-point.sh && \
    echo 'fi' >> /opt/entry-point.sh && \
    echo '' >> /opt/entry-point.sh && \
    echo 'if [ "$(id -g bitcoin)" -ne "${B_GID}" ]; then' >> /opt/entry-point.sh && \
    echo '  groupmod -g ${B_GID} bitcoin' >> /opt/entry-point.sh && \
    echo 'fi' >> /opt/entry-point.sh && \
    echo '' >> /opt/entry-point.sh && \
    echo 'su - bitcoin -c "id"' >> /opt/entry-point.sh && \
    echo 'echo ""' >> /opt/entry-point.sh && \
    echo '' >> /opt/entry-point.sh && \
    echo 'if ! grep -qs " $BITCOIN_DATA " /proc/mounts; then' >> /opt/entry-point.sh && \
    echo '  echo "Error: Mounting point not found \"$BITCOIN_DATA\"."' >> /opt/entry-point.sh && \
    echo '  echo "Try: docker run <YOUR_DOCKER_OPTIONS> -v <HOST_DATA_DIRECTORY>:$BITCOIN_DATA <THIS_IMAGE_NAME_AND_TAG> <YOUR_BITCOIN_CORE_COMMAND_OPTIONS>"' >> /opt/entry-point.sh && \
    echo '  echo ""' >> /opt/entry-point.sh && \
    echo '  echo "For more information about this docker image:"' >> /opt/entry-point.sh && \
    echo '  echo "https://hub.docker.com/r/romeujr/bitcoin-core"' >> /opt/entry-point.sh && \
    echo '  echo "https://github.com/romeujr/docker-bitcoin-core"' >> /opt/entry-point.sh && \
    echo '  echo ""' >> /opt/entry-point.sh && \
    echo '  echo "For more information about the '"'docker run'"' command:"' >> /opt/entry-point.sh && \
    echo '  echo "https://docs.docker.com/engine/reference/run/"' >> /opt/entry-point.sh && \
    echo '  echo "https://docs.docker.com/engine/reference/commandline/run"' >> /opt/entry-point.sh && \
    echo '  echo ""' >> /opt/entry-point.sh && \
    echo '  echo "For more information about Bitcoin Core command options:"' >> /opt/entry-point.sh && \
    echo '  echo "https://man.archlinux.org/man/extra/bitcoin-daemon/bitcoind.1.en"' >> /opt/entry-point.sh && \
    echo '  echo "You can also get help directly by using '"'-help'"' or '"'-help-debug'"' in your Bitcoin Core command options."' >> /opt/entry-point.sh && \
    echo '  echo ""' >> /opt/entry-point.sh && \
    echo '  echo "For more information about Bitcoin Core release notes:"' >> /opt/entry-point.sh && \
    echo '  echo "https://github.com/bitcoin/bitcoin/tree/master/doc/release-notes"' >> /opt/entry-point.sh && \
    echo '  echo "https://github.com/bitcoin/bitcoin/blob/master/doc/release-notes/release-notes-'${P_BITCOIN_VERSION}'.md"' >> /opt/entry-point.sh && \
    echo '  echo ""' >> /opt/entry-point.sh && \
    echo '  exit -1' >> /opt/entry-point.sh && \
    echo 'fi' >> /opt/entry-point.sh && \
    echo '' >> /opt/entry-point.sh && \
    echo 'su - bitcoin -c "echo '\'Parameters:\'' && echo $* && echo '\'\'' && /opt/bitcoin/bin/bitcoind $*"' >> /opt/entry-point.sh && \
    chmod 744 /opt/entry-point.sh

ENTRYPOINT ["/opt/entry-point.sh"]
