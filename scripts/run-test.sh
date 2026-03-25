#!/bin/bash
set -euo pipefail

# 사용법: ./scripts/run-test.sh <phase> <qps> [runs] [nodes]
#   예: ./scripts/run-test.sh baseline 40 5 5
#       ./scripts/run-test.sh localdns 80 5 10

PHASE=${1:?Usage: $0 <baseline|localdns> <qps> [runs=5] [nodes=5]}
QPS=${2:?Usage: $0 <baseline|localdns> <qps> [runs=5] [nodes=5]}
RUNS=${3:-5}
NODES=${4:-5}
NAMESPACE="dnsperf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

MANIFEST="${PROJECT_DIR}/manifests/dnsperf-job-node${NODES}.yaml"
if [ ! -f "${MANIFEST}" ]; then
  echo "Error: manifest not found: ${MANIFEST}"
  exit 1
fi

echo "=== Config: phase=${PHASE}, qps=${QPS}, runs=${RUNS}, nodes=${NODES} ==="
echo "    Manifest: ${MANIFEST}"

for i in $(seq 1 ${RUNS}); do
  JOB_NAME="dnsperf-${PHASE}-q${QPS}-run${i}"
  OUTPUT_DIR="${PROJECT_DIR}/results/${NODES}nodes/qps-${QPS}/${PHASE}/run${i}"
  mkdir -p "${OUTPUT_DIR}/raw"

  echo ""
  echo "========================================"
  echo " [Run ${i}/${RUNS}] ${JOB_NAME} (QPS=${QPS}, ${NODES} nodes)"
  echo "========================================"

  # Job 생성 (job name + QPS 변경하여 apply)
  sed -e "s/name: dnsperf-baseline-run1/name: ${JOB_NAME}/" \
      -e "s/-Q 40/-Q ${QPS}/" \
    "${MANIFEST}" \
    | kubectl apply -f -

  # Job 완료 대기
  echo "Waiting for job completion..."
  kubectl wait --for=condition=complete job/${JOB_NAME} -n ${NAMESPACE} --timeout=600s

  # 결과 수집 (병렬)
  echo "Collecting results..."
  PODS=$(kubectl get pods -n ${NAMESPACE} -l job-name=${JOB_NAME} -o jsonpath='{.items[*].metadata.name}')
  echo "${PODS}" | tr ' ' '\n' | xargs -P 20 -I {} sh -c \
    "kubectl logs -n ${NAMESPACE} {} > \"${OUTPUT_DIR}/raw/{}.log\" 2>/dev/null"

  # Job 삭제 (다음 run을 위해)
  kubectl delete job "${JOB_NAME}" -n ${NAMESPACE} --ignore-not-found

  echo "[Run ${i}] Done. Results in ${OUTPUT_DIR}"

  # 다음 run 전 30초 대기
  if [ ${i} -lt ${RUNS} ]; then
    echo "Waiting 30s before next run..."
    sleep 30
  fi
done

echo ""
echo "=== All ${RUNS} runs complete for ${NODES}nodes/${PHASE}/qps-${QPS} ==="
