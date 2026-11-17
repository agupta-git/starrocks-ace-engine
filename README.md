# StarRocks ACE Engine

ACE engine that deploys StarRocks via the upstream [kube-starrocks](https://starrocks.github.io/starrocks-kubernetes-operator/helm-charts/charts/kube-starrocks/) umbrella Helm chart. Each instance installs the operator and a minimal shared-nothing cluster (1 FE + 1 BE) through Flux in a single Helm release.

**Constraint:** one StarRocks instance per cluster.

| | Name |
| --- | --- |
| Engine | `starrocks-ace-engine` |
| Blueprint / instance | `starrocks-ace-blueprint` / `starrocks-ace-cluster` |
| Version | `1.11.4` (chart, operator) · FE/BE `3.4.3` |

Prepare → Publish → Register → Deploy → Verify

## Publish

**Tools:** `helm` v3, [awc-marketplace](https://github.infra.cloudera.com/AWC/awc-marketplace-spec) CLI (`make cli`), `yq`, and `docker login` for your private OCI registry.

```bash
git clone https://github.infra.cloudera.com/AWC/awc-marketplace-spec.git
cd awc-marketplace-spec && make cli
export AWC_MARKETPLACE="$(pwd)/awc-marketplace"

export REGISTRY="<your-registry>"     # docker-sandbox.infra.cloudera.com
export NAMESPACE="<your-namespace>"   # awc-partners
docker login "${REGISTRY}"
```

`helm push` and `awc-marketplace publish --push` read credentials from `~/.docker/config.json`.

Mirror the kube-starrocks chart, then set `registry` and `repository` in [chartcatalog.yaml](chartcatalog.yaml):

```bash
helm repo add starrocks https://starrocks.github.io/starrocks-kubernetes-operator
helm repo update
helm pull starrocks/kube-starrocks --version 1.11.4
helm push kube-starrocks-1.11.4.tgz "oci://${REGISTRY}/${NAMESPACE}"
```

```yaml
spec:
  charts:
    - id: kubeStarrocks
      registry: <your-registry>
      repository: <your-namespace>/kube-starrocks
      version: "1.11.4"
```

`publish --push` mirrors the public Docker Hub images in [imagecatalog.yaml](imagecatalog.yaml) into your registry.

```bash
./publish.sh "${REGISTRY}" "${NAMESPACE}"
```

Validates, then pushes `starrocks-ace-engine:1.11.4` and `starrocks-ace-blueprint:1.11.4` (instance wiring: `starrocks-ace-cluster=starrocks-ace-engine:1.11.4`).

## Register the registry

After publish, register the private OCI registry on the AWC control plane with [awc-oci-register](https://github.com/agupta-git/awc-oci-register). Follow that README. The tool merges pull credentials and adds the registry to the marketplace catalog.

## Deploy

Select `starrocks-ace-blueprint` (v1.11.4) in the AWC Console marketplace.

| Setting | Value |
| --- | --- |
| Kubernetes version | `v1.34.3` |
| StarRocks cluster nodes | `c5.2xlarge` or `m5.2xlarge`, 2 nodes, 100 GB |

Optional instance config overrides: see [Configuration](#configuration). Wait for a healthy status, then [verify](#verify).

## Verify

The Console shows the instance healthy and a landing page URL.

| | URL |
| --- | --- |
| Web UI | `https://<instance>.<cluster-domain>/query` |
| MySQL (in-cluster) | `<instance>-fe-service.<namespace>.svc:9030` |

SQL check (`root`, empty password). On the workload cluster, list EngineInstances and pass the `NAME` column, then the `NAMESPACE` column. The name typed in the Console is neither value.

```bash
export KUBECONFIG="<workload-cluster-kubeconfig>"
kubectl get engineinstances -A
./examples/validate-queries.sh "<NAME>" "<NAMESPACE>"
```

The default deploy uses 1 BE. User-created tables need `replication_num=1`; the validation script sets this.

## Strict ACE RBAC

[role.yaml](role.yaml) is a `ClusterRole` (Flux chart runtime, StarRocks CRD install) and a `Role` (engine template, Helm workloads, namespace-scoped StarRocks operator). With strict ACE RBAC (`features.strictAceRBAC`), [engine.yaml](engine.yaml) sets `starrocksOperator.watchNamespace` to the instance namespace, disables chart-owned operator RBAC, and runs the operator as the ACE-managed engine `ServiceAccount`.

```bash
# from a checkout of awc-core/services/ace-hub
go run ./cmd/validate-engine-rbac /path/to/starrocks-ace-engine/role.yaml
```

Live cluster checklist: [docs/strict-ace-rbac-verification.md](docs/strict-ace-rbac-verification.md).

## Configuration

Console overrides map to [engine.yaml](engine.yaml) `configSchema`:

| Key | Default | Key | Default |
| --- | --- | --- | --- |
| `feReplicas` | 1 | `beReplicas` | 1 |
| `feCpu` / `feMemory` | 2 / 4Gi | `beCpu` / `beMemory` | 2 / 4Gi |
| `feMetaStorageSize` | 10Gi | `beStorageSize` | 20Gi |
| `feLogStorageSize` | 5Gi | `beLogStorageSize` | 1Gi |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Blueprint not in the Console catalog | Register the registry with [awc-oci-register](https://github.com/agupta-git/awc-oci-register) |
| `HelmRelease` `AuthenticationFailed` | Same registration; it merges pull credentials for `${REGISTRY}` |
| `HelmRelease` not Ready | Check the chart mirror, `chartcatalog.yaml` version, and node sizing; `kubectl describe helmrelease` |
| Stale chart pull after a credential fix | Delete the stale `HelmChart` and annotate the `HelmRelease` with `reconcile.fluxcd.io/requestedAt` |

## Upgrade

1. Bump versions in [engine.yaml](engine.yaml) and [blueprint.yaml](blueprint.yaml).
2. Mirror the new chart version if needed.
3. `./publish.sh "${REGISTRY}" "${NAMESPACE}"`
4. Deploy the updated version from AWC Console.

API version: `ecosystem.awc.cloudera.com/v1alpha10`.
