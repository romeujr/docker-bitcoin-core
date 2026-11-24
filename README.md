# Bitcoin Core in Docker — `romeujr/bitcoin-core`

[![Docker Pulls](https://img.shields.io/docker/pulls/romeujr/bitcoin-core?logo=docker)](https://hub.docker.com/r/romeujr/bitcoin-core)
[![Docker Stars](https://img.shields.io/docker/stars/romeujr/bitcoin-core?logo=docker)](https://hub.docker.com/r/romeujr/bitcoin-core)
[![Image Size](https://img.shields.io/docker/image-size/romeujr/bitcoin-core/latest?logo=docker)](https://hub.docker.com/r/romeujr/bitcoin-core/tags)
[![CI](https://github.com/romeujr/docker-bitcoin-core/actions/workflows/ci.yml/badge.svg)](https://github.com/romeujr/docker-bitcoin-core/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Run **[Bitcoin Core](https://bitcoincore.org)** (`bitcoind`) in a small, isolated and reproducible container, on a Linux host, NAS, Raspberry Pi, cloud VM or Kubernetes cluster, with the **official release binaries** and **every release since 22.0**.

The image is built to be *boring and safe* for long-running nodes: your data is never left inside the container, the node always shuts down cleanly, and files on the host belong to the user you choose.

- **Docker Hub:** [`romeujr/bitcoin-core`](https://hub.docker.com/r/romeujr/bitcoin-core)
- **GitHub Container Registry:** [`ghcr.io/romeujr/bitcoin-core`](https://github.com/romeujr/docker-bitcoin-core/pkgs/container/bitcoin-core)
- **Source:** https://github.com/romeujr/docker-bitcoin-core

**Contents:** [Highlights](#highlights) · [Quick start](#quick-start) · [Tags, registries and supported versions](#tags-registries-and-supported-versions) · [Persistent data](#persistent-data-mandatory) · [Host user (B_UID / B_GID)](#running-as-your-host-user-b_uid--b_gid) · [Graceful shutdown](#graceful-shutdown) · [Configuring Bitcoin Core](#configuring-bitcoin-core) · [Docker Compose](#docker-compose) · [bitcoin-cli and tools](#using-bitcoin-cli-and-the-other-tools) · [Health checks](#health-checks) · [Memory and performance](#memory-and-performance) · [Kubernetes and cloud](#kubernetes-and-cloud) · [Logs](#logs) · [Reference](#reference) · [Security](#security) · [Extending](#extending-the-image) · [Building](#building-the-image-yourself) · [Migrating](#migrating) · [Changelog](#image-changelog)

---

## Highlights

| | |
|---|---|
| **Official, verified binaries** | Downloaded from bitcoincore.org at build time. `SHA256SUMS` must carry at least 3 valid signatures from the [Bitcoin Core builder keys](https://github.com/bitcoin-core/guix.sigs/tree/main/builder-keys), and the archive must match its checksum, or the build fails. |
| **Every release** | One tag per Bitcoin Core release since 22.0, plus `latest`. Multi-arch: `linux/amd64` and `linux/arm64`. |
| **Your data is always persisted** | `bitcoind` refuses to start unless its data directory is a bind mount or a named volume. No more blockchains (or wallets!) lost with a deleted container, and no disk filled by data you cannot see. |
| **Clean shutdown** | `bitcoind` runs as PID 1 and receives `docker stop`'s `SIGTERM` directly, so it flushes its caches and closes its databases before exiting. No corrupted chainstate, no reindex. |
| **Runs as your host user** | Set `B_UID` / `B_GID` and the blockchain, wallets and `.cookie` on the host belong to a real host user, which makes backups, restores and host-side tools (`bitcoin-cli`, Electrum servers, explorers) straightforward. |
| **Unprivileged** | `bitcoind` never runs as root. Compatible with the Kubernetes *restricted* Pod Security Standard (non-root, read-only root filesystem, no capabilities). |
| **Signed, with SBOM and provenance** | Images published by GitHub Actions are signed with cosign and carry SBOM and SLSA provenance attestations. |
| **Kept up to date** | The supported versions are rebuilt every month on a fresh Debian base for security updates, and every build is scanned and tested on amd64 and arm64. |
| **Cloud ready** | Health check script for Docker, Compose, Kubernetes and ECS probes; a warning when the memory limit is too small for `-dbcache`; a [Kubernetes guide](docs/kubernetes.md). |
| **Plain Bitcoin Core** | Every `bitcoind` option works as documented; the image adds no wrapper configuration. Logs go to `docker logs`. |
| **One self-contained Dockerfile** | No scripts, no files to `COPY`, a single `RUN` layer: easy to audit, copy and customize. |

---

## Quick start

```bash
# Mainnet full node, data stored in /srv/bitcoin on the host, owned by your user
docker run -d --name bitcoind \
  --restart unless-stopped \
  --stop-timeout 600 \
  -e B_UID=$(id -u) -e B_GID=$(id -g) \
  -v /srv/bitcoin:/home/bitcoin/.bitcoin \
  -p 8333:8333 \
  romeujr/bitcoin-core:latest

# Follow the logs
docker logs -f bitcoind

# Talk to the node
docker exec -u bitcoin bitcoind bitcoin-cli -getinfo

# Stop it cleanly (it may need more than Docker's default 10 seconds)
docker stop -t 600 bitcoind
```

Any argument after the image name is passed to `bitcoind`:

```bash
docker run --rm -v /srv/bitcoin:/home/bitcoin/.bitcoin romeujr/bitcoin-core -help
```

> **Pin a version in production** (`romeujr/bitcoin-core:32.1`) instead of `latest`, and upgrade deliberately after reading the [release notes](https://github.com/bitcoin/bitcoin/tree/master/doc/release-notes).

---

## Tags, registries and supported versions

| Tag | Description |
|---|---|
| `<version>` (e.g. `32.1`, `29.1`, `24.0.1`) | Multi-arch image (`linux/amd64` + `linux/arm64`) for that Bitcoin Core release. |
| `<version>-amd64`, `<version>-arm64` | Single-architecture images. |
| `latest` | The most recent release. |

All tags: https://hub.docker.com/r/romeujr/bitcoin-core/tags. The list of versions is [`versions.txt`](versions.txt).

`linux/arm64` runs on Raspberry Pi 4/5 (64-bit OS), Apple Silicon (Docker Desktop), AWS Graviton and similar hosts.

**Registries.** The same images are published to Docker Hub and to the GitHub Container Registry. Use GHCR to avoid Docker Hub pull rate limits in clusters and CI:

```bash
docker pull romeujr/bitcoin-core:32.1
docker pull ghcr.io/romeujr/bitcoin-core:32.1
```

**Supported versions.** Every tag stays available, but only the newest release of each of the **three newest major versions** (`bash versions.sh supported`) is rebuilt every month with Debian security updates. Older tags are frozen and may report vulnerabilities in base packages over time: upgrade to a supported version. Bitcoin Core's own maintenance policy is at https://bitcoincore.org/en/lifecycle/.

> For immutable deployments, pin the digest: `romeujr/bitcoin-core:32.1@sha256:...` (`docker buildx imagetools inspect romeujr/bitcoin-core:32.1` shows it). A tag such as `32.1` keeps pointing to the newest rebuild of that version.

---

## Persistent data (mandatory)

The data directory is `/home/bitcoin/.bitcoin`. It contains the blocks, the chainstate, the indexes, the wallets, `bitcoin.conf`, `debug.log` and the RPC `.cookie`.

A node can take days to sync and needs hundreds of GB, so the entrypoint checks where that directory lives **before** starting `bitcoind`, and stops the container with a clear error when the data would be lost or would fill your disk unnoticed:

| The data directory is... | Result |
|---|---|
| a **bind mount** of a host directory on disk (`-v /srv/bitcoin:...`) | Starts. |
| a **named volume** (`-v bitcoin-data:...`) | Starts. |
| **not mounted** (container's writable layer) | **Refused.** Data would grow inside Docker's storage without any visible volume and be lost when the container is removed or recreated (e.g. by `docker compose up` after an image upgrade). |
| an **anonymous volume** (`-v /home/bitcoin/.bitcoin`, without a name or host path) | **Refused.** It gets a random name, is easy to lose track of while it fills the disk, and is deleted by `docker run --rm` and `docker volume prune`. The error shows how to copy its data into a named volume. |
| **in memory** (`--tmpfs`, or a host directory on tmpfs such as `/tmp` on many systems) | **Refused**, except with `-regtest`. Lost at every stop or reboot. |
| mounted **read-only** (`:ro`) | **Refused.** `bitcoind` must write to it. |
| not **writable** by `B_UID:B_GID` | **Refused**, with the owner, the mode and the exact fix. |

For example:

```text
[entrypoint] ERROR: the data directory "/home/bitcoin/.bitcoin" is not on a Docker volume or bind mount.

  The blockchain, the wallets and all node state would be written to the
  container's writable layer: they would fill Docker's storage without any
  visible volume and be lost when the container is removed or recreated.

  Bind mount a host directory:
    docker run -d --name bitcoind -v /path/on/host:/home/bitcoin/.bitcoin romeujr/bitcoin-core:32.1
  ...
```

Use either:

```bash
# A host directory (bind mount): easiest to back up and inspect
-v /srv/bitcoin:/home/bitcoin/.bitcoin

# A named volume managed by Docker
-v bitcoin-data:/home/bitcoin/.bitcoin
```

Notes:

- The image intentionally has **no `VOLUME` instruction**, which would otherwise create an anonymous volume behind your back.
- If the host directory does not exist yet, Docker creates it owned by `root`. The entrypoint detects an **empty** directory that `bitcoind` cannot write to and hands it to `B_UID:B_GID`. A **non-empty** directory is never changed.
- To use another path, either set `-e BITCOIN_DATA=/data/bitcoin` or pass `-datadir=/data/bitcoin`; the checks apply to that path. Mounting a parent directory (e.g. `-v /srv:/data` with `BITCOIN_DATA=/data/bitcoin`) also works.
- **Throwaway regtest nodes** (e.g. in CI) can run in memory, so nothing is left on disk:

  ```bash
  docker run --rm --tmpfs /home/bitcoin/.bitcoin romeujr/bitcoin-core:latest -regtest
  ```

---

## Running as your host user (`B_UID` / `B_GID`)

`bitcoind` runs as the unprivileged user `bitcoin`, which is `1000:1000` by default. Set `B_UID` and `B_GID` to make it match a user of your host, so the files on the host belong to that user rather than to an unrelated numeric id:

```bash
docker run -d --name bitcoind \
  -e B_UID=$(id -u) -e B_GID=$(id -g) \
  -v /srv/bitcoin:/home/bitcoin/.bitcoin \
  romeujr/bitcoin-core:latest
```

Why this matters:

- **Backups and restores** keep sensible ownership; no `sudo chown -R` on hundreds of GB.
- **Host-side tools** can read the data directory and the RPC `.cookie` directly (`bitcoin-cli -rpccookiefile=/srv/bitcoin/.cookie ...`, Electrum servers, block explorers, monitoring).
- **NAS appliances** (Synology, QNAP, TrueNAS, Unraid) usually require a specific user/group; group ids already used inside the image, such as `100` (`users`), are accepted.

Details:

- The ids are applied every time the container starts; nothing is chowned recursively, so start-up stays instant even with a full blockchain.
- Already have data? Use the owner of the directory: `stat -c '%u %g' /srv/bitcoin`.
- `B_UID=0` (root) is refused on purpose.
- Alternatively, `docker run --user 1001:1001 ...` also works (no remapping happens then, and `docker exec -u bitcoin` will not match; prefer `B_UID`/`B_GID`).

---

## Graceful shutdown

When you run `docker stop`, Docker sends `SIGTERM`, waits for the **stop timeout** (10 seconds by default) and then kills the container with `SIGKILL`.

`bitcoind` handles `SIGTERM` by flushing its in-memory UTXO cache (`-dbcache`), writing its indexes and closing its databases. With a large `-dbcache`, during the initial block download or on slow disks, **this can take minutes**. Killing it in the middle can corrupt the chainstate and force a long `-reindex`.

This image:

1. runs `bitcoind` as **PID 1** (the entrypoint `exec`s into it), so it receives `SIGTERM` directly;
2. sets `STOPSIGNAL SIGTERM`;
3. refuses `-daemon` / `daemon=1`, which would detach `bitcoind` from the container.

What **you** must do is give it enough time:

```bash
docker run --stop-timeout 600 ...   # default for this container
docker stop -t 600 bitcoind         # or per stop
```

```yaml
# Docker Compose
services:
  bitcoind:
    stop_grace_period: 10m
```

Also:

- Never stop the node with `docker kill` or `docker rm -f`: both send `SIGKILL` immediately.
- On host shutdown/reboot the Docker daemon stops containers using their stop timeouts (see also the daemon's `shutdown-timeout` setting). If Docker runs under systemd, make sure the service manager does not kill it sooner.
- A clean shutdown ends with `Shutdown done` in `docker logs`.

---

## Configuring Bitcoin Core

Nothing is configured for you: the image runs plain `bitcoind`, so the [Bitcoin Core documentation](https://github.com/bitcoin/bitcoin/tree/master/doc) applies as is. You can see every option of the version you run with:

```bash
docker run --rm romeujr/bitcoin-core:latest -help                  # common options
docker run --rm romeujr/bitcoin-core:latest -help -help-debug      # everything
docker run --rm romeujr/bitcoin-core:latest -version
```

(`-help` and `-version` do not need a volume.)

### Command-line arguments or `bitcoin.conf`

Both are equivalent; pick one or mix them (command-line arguments win).

**Command line** (handy for a few options):

```bash
docker run -d --name bitcoind -v /srv/bitcoin:/home/bitcoin/.bitcoin \
  romeujr/bitcoin-core:latest -prune=10000 -dbcache=2048
```

**`bitcoin.conf`** in the data directory (`/srv/bitcoin/bitcoin.conf` on the host), read automatically:

```ini
# /srv/bitcoin/bitcoin.conf
server=1
prune=10000
dbcache=2048

[main]
rpcbind=0.0.0.0
rpcallowip=172.16.0.0/12
```

A complete, commented example is available in [`examples/bitcoin.conf`](https://github.com/romeujr/docker-bitcoin-core/blob/main/examples/bitcoin.conf). A configuration file elsewhere can be selected with `-conf=/path/inside/the/container/bitcoin.conf` (mount it read-only).

> The entrypoint always passes `-datadir=<data directory>` to `bitcoind` (unless you pass `-datadir` yourself), so the directory that was checked is the one used.

### Recipes

**Pruned node** (keeps only the most recent ~10 GB of blocks; still fully validating):

```bash
... romeujr/bitcoin-core:latest -prune=10000
```

**Faster initial sync** (more RAM for the UTXO cache, in MiB; set it back to a lower value afterwards if memory is tight):

```bash
... romeujr/bitcoin-core:latest -dbcache=4096
```

**Indexes** for Electrum servers, explorers, Lightning and wallets (not compatible with `-prune`):

```bash
... romeujr/bitcoin-core:latest -txindex=1 -blockfilterindex=1 -peerblockfilters=1 -coinstatsindex=1
```

**RPC access from the host and from other containers**: RPC listens on localhost only by default, so inside a container it must bind to all interfaces and allow the Docker networks. Publish the port on the host's loopback only:

```bash
docker run -d --name bitcoind \
  -v /srv/bitcoin:/home/bitcoin/.bitcoin \
  -p 127.0.0.1:8332:8332 -p 8333:8333 \
  romeujr/bitcoin-core:latest \
  -server=1 -rpcbind=0.0.0.0 -rpcallowip=172.16.0.0/12 -rpcallowip=192.168.0.0/16

# From the host, using the cookie (B_UID/B_GID must match your user):
bitcoin-cli -rpccookiefile=/srv/bitcoin/.cookie getblockcount

# Or with curl:
curl --user "__cookie__:$(cut -d: -f2 /srv/bitcoin/.cookie)" \
  -H 'content-type: text/plain;' \
  --data-binary '{"jsonrpc":"1.0","id":"test","method":"getblockcount","params":[]}' \
  http://127.0.0.1:8332/
```

For fixed credentials, prefer `-rpcauth` (hashed password) over `-rpcuser`/`-rpcpassword`. Generate a line with [`rpcauth.py`](https://github.com/bitcoin/bitcoin/tree/master/share/rpcauth) on any machine with Python:

```bash
curl -fsSLO https://raw.githubusercontent.com/bitcoin/bitcoin/master/share/rpcauth/rpcauth.py
python3 rpcauth.py alice   # prints rpcauth=alice:<salt>$<hash> and the password
```

**ZMQ notifications** (LND, Core Lightning, electrs, mempool, BTCPay Server...):

```bash
docker run -d --name bitcoind -v /srv/bitcoin:/home/bitcoin/.bitcoin \
  -p 127.0.0.1:28332:28332 -p 127.0.0.1:28333:28333 \
  romeujr/bitcoin-core:latest \
  -zmqpubrawblock=tcp://0.0.0.0:28332 -zmqpubrawtx=tcp://0.0.0.0:28333 -zmqpubhashblock=tcp://0.0.0.0:28332
```

**Test networks**:

```bash
... romeujr/bitcoin-core:latest -testnet4      # testnet4 (Bitcoin Core 28.0+)
... romeujr/bitcoin-core:latest -signet
... romeujr/bitcoin-core:latest -regtest
# or -chain=main|test|testnet4|signet|regtest
```

Each network keeps its data in a subdirectory (`testnet4/`, `signet/`, `regtest/`), and `bitcoin-cli` needs the same flag.

**Tor** (with a Tor container named `tor` on the same Docker network, SOCKS on 9050):

```bash
... romeujr/bitcoin-core:latest -proxy=tor:9050 -onlynet=onion
```

For an onion service, use `-torcontrol=tor:9051 -torpassword=...` (or let Tor publish the service and set `-externalip=<address>.onion`). See [doc/tor.md](https://github.com/bitcoin/bitcoin/blob/master/doc/tor.md).

**Low bandwidth / low resources**:

```bash
... romeujr/bitcoin-core:latest -blocksonly=1 -maxuploadtarget=5000 -maxconnections=20 -prune=5000
```

**Without wallet**:

```bash
... romeujr/bitcoin-core:latest -disablewallet=1
```

**Logs only in `docker logs`** (no `debug.log` in the data directory):

```bash
... romeujr/bitcoin-core:latest -nodebuglogfile
```

**Notification scripts** (`-blocknotify`, `-walletnotify`, `-alertnotify`, `-startupnotify`, `-shutdownnotify`): `bash` and `curl` are available in the image. Mount your scripts read-only and add `--init` to `docker run` (or `init: true` in Compose) so that the short-lived processes they start are reaped.

---

## Docker Compose

```yaml
services:
  bitcoind:
    image: romeujr/bitcoin-core:32.1
    container_name: bitcoind
    restart: unless-stopped
    stop_grace_period: 10m            # time for a clean shutdown
    environment:
      B_UID: "1000"                    # owner of ./data on the host (id -u)
      B_GID: "1000"                    # (id -g)
    volumes:
      - ./data:/home/bitcoin/.bitcoin
    ports:
      - "8333:8333"                    # P2P
      - "127.0.0.1:8332:8332"          # RPC, host loopback only
    command:
      - -server=1
      - -rpcbind=0.0.0.0
      - -rpcallowip=172.16.0.0/12
      - -dbcache=2048
    healthcheck:
      test: ["CMD", "/opt/healthcheck.sh"]
      interval: 1m
      timeout: 20s
      start_period: 10m
      retries: 5
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
```

A complete version is in [`examples/docker-compose.yml`](https://github.com/romeujr/docker-bitcoin-core/blob/main/examples/docker-compose.yml). Other containers on the same Compose network reach the node at `bitcoind:8332` (RPC) and `bitcoind:28332` (ZMQ, if enabled).

---

## Using `bitcoin-cli` and the other tools

The image contains `bitcoind`, `bitcoin-cli`, `bitcoin-tx`, `bitcoin-util`, `bitcoin-wallet` (and the `bitcoin` command in recent releases), all on the `PATH`.

Against a running container, run them as the `bitcoin` user so the RPC cookie is found:

```bash
docker exec -u bitcoin bitcoind bitcoin-cli getblockchaininfo
docker exec -u bitcoin bitcoind bitcoin-cli -netinfo 4
docker exec -u bitcoin bitcoind bitcoin-cli createwallet main
docker exec -it -u bitcoin bitcoind bash

# Handy alias on the host
alias bitcoin-cli='docker exec -u bitcoin bitcoind bitcoin-cli'
```

(On test networks add the network flag, e.g. `bitcoin-cli -testnet4 ...`; with a custom data directory add `-datadir=...`.)

They can also be the container's command, without starting a node:

```bash
docker run --rm romeujr/bitcoin-core bitcoin-tx -help
docker run --rm --network container:bitcoind romeujr/bitcoin-core \
  bitcoin-cli -rpcconnect=127.0.0.1 -rpcuser=alice -rpcpassword=... getblockcount
docker run --rm -v /srv/bitcoin:/home/bitcoin/.bitcoin romeujr/bitcoin-core \
  bitcoin-wallet -wallet=main info    # only while bitcoind is stopped
```

---

## Health checks

The image includes `/opt/healthcheck.sh`, which reads the running `bitcoind`'s own options (network, data directory, RPC port and credentials), so it works unchanged on mainnet, testnet4, signet or regtest:

| Command | Healthy (exit 0) when |
|---|---|
| `/opt/healthcheck.sh` or `/opt/healthcheck.sh liveness` | `bitcoind` runs and its RPC server answers, **including** while it is still loading at start-up. |
| `/opt/healthcheck.sh readiness` | In addition, the initial block download is finished. |

```bash
docker exec bitcoind /opt/healthcheck.sh readiness
# not ready: initial block download in progress (verificationprogress 0.4213...)
```

It is **not** enabled by default (you decide how your orchestrator reacts). Enable it with:

```bash
docker run ... --health-cmd /opt/healthcheck.sh --health-interval 1m --health-timeout 20s --health-start-period 10m ...
```

or with the `healthcheck:` block of the [Compose example](#docker-compose), or as Kubernetes probes (see the [Kubernetes guide](docs/kubernetes.md#5-probes-opthealthchecksh)). Keep timeouts generous: an unhealthy node that gets restarted pays a shutdown and a long start-up every time.

---

## Memory and performance

**Memory limit.** `bitcoind` uses roughly `-dbcache` (default 450 MiB) + `-maxmempool` (default 300 MB) + a few hundred MiB for the rest. If a container memory limit (`--memory`, Compose `mem_limit`, Kubernetes `limits.memory`) is lower, the kernel kills it (OOM): that is a `SIGKILL`, with the same risk of corruption as `docker kill`. The entrypoint prints a warning at start-up when the limit looks too small:

```text
[entrypoint] WARNING: the container memory limit is 2048 MiB, but bitcoind may need about 4908 MiB (dbcache 4096 + maxmempool 300 + ~512 for the rest). ...
```

**Initial sync.** It is mostly limited by disk I/O and `-dbcache`. Use an SSD (on cloud block volumes, provision enough IOPS/throughput), give it a large `-dbcache` during the sync (e.g. 4096 or more), and lower it afterwards if memory is tight. On low-memory devices see [reduce-memory.md](https://github.com/bitcoin/bitcoin/blob/master/doc/reduce-memory.md).

**UTXO snapshots (assumeutxo).** Bitcoin Core 28.0 and later can start from a UTXO snapshot (`bitcoin-cli loadtxoutset <file>`): the node becomes usable quickly while the full history is validated in the background. Only snapshots whose hash is built into the release are accepted. See [assumeutxo.md](https://github.com/bitcoin/bitcoin/blob/master/doc/assumeutxo.md).

---

## Kubernetes and cloud

The image runs unchanged on Kubernetes and other orchestrators, but their defaults assume short-lived, stateless workloads. The [Kubernetes and cloud guide](docs/kubernetes.md) covers each point, and [`examples/kubernetes/bitcoind.yaml`](examples/kubernetes/bitcoind.yaml) is a complete StatefulSet. In short:

- **Storage:** a PersistentVolumeClaim; `emptyDir` is refused by the image (it is deleted with the Pod).
- **Shutdown:** `terminationGracePeriodSeconds: 600` (the default 30 seconds is too short); avoid spot/preemptible nodes.
- **Security:** set `runAsUser`/`runAsGroup`/`fsGroup` (with `fsGroupChangePolicy: OnRootMismatch`); `B_UID`/`B_GID` are not needed there. Read-only root filesystem and `drop: ["ALL"]` work.
- **Memory:** `limits.memory` above `dbcache + maxmempool + ~512 MiB`.
- **Probes:** `/opt/healthcheck.sh liveness` (startup and liveness) and `readiness`, with `timeoutSeconds` raised.
- **RPC:** internal Service + NetworkPolicy, credentials in a Secret (`-conf=`), never `-rpcpassword` in the Pod spec.
- **ECS on Fargate** caps the stop timeout (120 seconds at the time of writing): keep `-dbcache` modest there.

---

## Logs

`bitcoind` writes its log to the console, so `docker logs -f bitcoind` shows everything. It also writes `debug.log` to the data directory unless `-nodebuglogfile` is set.

Configure log rotation for the container (see the Compose example, or `--log-opt max-size=50m --log-opt max-file=5`), since a node logs continuously.

The entrypoint prints a short summary before starting (RPC passwords are masked):

```text
[entrypoint] Bitcoin Core 32.1 - https://github.com/romeujr/docker-bitcoin-core
[entrypoint] User:           uid=1000 gid=1000
[entrypoint] Data directory: /home/bitcoin/.bitcoin
[entrypoint] Command:        bitcoind -datadir=/home/bitcoin/.bitcoin -server=1 -dbcache=2048
```

---

## Reference

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `B_UID` | `1000` | User id `bitcoind` runs as. |
| `B_GID` | `1000` | Group id `bitcoind` runs as. |
| `BITCOIN_DATA` | `/home/bitcoin/.bitcoin` | Data directory (must be a mount). Overridden by `-datadir=...`. |
| `BITCOIN_VERSION` | *(the image's version)* | Informational, read-only. |

### Ports

| Network | RPC | P2P |
|---|---|---|
| mainnet | 8332 | 8333 |
| testnet3 | 18332 | 18333 |
| testnet4 | 48332 | 48333 |
| signet | 38332 | 38333 |
| regtest | 18443 | 18444 |

The image does not declare any port (no `EXPOSE`), so nothing is published unless you decide to, with `-p` / `ports:`; even `docker run -P` publishes nothing. Only publish what you need: P2P can be public, but **RPC should never be published on a public interface** (use `127.0.0.1:8332:8332` or a Docker network). Containers on the same Docker network reach each other's listening ports without any publishing.

### Command

| Container command | What runs |
|---|---|
| *(none)* or arguments starting with `-` | `bitcoind <arguments>`, after the data directory checks. |
| `bitcoind ...`, `bitcoin node ...` | Same as above. |
| `bitcoin-cli`, `bitcoin-tx`, `bitcoin-util`, `bitcoin-wallet`, `bitcoin ...` | That tool, as the `bitcoin` user, no data directory checks. |
| Anything else (e.g. `bash`) | Executed as is (as root), useful for debugging. |

### Files

| Path | Content |
|---|---|
| `/opt/bitcoin` | Bitcoin Core (symlink to `/opt/bitcoin-<version>`), `bin/` is on the `PATH`. |
| `/opt/entry-point.sh` | Entrypoint. |
| `/opt/healthcheck.sh` | Health check (`liveness` / `readiness`). |
| `/home/bitcoin/.bitcoin` | Default data directory (mount it). |

### Labels

Standard `org.opencontainers.image.*` labels (version, source, revision of this repository, documentation) and `io.github.romeujr.bitcoin-core.guix-sigs-ref`, the commit of [bitcoin-core/guix.sigs](https://github.com/bitcoin-core/guix.sigs) whose builder keys verified the release.

---

## Security

- `bitcoind` runs as an unprivileged user; root is refused.
- Release binaries are verified at build time against the Bitcoin Core builders' GPG signatures and SHA-256 checksums.
- Published images are signed (keyless cosign, GitHub Actions OIDC) and carry an SBOM and SLSA provenance. Verify before deploying:

  ```bash
  cosign verify romeujr/bitcoin-core:32.1 \
    --certificate-identity-regexp '^https://github.com/romeujr/docker-bitcoin-core/\.github/workflows/publish\.yml@' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```

- Every CI build is scanned with Trivy, and supported versions are rebuilt monthly with Debian security updates.
- RPC is not reachable from outside the container unless you explicitly bind it (`-rpcbind`) and allow clients (`-rpcallowip`). Keep RPC on loopback or on a private Docker network, and prefer `-rpcauth` or the cookie over plain `-rpcpassword`.
- Bitcoin Core creates its files with restrictive permissions (umask `077`), so wallets and the cookie are only readable by `B_UID` (and root).
- Back up your wallets (`bitcoin-cli backupwallet`, or copy the `wallets/` directory while the node is stopped). A volume is not a backup.

---

## Extending the image

Add tools on top of it:

```dockerfile
FROM romeujr/bitcoin-core:32.1
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*
```

Bake a configuration into your own image:

```dockerfile
FROM romeujr/bitcoin-core:32.1
COPY bitcoin.conf /etc/bitcoin/bitcoin.conf
CMD ["-conf=/etc/bitcoin/bitcoin.conf"]
```

Keep `/opt/entry-point.sh` as the `ENTRYPOINT` to retain the data directory checks, the UID/GID mapping and the clean shutdown.

---

## Building the image yourself

The [`Dockerfile`](https://github.com/romeujr/docker-bitcoin-core/blob/main/Dockerfile) is self-contained: it needs no build context and does everything in a single `RUN` layer. It requires BuildKit (the default builder since Docker 23).

```bash
# For the current platform
docker buildx build --build-arg P_BITCOIN_VERSION=32.1 -t bitcoin-core:32.1 .

# For another platform (on x86 hosts, enable QEMU first:
#   docker run --rm --privileged multiarch/qemu-user-static --reset -p yes)
docker buildx build --platform linux/arm64 --build-arg P_BITCOIN_VERSION=32.1 -t bitcoin-core:32.1-arm64 .
```

| Build argument | Default | Description |
|---|---|---|
| `P_BITCOIN_VERSION` | *(required)* | Bitcoin Core version, as in `https://bitcoincore.org/bin/bitcoin-core-<version>/`. |
| `P_TARGETPLATFORM` | the target platform | `linux/amd64`, `linux/arm64`, `linux/arm/v7`, `linux/ppc64le` or `linux/riscv64`. |
| `P_MIN_SIGNATURES` | `3` | Minimum number of valid builder signatures on `SHA256SUMS`. |
| `P_GUIX_SIGS_REF` | `main` | Branch, tag or commit of `bitcoin-core/guix.sigs` providing the builder keys. Pin a commit for reproducible builds. |
| `P_REVISION` | *(empty)* | Commit of this repository, stored in the `org.opencontainers.image.revision` label. |

The build fails if the signatures or the checksum do not verify.

Test your build with the same smoke tests as CI (data directory protections, UID/GID, clean shutdown, health checks, restricted mode...):

```bash
docker buildx build --load --build-arg P_BITCOIN_VERSION=32.1 -t bitcoin-core:test .
bash tests/smoke.sh bitcoin-core:test
```

How the official images are built, tested, signed and published (GitHub Actions, [`versions.txt`](versions.txt), [`build-version.sh`](build-version.sh), [`build-all.sh`](build-all.sh)): see [docs/publishing.md](docs/publishing.md).

---

## Migrating

**From [`ruimarinho/bitcoin-core`](https://hub.docker.com/r/ruimarinho/bitcoin-core)** (no longer updated after 23.0): the data directory is the same (`/home/bitcoin/.bitcoin`) and arguments are still passed to `bitcoind`, so in most cases you only change the image name. Check the owner of your data (`stat -c '%u %g' /path/to/data`) and pass it as `B_UID`/`B_GID`.

**From a bare-metal installation:** stop `bitcoind`, mount your existing `~/.bitcoin` and set `B_UID`/`B_GID` to your user's ids. No resync is needed as long as you do not downgrade to an older Bitcoin Core version.

**Upgrading Bitcoin Core:** stop the container cleanly, change the tag, start it again. Read the release notes first: some upgrades rebuild indexes or migrate databases on first start, and downgrades are often not possible.

---

## Image changelog

- **2026-11 (cloud)** — images also on GHCR; signed with cosign, with SBOM and provenance; built, tested (amd64 and arm64) and scanned by GitHub Actions; supported versions rebuilt monthly; `/opt/healthcheck.sh` for liveness/readiness probes; warning when the memory limit is below `-dbcache` + `-maxmempool`; Kubernetes `emptyDir` refused; non-root / read-only root filesystem mode (Kubernetes restricted) supported and tested; Kubernetes and cloud guide; no `EXPOSE`; MIT license.
- **2026-11** — `bitcoind` now runs as PID 1 and shuts down cleanly on `docker stop` (previously the entrypoint did not forward signals and the node was terminated without its shutdown sequence); release binaries are verified with the builders' GPG signatures and SHA-256 checksums; `B_UID`/`B_GID` no longer change file ownership recursively and accept group ids already in use; empty data directories created by Docker are handed to `B_UID:B_GID`; the data directory is also refused on anonymous volumes, in-memory filesystems (except `-regtest`) and read-only mounts; clear errors for unwritable data directories and for `-daemon`; `-help`/`-version` and the bundled tools work without a volume; Bitcoin Core binaries on the `PATH`; `-rpcpassword` masked in the start-up summary; GUI and test binaries removed.
- **Earlier** — `B_UID`/`B_GID` support; refuse to start without a mounted data directory.

---

## Links

- Bitcoin Core: https://bitcoincore.org · [source](https://github.com/bitcoin/bitcoin) · [documentation](https://github.com/bitcoin/bitcoin/tree/master/doc) · [release notes](https://github.com/bitcoin/bitcoin/tree/master/doc/release-notes)
- `bitcoind` manual page: https://man.archlinux.org/man/extra/bitcoin-daemon/bitcoind.1.en
- Docker `run` reference: https://docs.docker.com/reference/cli/docker/container/run/
- Issues and suggestions: https://github.com/romeujr/docker-bitcoin-core/issues

## License

This repository is released under the [MIT license](LICENSE). Bitcoin Core is also released under the [MIT license](https://github.com/bitcoin/bitcoin/blob/master/COPYING); the Debian packages in the image keep their own licenses. This image is a community project and is not affiliated with the Bitcoin Core project.
