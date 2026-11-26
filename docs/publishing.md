# Publishing (maintainers)

How the images of [`romeujr/bitcoin-core`](https://hub.docker.com/r/romeujr/bitcoin-core) are built, tested and published.

## Overview

| Piece | Role |
|---|---|
| [`Dockerfile`](../Dockerfile) | Self-contained image definition: one `RUN`, verified Bitcoin Core binaries, entrypoint and health check embedded. Explained part by part in [dockerfile.md](dockerfile.md). |
| [`versions.txt`](../versions.txt) | Every published Bitcoin Core version, one per line. **Single source of truth.** |
| [`versions.sh`](../versions.sh) | Lists `all`, `latest`, `oldest` or `supported` versions (newest release of the 3 newest majors). |
| [`build-version.sh`](../build-version.sh) | Builds one version for `linux/amd64` + `linux/arm64`, pushes it with SBOM and provenance attestations, creates the `<version>-<arch>` tags (and `latest`), optionally signs with cosign. Waits and retries when a registry rate limits it (see [Docker Hub rate limits](#docker-hub-rate-limits)). Used both locally and by CI. |
| [`build-all.sh`](../build-all.sh) | Runs `build-version.sh` for `all` or `supported` versions. |
| [`tests/smoke.sh`](../tests/smoke.sh) | Behaviour tests of a built image (data directory protections, UID/GID, clean shutdown, health checks, restricted mode...). |
| [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) | On every PR and push to `main`: lint, build the newest version on amd64 **and** arm64 (native runners) and the oldest version on amd64, smoke tests, ShellCheck of the embedded scripts, vulnerability scan (Trivy, fixable critical issues). Publishes nothing. |
| [`.github/workflows/publish.yml`](../.github/workflows/publish.yml) | Publishes to Docker Hub and GHCR, signed. Triggers below. |
| [`.github/workflows/dockerhub-description.yml`](../.github/workflows/dockerhub-description.yml) | Copies [`DOCKERHUB.md`](../DOCKERHUB.md) to the Docker Hub overview when it changes on `main`. |
| [`.github/dependabot.yml`](../.github/dependabot.yml) | Weekly updates of the GitHub Actions used. |

## One-time setup

1. **Docker Hub token.** In Docker Hub, create a personal access token ("Account settings" > "Personal access tokens"). Updating the repository description requires a token with *Read, Write, Delete* permissions (see [peter-evans/dockerhub-description](https://github.com/peter-evans/dockerhub-description)).
2. **GitHub variable and secret.** In the repository, "Settings" > "Secrets and variables" > "Actions", add:
   - on the "Variables" tab, the repository variable `DOCKERHUB_USERNAME`: `romeujr` (it is not sensitive, and as a variable it is not masked in the logs)
   - on the "Secrets" tab, the repository secret `DOCKERHUB_TOKEN`: the token above
3. **GHCR.** Nothing to configure: the workflow uses the built-in `GITHUB_TOKEN`. After the first publish, open the `bitcoin-core` package on GitHub ("Packages"), and in "Package settings" set its visibility to **Public** (new packages are private) and check that it is linked to this repository.
4. **Branch protection (recommended).** Require the `CI` checks before merging into `main`.

## Releasing a new Bitcoin Core version

1. Add the version to [`versions.txt`](../versions.txt) in a branch, open a PR. CI builds and tests the newest version on both architectures, and the oldest one on amd64.
2. Merge. `publish.yml` publishes the lines added to `versions.txt`, and moves `latest` when the newest version was added.

No local build is needed.

## Automatic security rebuilds

On the 1st of every month, `publish.yml` rebuilds the **supported** versions (`bash versions.sh supported`: the newest release of each of the 3 newest major versions) from a fresh `debian:trixie-slim`, so they get Debian security updates. Older tags are not rebuilt.

## Manual runs

"Actions" > "Publish" > "Run workflow", with:

- `supported` (default), `latest`, or `all` (every version);
- or an explicit list, e.g. `30.4 31.2`.

Rebuild `all` after a change to the `Dockerfile` that should reach older tags too.

Versions are published **one at a time**, in the order of the list (one job per version, `max-parallel: 1`), like `build-all.sh` run locally. Each version takes several minutes (smoke tests, build for both architectures, push, signatures), so `all` takes a few hours. If a job fails, "Re-run failed jobs" publishes only the versions that failed.

### Docker Hub rate limits

Docker Hub limits how many requests an account may make per hour; past it, it answers `429 Too Many Requests`. Parallel jobs used that limit up within minutes. To stay below it:

- jobs run one at a time (above), and log in to Docker Hub before their first pull;
- [`build-version.sh`](../build-version.sh) never reads digests back from Docker Hub: the index digest comes from the build's metadata file, the platform digests from GHCR, and the digests of the `<version>-<arch>` tags from the output of the command that creates them;
- when a registry still answers `429`, `build-version.sh` waits 1, 2, 4, 8, 16 and 32 minutes and tries again (`RETRIES`, default 7 attempts: 63 minutes of waiting, more than Docker Hub's hourly window) before failing. Other errors fail immediately.

## What each publish produces

For each version and each registry (`docker.io/romeujr/bitcoin-core`, `ghcr.io/romeujr/bitcoin-core`):

- `<version>`: multi-platform index (`linux/amd64`, `linux/arm64`) with SBOM (SPDX) and SLSA provenance attestations;
- `<version>-amd64`, `<version>-arm64`: single-platform tags (kept for backward compatibility);
- `latest`, for the newest version;
- keyless cosign signatures (GitHub OIDC) on all of the above;
- labels: `org.opencontainers.image.revision` (commit of this repository) and `io.github.romeujr.bitcoin-core.guix-sigs-ref` (commit of `bitcoin-core/guix.sigs` whose builder keys verified the release).

Verify a published image (signatures are made with cosign 3, so verifying them needs cosign 2.6 or later):

```bash
cosign verify docker.io/romeujr/bitcoin-core:32.1 \
  --certificate-identity-regexp '^https://github.com/romeujr/docker-bitcoin-core/\.github/workflows/publish\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

docker buildx imagetools inspect docker.io/romeujr/bitcoin-core:32.1 --format '{{json .SBOM}}'
docker buildx imagetools inspect docker.io/romeujr/bitcoin-core:32.1 --format '{{json .Provenance}}'
```

A step-by-step audit (provenance, builder keys, binaries compared byte for byte with the official release) is in [dockerfile.md](dockerfile.md#verify-it-yourself).

## Building and publishing locally (WSL)

CI is the normal path. Local publishing still works, for example for an urgent release; those images are **not signed by the workflow**, so `cosign verify` with the command above fails for them. (With cosign installed and `SIGN=true` they are signed with your own identity instead, which that command does not accept either.)

With only Docker Hub in `IMAGES` (the default), the platform digests are read from Docker Hub: a few extra requests per version, well within the limits for local use.

```bash
# Once per WSL session: emulation for the other architecture
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

docker login                       # Docker Hub
bash build-version.sh 32.1 --latest
bash build-all.sh supported        # or: bash build-all.sh all

# Also publish to GHCR (after: docker login ghcr.io)
IMAGES="docker.io/romeujr/bitcoin-core ghcr.io/romeujr/bitcoin-core" bash build-version.sh 32.1
```

Test a change before opening a PR:

```bash
docker buildx build --load --build-arg P_BITCOIN_VERSION="$(bash versions.sh latest)" -t bitcoin-core:test .
bash tests/smoke.sh bitcoin-core:test
```

The arm64 build under QEMU takes several minutes; in CI arm64 runs natively.
