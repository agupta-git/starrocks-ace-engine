# StarRocks ACE Engine

ACE engine that deploys StarRocks via the upstream **[kube-starrocks](https://starrocks.github.io/starrocks-kubernetes-operator/helm-charts/charts/kube-starrocks/)** umbrella Helm chart. Each instance installs the operator and a minimal shared-nothing cluster (1 FE + 1 BE) through Flux in a single Helm release.

**Constraint:** one StarRocks instance per cluster.


|                      | Name                                                |
| -------------------- | --------------------------------------------------- |
| Engine               | `starrocks-ace-engine`                              |
| Blueprint / instance | `starrocks-ace-blueprint` / `starrocks-ace-cluster` |
| Version              | `1.11.4` (chart, operator) · FE/BE `3.4.3`          |


---

## Workflow

```
Prepare → Publish → Add registry to Console → Deploy → Verify
```


| Phase           | What happens                                                           |
| --------------- | ---------------------------------------------------------------------- |
| Prepare         | Mirror chart, update catalogs, configure registry auth                 |
| Publish         | Push engine + blueprint OCI artifacts to your private registry         |
| Console catalog | Add `${REGISTRY}/${NAMESPACE}` to AWC Console catalog sources          |
| Deploy          | Launch blueprint from AWC Console UI                                   |
| Runtime         | ace-operator → Flux → kube-starrocks → StarRocks operator → FE/BE pods |


---

## Prerequisites

**Tools:** `helm` v3, [awc-marketplace](https://github.infra.cloudera.com/AWC/awc-marketplace-spec) CLI (`make cli`), `yq`, `docker login` (or credential helper) for your private OCI registry.

**Cluster sizing** (default: 2 CPU / 4Gi per FE and BE pod):


|               | Used for testing                        |
| ------------- | --------------------------------------- |
| Workers (AWS) | `c5.2xlarge` or `m5.2xlarge`, × 2 nodes |
| Root disk     | 100 GiB                                 |


`blueprint.yaml` encodes these for AWC Console cluster provisioning.

---

## Prepare for Publish

```bash
export REGISTRY="<your-registry>"     # docker-sandbox.infra.cloudera.com
export NAMESPACE="<your-namespace>"   # awc-partners
```

### 1. Build awc-marketplace CLI

```bash
git clone https://github.infra.cloudera.com/AWC/awc-marketplace-spec.git
cd awc-marketplace-spec && make cli
export AWC_MARKETPLACE="$(pwd)/awc-marketplace"
```

### 2. Authenticate

```bash
docker login "${REGISTRY}"
```

Credentials are read from `~/.docker/config.json` by `helm push` and `awc-marketplace publish --push`.

### 3. Mirror kube-starrocks chart

```bash
helm repo add starrocks https://starrocks.github.io/starrocks-kubernetes-operator
helm repo update
helm pull starrocks/kube-starrocks --version 1.11.4
helm push kube-starrocks-1.11.4.tgz "oci://${REGISTRY}/${NAMESPACE}"
helm show chart "oci://${REGISTRY}/${NAMESPACE}/kube-starrocks" --version 1.11.4
```

Update `chartcatalog.yaml`:

```yaml
spec:
  charts:
    - id: kubeStarrocks
      registry: <your-registry>
      repository: <your-namespace>/kube-starrocks
      version: "1.11.4"
```

`awc-marketplace publish --push` mirrors public Docker Hub images from `imagecatalog.yaml` into your registry.

### 4. **Add registry pull credentials to control plane secret**

Before deploy, merge `${REGISTRY}` credentials into the source secret `awc-console-registry-creds` in `auth-config-operator-system` on the control plane. A reflector propagates this secret to workload instance namespaces so Flux can pull charts and images at deploy time.

```bash
export KUBECONFIG="<control-plane-kubeconfig>"
SOURCE_NS="auth-config-operator-system"
SECRET_NAME="awc-console-registry-creds"

# inspect
kubectl get secret "${SECRET_NAME}" -n "${SOURCE_NS}" \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths | keys[]'

docker login "${REGISTRY}"

kubectl get secret "${SECRET_NAME}" -n "${SOURCE_NS}" \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/cluster-dockerconfig.json

jq -s '.[0].auths += .[1].auths | .[0]' \
  /tmp/cluster-dockerconfig.json ~/.docker/config.json \
  > /tmp/merged-dockerconfig.json

kubectl patch secret "${SECRET_NAME}" -n "${SOURCE_NS}" --type=merge \
  -p "{\"data\":{\".dockerconfigjson\":\"$(base64 < /tmp/merged-dockerconfig.json | tr -d '\n')\"}}"
```

---

## Publish to Marketplace

```bash
./starrocks-ace-engine/publish.sh "${REGISTRY}" "${NAMESPACE}"
```

Validates, then pushes `starrocks-ace-engine:1.11.4` and `starrocks-ace-blueprint:1.11.4` (instance wiring: `starrocks-ace-cluster=starrocks-ace-engine:1.11.4`).

---

## Add OCI Registry to AWC Console

After publishing, AWC Console must scan your OCI registry namespace to discover engine and blueprint artifacts. One-time per `${REGISTRY}/${NAMESPACE}`.

```bash
export KUBECONFIG="<control-plane-kubeconfig>"
kubectl config current-context
```

Append your namespace to the comma-separated `MARKETPLACE_REGISTRIES` list in `awc-taikun-secrets` (`awc-core`). Do not replace existing entries:

```bash
CURRENT="$(kubectl get secret awc-taikun-secrets -n awc-core \
  -o jsonpath='{.data.MARKETPLACE_REGISTRIES}' | base64 -d)"
NEW_VALUE="${CURRENT},${REGISTRY}/${NAMESPACE}"

kubectl patch secret awc-taikun-secrets -n awc-core --type merge \
  -p "{\"data\":{\"MARKETPLACE_REGISTRIES\":\"$(echo -n "$NEW_VALUE" | base64)\"}}"

kubectl rollout restart deployment/awc-console -n awc-core
kubectl rollout status deployment/awc-console -n awc-core
```

Confirm `starrocks-ace-blueprint` appear in the Console marketplace catalog.

---

## Deploy from AWC Console

Select `starrocks-ace-blueprint` (v**1.11.4**) in the marketplace and start a new deployment.


| Setting                 | Value                                            |
| ----------------------- | ------------------------------------------------ |
| Kubernetes Version      | `v1.34.3`                                        |
| Compute Infrastructure  | Your AWS environment (e.g. `AWS : aws-pse-usw2`) |
| Control plane           | Defaults — 1 node, 30 GB                         |
| StarRocks Cluster Nodes | `c5.2xlarge` or `m5.2xlarge`, 2 nodes, 100 GB    |


Optional instance config overrides: see [Configuration](#configuration). Wait for healthy status, then [verify](#verify).

---

## Verify

**Console:** instance healthy; landing page URL available.

**Endpoints:**


|                    | URL                                          |
| ------------------ | -------------------------------------------- |
| Web UI             | `https://<instance>.<cluster-domain>/query`  |
| MySQL (in-cluster) | `<instance>-fe-service.<namespace>.svc:9030` |


**SQL check** (credentials: `root` / empty password). Use the **EngineInstance name**, not the AWC cluster name:

```bash
export KUBECONFIG="<workload-cluster-kubeconfig>"
./starrocks-ace-engine/examples/validate-queries.sh "<engine-instance-name>"
```

The default deploy uses 1 BE; user-created tables need `replication_num=1` (the validation script sets this automatically).

---

## Configuration

Console UI overrides map to `[engine.yaml](engine.yaml)` `configSchema`:


| Key                  | Default | Key                  | Default |
| -------------------- | ------- | -------------------- | ------- |
| `feReplicas`         | 1       | `beReplicas`         | 1       |
| `feCpu` / `feMemory` | 2 / 4Gi | `beCpu` / `beMemory` | 2 / 4Gi |
| `feMetaStorageSize`  | 10Gi    | `beStorageSize`      | 20Gi    |
| `feLogStorageSize`   | 5Gi     | `beLogStorageSize`   | 1Gi     |


---

## Troubleshooting


| Symptom                              | Fix                                                                                                          |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| Blueprint not in Console catalog     | Complete [Add OCI Registry to AWC Console](#add-oci-registry-to-awc-console); verify `awc-console` rollout   |
| `HelmRelease` `AuthenticationFailed` | Complete [Add registry pull credentials on control plane](#4-add-registry-pull-credentials-on-control-plane) |
| `HelmRelease` not Ready              | Check chart mirror, `chartcatalog.yaml` version, node sizing; `kubectl describe helmrelease`                 |
| Stale chart pull after cred fix      | Delete stale `HelmChart`, annotate `HelmRelease` with `reconcile.fluxcd.io/requestedAt`                      |


---

## Upgrade

1. Bump versions in `[engine.yaml](engine.yaml)` and `[blueprint.yaml](blueprint.yaml)`.
2. Mirror new chart version if needed.
3. `./starrocks-ace-engine/publish.sh "${REGISTRY}" "${NAMESPACE}"`
4. Deploy updated version from AWC Console.

API version: `ecosystem.awc.cloudera.com/v1alpha9`.