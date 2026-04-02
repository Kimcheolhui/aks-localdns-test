#!/bin/bash
set -euo pipefail

# =============================================================================
# DNS Path Diagnostic Script
# 각 Case에서 DNS 요청 경로를 진단하는 스크립트
# 사용법: ./localdns-dnscache/diagnose-dns-path.sh <case_name>
#   예: ./localdns-dnscache/diagnose-dns-path.sh case2-nodelocal-only
# =============================================================================

CASE_NAME=${1:?"Usage: $0 <case_name>"}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
OUTPUT_DIR="${SCRIPT_DIR}/results/${CASE_NAME}"
mkdir -p "${OUTPUT_DIR}"

DIAG_POD="dns-diag"
NAMESPACE="default"

# 고유 nonce 생성 (캐시 회피용)
NONCE=$(date +%s%N | md5sum | head -c 8)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${OUTPUT_DIR}/experiment.log"
}

# 1. 진단 Pod가 Running인지 확인
wait_for_pod() {
  log "진단 Pod 상태 확인..."
  local max_wait=120
  local elapsed=0
  while [ ${elapsed} -lt ${max_wait} ]; do
    local status=$(kubectl get pod ${DIAG_POD} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    if [ "${status}" = "Running" ]; then
      log "✅ 진단 Pod Running"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  log "❌ 진단 Pod를 찾을 수 없거나 Running이 아님"
  exit 1
}

# 2. resolv.conf 확인
check_resolv_conf() {
  log "=== [1] Pod resolv.conf ==="
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- cat /etc/resolv.conf | tee "${OUTPUT_DIR}/resolv.conf"
  echo ""
}

# 3. DNS 쿼리 테스트 (internal + external)
run_dns_queries() {
  log "=== [2] DNS 쿼리 테스트 (nonce: ${NONCE}) ==="

  # Internal 도메인 (cluster.local)
  log "--- Internal: kubernetes.default.svc.cluster.local ---"
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- dig +all kubernetes.default.svc.cluster.local A 2>&1 | tee "${OUTPUT_DIR}/dig-internal-kubernetes.txt"
  echo ""

  # kube-dns 서비스
  log "--- Internal: kube-dns.kube-system.svc.cluster.local ---"
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- dig +all kube-dns.kube-system.svc.cluster.local A 2>&1 | tee "${OUTPUT_DIR}/dig-internal-kubedns.txt"
  echo ""

  # External 도메인 (cache miss 유도 - nonce 포함)
  log "--- External (unique): ${NONCE}.nonce.example.com ---"
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- dig +all ${NONCE}.nonce.example.com A 2>&1 | tee "${OUTPUT_DIR}/dig-external-nonce.txt"
  echo ""

  # External 도메인 (실제 도메인)
  log "--- External: login.microsoftonline.com ---"
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- dig +all login.microsoftonline.com A 2>&1 | tee "${OUTPUT_DIR}/dig-external-msft.txt"
  echo ""

  # External 도메인 (google.com)
  log "--- External: google.com ---"
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- dig +all google.com A 2>&1 | tee "${OUTPUT_DIR}/dig-external-google.txt"
  echo ""
}

# 4. 특정 IP로 직접 쿼리하여 각 DNS 컴포넌트의 응답 여부 확인
probe_dns_components() {
  log "=== [3] DNS 컴포넌트 직접 프로빙 ==="

  # kube-dns Service IP (10.0.0.10 = CoreDNS)
  log "--- Probe: CoreDNS (10.0.0.10) ---"
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- dig @10.0.0.10 kubernetes.default.svc.cluster.local A +short +time=3 +tries=1 2>&1 | tee "${OUTPUT_DIR}/probe-coredns.txt"
  echo ""

  # NodeLocal DNSCache (169.254.20.10)
  log "--- Probe: NodeLocal DNSCache (169.254.20.10) ---"
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- dig @169.254.20.10 kubernetes.default.svc.cluster.local A +short +time=3 +tries=1 2>&1 | tee "${OUTPUT_DIR}/probe-nodelocaldns.txt" || echo "UNREACHABLE" | tee "${OUTPUT_DIR}/probe-nodelocaldns.txt"
  echo ""

  # LocalDNS (169.254.10.10)
  log "--- Probe: LocalDNS (169.254.10.10) ---"
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- dig @169.254.10.10 kubernetes.default.svc.cluster.local A +short +time=3 +tries=1 2>&1 | tee "${OUTPUT_DIR}/probe-localdns-10.txt" || echo "UNREACHABLE" | tee "${OUTPUT_DIR}/probe-localdns-10.txt"
  echo ""

  # LocalDNS (169.254.10.11)
  log "--- Probe: LocalDNS (169.254.10.11) ---"
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- dig @169.254.10.11 kubernetes.default.svc.cluster.local A +short +time=3 +tries=1 2>&1 | tee "${OUTPUT_DIR}/probe-localdns-11.txt" || echo "UNREACHABLE" | tee "${OUTPUT_DIR}/probe-localdns-11.txt"
  echo ""
}

# 5. CoreDNS 로그 수집 (최근 쿼리)
collect_coredns_logs() {
  log "=== [4] CoreDNS 로그 수집 ==="
  for pod in $(kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].metadata.name}'); do
    log "--- CoreDNS pod: ${pod} ---"
    kubectl logs -n kube-system ${pod} --since=5m 2>&1 | tail -100 | tee "${OUTPUT_DIR}/coredns-${pod}.log"
    echo ""
  done
}

# 6. NodeLocal DNSCache 로그 수집
collect_nodelocaldns_logs() {
  log "=== [5] NodeLocal DNSCache 로그 수집 ==="
  for pod in $(kubectl get pods -n kube-system -l k8s-app=node-local-dns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    log "--- NodeLocal DNS pod: ${pod} ---"
    kubectl logs -n kube-system ${pod} --since=5m 2>&1 | tail -50 | tee "${OUTPUT_DIR}/nodelocaldns-${pod}.log"
    echo ""
  done
  if ! kubectl get pods -n kube-system -l k8s-app=node-local-dns --no-headers 2>/dev/null | grep -q .; then
    log "No NodeLocal DNSCache pods found"
    echo "No NodeLocal DNSCache pods" > "${OUTPUT_DIR}/nodelocaldns-not-present.txt"
  fi
}

# 7. DNS 관련 DaemonSet / Pod 상태
collect_dns_infra_state() {
  log "=== [6] DNS 인프라 상태 수집 ==="

  log "--- kube-system pods (DNS 관련) ---"
  kubectl get pods -n kube-system -o wide 2>&1 | grep -E "coredns|node-local|localdns|kube-dns" | tee "${OUTPUT_DIR}/dns-pods.txt"
  echo ""

  log "--- kube-system DaemonSets ---"
  kubectl get ds -n kube-system -o wide 2>&1 | grep -E "NAME|node-local|localdns" | tee "${OUTPUT_DIR}/dns-daemonsets.txt"
  echo ""

  log "--- kube-dns Service ---"
  kubectl get svc kube-dns -n kube-system -o yaml 2>&1 | tee "${OUTPUT_DIR}/kube-dns-svc.yaml"
  echo ""

  log "--- Node info for diag pod ---"
  local node=$(kubectl get pod ${DIAG_POD} -n ${NAMESPACE} -o jsonpath='{.spec.nodeName}')
  log "진단 Pod가 위치한 노드: ${node}"
  echo "${node}" > "${OUTPUT_DIR}/diag-pod-node.txt"
}

# 8. NodeLocal DNSCache configmap
collect_nodelocaldns_config() {
  log "=== [7] NodeLocal DNSCache ConfigMap ==="
  kubectl get configmap node-local-dns -n kube-system -o yaml 2>&1 | tee "${OUTPUT_DIR}/nodelocaldns-configmap.yaml" || echo "Not found" | tee "${OUTPUT_DIR}/nodelocaldns-configmap.yaml"
}

# 9. dig로 상세 trace (SERVER 확인용)
run_detailed_trace() {
  log "=== [8] 상세 dig trace ==="

  # 기본 nameserver로 쿼리 - SERVER 라인에서 실제 대상 확인
  log "--- Default nameserver로 internal 쿼리 ---"
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- dig kubernetes.default.svc.cluster.local A +noall +answer +comments 2>&1 | tee "${OUTPUT_DIR}/trace-internal-default.txt"
  echo ""

  log "--- Default nameserver로 external 쿼리 (unique: trace-${NONCE}.example.com) ---"
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- dig trace-${NONCE}.example.com A +noall +answer +comments 2>&1 | tee "${OUTPUT_DIR}/trace-external-default.txt"
  echo ""

  log "--- Default nameserver로 external 쿼리 (github.com) ---"
  kubectl exec ${DIAG_POD} -n ${NAMESPACE} -- dig github.com A +noall +answer +comments 2>&1 | tee "${OUTPUT_DIR}/trace-external-github.txt"
  echo ""
}

# 10. NodeLocal DNSCache 메트릭을 통해 실제 쿼리 수신 여부 확인
check_nodelocaldns_metrics() {
  log "=== [9] NodeLocal DNSCache 메트릭 확인 ==="
  local node=$(kubectl get pod ${DIAG_POD} -n ${NAMESPACE} -o jsonpath='{.spec.nodeName}')
  local nld_pod=$(kubectl get pods -n kube-system -l k8s-app=node-local-dns --field-selector spec.nodeName=${node} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [ -n "${nld_pod}" ]; then
    log "진단 Pod 동일 노드의 NodeLocal DNS: ${nld_pod}"
    # coredns metrics endpoint에서 쿼리 수 확인
    kubectl exec -n kube-system ${nld_pod} -- wget -qO- http://localhost:9253/metrics 2>/dev/null | grep -E "coredns_dns_requests_total|coredns_cache_hits_total|coredns_cache_misses_total|coredns_forward_requests_total" | tee "${OUTPUT_DIR}/nodelocaldns-metrics.txt" || echo "Metrics not available" | tee "${OUTPUT_DIR}/nodelocaldns-metrics.txt"
  else
    log "해당 노드에 NodeLocal DNSCache 없음"
    echo "No NodeLocal DNSCache on this node" > "${OUTPUT_DIR}/nodelocaldns-metrics.txt"
  fi
}

# ===== Main =====
log "=========================================="
log " DNS Path 진단 시작: ${CASE_NAME}"
log " nonce: ${NONCE}"
log "=========================================="

wait_for_pod
collect_dns_infra_state
check_resolv_conf
collect_nodelocaldns_config

# 메트릭 스냅샷 (before)
log "=== 메트릭 스냅샷 (BEFORE) ==="
check_nodelocaldns_metrics
if [ -f "${OUTPUT_DIR}/nodelocaldns-metrics.txt" ]; then
  cp "${OUTPUT_DIR}/nodelocaldns-metrics.txt" "${OUTPUT_DIR}/nodelocaldns-metrics-before.txt"
fi

run_dns_queries
probe_dns_components
run_detailed_trace
collect_coredns_logs
collect_nodelocaldns_logs

# 메트릭 스냅샷 (after)
log "=== 메트릭 스냅샷 (AFTER) ==="
check_nodelocaldns_metrics
if [ -f "${OUTPUT_DIR}/nodelocaldns-metrics.txt" ]; then
  cp "${OUTPUT_DIR}/nodelocaldns-metrics.txt" "${OUTPUT_DIR}/nodelocaldns-metrics-after.txt"
fi

log "=========================================="
log " DNS Path 진단 완료: ${CASE_NAME}"
log " 결과: ${OUTPUT_DIR}/"
log "=========================================="
