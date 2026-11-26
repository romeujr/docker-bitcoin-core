# Bitcoin Core in Docker

Run **[Bitcoin Core](https://bitcoincore.org)** (`bitcoind`) in an isolated, reproducible container, with the **official release binaries** and **every release since 22.0**, on `linux/amd64` and `linux/arm64` (Raspberry Pi 4/5, Apple Silicon, AWS Graviton).

> 📖 **Full documentation, examples and guides are on GitHub: https://github.com/romeujr/docker-bitcoin-core**
>
> This page is a summary. On GitHub you will also find configuration recipes (pruning, indexes, RPC, ZMQ, Tor, test networks), a [Kubernetes and cloud guide](https://github.com/romeujr/docker-bitcoin-core/blob/main/docs/kubernetes.md), ready-to-use [Docker Compose, `bitcoin.conf` and Kubernetes examples](https://github.com/romeujr/docker-bitcoin-core/tree/main/examples), how to build and verify the image, and the changelog. Questions and suggestions: [GitHub issues](https://github.com/romeujr/docker-bitcoin-core/issues).

## Why this image

- **Verified binaries:** downloaded from bitcoincore.org; the build fails unless `SHA256SUMS` has at least 3 valid signatures from the Bitcoin Core builder keys and the archive matches its checksum.
- **Your data is protected:** `bitcoind` refuses to start unless its data directory is a bind mount or a named volume. Anonymous volumes, in-memory filesystems and Kubernetes `emptyDir` are refused too (except for `-regtest`).
- **Clean shutdown:** `bitcoind` runs as PID 1 and receives `docker stop`'s `SIGTERM` directly, so it flushes its caches. No corrupted chainstate.
- **Runs as your host user** (`B_UID` / `B_GID`), never as root. Kubernetes *restricted* compatible.
- **Signed** (cosign), with **SBOM and provenance**; supported versions **rebuilt monthly** for security updates; tested on amd64 and arm64.
- **Plain Bitcoin Core:** every `bitcoind` option works as documented.

## Quick start

```bash
docker run -d --name bitcoind \
  --restart unless-stopped \
  --stop-timeout 600 \
  -e B_UID=$(id -u) -e B_GID=$(id -g) \
  -v /srv/bitcoin:/home/bitcoin/.bitcoin \
  -p 8333:8333 \
  romeujr/bitcoin-core:latest

docker logs -f bitcoind                                  # logs
docker exec -u bitcoin bitcoind bitcoin-cli -getinfo     # talk to the node
docker stop -t 600 bitcoind                              # clean stop
```

Arguments after the image name go to `bitcoind` (e.g. `... romeujr/bitcoin-core:latest -prune=10000 -dbcache=2048`). See every option with `docker run --rm romeujr/bitcoin-core -help`.

> Pin a version in production (`romeujr/bitcoin-core:32.1`) and upgrade after reading the [release notes](https://github.com/bitcoin/bitcoin/tree/master/doc/release-notes).

## Tags and registries

| Tag | Description |
|---|---|
| `<version>` (e.g. `32.1`, `24.0.1`) | Multi-arch image for that release. |
| `<version>-amd64`, `<version>-arm64` | Single-architecture images. |
| `latest` | Newest release. |

Also on GHCR (no Docker Hub rate limits): `ghcr.io/romeujr/bitcoin-core:<tag>`. The newest release of the three newest major versions is rebuilt monthly; older tags are frozen. [Details](https://github.com/romeujr/docker-bitcoin-core#tags-registries-and-supported-versions).

## Data directory (mandatory mount)

Mount `/home/bitcoin/.bitcoin` (blocks, chainstate, wallets, `bitcoin.conf`, `.cookie`):

```bash
-v /srv/bitcoin:/home/bitcoin/.bitcoin      # host directory
-v bitcoin-data:/home/bitcoin/.bitcoin      # or a named volume
```

The container stops with a clear error when the data would be lost or fill your disk unnoticed: no mount, anonymous volume, `--tmpfs` (allowed only with `-regtest`), read-only mount, or a directory `bitcoind` cannot write to. Throwaway regtest node: `docker run --rm --tmpfs /home/bitcoin/.bitcoin romeujr/bitcoin-core -regtest`. [Details](https://github.com/romeujr/docker-bitcoin-core#persistent-data-mandatory).

## Host user: `B_UID` / `B_GID`

`bitcoind` runs as `1000:1000` by default. Set `-e B_UID=$(id -u) -e B_GID=$(id -g)` (or the owner of existing data: `stat -c '%u %g' /srv/bitcoin`) so files on the host belong to a real user, for backups and host-side tools. Nothing is chowned recursively. [Details](https://github.com/romeujr/docker-bitcoin-core#running-as-your-host-user-b_uid--b_gid).

## Clean shutdown: give it time

Docker waits only **10 seconds** by default before killing a container; flushing `-dbcache` can take minutes. Use `--stop-timeout 600` (or `docker stop -t 600`; Compose: `stop_grace_period: 10m`; Kubernetes: `terminationGracePeriodSeconds: 600`). Never `docker kill` / `docker rm -f` a running node. `-daemon` is refused.

## Docker Compose

```yaml
services:
  bitcoind:
    image: romeujr/bitcoin-core:32.1
    restart: unless-stopped
    stop_grace_period: 10m
    environment:
      B_UID: "1000"
      B_GID: "1000"
    volumes:
      - ./data:/home/bitcoin/.bitcoin
    ports:
      - "8333:8333"                # P2P
      - "127.0.0.1:8332:8332"      # RPC, host only
    command: [-server=1, -rpcbind=0.0.0.0, -rpcallowip=172.16.0.0/12, -dbcache=2048]
    healthcheck:
      test: ["CMD", "/opt/healthcheck.sh"]
      interval: 1m
      timeout: 20s
      start_period: 10m
```

[Complete example](https://github.com/romeujr/docker-bitcoin-core/blob/main/examples/docker-compose.yml) · [`bitcoin.conf` example](https://github.com/romeujr/docker-bitcoin-core/blob/main/examples/bitcoin.conf) · [Configuration recipes](https://github.com/romeujr/docker-bitcoin-core#recipes)

## Health checks, memory, Kubernetes

- `/opt/healthcheck.sh [liveness|readiness]`: works on any network without arguments; `readiness` waits for the initial sync. Not enabled by default.
- The memory limit must fit `dbcache + maxmempool + ~512 MiB`, or `bitcoind` is OOM-killed (an unclean shutdown). The entrypoint warns when it does not.
- Kubernetes: use a PersistentVolumeClaim, `terminationGracePeriodSeconds: 600`, `runAsUser`/`fsGroup`, probes with the script above. See the [Kubernetes and cloud guide](https://github.com/romeujr/docker-bitcoin-core/blob/main/docs/kubernetes.md) and the [StatefulSet example](https://github.com/romeujr/docker-bitcoin-core/blob/main/examples/kubernetes/bitcoind.yaml).

## Reference

| Environment variable | Default | Description |
|---|---|---|
| `B_UID` / `B_GID` | `1000` | User / group `bitcoind` runs as. |
| `BITCOIN_DATA` | `/home/bitcoin/.bitcoin` | Data directory (must be a mount); overridden by `-datadir`. |

| Network | RPC | P2P |
|---|---|---|
| mainnet | 8332 | 8333 |
| testnet4 | 48332 | 48333 |
| signet | 38332 | 38333 |
| regtest | 18443 | 18444 |

No port is declared or published by the image: you choose with `-p`. **Never publish RPC on a public interface.**

Tools: `bitcoin-cli`, `bitcoin-tx`, `bitcoin-util`, `bitcoin-wallet` are on the `PATH` (`docker exec -u bitcoin bitcoind bitcoin-cli ...`, or as the container command).

## Verify the image

With cosign 2.6 or later:

```bash
cosign verify romeujr/bitcoin-core:32.1 \
  --certificate-identity-regexp '^https://github.com/romeujr/docker-bitcoin-core/\.github/workflows/publish\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Every part of the Dockerfile is explained, with a step-by-step audit (provenance, builder keys, binaries compared byte for byte with the official release): [The Dockerfile, explained](https://github.com/romeujr/docker-bitcoin-core/blob/main/docs/dockerfile.md).

## More

Everything else (recipes, RPC and cookie access from the host, ZMQ, Tor, logs, extending the image, building it yourself, migrating from `ruimarinho/bitcoin-core`, changelog) is on GitHub:

### 👉 https://github.com/romeujr/docker-bitcoin-core

MIT licensed. Community project, not affiliated with the Bitcoin Core project.
