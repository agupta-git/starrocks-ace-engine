#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <instance-name> [namespace]

Validate a StarRocks ACE instance by running SQL against the FE MySQL endpoint.

Arguments:
  instance-name   EngineInstance metadata.name (also the StarRocks cluster name)
  namespace       Kubernetes namespace (default: same as instance name)

Environment:
  KUBECTL         kubectl binary (default: kubectl on PATH)

The StarRocks web UI "Finished Queries" panel may remain empty even when SQL
succeeds. This script validates query execution via the MySQL protocol instead.

Examples:
  $(basename "$0") my-starrocks
  $(basename "$0") my-starrocks my-namespace
EOF
    exit 1
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
fi

INSTANCE="$1"
NAMESPACE="${2:-$INSTANCE}"
KUBECTL="${KUBECTL:-kubectl}"
POD="starrocks-validate-${INSTANCE}-$$"

cleanup() {
    "$KUBECTL" delete pod "$POD" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

FE_HOST="${INSTANCE}-fe-service.${NAMESPACE}.svc.cluster.local"
FE_PORT="9030"

echo "==> Creating ephemeral mysql client pod in namespace ${NAMESPACE}"
"$KUBECTL" run "$POD" -n "$NAMESPACE" \
    --restart=Never \
    --image=mysql:8.0 \
    --command -- sleep 3600

echo "==> Waiting for client pod to be ready"
"$KUBECTL" wait --for=condition=Ready "pod/${POD}" -n "$NAMESPACE" --timeout=120s

run_sql() {
    local sql="$1"
    "$KUBECTL" exec -n "$NAMESPACE" "$POD" -- \
        mysql -h "$FE_HOST" -P "$FE_PORT" -u root --connect-timeout=10 -e "$sql"
}

echo "==> SHOW FRONTENDS"
run_sql "SHOW FRONTENDS;"

echo "==> SHOW BACKENDS"
run_sql "SHOW BACKENDS;"

echo "==> Create test database and table"
run_sql "CREATE DATABASE IF NOT EXISTS ace_test;"
run_sql "CREATE TABLE IF NOT EXISTS ace_test.hello (id INT, message VARCHAR(100));"
run_sql "INSERT INTO ace_test.hello VALUES (1, 'hello from ace'), (2, 'validation ok');"

echo "==> SELECT validation query"
run_sql "SELECT * FROM ace_test.hello ORDER BY id;"

echo "==> Validation complete"
