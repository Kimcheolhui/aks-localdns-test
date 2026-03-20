#!/bin/bash
set -euo pipefail

RESOURCE_GROUP="rg-localdns-test"
CLUSTER_NAME="aks-localdns-test"
NODEPOOL_NAME="userpool"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Enabling LocalDNS on nodepool: ${NODEPOOL_NAME} ==="
az aks nodepool update \
  --name ${NODEPOOL_NAME} \
  --cluster-name ${CLUSTER_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --localdns-config "${SCRIPT_DIR}/localdnsconfig.json"

echo "=== Verifying resolv.conf (should show 169.254.10.10) ==="
kubectl run verify-dns --image=busybox --rm -it --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"agentpool":"userpool"}}}' \
  -- cat /etc/resolv.conf

echo "=== Done ==="
