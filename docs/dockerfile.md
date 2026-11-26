# The Dockerfile, explained

This guide walks through the [`Dockerfile`](../Dockerfile) of `romeujr/bitcoin-core` from top to bottom. It is written for people who know some Linux shell (bash) but have not written many Dockerfiles.

For every part you will find, where it applies:

- **What** it does;
- **Why** it is there;
- **Without it**: what would go wrong if it were missing;
- **Why this way**: the advantages of the chosen approach over the obvious alternatives.

The goal is that you can **trust the image because you checked it, not because you were told to**. The last two sections show how to [verify a published image yourself](#verify-it-yourself) and list [what you still have to trust](#what-you-still-have-to-trust).

Read this next to the Dockerfile. Its `RUN` instruction is split into numbered sections (`# 1. Validate build arguments…` to `# 8. Clean up…`), and this guide uses the same numbers.

---

## Contents

- [The big picture](#the-big-picture)
- [A few words first](#a-few-words-first)
- [The `syntax` line](#the-syntax-line)
- [`FROM debian:trixie-slim`](#from-debiantrixie-slim)
- [`ARG`: build arguments](#arg-build-arguments)
- [`LABEL`: metadata](#label-metadata)
- [`ENV`: environment variables](#env-environment-variables)
- [One `RUN`, one layer](#one-run-one-layer)
  - [1. Validate arguments, map the platform](#1-validate-arguments-map-the-platform)
  - [2. The unprivileged `bitcoin` user](#2-the-unprivileged-bitcoin-user)
  - [3. Packages](#3-packages)
  - [4. Download and verify the release](#4-download-and-verify-the-release)
  - [5. Install](#5-install)
  - [6. The entrypoint](#6-the-entrypoint)
  - [7. The health check helper](#7-the-health-check-helper)
  - [8. Clean up](#8-clean-up)
- [After the `RUN`: `STOPSIGNAL` and `ENTRYPOINT`](#after-the-run-stopsignal-and-entrypoint)
- [What is deliberately *not* in the Dockerfile](#what-is-deliberately-not-in-the-dockerfile)
- [Verify it yourself](#verify-it-yourself)
- [What you still have to trust](#what-you-still-have-to-trust)

---

## The big picture

The Dockerfile does four things:

1. starts from a small, official Debian image;
2. downloads the **official Bitcoin Core release** and refuses to continue unless it is signed by several independent Bitcoin Core builders and matches its published checksum;
3. installs it **unchanged** (only the GUI and the test programs are removed);
4. adds two small bash scripts, written inline: an **entrypoint** that protects your data and shuts `bitcoind` down cleanly, and an optional **health check**.

It is a **single file**. There is no `COPY` or `ADD`, and [`.dockerignore`](../.dockerignore) excludes everything (`*`), so not a single file of this repository other than the Dockerfile itself reaches the build. Everything that ends up in the image is either in the Dockerfile, in the Debian base image, in a Debian package, or in the verified Bitcoin Core release.

The chain of trust for the Bitcoin Core binaries looks like this:

```
Bitcoin Core builders (independent people, reproducible Guix builds)
        │  each one signs the same SHA256SUMS file with their own GPG key
        ▼
SHA256SUMS + SHA256SUMS.asc  ──  downloaded from bitcoincore.org
        │  must carry ≥ 3 valid signatures from keys published in
        │  github.com/bitcoin-core/guix.sigs (at a pinned commit)
        ▼
bitcoin-<version>-<arch>.tar.gz  ──  its SHA-256 must match SHA256SUMS
        │  extracted as is into /opt
        ▼
the image  ──  built by GitHub Actions, signed with cosign,
               with SBOM and SLSA provenance attached
```

---

## A few words first

| Term | Meaning here |
|---|---|
| **Image** | A read-only template (files + settings) from which containers are started. |
| **Layer** | Each `RUN`, `COPY` or `ADD` instruction adds a layer: a snapshot of the files it changed. An image is a stack of layers. A file deleted in a *later* layer is hidden, but still stored (and downloaded) in the earlier one. |
| **Build argument** (`ARG`) | A parameter of the build (`--build-arg NAME=value`). It exists only while the image is being built. |
| **Environment variable** (`ENV`) | Stored in the image; present both during the build and in every running container. |
| **BuildKit** | The builder behind `docker build` / `docker buildx build` since Docker 23. |
| **Heredoc** | The shell syntax `<<'EOF' … EOF` to pass several lines of text to a command. BuildKit accepts it in a Dockerfile too. |
| **PID 1** | The first process of a container. When it exits the container stops, and `docker stop` sends its signal to it. |
| **Volume / bind mount** | Storage that lives outside the container: a Docker-managed volume, or a host directory mounted with `-v /host/path:/container/path`. |
| **Digest** | `sha256:…`, the hash of an image or file. Unlike a tag (`32.1`, `latest`), it can never point to different content. |

---

## The `syntax` line

```dockerfile
# syntax=docker/dockerfile:1
```

**What.** Tells BuildKit which version of the Dockerfile language (the "frontend") to use: the newest stable 1.x release.

**Why.** The whole build happens in a `RUN <<'EOF'` heredoc, a feature added to the Dockerfile language in 2021. This line makes BuildKit fetch a frontend that understands it, even if the Docker installation itself is older.

**Without it.** The built-in frontend of an older Docker would fail to parse the heredoc, or (on very old versions) treat it as a broken shell command.

**Why this way.** `:1` follows bug and security fixes of the 1.x line without breaking changes. The exact frontend used is recorded, by digest, in the [provenance](#3-see-how-and-from-what-it-was-built) of every published image.

---

## `FROM debian:trixie-slim`

```dockerfile
FROM debian:trixie-slim
```

**What.** Starts from the Docker Official Image of Debian 13 "trixie", in its `slim` variant (no documentation, man pages or locales: about 80 MB).

**Why.**

- Bitcoin Core release binaries are linked against **glibc**. Debian has it; Alpine (musl) does not, so the official binaries would not run there without recompiling, and recompiling is exactly what we want to avoid (see [section 4](#4-download-and-verify-the-release)).
- The entrypoint and health check are bash scripts and need a shell plus a few standard tools (`awk`, `sed`, `stat`, `setpriv`). "Distroless" images have no shell.
- Debian has a security team, signed package archives and long support.

**Without it.** A `FROM` is mandatory. A different base would mean either recompiling Bitcoin Core (losing the "identical to the official release" property) or giving up the shell scripts.

**Why this way.** The base is referenced by **tag, not by digest**, on purpose: the supported versions are [rebuilt every month](publishing.md#automatic-security-rebuilds) (with `--pull`) to pick up Debian security updates. A digest would freeze the base, and its vulnerabilities, until someone updated it. Nothing is lost for auditing: the exact digest used for each build is recorded in the provenance, and the base name in the `org.opencontainers.image.base.name` label.

---

## `ARG`: build arguments

```dockerfile
ARG TARGETPLATFORM
ARG P_TARGETPLATFORM
ARG P_BITCOIN_VERSION
ARG P_MIN_SIGNATURES=3
ARG P_GUIX_SIGS_REF=main
ARG P_REVISION=""
```

**What.** Declares the parameters of the build:

| Argument | Role |
|---|---|
| `TARGETPLATFORM` | Set automatically by BuildKit (`linux/amd64`, `linux/arm64`…). It must be declared with `ARG` to be visible inside `RUN`. |
| `P_TARGETPLATFORM` | Optional override of the platform (e.g. `linux/arm/v7`). |
| `P_BITCOIN_VERSION` | **Required.** The Bitcoin Core version to install. |
| `P_MIN_SIGNATURES` | How many builder signatures must be valid (default 3). |
| `P_GUIX_SIGS_REF` | Which commit (or branch/tag) of `bitcoin-core/guix.sigs` provides the builders' public keys. |
| `P_REVISION` | Commit of this repository, stored as a label. |

**Why.** One Dockerfile builds every version and every architecture. The `P_` prefix marks *our* parameters, so they cannot be confused with variables of the running container (`B_UID`, `BITCOIN_DATA`…) or with BuildKit's own.

**Without it.** One Dockerfile per version and architecture, or values edited by hand before each build.

**Why this way.**

- `P_BITCOIN_VERSION` has **no default**: a build that forgets it fails at once (section 1) instead of silently building some old version.
- `P_MIN_SIGNATURES=3` makes the build depend on several independent people, not one. You can raise it for stricter builds.
- `P_GUIX_SIGS_REF` defaults to `main` so a manual build just works, but the publishing script resolves `main` to a **commit hash** before building and passes that. The keys that verified a published image are therefore fixed and public (see the label below).
- Build arguments and their values are recorded in the image history and in the provenance, so anyone can see how a given image was built.

---

## `LABEL`: metadata

```dockerfile
LABEL org.opencontainers.image.title="bitcoin-core" \
      org.opencontainers.image.revision="${P_REVISION}" \
      io.github.romeujr.bitcoin-core.guix-sigs-ref="${P_GUIX_SIGS_REF}" \
      org.opencontainers.image.version="${P_BITCOIN_VERSION}" \
      org.opencontainers.image.source="https://github.com/romeujr/docker-bitcoin-core" \
      …
```

**What.** Key/value metadata stored in the image. Most keys follow the [OCI annotations standard](https://github.com/opencontainers/image-spec/blob/main/annotations.md).

**Why.** So that any copy of the image, wherever it ends up, says where it came from:

- `revision`: the exact commit of this repository (and so the exact Dockerfile) it was built from;
- `io.github.romeujr.bitcoin-core.guix-sigs-ref`: the exact commit of `bitcoin-core/guix.sigs` whose keys verified the release;
- `version`, `source`, `documentation`, `base.name`: what it is and where to read more.

**Without it.** You would have to guess which Dockerfile produced an image, or trust the tag name.

**Why this way.** Standard keys are understood by registries, scanners and tools (Docker Hub, GHCR, Trivy, Renovate…). Read them with `docker image inspect` ([step 4 below](#4-see-which-keys-verified-the-release)).

---

## `ENV`: environment variables

```dockerfile
ENV B_UID=1000 \
    B_GID=1000 \
    BITCOIN_DATA=/home/bitcoin/.bitcoin \
    BITCOIN_VERSION=${P_BITCOIN_VERSION} \
    DEBIAN_FRONTEND=noninteractive \
    PATH=/opt/bitcoin/bin:${PATH}
```

**What / why**, variable by variable:

| Variable | Role | Without it |
|---|---|---|
| `B_UID`, `B_GID` | Default user and group id that `bitcoind` runs as; change them at run time with `-e B_UID=…` ([section 6](#user-and-group-b_uid--b_gid)). | The ids would be hard-coded, and files on a bind mount would belong to whoever has uid 1000 on the host. |
| `BITCOIN_DATA` | Default data directory, checked by the entrypoint. | The path would be repeated in several places. |
| `BITCOIN_VERSION` | Lets the entrypoint print the version and give correct example commands (`romeujr/bitcoin-core:32.1`). | Build arguments do not exist at run time; the version would be unknown inside the container. |
| `DEBIAN_FRONTEND=noninteractive` | `apt-get` never stops to ask questions. | A package that asks a question (time zone, restart services…) would hang the build. |
| `PATH` | `bitcoind`, `bitcoin-cli`… can be called by name. | Every command would need the full path: `docker exec bitcoind /opt/bitcoin/bin/bitcoin-cli …`. |

**Why this way.** `ENV` (and not `ARG`) because these values are needed **when the container runs**. `DEBIAN_FRONTEND` also stays in the image; it does nothing at run time, but helps images built `FROM` this one when they install extra packages ([Extending the image](../README.md#extending-the-image)).

---

## One `RUN`, one layer

```dockerfile
RUN <<'EOF'
#!/bin/bash
set -euo pipefail
…
EOF
```

**What.** The entire build (checks, user creation, download, verification, installation, scripts, cleanup) is one bash script, run by a single `RUN` instruction.

**Why.**

- **One layer.** Tools needed only during the build (`gpg`), the downloaded archive, the package lists and temporary files are deleted at the end *of the same `RUN`*, so they never exist in the image. If they were deleted in a later `RUN`, they would still be stored in the earlier layer: a bigger image, and build-only tools anybody could extract from it.
- **One readable script.** You read it top to bottom like any bash script, without `&& \` at the end of every line.

**The details of the first lines:**

| Part | What it does | Without it |
|---|---|---|
| `<<'EOF'` with **quotes** | bash receives the script exactly as written; `$VARIABLES` are expanded by bash when the script runs, where build arguments are available as normal variables. | Without quotes, the Dockerfile parser may expand variables before bash sees the script, so what runs is not exactly what you read. |
| `#!/bin/bash` | BuildKit runs the heredoc with bash. | It would run with `/bin/sh` (dash in Debian), which lacks `pipefail`, arrays and `[[ … ]]`. |
| `set -e` | Stop at the first command that fails. | A failed download or verification would be ignored and the build would continue. **This is what makes the verification in section 4 binding.** |
| `set -u` | Using an undefined variable is an error. | A typo in a variable name would silently become an empty string (e.g. `rm -rf "${WROK}/"`). |
| `set -o pipefail` | A pipeline fails if *any* command in it fails. | In `curl … \| tar …`, a failed `curl` would be hidden by a successful `tar`. |

**Why this way.** The usual alternative, several `RUN` lines joined with `&&`, is harder to read and easy to get wrong (one forgotten `&&` and errors are ignored). A heredoc gives a real script with real error handling.

---

### 1. Validate arguments, map the platform

```bash
if [ -z "${P_BITCOIN_VERSION:-}" ]; then
  echo "ERROR: build argument P_BITCOIN_VERSION is required, …" >&2
  exit 1
fi

PLATFORM="${P_TARGETPLATFORM:-${TARGETPLATFORM:-}}"
case "${PLATFORM}" in
  linux/amd64)               ARCH=x86_64-linux-gnu ;;
  linux/arm64|linux/arm64/*) ARCH=aarch64-linux-gnu ;;
  …
  *) echo "ERROR: unsupported platform '${PLATFORM}'." >&2; exit 1 ;;
esac
```

**What.** Checks that a version was given, then translates the Docker platform name (`linux/arm64`) into the name Bitcoin Core uses in its archive file names (`aarch64-linux-gnu`).

**Why.** Docker and Bitcoin Core name architectures differently. The mapping is needed to download the right file.

**Without it.** A missing version would produce a confusing download error (`bitcoin--x86_64…`); an unknown platform would download nothing or the wrong file.

**Why this way.** Fail **early** with a message that says what to do, before downloading anything. The `case` lists every supported platform explicitly, so adding or removing one is a one-line change that is easy to review.

---

### 2. The unprivileged `bitcoin` user

```bash
useradd --create-home --no-log-init --uid 1000 --user-group --shell /bin/bash bitcoin
install -d -m 0700 -o bitcoin -g bitcoin "${BITCOIN_DATA}"
```

**What.** Creates a normal user `bitcoin` (uid/gid 1000, with a home directory) and its data directory `/home/bitcoin/.bitcoin`, readable only by that user (`0700`).

**Why.** `bitcoind` is a network-facing program; it should never run as root. If it were ever compromised, the attacker would get an ordinary user, not root, inside the container.

**Without it.** `bitcoind` would run as root: a bug in it would be a bug with every privilege of the container, and every file it writes on a bind mount would belong to root on the host.

**Why this way.**

- `--no-log-init` avoids writing to `/var/log/lastlog` and `faillog`, files that grow with the uid and are useless in a container (a recommendation from Docker's own best practices).
- `install -d -m … -o … -g …` creates, sets permissions and owner in one command (instead of `mkdir` + `chmod` + `chown`).
- The uid 1000 is only a default: the entrypoint can [remap it at run time](#user-and-group-b_uid--b_gid).

---

### 3. Packages

```bash
SAVED_APT_MARK="$(apt-mark showmanual)"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gpg
```

**What.** Remembers which packages the base image already had, then installs:

- `ca-certificates` and `curl`: download over HTTPS;
- `gpg`: check the builders' signatures.

**Why.** These are the only tools needed to download and verify the release. `gpg` is removed again in [section 8](#8-clean-up); `curl` and `ca-certificates` stay because `-blocknotify` / `-walletnotify` scripts often need them.

**Without it.** No download, no verification.

**Why this way.**

- `--no-install-recommends` installs only what is strictly required (the log shows the "Recommended packages" that were skipped). Fewer packages, less to update and to scan.
- `SAVED_APT_MARK` makes the cleanup in section 8 precise: it removes exactly what this build added and nothing the base image needs.
- About `http://deb.debian.org` in the build log: `apt` downloads over HTTP but **verifies every package** against the Debian archive's GPG signatures (`InRelease`). A tampered package is rejected even over plain HTTP.

---

### 4. Download and verify the release

This is the most important part of the Dockerfile.

#### Background: how Bitcoin Core releases are signed

Bitcoin Core builds its releases with [Guix](https://guix.gnu.org/), a system that makes builds **reproducible**: different people, on different machines, compiling the same source, get **bit-for-bit identical** files. Several independent contributors (the "builders") each do the build and then GPG-sign the same `SHA256SUMS` file, which lists the SHA-256 of every release file. All these signatures are concatenated in `SHA256SUMS.asc`. The builders' public keys are published in the [`bitcoin-core/guix.sigs`](https://github.com/bitcoin-core/guix.sigs) repository, in the `builder-keys/` folder.

So if several builders, who do not depend on each other, signed the same checksums, then the files on bitcoincore.org are the ones produced from the public source code.

#### Download

```bash
WORK="$(mktemp -d)"
cd "${WORK}"
BASE_URL="https://bitcoincore.org/bin/bitcoin-core-${P_BITCOIN_VERSION}"
ARCHIVE="bitcoin-${P_BITCOIN_VERSION}-${ARCH}.tar.gz"

curl -fsSL --remote-name-all "${BASE_URL}/${ARCHIVE}" "${BASE_URL}/SHA256SUMS" "${BASE_URL}/SHA256SUMS.asc"
curl -fsSL "https://github.com/bitcoin-core/guix.sigs/archive/${P_GUIX_SIGS_REF}.tar.gz" \
  | tar -xz --wildcards --strip-components=1 '*/builder-keys/*'
```

**What.** In a fresh temporary directory, downloads the release archive for this architecture, `SHA256SUMS` and `SHA256SUMS.asc` from bitcoincore.org, and only the `builder-keys/` folder of `guix.sigs`, at the commit given by `P_GUIX_SIGS_REF`.

**Why.** These are the four inputs of the verification: the file, its checksum list, the signatures on that list, and the public keys of the signers.

**Without it.** Nothing to verify.

**Why this way.**

- `curl -f` turns an HTTP error (404, 500) into a failure, so with `set -e` the build stops right there. Without `-f`, an HTML error page would be saved as if it were the archive, and the build would fail later with a confusing message.
- The keys come from a **different place** (GitHub) than the files (bitcoincore.org). An attacker who controls bitcoincore.org alone cannot also replace the keys.
- The keys are taken at a **pinned commit** (recorded in the label), so the key set used for a published image never changes afterwards and can be inspected by anyone.

#### Check the signatures

```bash
export GNUPGHOME="${WORK}/gnupg"
install -d -m 0700 "${GNUPGHOME}"
gpg --batch --quiet --import builder-keys/*.gpg 2>/dev/null || true

gpg --batch --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS > gpg-status.txt 2>/dev/null || true
if grep -q '^\[GNUPG:\] BADSIG ' gpg-status.txt; then
  echo "ERROR: SHA256SUMS.asc contains an invalid signature." >&2
  exit 1
fi
GOOD_SIGNATURES="$(grep -cE '^\[GNUPG:\] (GOODSIG|EXPKEYSIG) ' gpg-status.txt || true)"
…
if [ "${GOOD_SIGNATURES}" -lt "${P_MIN_SIGNATURES}" ]; then
  echo "ERROR: expected at least ${P_MIN_SIGNATURES} valid signatures, found ${GOOD_SIGNATURES}." >&2
  exit 1
fi
```

**What.**

1. Creates an **empty, private** GPG keyring in the temporary directory and imports the builders' keys into it.
2. Verifies every signature in `SHA256SUMS.asc` and writes GPG's machine-readable status lines (`--status-fd 1`) to a file.
3. If **any** signature is bad (`BADSIG`), the build stops.
4. Counts the valid signatures and prints who made them (visible in the build log: `Valid builder signatures on SHA256SUMS: 5`, then the names).
5. If there are fewer than `P_MIN_SIGNATURES` (3), the build stops.

**Why.**

- A `BADSIG` means a signature that does not match the file: `SHA256SUMS` was modified after being signed. There is no innocent explanation, so it is a hard stop.
- Requiring **several** valid signatures means one stolen key, or one dishonest builder, is not enough to get a fake release accepted.

**Without it.** The image would contain whatever bitcoincore.org (or anybody between it and the build machine) served. The checksum check below would prove nothing on its own, because the checksums come from the same server as the file.

**Why this way.**

- **Status lines, not exit codes.** `gpg --verify` returns an error as soon as *one* signature cannot be checked, which is normal: `SHA256SUMS.asc` often has signatures from builders whose keys are not in `builder-keys/`. Using the exit code would either reject every release or (with `|| true` alone) accept anything. Reading the `[GNUPG:]` lines lets the script decide precisely: any `BADSIG` → stop; count the good ones → compare with the threshold. Signatures from unknown keys (`ERRSIG`/`NO_PUBKEY`) simply do not count.
- **`|| true` on the import.** If one key file in `builder-keys/` cannot be imported, the build should not stop: that key simply cannot produce a valid signature, and the threshold still has to be met by the others.
- **`EXPKEYSIG` counts as valid.** It means the signature is cryptographically correct, but the key has *since* expired. Old releases were signed years ago with keys that have expired since; without this, older versions could no longer be built. Revoked keys (`REVKEYSIG`) are **not** counted.
- **A private keyring (`GNUPGHOME`)** contains only the builder keys. Nothing else on the machine can influence the result, and the directory is deleted in section 8.
- GPG's "This key is not certified with a trusted signature" warning does not matter here: trust does not come from GPG's web of trust, but from the key set in `guix.sigs` at a known commit plus the threshold of independent signers.

#### Check the archive

```bash
awk -v f="${ARCHIVE}" '$2 == f || $2 == "*" f' SHA256SUMS > archive.sha256
if [ ! -s archive.sha256 ]; then
  echo "ERROR: ${ARCHIVE} is not listed in SHA256SUMS." >&2
  exit 1
fi
sha256sum -c archive.sha256
```

**What.** Takes the line of `SHA256SUMS` for this archive and checks that the downloaded file has exactly that SHA-256 (`bitcoin-23.1-x86_64-linux-gnu.tar.gz: OK` in the log).

**Why.** The signatures prove that `SHA256SUMS` is authentic; this step proves the **archive** is the one listed in it. Together: the archive is the one the builders built.

**Without it.** A valid, signed `SHA256SUMS` could be served next to a modified archive.

**Why this way.**

- `awk` compares the **whole** file name column (also in the `*name` form `sha256sum` uses for binary mode). `grep` would treat the dots as wildcards and match anywhere in the line.
- An archive that is not listed gets a clear error message, instead of `sha256sum`'s "no properly formatted checksum lines found".

---

### 5. Install

```bash
tar -xzf "${ARCHIVE}" -C /opt
ln -s "/opt/bitcoin-${P_BITCOIN_VERSION}" /opt/bitcoin
rm -f /opt/bitcoin/bin/bitcoin-qt /opt/bitcoin/bin/test_bitcoin … /opt/bitcoin/share/man/man1/bitcoin-qt.1
bitcoind -version | sed -n 1p
```

**What.** Extracts the verified archive to `/opt/bitcoin-<version>`, creates the shortcut `/opt/bitcoin`, removes the graphical wallet (`bitcoin-qt`) and the test programs, then runs `bitcoind -version` once.

**Why.**

- The release files are used **as they are**: nothing is compiled, patched or replaced. Anyone can [check that the files in the image are identical to the official release](#5-compare-the-binaries-with-the-official-release).
- The GUI cannot be used in a container without a display, and the tests are not needed to run a node: removing them makes the image smaller and leaves less code to scan.
- Running `bitcoind -version` proves the binary actually starts on this architecture and finds its libraries (`Bitcoin Core version v23.1.0` in the log). A broken image fails the build instead of failing on your server.

**Without it.** No Bitcoin Core in the image.

**Why this way.** `/opt/bitcoin` is a stable path for `PATH`, whatever the version, while `/opt/bitcoin-<version>` keeps the original folder name of the release, so it can be compared with the archive directly.

---

### 6. The entrypoint

```bash
cat > /opt/entry-point.sh <<'SCRIPT'
#!/bin/bash
…
SCRIPT
chmod 0755 /opt/entry-point.sh
bash -n /opt/entry-point.sh
```

**What.** Writes the script `/opt/entry-point.sh`, the program that runs first every time a container starts. It decides what to run, sets up the user, checks the data directory, and then **replaces itself** with `bitcoind`.

**Why it is written inside the Dockerfile** (and not copied from a separate file): the Dockerfile stays self-contained; what you read is exactly what is in the image, with no build context to inspect.

**The details:**

- `<<'SCRIPT'` is quoted, so variables like `${B_UID}` are written **literally** into the file and evaluated each time the container starts. Without the quotes they would be replaced by their build-time values (mostly empty), and the script would be broken.
- `bash -n` checks the script's syntax during the build: a syntax error fails the build instead of every container that starts. CI also runs [ShellCheck](https://www.shellcheck.net/) on the scripts extracted from the built image.

What the script does, in order:

#### What to run

```bash
if [ $# -eq 0 ] || [ "${1:0:1}" = "-" ]; then
  set -- bitcoind "$@"
fi
```

**What.** No arguments, or arguments starting with `-`, mean "run `bitcoind` with these options". `bitcoin-cli`, `bitcoin-tx`, `bitcoin-util`, `bitcoin-wallet` and `bitcoin` can also be given as the command, and anything else (such as `bash`) runs as is.

**Why.** `docker run romeujr/bitcoin-core -testnet4` and `docker run romeujr/bitcoin-core bitcoin-cli …` both work, without the user having to know an entrypoint exists.

**Without it.** Users would have to type `bitcoind` every time, or use `--entrypoint` to run anything else.

The script also looks at the options: `-help` / `-version` run immediately (no data directory needed), `-regtest` relaxes some checks (below), and **`-daemon` is refused**: it would make `bitcoind` fork into the background, PID 1 would exit and the container would stop.

#### User and group (`B_UID` / `B_GID`)

```bash
if [ "$(id -u)" = "0" ]; then
  …
  [ "${B_UID}" -ne 0 ] || die "running Bitcoin Core as root (B_UID=0) is not supported."
  # Edit passwd/group directly instead of usermod/groupmod …
  sed -i -E "s/^bitcoin:([^:]*):[0-9]+:[0-9]+:/bitcoin:\1:${B_UID}:${B_GID}:/" /etc/passwd
  …
  run_as=(setpriv --reuid="${B_UID}" --regid="${B_GID}" --clear-groups)
else
  # Started with "docker run --user": run as that user, no remapping possible.
  …
fi
```

**What.** When the container starts as root (the default), the `bitcoin` user is given the uid/gid in `B_UID`/`B_GID`, and `bitcoind` is later started as that user with `setpriv`. When the container is started directly as a non-root user (`docker run --user`, Kubernetes `runAsUser`), that user is used as is.

**Why.** On a bind mount, files keep their numeric owner. If your host user is uid 1001, `-e B_UID=1001 -e B_GID=1001` makes the blockchain and wallets belong to *you* on the host, and not to some other account or to root.

**Without it.** Files on the host would belong to uid 1000 (someone else, or nobody), and fixing them would need `sudo chown -R` on hundreds of GB.

**Why this way.**

- **Root is refused** (`B_UID=0`): `bitcoind` never runs with root privileges.
- **`sed` on `/etc/passwd` instead of `usermod`**: `usermod` would recursively change the owner of the whole home directory, which contains the mounted data directory (hundreds of GB, minutes or hours at every start), and `groupmod` refuses gids already used by another group (e.g. 100). Editing the two lines is instantaneous.
- **`setpriv` instead of `su`, `sudo` or `gosu`**: `setpriv` comes with Debian (`util-linux`), so there is no extra binary to download and trust. It changes the user and then *executes* the program in place: no parent process stays behind, so `bitcoind` is still PID 1 and receives signals directly (see [Start](#start)). `--clear-groups` drops root's extra groups.
- The container still works with a **read-only root filesystem** or when started as non-root (Kubernetes "restricted" policy): the script then warns or skips remapping instead of failing.

#### The data directory checks

The blockchain is several hundred GB and takes days to download and verify. The entrypoint refuses to start `bitcoind` in situations where that data would be lost or end up somewhere you did not intend. It reads `/proc/self/mountinfo` (the kernel's list of mounts) to find which mount holds the data directory, then checks:

| Situation | What happens | Why |
|---|---|---|
| Not on any volume or bind mount | **Error**, with example commands | The data would live in the container's writable layer: it fills Docker's storage invisibly and is lost when the container is removed or recreated (for example by `docker compose up` after an image update). |
| On an **anonymous** volume (random 64-character name) | **Error** | Such volumes are created by `-v /path` without a name, or by a `VOLUME` in a derived image. They are deleted by `docker run --rm` and `docker volume prune`, and are hard to recognise. The message shows how to copy data already synced into a named volume. |
| In memory (`tmpfs`, `ramfs`) | Error; **accepted with `-regtest`** (with a warning) | Lost at every stop; a blockchain does not fit in RAM. For a throwaway regtest node in CI it is fine. |
| Kubernetes `emptyDir` | Error; accepted with `-regtest` | Deleted with the Pod: every reschedule starts from zero. |
| Mounted read-only | **Error** | `bitcoind` must write to it. |
| Not writable by the user | Empty directory: its owner is fixed; otherwise **error** with the exact `-e B_UID=… -e B_GID=…` or `chown` to use | Typical case: a host directory just created by Docker, owned by root. |
| Owned by someone else but writable | Warning | Probably the wrong `B_UID`/`B_GID`. |
| `daemon=1` in `bitcoin.conf` | Error | Same as `-daemon`. |

**Without it.** These mistakes would go unnoticed until the data was lost or the node restarted its multi-day sync from zero.

**Why this way.** Each error says what is wrong **and** gives the command to fix it, and then stops. A container that refuses to start is noticed immediately; a container that "works" while writing to the wrong place is noticed when it is too late.

#### Memory warning

```bash
if [ -r /sys/fs/cgroup/memory.max ]; then
  MEM_LIMIT="$(cat /sys/fs/cgroup/memory.max)"
…
NEEDED_MIB=$(( DBCACHE + MAXMEMPOOL + 512 ))
```

**What.** Reads the container's memory limit (cgroup v2, or v1 on older hosts) and warns if it is lower than `-dbcache` + `-maxmempool` + about 512 MiB, taking the values from the command line, `bitcoin.conf` or Bitcoin Core's defaults.

**Why.** A process that goes over the limit is killed by the kernel (OOM) with `SIGKILL`: no clean shutdown, possible database damage and a long `-reindex`.

**Without it.** The node would be killed now and then, without an obvious reason.

**Why this way.** A **warning**, not an error: actual usage varies and the person running the node may know better.

#### Start

```bash
# Always tell bitcoind which directory was checked above.
set -- bitcoind "-datadir=${DATA_DIR}" "${@:2}"
…
-rpcpassword=*|--rpcpassword=*) shown+=("${arg%%=*}=******") ;;
…
exec "${run_as[@]}" "$@"
```

**What.**

1. Passes `-datadir` explicitly, so `bitcoind` uses exactly the directory that was just checked.
2. Prints a short summary (version, user, data directory, command) with **`-rpcpassword` masked**, because container logs are often collected by other systems.
3. **`exec`**: the shell process is *replaced* by `bitcoind` (through `setpriv`).

**Why `exec` matters.** `docker stop` sends `SIGTERM` to PID 1, waits (10 s by default), then kills with `SIGKILL`. `bitcoind` handles `SIGTERM` by writing its in-memory cache to disk and closing its databases, which can take minutes.

**Without `exec`.** Bash would stay PID 1 with `bitcoind` as its child. Bash does not pass `SIGTERM` on to its children, so `bitcoind` would never hear about the stop and would be killed with `SIGKILL` when the timeout ends, risking a corrupted chainstate and a `-reindex` that takes hours or days.

---

### 7. The health check helper

```bash
cat > /opt/healthcheck.sh <<'SCRIPT'
…
SCRIPT
chmod 0755 /opt/healthcheck.sh
bash -n /opt/healthcheck.sh
```

**What.** Writes `/opt/healthcheck.sh`, which answers "is the node OK?":

- `liveness` (default): `bitcoind` is running and its RPC server answers, including while it is still starting (RPC error `-28`, "warming up");
- `readiness`: in addition, the initial block download is finished.

It finds the running `bitcoind` in `/proc`, reads its own command line (network, data directory, RPC port and credentials), and calls `bitcoin-cli getblockchaininfo` **as the same user** as `bitcoind`.

**Why.** Orchestrators (Docker, Compose, Kubernetes, ECS) need a command to decide whether a container is healthy or ready to receive traffic.

**Without it.** Each user would write their own probe, often with RPC credentials or the network hard-coded, and often run as root, which with older `bitcoin-cli` versions can create root-owned directories that `bitcoind` then cannot write to (the reason is explained in the script itself).

**Why this way.**

- **No arguments needed**: the same command works on mainnet, testnet4, signet or regtest, whatever the configuration.
- "Starting" counts as **alive**: loading a large block index can take a long time, and a node restarted because of that would just start loading again.
- It is **not enabled by default** (no `HEALTHCHECK` instruction): you choose the intervals and what your orchestrator does with an unhealthy node. Restarting a node is expensive (clean shutdown plus a long start-up), so that decision should be yours. See [Health checks](../README.md#health-checks).

---

### 8. Clean up

```bash
cd /
apt-mark auto '.*' > /dev/null
apt-mark manual ${SAVED_APT_MARK} ca-certificates curl > /dev/null
apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false
apt-get clean
rm -rf /var/lib/apt/lists/* "${WORK}" /tmp/* /var/tmp/* /root/.gnupg
```

**What.**

1. Marks every package as "automatically installed", then marks as "manually installed" only what the base image had (`SAVED_APT_MARK`) plus `ca-certificates` and `curl`.
2. `apt-get purge --auto-remove` removes everything no longer needed: `gpg` and its libraries (the build log shows `9 to remove`: `gpg`, `gpgconf`, `libgcrypt20`…).
3. Deletes the package lists, the apt cache, the download directory (archive, keys, signatures) and temporary files.

**Why.** The image should contain only what is needed to *run* the node.

**Without it.** About 5 MB of packages, plus tens of MB of package lists and the downloaded archive, would be shipped in every image. Each extra package is also more for vulnerability scanners to report and for you to evaluate.

**Why this way.** Because it happens in the **same `RUN`** as the installation, the removed files never reach any layer. The `apt-mark` trick removes exactly what this build added, including dependencies pulled in by `gpg`, without listing them by hand (the list changes between Debian versions).

---

## After the `RUN`: `STOPSIGNAL` and `ENTRYPOINT`

```dockerfile
STOPSIGNAL SIGTERM

ENTRYPOINT ["/opt/entry-point.sh"]
```

### `STOPSIGNAL SIGTERM`

**What.** The signal `docker stop` sends to PID 1.

**Why.** `SIGTERM` is the signal `bitcoind` handles with a clean shutdown. It is already Docker's default; stating it explicitly documents the intent and protects against a base image that would set something else.

**What you still have to do.** Give it time: `docker stop -t 600`, `--stop-timeout 600`, or `stop_grace_period: 10m` in Compose (see [Graceful shutdown](../README.md#graceful-shutdown)).

### `ENTRYPOINT ["/opt/entry-point.sh"]`

**What.** The program started in every container; the arguments of `docker run` are passed to it.

**Why the JSON form** (`["…"]`, called the *exec form*). The program is started directly as PID 1.

**Without the JSON form.** The *shell form* (`ENTRYPOINT /opt/entry-point.sh`) is run as `/bin/sh -c "/opt/entry-point.sh"`: `sh` becomes PID 1, does not pass `SIGTERM` on, and ignores the arguments of `docker run`. Every `docker stop` would end with a `SIGKILL`.

---

## What is deliberately *not* in the Dockerfile

Missing instructions are decisions too:

| Not used | Why |
|---|---|
| `COPY` / `ADD` | Nothing from the repository enters the image; the Dockerfile is the whole definition. [`.dockerignore`](../.dockerignore) (`*`) even makes the build context empty. |
| `VOLUME` | A `VOLUME` silently creates an **anonymous** volume when the user forgets `-v`, which is exactly what the entrypoint refuses (see the comment at the top of the Dockerfile). Without it, forgetting the volume is an error with instructions, not data at risk. |
| `EXPOSE` | `EXPOSE` publishes nothing by itself, but `docker run -P` would publish every exposed port, possibly the RPC port, to the network. You choose which ports to publish with `-p` / `ports:`. |
| `USER` | The entrypoint needs root for a moment to apply `B_UID`/`B_GID` and fix the ownership of an empty data directory. It then drops privileges with `setpriv` **before** starting `bitcoind`, and refuses uid 0. Starting the container as non-root (`--user`, Kubernetes) is also supported. |
| `HEALTHCHECK` | Opt-in, see [section 7](#7-the-health-check-helper). |
| `CMD` | Not needed: without arguments the entrypoint runs `bitcoind`. |
| Build stages (`FROM … AS builder`) | Nothing is compiled; one stage is enough and easier to audit. |

---

## Verify it yourself

You do not need to trust this document either. Each step below can be done by anyone, with public tools and data. The examples use `32.1` and `linux/amd64`; replace them with the version and platform you use.

### 1. Read the source

The image is defined entirely by one file, [`Dockerfile`](../Dockerfile), about 640 lines, most of them comments and the two embedded scripts. The build context is empty ([`.dockerignore`](../.dockerignore)), so there is nothing else to review.

### 2. Check the signature

Published images are signed by the GitHub Actions workflow [`publish.yml`](../.github/workflows/publish.yml) with [cosign](https://docs.sigstore.dev/) (cosign 2.6 or later):

```bash
cosign verify docker.io/romeujr/bitcoin-core:32.1 \
  --certificate-identity-regexp '^https://github.com/romeujr/docker-bitcoin-core/\.github/workflows/publish\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

This proves that the image was produced by **that workflow in this repository**, and not pushed by hand from somebody's machine. The signature is also recorded in the public [Rekor](https://docs.sigstore.dev/logging/overview/) transparency log.

### 3. See how and from what it was built

Every published image carries a [SLSA provenance](https://slsa.dev/) attestation, written by BuildKit during the build:

```bash
# Build arguments and the exact commit of this repository
docker buildx imagetools inspect docker.io/romeujr/bitcoin-core:32.1 --format '{{json .Provenance}}' \
  | jq '."linux/amd64".SLSA.buildDefinition.externalParameters.request.root.request.args'

# Exact digests of everything the build used: base image and Dockerfile frontend
docker buildx imagetools inspect docker.io/romeujr/bitcoin-core:32.1 --format '{{json .Provenance}}' \
  | jq -r '."linux/amd64".SLSA.buildDefinition.resolvedDependencies[] | "\(.uri)  sha256:\(.digest.sha256)"'
```

The first command shows `P_BITCOIN_VERSION`, `P_GUIX_SIGS_REF`, `vcs:source` and `vcs:revision` (the repository and commit). The second shows, for example, `pkg:docker/debian@trixie-slim?platform=linux%2Famd64  sha256:…`: the exact Debian image the build started from.

### 4. See which keys verified the release

```bash
docker pull docker.io/romeujr/bitcoin-core:32.1
docker image inspect docker.io/romeujr/bitcoin-core:32.1 --format '{{json .Config.Labels}}'
```

`io.github.romeujr.bitcoin-core.guix-sigs-ref` is a commit of `bitcoin-core/guix.sigs`. Open `https://github.com/bitcoin-core/guix.sigs/tree/<that commit>/builder-keys` to see exactly which public keys were accepted. `org.opencontainers.image.revision` is the commit of this repository: open the Dockerfile at that commit to read exactly what ran.

### 5. Compare the binaries with the official release

This is the strongest check: it does not depend on this repository, its CI or its signatures at all.

```bash
V=32.1
ARCH=x86_64-linux-gnu        # aarch64-linux-gnu for arm64
mkdir audit && cd audit

# a) Get the official release and verify it as described on
#    https://bitcoincore.org/en/download/ (signatures + checksum).
curl -fsSLO "https://bitcoincore.org/bin/bitcoin-core-${V}/bitcoin-${V}-${ARCH}.tar.gz"
curl -fsSLO "https://bitcoincore.org/bin/bitcoin-core-${V}/SHA256SUMS"
curl -fsSLO "https://bitcoincore.org/bin/bitcoin-core-${V}/SHA256SUMS.asc"
sha256sum --ignore-missing -c SHA256SUMS

# b) Extract it, and copy the same folder out of the image.
mkdir official from-image
tar -xzf "bitcoin-${V}-${ARCH}.tar.gz" -C official
docker create --name audit --platform linux/amd64 "docker.io/romeujr/bitcoin-core:${V}"
docker cp "audit:/opt/bitcoin-${V}" from-image/
docker rm audit

# c) Compare every file.
diff -r "official/bitcoin-${V}" "from-image/bitcoin-${V}"
```

The only expected differences are the files [section 5](#5-install) removes on purpose, for example (version 23.1):

```
Only in official/bitcoin-23.1/bin: bitcoin-qt
Only in official/bitcoin-23.1/bin: test_bitcoin
Only in official/bitcoin-23.1/share/man/man1: bitcoin-qt.1
```

Any line starting with `Files … differ`, or any file found only in `from-image`, would mean the binaries were changed.

### 6. Look at the layers and the settings

```bash
docker image history --no-trunc docker.io/romeujr/bitcoin-core:32.1
docker image inspect docker.io/romeujr/bitcoin-core:32.1 \
  --format 'User=[{{.Config.User}}] Entrypoint={{.Config.Entrypoint}} Volumes={{.Config.Volumes}} Ports={{.Config.ExposedPorts}}'
```

You should see the Debian base layer, the build arguments, a single `RUN`, `STOPSIGNAL SIGTERM` and the `ENTRYPOINT`, with no volumes and no exposed ports. To read the scripts exactly as they are in the image:

```bash
docker run --rm --entrypoint cat docker.io/romeujr/bitcoin-core:32.1 /opt/entry-point.sh
docker run --rm --entrypoint cat docker.io/romeujr/bitcoin-core:32.1 /opt/healthcheck.sh
```

### 7. List the Debian packages

```bash
docker buildx imagetools inspect docker.io/romeujr/bitcoin-core:32.1 --format '{{json .SBOM}}' \
  | jq -r '."linux/amd64".SPDX.packages[] | "\(.name) \(.versionInfo // "")"'
```

The SBOM (Software Bill of Materials, in SPDX format) lists every Debian package in the image, with its version, so it can be checked against vulnerability databases. Bitcoin Core itself does **not** appear in it, because the scanner does not recognise a binary release extracted into `/opt`; [step 5](#5-compare-the-binaries-with-the-official-release) covers it instead.

### 8. Rebuild it yourself

```bash
docker buildx build \
  --build-arg P_BITCOIN_VERSION=32.1 \
  --build-arg P_GUIX_SIGS_REF=<io.github.romeujr.bitcoin-core.guix-sigs-ref label> \
  -t bitcoin-core:32.1 .
bash tests/smoke.sh bitcoin-core:32.1
```

Your build will **not** have the same image digest as the published one: the Debian packages may have received updates in the meantime, and files carry the time of the build. What is reproducible is what matters: the same verification against the same keys, and **the same Bitcoin Core files**, byte for byte (step 5 works on your image too).

### 9. Read the CI logs

Every build in [GitHub Actions](https://github.com/romeujr/docker-bitcoin-core/actions) is public. The logs show the builders whose signatures were accepted, the checksum check, the [smoke tests](../tests/smoke.sh) (data directory protections, UID/GID, clean shutdown, health checks, restricted mode), ShellCheck on the embedded scripts and the [Trivy](https://trivy.dev/) vulnerability scan.

---

## What you still have to trust

No build is free of trust. These are the remaining assumptions, and what limits each one:

| You trust | Why it is reasonable / what limits the risk |
|---|---|
| The Bitcoin Core builders and the `guix.sigs` repository | At least 3 independent signatures are required; the key set is pinned to a public commit; the builds are reproducible, so anybody can rebuild the release from source and compare. |
| bitcoincore.org | It cannot serve a modified file without valid signatures from the keys on GitHub, a different system. |
| The Debian base image and the Debian archive | Docker Official Image; packages verified by `apt` against Debian's signing keys; exact base digest in the provenance. |
| The Dockerfile frontend (`docker/dockerfile:1`) and BuildKit | Official Docker components; the frontend digest is in the provenance. |
| GitHub Actions and Sigstore | They run the build and certify the signature. Step 5 does not depend on them: it compares the image with the official release directly. |

Known limitations:

- The image is **not bit-for-bit reproducible** (see step 8); the Bitcoin Core files are.
- The SBOM covers the Debian packages only (see step 7).
- A local build without `P_GUIX_SIGS_REF` uses the **current** `main` of `guix.sigs`. Published images always use a pinned commit, shown in the label.
- Images built and pushed outside GitHub Actions (possible for maintainers, see [publishing.md](publishing.md#building-and-publishing-locally-wsl)) are not signed, so they fail step 2. Do not use an image that fails it.
