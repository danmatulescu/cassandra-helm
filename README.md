# cassandra-helm

A Helm chart for **Apache Cassandra 4.1** as a plain StatefulSet, with no operator. It's built for small clusters (3 nodes) and air-gapped environments.

- One pod per node, nodes joining one at a time, a PodDisruptionBudget, and `nodetool drain` on shutdown
- A generated superuser Secret: random password, the default `cassandra/cassandra` role disabled, auth keyspaces replicated
- Private registry support: `global.imageRegistry`, pull secrets, image digests
- Internode and client (CQL) **mutual TLS**, each behind its own flag, using cert-manager or your own keystores. Renewed certificates are reloaded without a restart
- A NetworkPolicy that limits the internode port to Cassandra pods, with a `helm test` that proves the network plugin enforces it
- `cassandra.yaml` overrides through `config:`, merged over the stock 4.1 file
- Weekly repair and daily snapshot CronJobs
- Runs under Pod Security `restricted`

## Quick start

```bash
kubectl create namespace cassandra
kubectl label namespace cassandra pod-security.kubernetes.io/enforce=restricted
helm install cassandra charts/cassandra -n cassandra --timeout 30m
helm test cassandra -n cassandra --logs
```

See [charts/cassandra/README.md](charts/cassandra/README.md) for all options: TLS (and turning it on in a running cluster), air-gapped image mirroring, `cassandra.yaml` overrides, and certificate renewal.

## Requirements

- Kubernetes with at least `replicaCount` worker nodes (default 3)
- Helm 3
- Optional: cert-manager, managed separately, for TLS with an existing Issuer or ClusterIssuer
- Optional: a CNI that enforces NetworkPolicy (Cilium, Calico, ...) for the internode port restriction

## Images

| Image | Used by |
|---|---|
| `docker.io/library/cassandra:4.1.11` | Cassandra, the auth bootstrap Job, `helm test` |
| `registry.k8s.io/kubectl:v1.36.5` | repair and snapshot CronJobs |

## Attribution

`charts/cassandra/files/cassandra-4.1.yaml` is the stock configuration file from [Apache Cassandra](https://github.com/apache/cassandra) 4.1, licensed under the Apache License 2.0.

## License

[Apache License 2.0](LICENSE).
