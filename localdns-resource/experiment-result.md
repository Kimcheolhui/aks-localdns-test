# LocalDNS 노드 리소스 사용량 측정 결과

> 측정 일시: 2026-04-02  
> 대상 노드: aks-userpool-15741607-vmss000002 (Standard_D16as_v6, 16 vCPU / 64 GB)  
> LocalDNS 바이너리: `/opt/azure/containers/localdns/binary/coredns` (PID 4179)

---

## 측정 방법

- `/proc/<PID>/status`, `/proc/<PID>/stat`에서 직접 읽어 6회 샘플링 (10초 간격)
- Idle: DNS 부하 없는 평상시
- Load: 동일 노드에서 dnsperf (`-Q 200 -c 10 -l 180`, 약 QPS 2,000)로 부하 인가

---

## 결과 요약

| 지표 | Idle | Load (QPS ~2,000) | 비고 |
|------|-----:|------------------:|------|
| **RSS (실제 메모리)** | 74.7 MB | 74.4~75.0 MB | 부하와 무관하게 안정 |
| **VmHWM (RSS 최대치)** | 74.8 MB | 77.5 MB | +2.7 MB |
| **VmData (heap)** | 217.3 MB | 225.7 MB | +8.4 MB |
| **VmSize (가상 메모리)** | 2,651.1 MB | 2,723.4 MB | Go 런타임 특성상 큼 |
| **Threads** | 20 | 21 | +1 |
| **FDs** | 13~15 | 13~17 | 미미한 변동 |
| **CPU (ticks/2s)** | 0 | 6~7 | Idle≈0%, Load≈0.3% of 1 core |
| **Context Switches (voluntary)** | 154 | 5,883 | 부하에 비례 |

---

## 상세 데이터

### Idle (DNS 부하 없음)

```
Sample1: RSS=76528kB  Threads=20  CPU_ticks_2s=0
Sample2: RSS=76528kB  Threads=20  CPU_ticks_2s=0
Sample3: RSS=76528kB  Threads=20  CPU_ticks_2s=0
Sample4: RSS=76528kB  Threads=20  CPU_ticks_2s=0
Sample5: RSS=76528kB  Threads=20  CPU_ticks_2s=0
Sample6: RSS=76528kB  Threads=20  CPU_ticks_2s=0
```

### Load (dnsperf QPS ~2,000)

```
Sample1: RSS=76852kB  Threads=21  CPU_ticks_2s=6
Sample2: RSS=75924kB  Threads=21  CPU_ticks_2s=6
Sample3: RSS=75924kB  Threads=21  CPU_ticks_2s=6
Sample4: RSS=76224kB  Threads=21  CPU_ticks_2s=6
Sample5: RSS=76224kB  Threads=21  CPU_ticks_2s=6
Sample6: RSS=76224kB  Threads=21  CPU_ticks_2s=7
```

---

## 판단

- **메모리**: RSS 약 75MB로 노드 전체 메모리(64GB) 대비 **0.1%**. 부하 증가에도 RSS 변동 거의 없음.
- **CPU**: Idle 시 사실상 0. QPS 2,000 부하에서도 1 코어의 0.3% 미만. 16 vCPU 대비 무시 가능.
- **VmSize가 ~2.6GB로 크게 보이지만**, 이는 Go 런타임의 가상 메모리 예약 특성이며, 실제 물리 메모리 점유(RSS)와 무관.
- LocalDNS가 노드 리소스에 미치는 영향은 **사실상 무시할 수 있는 수준**.
