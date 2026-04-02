# AKS LocalDNS + NodeLocal DNSCache 동시 활성화 동작 검증 실험 의뢰

## 목적

AKS에서 LocalDNS와 Kubernetes upstream NodeLocal DNSCache를 동시에 활성화했을 때, 실제 DNS 요청 경로가 어떻게 동작하는지 검증해주세요.

문서만으로는 아래 쟁점이 완전히 확정되지 않으므로, 추측이 아니라 실제 실험 결과를 바탕으로 판단하는 것이 목적입니다.

## 확인하고 싶은 핵심 질문

1. Pod의 DNS 첫 요청 대상은 누구인가?

* LocalDNS인가
* NodeLocal DNSCache인가
* kube-dns Service IP인가

2. LocalDNS와 NodeLocal DNSCache를 동시에 켠 경우에도 Pod의 첫 hop은 항상 LocalDNS인가?

3. LocalDNS cache miss가 발생했을 때, 그 다음 요청은 어디로 가는가?

* 바로 CoreDNS로 가는가
* NodeLocal DNSCache를 한 번 더 거치는가
* 다른 upstream으로 가는가

4. coexistence 상황에서 NodeLocal DNSCache는 실제 DNS path에 참여하는가?

* 실제로 query를 받는가
* 떠 있기만 하고 사실상 bypass되는가

5. 최종적으로 실제 경로는 아래 중 무엇에 가까운가?

* Pod -> LocalDNS -> CoreDNS
* Pod -> LocalDNS -> NodeLocal DNSCache -> CoreDNS
* Pod -> LocalDNS 이지만 NodeLocal DNSCache는 실질적으로 거의 관여하지 않음

## 배경

현재까지 문서 기준으로는 다음 정도만 비교적 분명합니다.

* AKS LocalDNS 활성화 시 Pod는 LocalDNS를 nameserver로 사용한다.
* Microsoft 문서에는 coexistence 시 “all DNS traffic is routed through LocalDNS”라는 취지의 설명이 있다.
* 하지만 이 문장만으로는 LocalDNS miss 이후 NodeLocal DNSCache가 개입하는지까지는 확정하기 어렵다.
* 따라서 Pod의 첫 hop과, LocalDNS miss 이후의 second hop을 분리해서 검증해야 한다.

## 실험 요청 범위

아래 3가지 케이스를 비교해주세요.

### Case 1

LocalDNS만 활성화

### Case 2

NodeLocal DNSCache만 활성화

### Case 3

LocalDNS와 NodeLocal DNSCache를 동시에 활성화

## 실험에서 꼭 확인해야 할 관점

### 1. Pod 관점

* Pod의 resolv.conf에 어떤 nameserver가 들어가는지
* Pod가 실제로 누구를 첫 destination으로 삼는지

### 2. LocalDNS 관점

* LocalDNS가 실제로 DNS 요청을 받는지
* cache miss 발생 시 어디를 upstream으로 사용하는지

### 3. NodeLocal DNSCache 관점

* coexistence 상황에서 실제 query를 받는지
* 받는다면 source가 Pod인지, LocalDNS인지, 다른 컴포넌트인지

### 4. CoreDNS 관점

* CoreDNS는 누구로부터 query를 받는지
* Pod가 직접 오는지
* LocalDNS를 통해 오는지
* NodeLocal DNSCache를 통해 오는지

## 기대 결과

최종적으로 아래 내용을 명확히 답해주세요.

### A. Pod first hop

Pod의 첫 DNS 요청 대상이 누구인지

### B. LocalDNS miss 이후 second hop

LocalDNS miss가 발생했을 때 다음 hop이 누구인지

### C. NodeLocal DNSCache의 실질적 역할

coexistence 상황에서 NodeLocal DNSCache가 실제 경로에 참여하는지, 아니면 실질적으로 우회되는지

## 결과 정리 형식

### 1. 결론 요약

한두 문단으로 최종 결론 요약

### 2. 케이스별 비교

* LocalDNS only
* NodeLocal only
* Coexistence

각 케이스마다 실제 DNS path를 간단히 서술

### 3. 확정 가능한 사실

실험으로 명확히 확인된 사실만 정리

### 4. 불확실하거나 추가 검증이 필요한 부분

실험으로도 완전히 닫히지 않은 부분이 있다면 따로 구분

### 5. 최종 판정

아래 중 무엇이 가장 정확한지 선택

* coexistence 시 실제로 2단 캐시 체인이 형성된다
* coexistence 시 LocalDNS가 entrypoint를 선점하고 NodeLocal DNSCache는 거의 bypass된다
* coexistence 시 일부 조건에서만 NodeLocal DNSCache가 개입한다

## 중요한 요청

* 추측성 설명보다는 실제 관찰 결과 중심으로 정리해주세요.
* 특히 Pod의 first hop과 LocalDNS miss 이후 second hop을 반드시 분리해서 판단해주세요.
* “컴포넌트가 떠 있다”와 “실제 트래픽 경로에 참여한다”를 구분해서 설명해주세요.
