# AKS LocalDNS + NodeLocal DNSCache 동시 활성화 동작 검증 실험 결과

> 실험 일시: 2026-04-02  
> 클러스터: aks-localdns-test (swedencentral)  
> Kubernetes: v1.33.7 / Azure CNI Overlay + Cilium  
> 노드: system 2 + userpool 3 (Standard_D16as_v6)

---

## 1. 결론 요약

**Coexistence(동시 활성화) 상황에서 NodeLocal DNSCache는 실질적으로 완전히 bypass된다.**

Pod의 첫 hop은 항상 LocalDNS(169.254.10.11)이며, LocalDNS cache miss 시 CoreDNS(10.0.0.10)로 직접 전달한다. NodeLocal DNSCache(169.254.20.10)는 Pod를 포함한 어떤 컴포넌트로부터도 쿼리를 수신하지 않으며, DNS 경로에 관여하지 않는다.

이는 두 가지 구조적 이유에 기인한다:

1. **LocalDNS가 resolv.conf의 nameserver를 선점한다.** LocalDNS 활성화 시 Pod의 nameserver가 `169.254.10.11`로 설정되므로, Pod는 NodeLocal DNSCache(169.254.20.10)에 쿼리를 보낼 이유가 없다.
2. **LocalDNS의 upstream은 CoreDNS로 직접 설정된다.** `localdnsconfig.json`의 `forwardDestination: ClusterCoreDNS`에 의해 LocalDNS가 cache miss 시 CoreDNS(10.0.0.10)로 직접 포워딩하며, NodeLocal DNSCache를 경유하지 않는다.

추가로, **이 클러스터 환경(Cilium kube-proxy replacement)에서는 NodeLocal DNSCache 단독으로도 DNS 경로에 자동으로 참여하지 않는다.** NodeLocal DNSCache의 iptables 기반 인터셉션 메커니즘은 Cilium의 eBPF 기반 서비스 라우팅과 호환되지 않기 때문이다.

---

## 2. 케이스별 비교

### Case 1: LocalDNS only

| 항목 | 값 |
|------|-----|
| Pod resolv.conf | `nameserver 169.254.10.11` (LocalDNS) |
| Pod first hop | LocalDNS (169.254.10.11) |
| cluster.local 쿼리 경로 | Pod → LocalDNS → CoreDNS (ForceTCP) |
| 외부 도메인 쿼리 경로 | Pod → LocalDNS → CoreDNS (PreferUDP) |
| NodeLocal DNSCache | 미설치 / 169.254.20.10 도달 불가 |
| CoreDNS가 보는 쿼리 소스 | 노드 IP (10.224.0.x) — LocalDNS가 호스트 네트워크로 동작 |

**실제 DNS 경로:**
```
Pod ──→ LocalDNS (169.254.10.11) ──→ CoreDNS (10.0.0.10)
```

**CoreDNS 로그 증거:**
```
[INFO] 10.224.0.6:41330 - "A IN kube-dns.kube-system.svc.cluster.local. tcp 79"   ← cluster.local, ForceTCP
[INFO] 10.224.0.6:34640 - "A IN 7c64c2f9.nonce.example.com. udp 67"              ← external, PreferUDP
```
→ 소스가 노드 IP(10.224.0.6)이며 프로토콜이 localdnsconfig.json 설정과 일치함.

---

### Case 2: NodeLocal DNSCache only (LocalDNS OFF)

| 항목 | 값 |
|------|-----|
| Pod resolv.conf | `nameserver 10.0.0.10` (kube-dns ClusterIP) |
| Pod first hop | CoreDNS (10.0.0.10) via Cilium eBPF routing |
| cluster.local 쿼리 경로 | Pod → CoreDNS (직통) |
| 외부 도메인 쿼리 경로 | Pod → CoreDNS (직통) |
| NodeLocal DNSCache | 실행 중 (169.254.20.10) 이지만 **DNS 경로에 불참** |
| CoreDNS가 보는 쿼리 소스 | Pod IP (10.244.x.x) — 직접 도달 |

**실제 DNS 경로:**
```
Pod ──→ CoreDNS (10.0.0.10)
         ↑ Cilium eBPF가 kube-dns Service를 CoreDNS Pod로 라우팅

NodeLocal DNSCache (169.254.20.10) ← 아무도 쿼리하지 않음
```

**CoreDNS 로그 증거:**
```
[INFO] 10.244.4.241:54204 - "A IN kube-dns.kube-system.svc.cluster.local. udp 79"  ← Pod IP에서 직접
[INFO] 10.244.4.241:48102 - "A IN 7b2997f2.nonce.example.com. udp 67"              ← Pod IP에서 직접
```
→ 소스가 Pod IP(10.244.4.241)이며, NodeLocal DNSCache를 거치지 않음.

**NodeLocal DNSCache가 bypass되는 구조적 이유:**
- Pod resolv.conf: `10.0.0.10` (kube-dns Service IP)
- Cilium `kube-proxy-replacement: true`: iptables가 아닌 eBPF로 서비스 라우팅
- NodeLocal DNSCache의 iptables 규칙: NOTRACK/ACCEPT만 존재, **DNAT 규칙 없음**
- 따라서 10.0.0.10으로 가는 트래픽이 169.254.20.10으로 리다이렉트되지 않음

---

### Case 3: Coexistence (LocalDNS + NodeLocal DNSCache)

| 항목 | 값 |
|------|-----|
| Pod resolv.conf | `nameserver 169.254.10.11` (LocalDNS) |
| Pod first hop | LocalDNS (169.254.10.11) |
| cluster.local 쿼리 경로 | Pod → LocalDNS → CoreDNS (ForceTCP) |
| 외부 도메인 쿼리 경로 | Pod → LocalDNS → CoreDNS (PreferUDP) |
| NodeLocal DNSCache | 실행 중 (169.254.20.10) 이지만 **DNS 경로에 완전 불참** |
| CoreDNS가 보는 쿼리 소스 | 노드 IP (10.224.0.x) — LocalDNS 경유 |

**실제 DNS 경로:**
```
Pod ──→ LocalDNS (169.254.10.11) ──→ CoreDNS (10.0.0.10)

NodeLocal DNSCache (169.254.20.10) ← 아무도 쿼리하지 않음 (헬스체크 자체도 실패)
```

**CoreDNS 로그 증거:**
```
[INFO] 10.224.0.6:41690 - "A IN kube-dns.kube-system.svc.cluster.local. tcp 79"  ← 노드 IP, ForceTCP
[INFO] 10.224.0.6:43815 - "A IN fd5e47db.nonce.example.com. udp 67"              ← 노드 IP, PreferUDP
[INFO] 10.224.0.6:43815 - "A IN login.microsoftonline.com. udp 66"               ← 노드 IP, PreferUDP
[INFO] 10.224.0.6:43815 - "A IN google.com. udp 51"                              ← 노드 IP, PreferUDP
```
→ Case 1과 동일한 패턴. LocalDNS만 DNS 경로에 참여.

**NodeLocal DNSCache 로그 (실질적 불참의 증거):**
```
[ERROR] plugin/errors: 2 ... cluster.local. HINFO: dial tcp 10.0.0.10:53: i/o timeout
[ERROR] plugin/errors: 2 ... in-addr.arpa. HINFO: dial tcp 10.0.0.10:53: i/o timeout
```
→ NodeLocal DNSCache는 자체 헬스체크(HINFO) 쿼리조차 CoreDNS에 도달하지 못하고 timeout 발생. 실제 사용자 DNS 쿼리는 **전혀 없음**.

---

## 3. 확정 가능한 사실

### A. Pod first hop

| 상황 | Pod first hop |
|------|---------------|
| LocalDNS ON | **LocalDNS (169.254.10.11)** — resolv.conf에 직접 설정됨 |
| LocalDNS OFF, NodeLocal ON | **CoreDNS (10.0.0.10)** — Cilium이 kube-dns Service를 직접 라우팅 |
| Coexistence | **LocalDNS (169.254.10.11)** — LocalDNS가 resolv.conf를 선점 |

→ **LocalDNS가 활성화되면 항상 Pod의 첫 hop은 LocalDNS이다.** 이는 resolv.conf의 nameserver를 직접 변경하는 방식이므로 확실하다.

### B. LocalDNS miss 이후 second hop

LocalDNS cache miss 시 **CoreDNS(10.0.0.10)로 직접** 포워딩된다.

- `localdnsconfig.json`의 `forwardDestination: ClusterCoreDNS` 설정에 의해 결정
- cluster.local: ForceTCP로 CoreDNS에 전달 (CoreDNS 로그에서 `tcp 77 false 65535` 확인)
- 외부 도메인: PreferUDP로 CoreDNS에 전달 (CoreDNS 로그에서 `udp 67 false 1232` 확인)
- **NodeLocal DNSCache를 경유하지 않는다** — LocalDNS는 169.254.20.10이 아닌 10.0.0.10으로 직접 포워딩

### C. NodeLocal DNSCache의 실질적 역할

| 상황 | NodeLocal DNSCache 역할 |
|------|-------------------------|
| LocalDNS OFF, NodeLocal ON | **실질적 불참** — Cilium 환경에서 iptables 인터셉션 미작동 |
| Coexistence | **완전 불참** — Pod도 LocalDNS도 NodeLocal DNSCache에 쿼리하지 않음 |

→ **이 클러스터 환경(Cilium + LocalDNS)에서 NodeLocal DNSCache는 어떤 상황에서도 실제 DNS 트래픽 경로에 참여하지 않는다.**

### D. iptables 규칙 분석

| 컴포넌트 | iptables 규칙 | DNAT/리다이렉트 |
|----------|---------------|-----------------|
| LocalDNS (169.254.10.10/11) | NOTRACK (conntrack 건너뜀) | 없음 — resolv.conf 직접 변경 방식 |
| NodeLocal DNSCache (169.254.20.10) | NOTRACK + ACCEPT | **없음** — Cilium 환경에서 DNAT 미설정 |

→ 두 컴포넌트 모두 iptables DNAT 규칙을 사용하지 않음. LocalDNS는 resolv.conf를 변경하여 진입점을 확보하고, NodeLocal DNSCache는 Cilium과의 비호환으로 인터셉션 실패.

---

## 4. 불확실하거나 추가 검증이 필요한 부분

### 4.1 Cilium 없는 환경에서의 NodeLocal DNSCache 인터셉션

이번 실험은 **Cilium kube-proxy replacement** 환경에서 수행되었다. Cilium이 아닌 **iptables 기반 kube-proxy** 환경에서는 NodeLocal DNSCache가 `10.0.0.10 → 169.254.20.10` DNAT 규칙을 설정하여 DNS 트래픽을 가로챌 수 있다. 해당 환경에서의 coexistence 동작은 이번 실험의 범위 밖이다.

### 4.2 LocalDNS의 upstream을 NodeLocal DNSCache로 변경한 경우

현재 `localdnsconfig.json`에서 `forwardDestination`이 `ClusterCoreDNS`로 설정되어 있다. 만약 이 값을 변경하여 LocalDNS의 upstream을 169.254.20.10(NodeLocal DNSCache)으로 설정할 수 있다면, 이론적으로 `Pod → LocalDNS → NodeLocal DNSCache → CoreDNS` 2단 캐시 체인이 형성될 수 있다. 단, 현재 `forwardDestination` 옵션의 가능한 값은 `VnetDNS`와 `ClusterCoreDNS`뿐이므로, 이러한 구성이 가능한지는 추가 확인이 필요하다.

### 4.3 NodeLocal DNSCache의 헬스체크 timeout

Coexistence 상태에서 NodeLocal DNSCache의 HINFO 헬스체크가 `dial tcp 10.0.0.10:53: i/o timeout`으로 실패하였다. 이는 LocalDNS 활성화로 인한 네트워크 경로 변경 때문인지, 또는 Cilium의 서비스 라우팅 문제인지 추가 분석이 필요하다.

### 4.4 vnetDNSOverrides vs kubeDNSOverrides

이번 실험에서 LocalDNS의 `kubeDNSOverrides` 경로만 검증하였다. `vnetDNSOverrides`의 외부 도메인 경로(`forwardDestination: VnetDNS`)는 CoreDNS를 거치지 않고 VNet DNS로 직접 가므로 별도 검증이 필요할 수 있다.

---

## 5. 최종 판정

> **Coexistence 시 LocalDNS가 entrypoint를 선점하고 NodeLocal DNSCache는 거의 bypass된다.**

정확히는 "거의"가 아니라 **"완전히"** bypass된다. 그 근거는 다음과 같다:

1. LocalDNS가 resolv.conf의 nameserver를 변경하여 Pod의 DNS 진입점을 선점한다.
2. LocalDNS downstream(Pod → LocalDNS) 경로에서 NodeLocal DNSCache는 관여하지 않는다.
3. LocalDNS upstream(LocalDNS → CoreDNS) 경로에서도 NodeLocal DNSCache를 경유하지 않는다.
4. NodeLocal DNSCache는 실행 상태(Running)이지만, 자체 헬스체크를 제외하면 어떤 DNS 트래픽도 수신하지 않는다.
5. 이 환경(Cilium)에서는 NodeLocal DNSCache를 단독으로 사용해도 iptables 인터셉션이 작동하지 않아 DNS 경로에 참여하지 못한다.

따라서, 세 가지 선택지 중:

- ~~coexistence 시 실제로 2단 캐시 체인이 형성된다~~ → **아니다**
- **✅ coexistence 시 LocalDNS가 entrypoint를 선점하고 NodeLocal DNSCache는 완전히 bypass된다**
- ~~coexistence 시 일부 조건에서만 NodeLocal DNSCache가 개입한다~~ → **아니다**

---

## 부록: 실험 환경 상세

### 클러스터 구성

| 항목 | 값 |
|------|-----|
| AKS 클러스터 | aks-localdns-test |
| 리전 | swedencentral |
| Kubernetes | v1.33.7 |
| 네트워크 | Azure CNI Overlay + Cilium |
| kube-proxy | **Cilium이 대체** (`kube-proxy-replacement: true`) |
| CoreDNS | 2 replicas |
| kube-dns Service IP | 10.0.0.10 |

### LocalDNS 설정 (localdnsconfig.json)

| 설정 | 값 |
|------|-----|
| mode | Required |
| kubeDNSOverrides `.` | PreferUDP → ClusterCoreDNS |
| kubeDNSOverrides `cluster.local` | ForceTCP → ClusterCoreDNS |
| cacheDurationInSeconds | 3600 |

### NodeLocal DNSCache 설정

| 설정 | 값 |
|------|-----|
| Listen IP | 169.254.20.10 |
| cluster.local upstream | 10.0.0.10 (force_tcp) |
| `.` upstream | /etc/resolv.conf |
| iptables args | `-setupiptables=true` |

### 실험에 사용된 DNS 쿼리

| 구분 | 도메인 | 목적 |
|------|--------|------|
| Internal | kubernetes.default.svc.cluster.local | cluster.local 경로 확인 |
| Internal | kube-dns.kube-system.svc.cluster.local | kube-dns 해석 경로 확인 |
| External (unique) | {nonce}.nonce.example.com | 캐시 미스 보장용 유니크 쿼리 |
| External | login.microsoftonline.com | 외부 도메인 경로 확인 |
| External | google.com | 외부 도메인 경로 확인 |

### 진단 방법

| 방법 | 목적 |
|------|------|
| Pod resolv.conf | nameserver 설정 확인 |
| dig +all (기본 nameserver) | Pod first hop 확인 (SERVER 필드) |
| dig @IP (직접 프로빙) | 각 DNS 컴포넌트 도달 가능성 확인 |
| CoreDNS log plugin | 쿼리 소스 IP/프로토콜 확인 |
| NodeLocal DNSCache 로그 | 쿼리 수신 여부 확인 |
| iptables-save | DNAT/인터셉션 규칙 확인 |
| Cilium configmap | kube-proxy-replacement 상태 확인 |
