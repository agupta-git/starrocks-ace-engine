# Strict ACE RBAC verification — starrocks-ace-engine

Evidence that **starrocks-ace-engine 1.11.4** deploys correctly under strict ACE RBAC on a live AWC stack.

**Verified:** 2026-11-13 (UTC)  
**Instances:** `starrocks-3` and `starrocks-4` (both `starrocks-ace-engine` 1.11.4)  
**Evidence below** uses `starrocks-3` on `starrocks-cluster-3`; see [multi-instance comparison](#multi-instance-comparison-same-awc-environment) for `starrocks-4`.

Platform docs: [strict ACE RBAC](https://github.infra.cloudera.com/AWC/awc-core/blob/main/services/ace-hub/docs/features/strict-ace-rbac.md), [ace-operator strict mode](https://github.infra.cloudera.com/AWC/ace-operator/blob/main/docs/operator_configuration.md#--strict-ace-rbac).

---

## Success criteria (all required)

| # | Check | Result |
|---|--------|--------|
| 1 | `role.yaml` passes ACE Hub `ValidateEngineRBAC` | **PASS** |
| 2 | ace-hub and ace-operator run with `--strict-ace-rbac=true` | **PASS** |
| 3 | No `ace-operator-manager-cluster-admin` ClusterRoleBinding | **PASS** (NotFound) |
| 4 | Per–EngineInstance RBAC `<ei-ns>-engine` (+ Kyverno mirror + impersonate) | **PASS** |
| 5 | `EngineInstance` Running; `spec.serviceAccountName` set | **PASS** |
| 6 | Flux `HelmRelease` sets `spec.serviceAccountName`; chart uses engine SA + `watchNamespace` | **PASS** |
| 7 | StarRocks CRDs installed with engine CRD-owner labels | **PASS** |
| 8 | FE reachable over MySQL (strict path exercised through install) | **PASS** (BE slot capacity blocked DDL; not RBAC) |

---

## 1. Pre-deploy: validate `role.yaml`

From `awc-core/services/ace-hub`:

```bash
go run ./cmd/validate-engine-rbac /path/to/starrocks-ace-engine/role.yaml
```

**Observed output:**

```
PASS: .../starrocks-ace-engine/role.yaml (1 ClusterRole, 1 Role)
exit=0
```

---

## 2. Control plane (console cluster)

**EngineDeployment** (namespace `ace-hub-system`):

```
phase=Running
EngineInstanceReady=True
```

Strict-mode scoped cluster RBAC names recorded in status (excerpt):

```
c005-starrocks-3-1de878-engine
c005-starrocks-3-1de878-engine-kyverno
```

**ace-hub** manager args include:

```
--strict-ace-rbac=true
```

---

## 3. Workload cluster

Obtain workload credentials from the console RemoteCluster secret (do not commit):

```bash
kubectl -n ace-hub-system get secret <remote-cluster>-kubeconfig \
  -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/workload-kubeconfig.yaml
export KUBECONFIG=/tmp/workload-kubeconfig.yaml
```

Set `NS` and `EI` for your instance:

```bash
NS=c005-starrocks-3-1de878
EI=starrocks-3-starrocks-ace-cluster
```

### 3.1 ace-operator strict mode

```
--strict-ace-rbac=true
```

```
$ kubectl get clusterrolebinding ace-operator-manager-cluster-admin
Error from server (NotFound): clusterrolebindings.rbac.authorization.k8s.io "ace-operator-manager-cluster-admin" not found
```

### 3.2 Scoped engine RBAC (ACE Hub)

```
NAME                                       AGE
role/c005-starrocks-3-1de878-engine        5h41m
rolebinding/c005-starrocks-3-1de878-engine
rolebinding/c005-starrocks-3-1de878-impersonate   # → helm-controller @ flux-system
clusterrole/c005-starrocks-3-1de878-engine
clusterrole/c005-starrocks-3-1de878-engine-kyverno
clusterrolebinding/c005-starrocks-3-1de878-engine
clusterrolebinding/c005-starrocks-3-1de878-engine-kyverno
```

Namespaced `Role` includes expected API groups (13 rules), including `starrocks.com` and `security.awc.cloudera.com`. Cluster `ClusterRole` holds cluster-scoped rules only (3 rules; no `starrocks.com` in ClusterRole — as designed).

### 3.3 EngineInstance SA

```
serviceAccountName=starrocks-3-starrocks-ace-cluster
phase=Running
```

ServiceAccounts in namespace: `starrocks-3-starrocks-ace-cluster` (engine SA) and `default`.

### 3.4 Flux + kube-starrocks chart (strict template path)

| Object | Expected | Observed |
|--------|----------|----------|
| `HelmRelease` `spec.serviceAccountName` | engine SA | `starrocks-3-starrocks-ace-cluster` |
| HelmRelease Ready | True | `ready=True` |
| Operator Deployment `serviceAccountName` | engine SA | `starrocks-3-starrocks-ace-cluster` |
| Rendered values `operator.global.rbac.create` | false (when SA set) | present in release values |
| `starrocksOperator.watchNamespace` | instance NS | `c005-starrocks-3-1de878` |

No chart-owned `starrocks-ace-engine-role` ClusterRoleBinding; only ACE-managed `${NS}-engine` objects.

### 3.5 CRD ownership (Kyverno)

```
starrocksclusters.starrocks.com labels:
  hub.ecosystem.awc.cloudera.com/crd-owner-kind=engine
  hub.ecosystem.awc.cloudera.com/crd-owner-name=starrocks-ace-engine
```

### 3.6 Runtime

```
$ kubectl get starrockscluster -n $NS
PHASE=reconciling  FESTATUS=running  BESTATUS=reconciling
```

SQL probe (`examples/validate-queries.sh`):

- `SHOW FRONTENDS` — **OK** (FE leader alive).
- `CREATE TABLE` — failed with `Cluster has no available capacity` (sizing/capacity, not RBAC).

---

## Multi-instance comparison (same AWC environment)

Two independent Console deployments of `starrocks-ace-blueprint` (v1.11.4), checked from the same console kubeconfig and each workload cluster’s `RemoteCluster` kubeconfig secret (`starrocks-cluster-3-kubeconfig`, `starrocks-cluster-4-kubeconfig`).

| Item | **starrocks-3** | **starrocks-4** |
|------|-----------------|-----------------|
| Console blueprint | `starrocks-3` | `starrocks-4` |
| `EngineDeployment` | `starrocks-3-starrocks-ace-cluster` | `starrocks-4-starrocks-ace-cluster` |
| `EngineDeployment` phase | Running | Running |
| `RemoteCluster` | `starrocks-cluster-3` | `starrocks-cluster-4` |
| EngineInstance **namespace** (`<ei-ns>`) | `c005-starrocks-3-1de878` | `c007-starrocks-4-7155a1` |
| EngineInstance **name** | `starrocks-3-starrocks-ace-cluster` | `starrocks-4-starrocks-ace-cluster` |
| EngineInstance phase | Running | Running |
| EngineInstance **ServiceAccount** | `starrocks-3-starrocks-ace-cluster` | `starrocks-4-starrocks-ace-cluster` |
| Namespaced **Role** | `c005-starrocks-3-1de878-engine` | `c007-starrocks-4-7155a1-engine` |
| **RoleBinding** (engine) | `c005-starrocks-3-1de878-engine` | `c007-starrocks-4-7155a1-engine` |
| **RoleBinding** (Flux impersonate) | `c005-starrocks-3-1de878-impersonate` | `c007-starrocks-4-7155a1-impersonate` |
| **ClusterRole** / **CRB** (engine) | `c005-starrocks-3-1de878-engine` | `c007-starrocks-4-7155a1-engine` |
| **ClusterRole** / **CRB** (Kyverno) | `c005-starrocks-3-1de878-engine-kyverno` | `c007-starrocks-4-7155a1-engine-kyverno` |
| Flux **HelmRelease** | `starrocks-3-1420d4` (Ready) | `starrocks-4-640e58` (Ready) |
| `HelmRelease.spec.serviceAccountName` | `starrocks-3-starrocks-ace-cluster` | `starrocks-4-starrocks-ace-cluster` |
| `starrocksOperator.watchNamespace` | `c005-starrocks-3-1de878` | `c007-starrocks-4-7155a1` |
| Operator **Deployment** | `starrocks-3-starrocks-ace-cluster-operator` | `starrocks-4-starrocks-ace-cluster-operator` |
| Operator pod **ServiceAccount** | `starrocks-3-starrocks-ace-cluster` | `starrocks-4-starrocks-ace-cluster` |
| `StarRocksCluster` phase | reconciling | running |
| `ace-operator-manager-cluster-admin` | NotFound | NotFound |

**Isolation:** Separate workload Kubernetes clusters, namespace prefixes (`c005-` vs `c007-`), engine ServiceAccount names, and `<ei-ns>-engine` RBAC objects—strict scoped RBAC is **per EngineInstance**, not shared across deploys.

```bash
# Re-check both instances (console kubeconfig)
CONSOLE_KC=<path-to-console-kubeconfig>
export KUBECONFIG="$CONSOLE_KC"
for pair in "starrocks-cluster-3:c005-starrocks-3-1de878:starrocks-3-starrocks-ace-cluster" \
            "starrocks-cluster-4:c007-starrocks-4-7155a1:starrocks-4-starrocks-ace-cluster"; do
  IFS=: read -r RC NS EI <<< "$pair"
  kubectl -n ace-hub-system get secret "${RC}-kubeconfig" -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/wc.yaml
  KUBECONFIG=/tmp/wc.yaml kubectl get engineinstance -n "$NS" "$EI" \
    -o jsonpath="${RC} ns=${NS} sa={.spec.serviceAccountName} phase={.status.phase}{\"\n\"}"
done
```

---

## What this does not prove

- **Kyverno policy matrix** — only that CRD owner labels exist and RBAC objects match strict naming.
- **Full SQL workload** — blocked by BE capacity on this test cluster; RBAC path is already proven by Running `EngineInstance`, Ready `HelmRelease`, FE query port, and scoped RBAC.

---

## Quick re-check script

```bash
# workload cluster
NS=<engine-instance-namespace>
EI=<engine-instance-name>

kubectl get engineinstance -n "$NS" "$EI" -o jsonpath='sa={.spec.serviceAccountName} phase={.status.phase}{"\n"}'
kubectl get role,rolebinding,clusterrole,clusterrolebinding -n "$NS" | grep "${NS}-engine"
kubectl get helmrelease -n "$NS" -o json | jq -r '.items[] | "\(.metadata.name) sa=\(.spec.serviceAccountName)"'
kubectl get deploy -n "$NS" -l app.kubernetes.io/component=starrocksoperator -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.serviceAccountName}{"\n"}{end}'
```

---

## References in this repo

- `role.yaml` — `ClusterRole` + `Role` split for `ValidateEngineRBAC`
- `engine.yaml` — `rbac.create: false`, engine SA, `watchNamespace` when `.ServiceAccountName` is set
- `examples/validate-queries.sh` — post-deploy FE connectivity check

---

## Mental model: operator runtime vs Helm install vs RBAC

StarRocks on AWC is **operator-based at runtime** and **Helm-based for install**. The checks in this doc prove that the strict-RBAC path still delivers a working operator.

| Layer | What it is |
|-------|------------|
| **Runtime** | The StarRocks Kubernetes operator reconciles `StarRocksCluster` (`starrocks.com`) and owns FE/BE workloads. |
| **Install on AWC** | ace-operator creates a Flux `HelmRelease` for the **kube-starrocks** umbrella chart, which installs the **operator Deployment** and the **StarRocksCluster** CR in one release. |
| **Permissions (strict)** | ACE Hub applies engine `role.yaml` per EngineInstance and binds it to the **EngineInstance ServiceAccount (SA)**. Flux installs the chart **as that SA** (`HelmRelease.spec.serviceAccountName`). |

**“Disable chart-owned operator RBAC”** does not mean StarRocks stops using an operator. It means `engine.yaml` sets `operator.global.rbac.create: false` so kube-starrocks does **not** render its bundled ClusterRole/Role/Bindings for the operator. Instead, the operator pod runs as the **EngineInstance SA**, and permissions come only from validated `role.yaml` (`<ei-ns>-engine` Role + ClusterRole). With `.ServiceAccountName` set, the chart also sets `starrocksOperator.watchNamespace` to the instance namespace so the operator does not need a cluster-wide watch.

```
EngineInstance (ACE Hub)
  → ace-operator: HelmRelease + spec.serviceAccountName = engine SA
    → Flux helm-controller (impersonates engine SA)
      → kube-starrocks chart:
          · StarRocks operator Deployment     (operator-based runtime)
          · StarRocksCluster CR               (operator reconciles)
          · chart operator RBAC templates     OFF (rbac.create: false)
      → permissions: role.yaml via ACE Hub (<ei-ns>-engine bindings)
```
