# AKS LocalDNS 도입 실험 계획서

## 1. 실험 목적

AKS 클러스터에서 LocalDNS 도입 전/후의 DNS 쿼리 latency 차이를 정량적으로 측정한다.
QPS 부하 수준(20, 40, 80, 160)별, 노드 규모(5, 10)별로 비교하여 부하 및 클러스터 스케일에 따른 LocalDNS 효과를 확인한다.

---

## 2. 실험 환경 구성

### 2.1 AKS 클러스터 스펙

```
리소스 그룹     : rg-localdns-test
클러스터 이름    : aks-localdns-test
리전            : Sweden Central (swedencentral)
Kubernetes 버전 : 1.33.7
노드 풀         :
  - system pool : Standard_D4as_v6 x 2 (시스템 워크로드 전용)
  - user pool   : Standard_D16as_v6 x 5 또는 10 (dnsperf 워크로드, 노드당 ~50 Pod)
네트워크 플러그인 : Azure CNI Overlay
데이터플레인     : Cilium
노드 OS         : Ubuntu 22.04.05 LTS
```

### 2.2 실험 매트릭스

| 변수 | 조건 |
|------|------|
| 노드 수 | 5, 10 |
| LocalDNS | OFF (baseline), ON (localdns) |
| Pod당 QPS | 20, 40, 80, 160 |
| 반복 횟수 | 5회 (조건 당) |

> 노드 수에 따라 CoreDNS replica 수와 총 Pod 수가 변동한다.

| 노드 수 | dnsperf Pod | CoreDNS replica (예상) |
|---------|-------------|----------------------|
| 5 | 250 | 2 |
| 10 | 500 | 3~4 |

### 2.3 클러스터 프로비저닝 (azd + Bicep)

인프라를 `azd` (Azure Developer CLI) + Bicep 으로 관리한다.

```bash
azd init        # 환경 초기화 (최초 1회)
azd provision   # 프로비저닝

az aks get-credentials --resource-group rg-localdns-test --name aks-localdns-test
```

> Bicep 정의: `infra/main.bicep`, `infra/aks.bicep` / azd 설정: `azure.yaml`

### 2.4 노드 스케일링

```bash
# 10노드로 증설
az aks nodepool scale \
  --name userpool \
  --cluster-name aks-localdns-test \
  --resource-group rg-localdns-test \
  --node-count 10

# CoreDNS replica 수 확인
kubectl get deploy coredns -n kube-system

# 5노드로 축소
az aks nodepool scale \
  --name userpool \
  --cluster-name aks-localdns-test \
  --resource-group rg-localdns-test \
  --node-count 5
```

---

## 3. DNS 쿼리 대상 구성

### 3.1 Dummy Service 배포 (`manifests/dummy-services.yaml`)

dnsperf가 resolve할 Internal 도메인이 실제로 존재해야 하므로, Headless Service(`clusterIP: None`)를 3개 namespace에 배포한다.

| Namespace | Services |
|-----------|----------|
| `app-a` | api-gateway, user-service, order-service, payment-service, notification-service |
| `app-b` | product-catalog, inventory-service, search-service, recommendation-service, cache-service |
| `app-c` | auth-service, logging-service, monitoring-service, config-service, messaging-service |

> 총 15개 Headless Service → 15개 internal FQDN 생성

### 3.2 쿼리 파일 (`manifests/dnsperf-queryfile-cm.yaml`)

dnsperf에 입력할 도메인 리스트를 ConfigMap으로 모든 Pod에 마운트한다.

| 구분 | 개수 | 예시 |
|------|------|------|
| Internal (클러스터 서비스 FQDN) | 17개 | `api-gateway.app-a.svc.cluster.local`, `kubernetes.default.svc.cluster.local` 등 |
| External (Azure 서비스) | 10개 | `login.microsoftonline.com`, `management.azure.com`, `vault.azure.net` 등 |
| External (일반 도메인) | 5개 | `google.com`, `github.com`, `amazonaws.com` 등 |
| **합계** | **32개** | |

---

## 4. dnsperf 부하 테스트 구성

### 4.1 테스트 조건

Pod당 QPS를 변경하여 4가지 부하 수준에서 테스트한다. Pod 수는 노드 수에 비례한다.

| QPS 조건 | Pod당 QPS (`-Q`) | 총 QPS (5노드/250 Pod) | 총 QPS (10노드/500 Pod) |
|----------|------------------|------------------------|-------------------------|
| **Low** | 20 | 5,000 | 10,000 |
| **Medium** | 40 | 10,000 | 20,000 |
| **High** | 80 | 20,000 | 40,000 |
| **Very High** | 160 | 40,000 | 80,000 |

공통 설정:

| 항목 | 값 |
|------|------|
| 노드 | D16as_v6 × 5 또는 10 (노드당 ~50 Pod) |
| Image | `guessi/dnsperf:latest` |
| dnsperf 고정 옵션 | `-c 10` `-S 10` `-l 60` `-v` |
| 반복 횟수 | **5회** (조건 당) |

### 4.2 dnsperf Job 매니페스트

| 매니페스트 | Pod 수 | 용도 |
|-----------|--------|------|
| `manifests/dnsperf-job-node5.yaml` | 250 (parallelism/completions) | 5노드 실험 |
| `manifests/dnsperf-job-node10.yaml` | 500 (parallelism/completions) | 10노드 실험 |

Pod를 병렬 실행하는 Kubernetes Job. `-Q 40`이 기본값이며, `run-test.sh`가 실행 시 sed로 QPS를 동적 치환한다.

### 4.3 반복 실행 스크립트 (`scripts/run-test.sh`)

사용법: `./scripts/run-test.sh <baseline|localdns> <qps> [runs=5]`

각 run에서 다음을 순차 수행한다:

1. Job 이름과 `-Q` 값을 sed로 치환하여 `kubectl apply`
2. `kubectl wait --for=condition=complete --timeout=600s` 로 완료 대기
3. 모든 Pod 로그를 `results/qps-<Q>/<phase>/runN/raw/` 에 수집 (xargs -P 20 병렬)
4. Job 삭제 → 30초 대기 → 다음 run

### 4.4 결과 집계 스크립트 (`scripts/aggregate_results.py`)

사용법: `python3 scripts/aggregate_results.py <qps> <baseline|localdns>`

각 run 디렉토리의 Pod 로그를 파싱하여 run별 독립 통계를 산출한다:

1. `-v` 옵션으로 출력된 **개별 쿼리 latency**를 전 Pod에서 수집
2. numpy로 전체 쿼리에 대한 **정확한 percentile** 산출
3. **기본 지표**: avg, min, max, stddev (ms)
4. **Percentile**: p50, p90, p95, p99 (ms)
5. **처리량**: queries sent/completed/lost, QPS
6. 출력: `results/qps-<Q>/<phase>/runN/summary.json`

### 4.5 리포트 스크립트

| 스크립트 | 용도 |
|----------|------|
| `scripts/collect_summary.py` | 전체 run summary를 `results/summary.json`으로 통합 |
| `scripts/generate_report.py` | `results/summary.json`에서 `experiment-result.md` 생성 |

---

## 5. 실험 절차

### Phase 1: Baseline — 5노드

| 단계 | 작업 |
|------|------|
| 1-1 | `azd provision`으로 AKS 클러스터 생성 (userpool 5노드) |
| 1-2 | `kubectl apply -f manifests/dummy-services.yaml` |
| 1-3 | `kubectl apply -f manifests/dnsperf-queryfile-cm.yaml` |
| 1-4 | CoreDNS replica 수 확인: `kubectl get deploy coredns -n kube-system` |
| 1-5 | QPS 20 → 40 → 80 → 160 각 5회 실행 |

> 5노드 실험이므로 `dnsperf-job-node5.yaml` (250 Pod) 사용

```bash
for qps in 20 40 80 160; do
  ./scripts/run-test.sh baseline $qps 5
  python3 scripts/aggregate_results.py $qps baseline
  sleep 30
done
```

### Phase 2: Baseline — 10노드

```bash
# 노드 증설
az aks nodepool scale --name userpool --cluster-name aks-localdns-test \
  --resource-group rg-localdns-test --node-count 10

# CoreDNS replica 수 확인 (증가했는지)
kubectl get deploy coredns -n kube-system
```

> 10노드 실험이므로 `dnsperf-job-node10.yaml` (500 Pod) 사용

```bash
for qps in 20 40 80 160; do
  ./scripts/run-test.sh baseline $qps 5
  python3 scripts/aggregate_results.py $qps baseline
  sleep 30
done
```

### Phase 3: LocalDNS — 5노드

```bash
# 노드 축소
az aks nodepool scale --name userpool --cluster-name aks-localdns-test \
  --resource-group rg-localdns-test --node-count 5

# CoreDNS replica 수 확인 (원복했는지)
kubectl get deploy coredns -n kube-system

# LocalDNS 활성화
az aks nodepool update \
  --name userpool \
  --cluster-name aks-localdns-test \
  --resource-group rg-localdns-test \
  --localdns-config ./infra/localdnsconfig.json \
  --max-surge 0 \
  --max-unavailable 1

# resolv.conf 확인 (nameserver가 169.254.10.10인지)
kubectl run verify-dns --image=busybox --rm -it --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"agentpool":"userpool"}}}' \
  -- cat /etc/resolv.conf
```

> 5노드 실험이므로 `dnsperf-job-node5.yaml` (250 Pod) 사용

```bash
for qps in 20 40 80 160; do
  ./scripts/run-test.sh localdns $qps 5
  python3 scripts/aggregate_results.py $qps localdns
  sleep 30
done
```

### Phase 4: LocalDNS — 10노드

```bash
# 노드 증설
az aks nodepool scale --name userpool --cluster-name aks-localdns-test \
  --resource-group rg-localdns-test --node-count 10

# CoreDNS replica 수 확인
kubectl get deploy coredns -n kube-system
```

> 10노드 실험이므로 `dnsperf-job-node10.yaml` (500 Pod) 사용

```bash
for qps in 20 40 80 160; do
  ./scripts/run-test.sh localdns $qps 5
  python3 scripts/aggregate_results.py $qps localdns
  sleep 30
done
```

### Phase 5: 결과 통합 및 리포트

```bash
python3 scripts/collect_summary.py
python3 scripts/generate_report.py
```

---

## 6. 비교 항목

각 조건(노드 수 × QPS × LocalDNS 유무)에 대해 5회 시행하고, 시행별로 다음 지표를 독립적으로 집계한다.

- **Latency**: avg, min, max, stddev, p50, p90, p95, p99 (ms)
- **처리량**: queries sent, queries completed, QPS achieved
- **손실률**: queries lost (%)

---

## 7. 필요 리소스 정리

| 리소스 | 스펙 |
|--------|------|
| AKS system pool | Standard_D4as_v6 x 2 |
| AKS user pool | Standard_D16as_v6 x 5 → 10 (스케일링) |

> ⚠️ 실험 완료 후 반드시 리소스 삭제  
> `azd down --purge --force`

---

## 8. 디렉토리 구조

```
aks-localdns-test/
├── azure.yaml                      # azd 프로젝트 설정
├── experiment-plan.md              # 본 실험 계획서
├── infra/
│   ├── main.bicep                  # Bicep 진입점 (subscription scope)
│   ├── main.parameters.json        # Bicep 파라미터
│   ├── aks.bicep                   # AKS 클러스터 리소스 정의
│   ├── localdns-enable.sh          # LocalDNS 활성화
│   └── localdnsconfig.json         # LocalDNS 설정 파일
├── manifests/
│   ├── dummy-services.yaml         # Internal DNS 대상 서비스
│   ├── dnsperf-queryfile-cm.yaml   # 쿼리 도메인 목록 ConfigMap
│   ├── dnsperf-job-node5.yaml      # dnsperf Job (250 Pod, 5노드용)
│   └── dnsperf-job-node10.yaml     # dnsperf Job (500 Pod, 10노드용)
├── scripts/
│   ├── run-test.sh                 # 반복 실행 스크립트
│   ├── aggregate_results.py        # 결과 집계 (Python)
│   ├── collect_summary.py          # 전체 summary 통합 (Python)
│   ├── generate_report.py          # 리포트 생성 (Python)
│   └── requirements.txt            # Python 의존성
└── results/
    ├── 5nodes/
    │   ├── qps-20/
    │   │   ├── baseline/run1~5/
    │   │   └── localdns/run1~5/
    │   ├── qps-40/ ...
    │   ├── qps-80/ ...
    │   └── qps-160/ ...
    ├── 10nodes/
    │   ├── qps-20/ ...
    │   ├── qps-40/ ...
    │   ├── qps-80/ ...
    │   └── qps-160/ ...
    ├── summary.json                # 전체 통합 결과
    └── comparison.md               # 최종 비교 리포트
```

---

## 9. 참고 자료

- [AKS LocalDNS 공식 문서](https://learn.microsoft.com/en-us/azure/aks/localdns-custom)
- [AKS Engineering Blog — Accelerate DNS Performance with LocalDNS](https://blog.aks.azure.com/2025/08/04/accelerate-dns-performance-with-localdns)
- [dnsperf — DNS-OARC](https://www.dns-oarc.net/tools/dnsperf)
- [dnsperf JSON output (`-O json-stats=on`)](https://codeberg.org/DNS-OARC/dnsperf)
