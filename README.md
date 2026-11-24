# Bitcoin Core in Docker — `romeujr/bitcoin-core`

[![Docker Pulls](https://img.shields.io/docker/pulls/romeujr/bitcoin-core?logo=docker)](https://hub.docker.com/r/romeujr/bitcoin-core)
[![Docker Stars](https://img.shields.io/docker/stars/romeujr/bitcoin-core?logo=docker)](https://hub.docker.com/r/romeujr/bitcoin-core)
[![Image Size](https://img.shields.io/docker/image-size/romeujr/bitcoin-core/latest?logo=docker)](https://hub.docker.com/r/romeujr/bitcoin-core/tags)
[![GitHub](https://img.shields.io/badge/source-GitHub-181717?logo=github)](https://github.com/romeujr/docker-bitcoin-core)

Run **[Bitcoin Core](https://bitcoincore.org)** (`bitcoind`) in a small, isolated and reproducible Docker container, on any Linux host, NAS, server or Raspberry Pi, with the **official release binaries** and **every release since 22.0**.

The image is built to be *boring and safe* for long-running nodes: your data is never left inside the container, the node always shuts down cleanly, and files on the host belong to the user you choose.

- **Docker Hub:** https://hub.docker.com/r/romeujr/bitcoin-core
- **Source:** https://github.com/romeujr/docker-bitcoin-core

---

## Highlights

| | |
|---|---|
| **Official, verified binaries** | Downloaded from bitcoincore.org at build time. `SHA256SUMS` must carry at least 3 valid signatures from the [Bitcoin Core builder keys](https://github.com/bitcoin-core/guix.sigs/tree/main/builder-keys), and the archive must match its checksum, or the build fails. |
| **Every release** | One tag per Bitcoin Core release since 22.0, plus `latest`. Multi-arch: `linux/amd64` and `linux/arm64`. |
| **Your data is always persisted** | `bitcoind` refuses to start unless its data directory is a bind mount or a named volume. No more blockchains (or wallets!) lost with a deleted container. |
| **Clean shutdown** | `bitcoind` runs as PID 1 and receives `docker stop`'s `SIGTERM` directly, so it flushes its caches and closes its databases before exiting. No corrupted chainstate, no reindex. |
| **Runs as your host user** | Set `B_UID` / `B_GID` and the blockchain, wallets and `.cookie` on the host belong to a real host user, which makes backups, restores and host-side tools (`bitcoin-cli`, Electrum servers, explorers) straightforward. |
| **Unprivileged** | `bitcoind` never runs as root. |
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

> **Pin a version in production** (`romeujr/bitcoin-core:30.0`) instead of `latest`, and upgrade deliberately after reading the [release notes](https://github.com/bitcoin/bitcoin/tree/master/doc/release-notes).

---

## Supported tags and platforms

| Tag | Description |
|---|---|
| `<version>` (e.g. `30.0`, `29.1`, `24.0.1`) | Multi-arch manifest (`linux/amd64` + `linux/arm64`) for that Bitcoin Core release. |
| `<version>-amd64`, `<version>-arm64` | Single-architecture images. |
| `latest` | The most recent release. |

All tags: https://hub.docker.com/r/romeujr/bitcoin-core/tags

`linux/arm64` runs on Raspberry Pi 4/5 (64-bit OS), Apple Silicon (Docker Desktop), AWS Graviton and similar hosts.

---

## Persistent data (mandatory)

The data directory is `/home/bitcoin/.bitcoin`. It contains the blocks, the chainstate, the indexes, the wallets, `bitcoin.conf`, `debug.log` and the RPC `.cookie`.

The container **will not start `bitcoind`** if that directory (or one of its parent directories) is not a mount. This is deliberate: without a mount everything would be written to the container's writable layer and silently lost when the container is removed or recreated (for example by `docker compose up` after an image upgrade).

```text
[entrypoint] ERROR: the data directory "/home/bitcoin/.bitcoin" is not on a Docker volume or bind mount.

  bitcoind will NOT start: the blockchain, the wallets and all node state would
  be written to the container's writable layer and lost with the container.
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

- The image intentionally has **no `VOLUME` instruction**, which would otherwise create an anonymous volume behind your back and defeat this check.
- If the host directory does not exist yet, Docker creates it owned by `root`. The entrypoint detects an **empty** directory that `bitcoind` cannot write to and hands it to `B_UID:B_GID`. A **non-empty** directory is never changed: you get an error explaining how to fix the ownership.
- To use another path, either set `-e BITCOIN_DATA=/data/bitcoin` or pass `-datadir=/data/bitcoin`; the mount check applies to that path.
- **Throwaway nodes only** (e.g. `-regtest` in CI): opt out with `-e B_ALLOW_EPHEMERAL_DATA=true`. A warning is printed and all data is lost with the container.

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
    image: romeujr/bitcoin-core:30.0
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
      test: ["CMD", "bitcoin-cli", "-datadir=/home/bitcoin/.bitcoin", "getblockchaininfo"]
      interval: 1m
      timeout: 15s
      start_period: 10m
      retries: 3
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

## Logs

`bitcoind` writes its log to the console, so `docker logs -f bitcoind` shows everything. It also writes `debug.log` to the data directory unless `-nodebuglogfile` is set.

Configure log rotation for the container (see the Compose example, or `--log-opt max-size=50m --log-opt max-file=5`), since a node logs continuously.

The entrypoint prints a short summary before starting (RPC passwords are masked):

```text
[entrypoint] Bitcoin Core 30.0 - https://github.com/romeujr/docker-bitcoin-core
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
| `B_ALLOW_EPHEMERAL_DATA` | `false` | `true` allows running without a mount. **All data is lost with the container.** |
| `BITCOIN_VERSION` | *(the image's version)* | Informational, read-only. |

### Ports

| Network | RPC | P2P |
|---|---|---|
| mainnet | 8332 | 8333 |
| testnet3 | 18332 | 18333 |
| testnet4 | 48332 | 48333 |
| signet | 38332 | 38333 |
| regtest | 18443 | 18444 |

Only publish what you need. P2P can be public; **RPC should never be published on a public interface** (use `127.0.0.1:8332:8332` or a Docker network).

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
| `/home/bitcoin/.bitcoin` | Default data directory (mount it). |

---

## Security notes

- `bitcoind` runs as an unprivileged user; root is refused.
- Release binaries are verified at build time against the Bitcoin Core builders' GPG signatures and SHA-256 checksums.
- RPC is not reachable from outside the container unless you explicitly bind it (`-rpcbind`) and allow clients (`-rpcallowip`). Keep RPC on loopback or on a private Docker network, and prefer `-rpcauth` or the cookie over plain `-rpcpassword`.
- Bitcoin Core creates its files with restrictive permissions (umask `077`), so wallets and the cookie are only readable by `B_UID` (and root).
- Back up your wallets (`bitcoin-cli backupwallet`, or copy the `wallets/` directory while the node is stopped). A volume is not a backup.

---

## Extending the image

Add tools on top of it:

```dockerfile
FROM romeujr/bitcoin-core:30.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*
```

Bake a configuration into your own image:

```dockerfile
FROM romeujr/bitcoin-core:30.0
COPY bitcoin.conf /etc/bitcoin/bitcoin.conf
CMD ["-conf=/etc/bitcoin/bitcoin.conf"]
```

Keep `/opt/entry-point.sh` as the `ENTRYPOINT` to retain the data directory checks, the UID/GID mapping and the clean shutdown.

---

## Building the image yourself

The [`Dockerfile`](https://github.com/romeujr/docker-bitcoin-core/blob/main/Dockerfile) is self-contained: it needs no build context and does everything in a single `RUN` layer. It requires BuildKit (the default builder since Docker 23).

```bash
# For the current platform
docker buildx build --build-arg P_BITCOIN_VERSION=30.0 -t bitcoin-core:30.0 .

# For another platform (on x86 hosts, enable QEMU first:
#   docker run --rm --privileged multiarch/qemu-user-static --reset -p yes)
docker buildx build --platform linux/arm64 --build-arg P_BITCOIN_VERSION=30.0 -t bitcoin-core:30.0-arm64 .
```

| Build argument | Default | Description |
|---|---|---|
| `P_BITCOIN_VERSION` | *(required)* | Bitcoin Core version, as in `https://bitcoincore.org/bin/bitcoin-core-<version>/`. |
| `P_TARGETPLATFORM` | the target platform | `linux/amd64`, `linux/arm64`, `linux/arm/v7`, `linux/ppc64le` or `linux/riscv64`. |
| `P_MIN_SIGNATURES` | `3` | Minimum number of valid builder signatures on `SHA256SUMS`. |

The build fails if the signatures or the checksum do not verify. The scripts used to publish the images are [`build-version.sh`](https://github.com/romeujr/docker-bitcoin-core/blob/main/build-version.sh) (one version, both architectures, manifest) and [`build-all.sh`](https://github.com/romeujr/docker-bitcoin-core/blob/main/build-all.sh) (all versions and `latest`).

---

## Migrating

**From [`ruimarinho/bitcoin-core`](https://hub.docker.com/r/ruimarinho/bitcoin-core)** (no longer updated after 23.0): the data directory is the same (`/home/bitcoin/.bitcoin`) and arguments are still passed to `bitcoind`, so in most cases you only change the image name. Check the owner of your data (`stat -c '%u %g' /path/to/data`) and pass it as `B_UID`/`B_GID`.

**From a bare-metal installation:** stop `bitcoind`, mount your existing `~/.bitcoin` and set `B_UID`/`B_GID` to your user's ids. No resync is needed as long as you do not downgrade to an older Bitcoin Core version.

**Upgrading Bitcoin Core:** stop the container cleanly, change the tag, start it again. Read the release notes first: some upgrades rebuild indexes or migrate databases on first start, and downgrades are often not possible.

---

## Image changelog

- **2026-11** — `bitcoind` now runs as PID 1 and shuts down cleanly on `docker stop` (previously the entrypoint did not forward signals and the node was terminated without its shutdown sequence); release binaries are verified with the builders' GPG signatures and SHA-256 checksums; `B_UID`/`B_GID` no longer change file ownership recursively and accept group ids already in use; empty data directories created by Docker are handed to `B_UID:B_GID`; clear errors for unwritable data directories and for `-daemon`; `-help`/`-version` and the bundled tools work without a volume; Bitcoin Core binaries on the `PATH`; `-rpcpassword` masked in the start-up summary; GUI and test binaries removed.
- **Earlier** — `B_UID`/`B_GID` support; refuse to start without a mounted data directory.

---

## Links

- Bitcoin Core: https://bitcoincore.org · [source](https://github.com/bitcoin/bitcoin) · [documentation](https://github.com/bitcoin/bitcoin/tree/master/doc) · [release notes](https://github.com/bitcoin/bitcoin/tree/master/doc/release-notes)
- `bitcoind` manual page: https://man.archlinux.org/man/extra/bitcoin-daemon/bitcoind.1.en
- Docker `run` reference: https://docs.docker.com/reference/cli/docker/container/run/
- Issues and suggestions: https://github.com/romeujr/docker-bitcoin-core/issues

Bitcoin Core is released under the [MIT license](https://github.com/bitcoin/bitcoin/blob/master/COPYING). This image is a community project and is not affiliated with the Bitcoin Core project.
