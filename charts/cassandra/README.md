# cassandra Helm chart

Cassandra 4.1 as a plain StatefulSet. It uses no operator, no Bitnami images and no chart dependencies, so it works in an air-gapped environment.

## Install

The namespace is created outside the chart, so it can enforce Pod Security `restricted`:

```bash
kubectl create namespace cassandra
kubectl label namespace cassandra pod-security.kubernetes.io/enforce=restricted
helm install cassandra . -n cassandra -f my-values.yaml --timeout 30m
```

The `--timeout` matters. Helm waits for the superuser bootstrap Job, and that Job waits for all nodes to join, which takes about 2 minutes per node.

## Air-gapped / private registry

Mirror these two images. Their versions are set in `values.yaml`:

| Image | Used by |
|---|---|
| `docker.io/library/cassandra:4.1.11` | Cassandra pods, the init container, the auth bootstrap Job, the `helm test` pod |
| `registry.k8s.io/kubectl:v1.36.5` | repair and snapshot CronJobs |

```yaml
global:
  imageRegistry: registry.internal:5000   # replaces the registry of both images
  imagePullSecrets: [{name: regcred}]
image:
  repository: mirror/cassandra            # if your mirror uses a different path
  digest: sha256:...                      # optional, wins over the tag
maintenance:
  image:
    repository: mirror/kubectl
```

cert-manager is a prerequisite managed outside this chart. The chart only creates `Certificate` resources against an existing Issuer or ClusterIssuer, and installs or mirrors nothing from cert-manager.
Without cert-manager, use TLS option B (your own keystores).

## Superuser

With `auth.enabled=true` (the default), the chart creates Secret `<release>-cassandra-superuser`, or `cassandra` when the release is named `cassandra`.
It is a `kubernetes.io/basic-auth` Secret: the username is `auth.superuser.name` and the password is 32 random characters.
Helm keeps the same password on every upgrade, and the Secret is kept on uninstall because the role survives in the retained volumes.

A post-install/post-upgrade Job then:

1. waits until every node has joined;
2. sets `system_auth`, `system_distributed` and `system_traces` to `NetworkTopologyStrategy` with RF min(3, replicas). It retries while a rolling restart is in progress, because Cassandra rejects RF changes while any node is down;
3. creates the superuser;
4. disables the built-in `cassandra/cassandra` role (`auth.superuser.disableDefault`).

The Job is idempotent and runs again on every upgrade. To bring your own credentials, set `auth.superuser.existingSecret` to a Secret with `username` and `password` keys.
To read the password:

```bash
kubectl -n cassandra get secret cassandra-superuser -o jsonpath='{.data.password}' | base64 -d
```

## Internode TLS

Set `tls.internode.enabled: true`. Nodes then use mutual TLS on port 7000 with PKCS12 keystore and truststore files.
Hostname verification stays off, because pod IPs change. Peers are trusted through the CA instead.

**A) cert-manager (default).** The chart creates one `Certificate` for all nodes, with the `*.<svc>` names and both server and client auth.
cert-manager writes `keystore.p12` and `truststore.p12` into the Secret, encrypted with a generated password (or `tls.internode.passwordSecret`).
The issuer must provide a CA certificate (CA, Vault or self-signed issuers do; ACME does not), otherwise no truststore is written.

```yaml
tls:
  internode:
    enabled: true
    certManager:
      issuerRef: {name: my-ca-issuer, kind: ClusterIssuer}
```

**B) Your own keystores.** Set `certManager.enabled: false`, then set `existingSecret` to a Secret containing `keystoreFile` and `truststoreFile`, and `passwordSecret` to a Secret whose `password` key holds the store password.
JKS works too: set `storeType: JKS` and change the file names.

**Certificate renewal needs no restart, so don't add Reloader.** The Secrets are mounted directly, not through `subPath`, so a renewed certificate appears in the pods after about a minute.
Cassandra checks its key files every 10 minutes, each node on its own schedule, and reloads changed ones. It logs `SSL certificates have been updated for server_encryption_options` (and `client_encryption_options`).

This was tested on a 3-node cluster by forcing a renewal of both certificates. All nodes served the new certificates within 242 seconds, with no restarts and no errors.
The mixed period, where some nodes have reloaded and some haven't, is harmless because old and new certificates come from the same CA. Worst case is about 11 minutes, well within `renewBefore` (30 days).

- **Only new connections use the new certificate.** Internode connections are long-lived, so existing sessions keep the old certificate until they reconnect. That's fine for routine renewal.
- **For an emergency rotation (compromised key), restart deliberately** once cert-manager has issued the new certificate. This rolls one pod at a time and respects the PDB:
  `kubectl -n cassandra rollout restart statefulset/cassandra`
- **Alert on `Failed to hot reload the SSL Certificates` in the Cassandra logs.** It means a renewed file couldn't be loaded, for example after a keystore password change, and the node keeps serving the old certificate.

**Turning TLS on for a running cluster** takes three rolling restarts. Wait for each one to finish before starting the next:

```bash
# 1. load keystores and accept TLS, still send plaintext
helm upgrade cassandra . -n cassandra -f my-values.yaml --timeout 30m \
  --set tls.internode.encryption=none,tls.internode.optional=true
# 2. send TLS, still accept plaintext from nodes not yet restarted
helm upgrade cassandra . -n cassandra -f my-values.yaml --timeout 30m \
  --set tls.internode.optional=true
# 3. TLS only
helm upgrade cassandra . -n cassandra -f my-values.yaml --timeout 30m
```

Don't skip step 1. Cassandra's own instructions start at step 2, but those assume every node already has a keystore.
Without one, the not-yet-restarted nodes can't answer TLS, and the first restarted node fails with `Unable to gossip with any peers`.
If that happens, upgrade with step 1's values and delete the crashlooping pod: an `OrderedReady` StatefulSet won't replace a pod that never became Ready on its own.

For a fresh install, enable TLS from the start in one step.

## Client TLS (CQL, port 9042)

Set `tls.client.enabled: true`. This works like internode TLS: a cert-manager `Certificate` (option A) or your own keystores (option B), with PKCS12 by default, a generated password, and renewals picked up automatically.

```yaml
tls:
  client:
    enabled: true
    requireClientAuth: true        # also require client certificates (mutual TLS)
    certManager:
      issuerRef: {name: my-client-ca, kind: ClusterIssuer}
```

- **One CA for both works, with the NetworkPolicy on.** Cassandra 4.1 accepts any certificate from the trusted CA on port 7000; checking peers by certificate identity only arrives in 5.0.
  So if application certificates come from the same CA, they would pass the internode check. `networkPolicy.enabled` (default `true`) closes that gap by letting only the Cassandra pods reach port 7000. See [Network policy](#network-policy).
- **`optional: true`** accepts plaintext and TLS on 9042 at the same time, so existing clients can move over gradually. Set it back to `false` when they're done.
- **What clients need:** trust `ca.crt` from Secret `<release>-cassandra-client-tls`. The server certificate covers the `-client` Service and the pod DNS names, but not pod IPs.
  Drivers connect to peers by IP, so turn hostname validation off and keep CA validation on. With the Java driver 4.x, that's `advanced.ssl-engine-factory.hostname-validation = false`.
- **With `requireClientAuth`**, every client needs its own certificate signed by the client CA, on top of username and password.
- **Built-in cqlsh calls are handled.** The auth bootstrap Job reads `ca.crt`, `tls.crt` and `tls.key` from the Secret. With option B, put those PEM files in your Secret as well. Repair and snapshots use nodetool (JMX on localhost) and aren't affected.

cqlsh inside a pod with client TLS:

```bash
kubectl -n cassandra exec -it cassandra-0 -c cassandra -- bash -c \
  'printf "[ssl]\ncertfile=/etc/cassandra/tls/client/ca.crt\nuserkey=/etc/cassandra/tls/client/tls.key\nusercert=/etc/cassandra/tls/client/tls.crt\n" > /tmp/rc; cqlsh --ssl --cqlshrc /tmp/rc -u admin'
```

## Network policy

`networkPolicy.enabled` (default `true`) adds an ingress allow-list to the Cassandra pods:

| Port | Allowed from |
|---|---|
| 7000 internode | only the Cassandra pods of this release |
| 9042 CQL | anyone, or only `networkPolicy.cqlFrom` (the auth bootstrap Job is always allowed) |
| anything else | nobody |

```yaml
networkPolicy:
  enabled: true
  cqlFrom:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: my-app}
```

This is what makes a single CA safe: an application certificate is valid on port 7000, but the application can't reach that port.
It needs a CNI that enforces NetworkPolicy, such as Cilium or Calico. Others accept the object and silently ignore it, so test it as described below.
Set `enabled: false` if the cluster manages policies some other way.

To check it, run the chart's test:

```bash
helm test cassandra -n cassandra --logs
```

It starts a pod without the Cassandra labels and checks each node. 9042 must accept a TCP connection, which proves the node is up and reachable. 7000 must not.
On a cluster whose network plugin ignores NetworkPolicy, it fails with `7000 reachable from a non-Cassandra pod; the CNI is NOT enforcing NetworkPolicy`.
It uses the Cassandra image, so nothing extra has to be mirrored. Run it after the first install and whenever the network plugin changes.
The test pod is allowed through `cqlFrom` automatically, but only from the same namespace.

## cassandra.yaml settings

The chart ships the stock 4.1 `cassandra.yaml` (`files/cassandra-4.1.yaml`) and merges `config:` over it. Nested maps are merged and lists are replaced.
The result is rendered into ConfigMap `<release>-cassandra-config`, and any change triggers a rolling restart.

```yaml
config:
  concurrent_compactors: 2
  compaction_throughput: 32MiB/s
  auto_snapshot: false
  server_encryption_options:
    accepted_protocols: [TLSv1.3]
```

The chart always sets these itself: `cluster_name`, `seed_provider`, `listen_address`, `rpc_address`, `broadcast_rpc_address`, `endpoint_snitch`.
With auth on, it also sets `authenticator` and `authorizer`. With TLS on, it sets the keystore, truststore and mode keys of `server_encryption_options`.
Cassandra refuses to start on an unknown key, so a typo shows up as a crash of the first restarted pod, and the PDB stops it from spreading.
If you change the image to a different minor version, replace `files/cassandra-4.1.yaml` with that version's file.

## Other values

| Value | Default | Notes |
|---|---|---|
| `replicaCount` | 3 | Needs that many nodes (hard anti-affinity). To scale down, run `nodetool decommission` first. |
| `cluster.name`, `cluster.datacenter` | `cassandra-k8s`, `dc1` | Effectively fixed after first start. |
| `jvm.heap`, `jvm.newSize` | `2G`, `400M` | Written to `jvm-server.options`. |
| `resources` | 1500m CPU, 5Gi memory | No CPU limit on purpose. |
| `persistence.size`, `.storageClass` | `20Gi`, cluster default | Immutable through `helm upgrade`. Expand existing PVCs directly instead. |
| `maintenance.repair.*` | Sundays 01:00 | `nodetool repair -full -pr`, run on one node after another. |
| `maintenance.snapshot.*` | daily 02:00 | `daily-<weekday>` tags, 7 kept, stored on the same PVC (not off-site). |
