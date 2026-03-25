#!/bin/bash
set -euo pipefail

# =============================================================================
# AKS LocalDNS 전체 실험 자동화 스크립트
#
# 사용법:
#   nohup ./scripts/run-all.sh > run-all.log 2>&1 &
#   tail -f run-all.log
#
# Phase 1: Baseline  — 5노드  (250 Pod)
# Phase 2: Baseline  — 10노드 (500 Pod)
# Phase 3: LocalDNS  — 5노드  (250 Pod)
# Phase 4: LocalDNS  — 10노드 (500 Pod)
# Phase 5: 결과 통합 및 리포트 생성
# =============================================================================

RESOURCE_GROUP="rg-localdns-test"
CLUSTER_NAME="aks-localdns-test"
NODEPOOL="userpool"
RUNS=5
QPS_LIST=(20 40 80 160)
QPS_INTERVAL=30

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

# 스크립트 전체에서 cwd를 프로젝트 루트로 고정
cd "${PROJECT_DIR}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

run_qps_loop() {
  local phase=$1
  local nodes=$2

  for qps in "${QPS_LIST[@]}"; do
    log "--- ${nodes}nodes / ${phase} / QPS ${qps} ---"
    "${SCRIPT_DIR}/run-test.sh" "${phase}" "${qps}" "${RUNS}" "${nodes}"
    python3 "${SCRIPT_DIR}/aggregate_results.py" "${qps}" "${phase}" "${nodes}"

    log "QPS 간 쿨다운 ${QPS_INTERVAL}s..."
    sleep ${QPS_INTERVAL}
  done
}

scale_nodepool() {
  local count=$1
  log "노드풀 스케일링: ${NODEPOOL} → ${count}노드"
  az aks nodepool scale \
    --name ${NODEPOOL} \
    --cluster-name ${CLUSTER_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --node-count ${count} \
    --no-wait false

  # userpool 노드 수 기준: 5 → CoreDNS 2개, 10 → CoreDNS 3개
  local expected_replicas
  if [ ${count} -le 5 ]; then
    expected_replicas=2
  elif [ ${count} -le 10 ]; then
    expected_replicas=3
  else
    expected_replicas=2
  fi

  log "스케일링 완료. CoreDNS replica 확인 (기대값: ${expected_replicas})..."

  local max_wait=300
  local interval=15
  local elapsed=0
  while [ ${elapsed} -lt ${max_wait} ]; do
    local actual=$(kubectl get deploy coredns -n kube-system -o jsonpath='{.status.readyReplicas}')
    actual=${actual:-0}
    if [ "${actual}" -eq "${expected_replicas}" ]; then
      log "✅ CoreDNS replica OK: ${actual}/${expected_replicas}"
      kubectl get deploy coredns -n kube-system
      return 0
    fi
    log "CoreDNS replica: ${actual}/${expected_replicas} — ${interval}s 후 재확인..."
    sleep ${interval}
    elapsed=$((elapsed + interval))
  done

  log "❌ CoreDNS replica가 기대값에 도달하지 못함 (현재: ${actual}, 기대: ${expected_replicas})"
  kubectl get deploy coredns -n kube-system
  log "실험 중단."
  exit 1
}

enable_localdns() {
  log "LocalDNS 활성화 중..."
  az aks nodepool update \
    --name ${NODEPOOL} \
    --cluster-name ${CLUSTER_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --localdns-config "${PROJECT_DIR}/infra/localdnsconfig.json" \
    --max-surge 0 \
    --max-unavailable 1

  log "resolv.conf 확인 (169.254.10.10 여부)..."
  local max_retries=3
  local retry_wait=300
  for attempt in $(seq 1 ${max_retries}); do
    local dns_output
    dns_output=$(kubectl run verify-dns-${attempt} --image=busybox --rm -i --restart=Never \
      --overrides='{"spec":{"nodeSelector":{"agentpool":"userpool"}}}' \
      -- cat /etc/resolv.conf 2>/dev/null) || true
    echo "${dns_output}"

    if echo "${dns_output}" | grep -q "169.254.10.10"; then
      log "✅ LocalDNS 활성화 확인 완료 (nameserver 169.254.10.10)"
      return 0
    fi

    if [ ${attempt} -lt ${max_retries} ]; then
      log "⚠️ 시도 ${attempt}/${max_retries}: 169.254.10.10 미확인. ${retry_wait}s 후 재시도..."
      sleep ${retry_wait}
    fi
  done

  log "❌ LocalDNS가 활성화되지 않음 — ${max_retries}회 시도 실패"
  log "실험 중단."
  exit 1
}

check_coredns_initial() {
  local expected=$1
  log "Phase 1 초기 CoreDNS replica 확인 (기대값: ${expected})..."

  local actual=$(kubectl get deploy coredns -n kube-system -o jsonpath='{.status.readyReplicas}')
  actual=${actual:-0}
  if [ "${actual}" -eq "${expected}" ]; then
    log "✅ CoreDNS replica OK: ${actual}/${expected}"
    kubectl get deploy coredns -n kube-system
    return 0
  fi

  log "❌ CoreDNS replica 이상 (현재: ${actual}, 기대: ${expected})"
  kubectl get deploy coredns -n kube-system
  log "실험 중단."
  exit 1
}

# =============================================================================
log "=========================================="
log " AKS LocalDNS 실험 시작"
log "=========================================="

# --- Phase 1: Baseline — 5노드 ---
log ""
log "=========================================="
log " Phase 1: Baseline — 5노드 (250 Pod)"
log "=========================================="

log "사전 준비: manifests 적용"
kubectl apply -f "${PROJECT_DIR}/manifests/dummy-services.yaml"
kubectl apply -f "${PROJECT_DIR}/manifests/dnsperf-queryfile-cm.yaml"

check_coredns_initial 2

run_qps_loop "baseline" 5

# --- Phase 2: Baseline — 10노드 ---
log ""
log "=========================================="
log " Phase 2: Baseline — 10노드 (500 Pod)"
log "=========================================="

scale_nodepool 10
run_qps_loop "baseline" 10

# --- Phase 3: LocalDNS — 5노드 ---
log ""
log "=========================================="
log " Phase 3: LocalDNS — 5노드 (250 Pod)"
log "=========================================="

scale_nodepool 5
enable_localdns
run_qps_loop "localdns" 5

# --- Phase 4: LocalDNS — 10노드 ---
log ""
log "=========================================="
log " Phase 4: LocalDNS — 10노드 (500 Pod)"
log "=========================================="

scale_nodepool 10
run_qps_loop "localdns" 10

# --- Phase 5: 결과 통합 및 리포트 ---
log ""
log "=========================================="
log " Phase 5: 결과 통합 및 리포트 생성"
log "=========================================="

cd "${PROJECT_DIR}"
python3 "${SCRIPT_DIR}/collect_summary.py"
python3 "${SCRIPT_DIR}/generate_report.py"

log ""
log "=========================================="
log " 전체 실험 완료!"
log "=========================================="
