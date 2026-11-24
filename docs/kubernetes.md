# Kubernetes and other orchestrators

How to run [`romeujr/bitcoin-core`](https://github.com/romeujr/docker-bitcoin-core) safely on Kubernetes, Amazon ECS, Docker Swarm and similar platforms.

A complete, ready-to-adapt manifest is in [`examples/kubernetes/bitcoind.yaml`](../examples/kubernetes/bitcoind.yaml): a StatefulSet with a PersistentVolumeClaim, a Secret holding `bitcoin.conf`, probes, a Service and a NetworkPolicy. It is compatible with the **restricted** Pod Security Standard.

```bash
kubectl create namespace bitcoin
kubectl -n bitcoin apply -f examples/kubernetes/bitcoind.yaml
kubectl -n bitcoin logs -f bitcoind-0
```

A Bitcoin node is a **stateful, long-running** workload with a large disk and an expensive shutdown. Most problems in orchestrated environments come from defaults that assume the opposite. The sections below cover them one by one.

---

## 1. Storage: a PersistentVolumeClaim

Use a StatefulSet with `volumeClaimTemplates` (or a PVC you create) mounted at `/home/bitcoin/.bitcoin`.

- **`emptyDir` is refused** by the image, except with `-regtest`: it is deleted with the Pod, so every reschedule, eviction or rollout would start a resync from scratch. Memory-backed `emptyDir` (`medium: Memory`) is refused as well.
- `hostPath` works but ties the node to one machine; prefer a PVC.
- Size: a full mainnet node with indexes needs several hundred GB and keeps growing. Add `-prune=<MiB>` to keep only recent blocks.
- Performance: the initial block download is I/O bound. Use an SSD storage class with enough IOPS/throughput (for example, provision them explicitly on cloud block volumes), and give it more `-dbcache` during the sync.
- Backups: a snapshot of a running node is like a power loss; it usually recovers, but may need a reindex. Scale the StatefulSet to 0 (clean shutdown) before taking a VolumeSnapshot.

## 2. Graceful shutdown: `terminationGracePeriodSeconds`

When a Pod is deleted, rescheduled or evicted (node drain, rollout, autoscaler), Kubernetes sends `SIGTERM`, waits `terminationGracePeriodSeconds` (**30 seconds by default**) and then kills the container. `bitcoind` receives the `SIGTERM` directly (it is PID 1) and flushes its caches, which can take minutes.

```yaml
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 600
```

- No `preStop` hook is needed.
- **Spot / preemptible nodes** only give between about 30 seconds and 2 minutes of notice, depending on the provider. Run the node on regular nodes, or accept the risk of a reindex (a smaller `-dbcache` shortens the flush).
- A clean stop ends with `Shutdown done` in `kubectl logs --previous`.

## 3. Security context (restricted Pod Security Standard)

The image starts as root by default only to remap `B_UID`/`B_GID`. On Kubernetes, set the ids in the Pod instead; the entrypoint detects that it is not root and runs `bitcoind` directly as that user. `B_UID`/`B_GID` are not used.

```yaml
securityContext:              # Pod
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  fsGroupChangePolicy: OnRootMismatch   # no recursive chown of the whole chain at every start
  seccompProfile:
    type: RuntimeDefault
containers:
  - securityContext:          # container
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

- `runAsNonRoot: true` **requires** `runAsUser`: the image's default user is root, so the Pod is rejected without it.
- `readOnlyRootFilesystem: true` is supported: `bitcoind` only writes to its data directory.
- Any uid works; `1000` matches the `bitcoin` user of the image.

## 4. Memory: requests, limits and `-dbcache`

If `bitcoind` exceeds the memory limit, it is **OOMKilled**, which is a `SIGKILL`: no clean shutdown, possibly a corrupted chainstate. Size the limit for:

```
dbcache (default 450 MiB) + maxmempool (default 300 MB) + ~512 MiB for the rest
```

The entrypoint prints a warning when the container's memory limit is below this estimate. During the initial sync a larger `-dbcache` (e.g. 4096) speeds things up a lot; lower it afterwards together with the limit if needed. See also [Bitcoin Core: reduce-memory.md](https://github.com/bitcoin/bitcoin/blob/master/doc/reduce-memory.md).

## 5. Probes: `/opt/healthcheck.sh`

The image ships a probe script that reads the running `bitcoind`'s own options (network, data directory, RPC port, credentials), so it needs no arguments:

| Mode | Healthy when |
|---|---|
| `/opt/healthcheck.sh liveness` | `bitcoind` runs and its RPC answers, **including** while it is still loading at start-up (`-28` "in warmup" counts as alive). |
| `/opt/healthcheck.sh readiness` | Additionally, the initial block download is finished. |

```yaml
startupProbe:
  exec: { command: ["/opt/healthcheck.sh", "liveness"] }
  periodSeconds: 10
  timeoutSeconds: 20
  failureThreshold: 360     # start-up can take long after an unclean stop
livenessProbe:
  exec: { command: ["/opt/healthcheck.sh", "liveness"] }
  periodSeconds: 60
  timeoutSeconds: 20
  failureThreshold: 5
readinessProbe:
  exec: { command: ["/opt/healthcheck.sh", "readiness"] }
  periodSeconds: 60
  timeoutSeconds: 20
```

- Always raise `timeoutSeconds`: the default (1 second) is too short for an RPC call on a busy node.
- A liveness probe that is too strict restarts the container, and every restart is a shutdown plus a long start-up: be generous.
- Readiness stays false for days during the initial sync, which is usually what you want for Services feeding wallets or explorers.

## 6. RPC access, configuration and secrets

- RPC listens on localhost by default. To reach it through a Service, set `rpcbind=0.0.0.0` and allow the Pod network with `rpcallowip=` (in the `[main]` section of `bitcoin.conf`, or on the command line).
- Keep RPC internal: a `ClusterIP` Service plus a NetworkPolicy (the example only allows Pods labelled `bitcoin-rpc-client: "true"`). Never expose 8332 through a LoadBalancer or Ingress.
- Credentials: store `bitcoin.conf` (with `rpcauth=` lines) in a **Secret** and pass `-conf=/etc/bitcoin/bitcoin.conf`. Do not put `-rpcpassword` in `args`: Pod specs are readable by anyone with access to the namespace.
- In-Pod tools use the cookie automatically:

  ```bash
  kubectl exec bitcoind-0 -- bitcoin-cli -datadir=/home/bitcoin/.bitcoin getblockchaininfo
  ```

- P2P (8333) can be exposed with a `LoadBalancer` or `NodePort` Service if you want inbound connections; outbound-only nodes need nothing.

## 7. Faster start: UTXO snapshots (assumeutxo)

Bitcoin Core 28.0 and later can start from a UTXO snapshot (`bitcoin-cli loadtxoutset <file>`): the node becomes usable quickly while the full history is still validated in the background. Bitcoin Core only accepts snapshots whose hash is built into the release. See [doc/assumeutxo.md](https://github.com/bitcoin/bitcoin/blob/master/doc/assumeutxo.md).

---

## Other orchestrators

| Platform | What to set |
|---|---|
| **Docker / Compose** | `--stop-timeout 600` / `stop_grace_period: 10m`, a named volume or bind mount, `mem_limit` sized as above. See the [README](../README.md). |
| **Docker Swarm** | `stop_grace_period: 10m` in the stack file, a volume pinned to a node (placement constraint), `resources.limits.memory`. |
| **Amazon ECS on EC2** | `stopTimeout` in the container definition (and `ECS_CONTAINER_STOP_TIMEOUT` on the agent), an EBS volume, `memory` sized as above. |
| **Amazon ECS on Fargate** | `stopTimeout` is capped (120 seconds at the time of writing): keep `-dbcache` modest, so that the flush fits. Data on EFS works but is slow for a node; EBS volumes for Fargate tasks are faster. |
| **Nomad** | `kill_timeout = "10m"`, a host or CSI volume. |
| **Serverless containers** (Cloud Run, Azure Container Apps scale-to-zero...) | Not suitable: a node needs a persistent disk and a long-lived process. |
