#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWC_MARKETPLACE="${AWC_MARKETPLACE:-awc-marketplace}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <registry-url> <namespace>

Publish starrocks-ace-engine and its blueprint to an OCI marketplace registry.

Arguments:
  registry-url    Destination registry host (e.g., registry.example.com)
  namespace       OCI namespace for artifacts (e.g., my-org/awc-marketplace)

Environment:
  AWC_MARKETPLACE   Path to awc-marketplace binary (default: awc-marketplace on PATH)

Examples:
  $(basename "$0") registry.example.com my-org/awc-marketplace
EOF
    exit 1
}

if [[ $# -ne 2 ]]; then
    usage
fi

REGISTRY="$1"
NAMESPACE="$2"

VERSION="$(yq '.spec.versionCatalog[0].displayName' "$SCRIPT_DIR/engine.yaml")"
BLUEPRINT_VERSION="$(yq '.spec.versionMatrix[0].displayVersion' "$SCRIPT_DIR/blueprint.yaml")"

echo "==> Validating starrocks-ace-engine"
"$AWC_MARKETPLACE" validate "$SCRIPT_DIR"
"$AWC_MARKETPLACE" validate --blueprint "$SCRIPT_DIR/blueprint.yaml"

echo "==> Publishing starrocks-ace-engine version $VERSION"
"$AWC_MARKETPLACE" publish \
    --namespace "$NAMESPACE" \
    "$SCRIPT_DIR" \
    --version "$VERSION" \
    --push \
    --destination-registry "$REGISTRY" \
    --force

echo "==> Publishing starrocks-ace-blueprint blueprint version $BLUEPRINT_VERSION"
"$AWC_MARKETPLACE" publish \
    --namespace "$NAMESPACE" \
    --blueprint "$SCRIPT_DIR/blueprint.yaml" \
    --version "$BLUEPRINT_VERSION" \
    --push \
    --destination-registry "$REGISTRY" \
    --instance "starrocks-ace-cluster=starrocks-ace-engine:${VERSION}" \
    --force

echo "==> Done. Catalog contents:"
"$AWC_MARKETPLACE" catalog fetch \
    --registry "$REGISTRY" \
    --namespace "$NAMESPACE"
