# AKS LocalDNS 도입 실험 계획서

## 1. 실험 목적

AKS 클러스터에서 LocalDNS 도입 전/후의 DNS 쿼리 latency 차이를 정량적으로 측정한다.

---

## 2. 실험 환경 구성

### 2.1 AKS 클러스터 스펙

```
리소스 그룹     : rg-localdns-test
클러스터 이름    : aks-localdns-test
리전            : North Europe (northeurope)
Kubernetes 버전 : 1.33.7
노드 풀         :
  - system pool : Standard_D4as_v6 x 2 (시스템 워크로드 전용)
  - user pool   : Standard_D16as_v6 x 5 (dnsperf 워크로드, 노드당 ~50 Pod)
네트워크 플러그인 : Azure CNI Overlay
데이터플레인     : Cilium
CoreDNS         : 기본 2 replica 유지
노드 OS         : Ubuntu 22.04.05 LTS
```

### 2.2 클러스터 프로비저닝 (azd + Bicep)

인프라를 `azd` (Azure Developer CLI) + Bicep 으로 관리한다.

```bash
# 환경 초기화 (최초 1회)
azd init

# 프로비저닝 (리소스 그룹 + AKS 클러스터 한 번에 생성)
azd provision

# kubeconfig 가져오기
az aks get-credentials --resource-group rg-localdns-test --name aks-localdns-test
```

> Bicep 정의 파일: `infra/main.bicep`, `infra/aks.bicep`  
> azd 설정: `azure.yaml`

---

## 3. DNS 쿼리 대상 구성

### 3.1 Dummy Service 배포 (`manifests/dummy-services.yaml`)

dnsperf가 resolve할 Internal 도메인이 실제로 존재해야 하므로, Headless Service(`clusterIP: None`)를 3개 namespace에 배포한다.

| Namespace | Services                                                                                  |
| --------- | ----------------------------------------------------------------------------------------- |
| `app-a`   | api-gateway, user-service, order-service, payment-service, notification-service           |
| `app-b`   | product-catalog, inventory-service, search-service, recommendation-service, cache-service |
| `app-c`   | auth-service, logging-service, monitoring-service, config-service, messaging-service      |

> 총 15개 Headless Service → 15개 internal FQDN 생성

### 3.2 쿼리 파일 (`manifests/dnsperf-queryfile-cm.yaml`)

dnsperf에 입력할 도메인 리스트를 ConfigMap으로 모든 Pod에 마운트한다.

| 구분                            | 개수     | 예시                                                                             |
| ------------------------------- | -------- | -------------------------------------------------------------------------------- |
| Internal (클러스터 서비스 FQDN) | 17개     | `api-gateway.app-a.svc.cluster.local`, `kubernetes.default.svc.cluster.local` 등 |
| External (Azure 서비스)         | 10개     | `login.microsoftonline.com`, `management.azure.com`, `vault.azure.net` 등        |
| External (일반 도메인)          | 5개      | `google.com`, `github.com`, `amazonaws.com` 등                                   |
| **합계**                        | **32개** |                                                                                  |

---

## 4. dnsperf 부하 테스트 구성

### 4.1 규모

| 항목          | 값                                | 근거                                                   |
| ------------- | --------------------------------- | ------------------------------------------------------ |
| 노드 수       | 5 (D16as_v6: 16 vCPU, 64GB RAM)   | Pod 50개 × CPU 200m limit = 10 vCPU, 16 vCPU 대비 여유 |
| Pod 수        | 250 (노드당 50)                   | `--max-pods 60` 설정, 시스템 Pod 고려                  |
| Pod당 QPS     | 40                                | 10 concurrent × queryfile 32개 도메인                  |
| **총 QPS**    | **10,000**                        | AKS Engineering Blog 벤치마크와 동일 수준              |
| 테스트 시간   | 60초                              | 중간 통계 10초 간격 (`-S 10`)                          |
| CoreDNS       | 2 replica (기본값)                | 고객 환경과 동일한 기본 설정 유지                      |
| **반복 횟수** | **5회 × 2 (Baseline + LocalDNS)** | 결과 신뢰성 확보                                       |

### 4.2 dnsperf Job (`manifests/dnsperf-job.yaml`)

250개 Pod를 병렬 실행하는 Kubernetes Job. 핵심 설정:

| 항목                      | 값                                                                                    |
| ------------------------- | ------------------------------------------------------------------------------------- |
| Image                     | `guessi/dnsperf:latest`                                                               |
| parallelism / completions | 250                                                                                   |
| nodeSelector              | `agentpool: userpool`                                                                 |
| dnsperf 옵션              | `-s <resolv.conf nameserver>` `-d queryfile.txt` `-l 60` `-Q 40` `-c 10` `-S 10` `-v` |
| 리소스                    | requests: 50m CPU, 64Mi / limits: 200m CPU, 128Mi                                     |

각 Pod는 시작 시 resolv.conf에서 nameserver IP를 읽어 dnsperf에 전달하고, 결과를 JSON으로 stdout에 출력한다.

### 4.3 반복 실행 스크립트 (`scripts/run-test.sh`)

사용법: `./scripts/run-test.sh <baseline|localdns> [runs=5]`

각 run에서 다음을 순차 수행한다:

1. Job 이름을 `dnsperf-<phase>-runN`으로 변경하여 `kubectl apply`
2. `kubectl wait --for=condition=complete --timeout=600s` 로 완료 대기
3. 모든 Pod 로그를 `results/<phase>/runN/raw/` 에 수집
4. Job 삭제 → 30초 대기 → 다음 run

### 4.4 결과 집계 스크립트 (`scripts/aggregate_results.py`)

사용법: `python3 scripts/aggregate_results.py <baseline|localdns>`

각 run 디렉토리의 Pod 로그를 파싱하여 run별 독립 통계를 산출한다:

1. `-v` 옵션으로 출력된 **개별 쿼리 latency**를 전 Pod에서 수집
2. numpy로 전체 쿼리(Pod당 2,400 × 250 = 600,000건)에 대한 **정확한 percentile** 산출
3. **기본 지표**: avg, min, max, stddev (ms)
4. **Percentile**: p50, p90, p95, p99 (ms)
5. **처리량**: queries sent/completed/lost, QPS
6. 출력: `results/<phase>/runN/summary.json`

---

## 5. 실험 절차

### Phase 1: Baseline 측정 (LocalDNS OFF) — 5회 반복

| 단계 | 작업                                                   |
| ---- | ------------------------------------------------------ |
| 1-1  | `azd provision` 으로 AKS 클러스터 생성 (섹션 2.2)      |
| 1-2  | Dummy Service 배포 (섹션 3.1)                          |
| 1-3  | dnsperf namespace 및 ConfigMap 배포 (섹션 3.2)         |
| 1-4  | `./run-test.sh baseline 5` (5회 반복 자동 실행)        |
| 1-5  | `python3 scripts/aggregate_results.py baseline` (집계) |

### Phase 2: LocalDNS 활성화

```bash
# LocalDNS 활성화 (노드풀 단위, 노드 reimage 발생)
az aks nodepool update \
  --name userpool \
  --cluster-name aks-localdns-test \
  --resource-group rg-localdns-test \
  --localdns-config ./infra/localdnsconfig.json \
  --max-surge 0 \
  --max-unavailable 1

# LocalDNS Pod 동작 확인
kubectl get pods -n kube-system -l k8s-app=localdns

# resolv.conf 확인 (nameserver가 169.254.10.10인지)
kubectl run verify-dns --image=busybox --rm -it --restart=Never -- cat /etc/resolv.conf
```

### Phase 3: LocalDNS 적용 후 측정 (LocalDNS ON) — 5회 반복

| 단계 | 작업                                                   |
| ---- | ------------------------------------------------------ |
| 3-1  | `./run-test.sh localdns 5` (5회 반복 자동 실행)        |
| 3-2  | `python3 scripts/aggregate_results.py localdns` (집계) |

### 결과 비교

```bash
python3 scripts/compare_results.py
```

> 각 phase의 run별 테이블 + Baseline vs LocalDNS 평균 비교 테이블을 `results/comparison.md`로 출력한다.

---

## 6. 비교 항목

Baseline(LocalDNS OFF)과 LocalDNS ON 환경 각각에 대해 5회 시행하고, 각 시행별로 다음 지표를 독립적으로 집계한다.

- **Latency**: avg, min, max, p50, p90, p95, p99 (ms)
- **처리량**: queries sent, queries completed, QPS achieved
- **손실률**: queries lost (%)

---

## 7. 필요 리소스 정리

| 리소스          | 스펙                  |
| --------------- | --------------------- |
| AKS system pool | Standard_D4as_v6 x 2  |
| AKS user pool   | Standard_D16as_v6 x 5 |

> ⚠️ 실험 완료 후 반드시 리소스 삭제  
> `azd down --purge --force`

---

## 8. 디렉토리 구조

```
localdns-test/
├── azure.yaml                      # azd 프로젝트 설정
├── experiment-plan.md              # 본 실험 계획서
├── infra/
│   ├── main.bicep                  # Bicep 진입점 (subscription scope)
│   ├── main.parameters.json        # Bicep 파라미터
│   ├── aks.bicep                   # AKS 클러스터 리소스 정의
│   └── localdns-enable.sh          # LocalDNS 활성화
├── manifests/
│   ├── dummy-services.yaml         # Internal DNS 대상 서비스
│   ├── dnsperf-queryfile-cm.yaml   # 쿼리 도메인 목록 ConfigMap
│   └── dnsperf-job.yaml            # dnsperf Job (250 Pod)
├── scripts/
│   ├── run-test.sh                 # 반복 실행 스크립트
│   └── aggregate_results.py        # 결과 집계 (Python)
└── results/
    ├── baseline/
    │   ├── run1/ ~ run5/           # 각 run별 raw 로그 + summary.json
    │   └── ...
    └── localdns/
        ├── run1/ ~ run5/
        └── ...
```

---

## 9. 참고 자료

- [AKS LocalDNS 공식 문서](https://learn.microsoft.com/en-us/azure/aks/localdns-custom)
- [AKS Engineering Blog — Accelerate DNS Performance with LocalDNS](https://blog.aks.azure.com/2025/08/04/accelerate-dns-performance-with-localdns)
- [dnsperf — DNS-OARC](https://www.dns-oarc.net/tools/dnsperf)
- [dnsperf JSON output (`-O json-stats=on`)](https://codeberg.org/DNS-OARC/dnsperf)
