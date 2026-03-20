#!/bin/bash
set -euo pipefail

PHASE=${1:?Usage: $0 <baseline|localdns> [runs]}
RUNS=${2:-5}
NAMESPACE="dnsperf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

for i in $(seq 1 ${RUNS}); do
  JOB_NAME="dnsperf-${PHASE}-run${i}"
  OUTPUT_DIR="${PROJECT_DIR}/results/${PHASE}/run${i}"
  mkdir -p "${OUTPUT_DIR}/raw"

  echo ""
  echo "========================================"
  echo " [Run ${i}/${RUNS}] ${JOB_NAME}"
  echo "========================================"

  # Job 생성 (job name만 변경하여 apply)
  sed "s/name: dnsperf-baseline-run1/name: ${JOB_NAME}/" \
    "${PROJECT_DIR}/manifests/dnsperf-job.yaml" \
    | kubectl apply -f -

  # Job 완료 대기
  echo "Waiting for job completion..."
  kubectl wait --for=condition=complete job/${JOB_NAME} -n ${NAMESPACE} --timeout=600s

  # 결과 수집
  echo "Collecting results..."
  PODS=$(kubectl get pods -n ${NAMESPACE} -l job-name=${JOB_NAME} -o jsonpath='{.items[*].metadata.name}')
  for POD in ${PODS}; do
    kubectl logs -n ${NAMESPACE} ${POD} > "${OUTPUT_DIR}/raw/${POD}.log" 2>/dev/null
  done

  # Job 삭제 (다음 run을 위해)
  kubectl delete job ${JOB_NAME} -n ${NAMESPACE}

  echo "[Run ${i}] Done. Results in ${OUTPUT_DIR}"

  # 다음 run 전 30초 대기
  if [ ${i} -lt ${RUNS} ]; then
    echo "Waiting 30s before next run..."
    sleep 30
  fi
done

echo ""
echo "=== All ${RUNS} runs complete for phase: ${PHASE} ==="
