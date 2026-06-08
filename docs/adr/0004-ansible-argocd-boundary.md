# ADR-0004: Ansible(Day-0)와 ArgoCD(Day-1)의 책임 경계

## 상태

채택됨

## 날짜

2026-06-08

## 맥락

목표는 "어느 클러스터에나 딸깍 한 번으로 배포"다. GitOps(ArgoCD)는 강력하지만 **자기 자신과 클러스터를 부트스트랩할 수 없다**(닭-달걀):

- k3s 자체가 없으면 ArgoCD를 띄울 수 없다
- ArgoCD가 없으면 App of Apps가 동작하지 않다
- SealedSecret은 클러스터마다 sealing 키가 달라 git에 커밋된 암호문이 새 클러스터에서 복호화되지 않다

이 공백을 메우는 Day-0 부트스트랩 도구가 필요하다.

## 결정

**Ansible(Day-0 부트스트랩)과 ArgoCD(Day-1+ 지속배포)로 책임을 분리한다.**

### Ansible 책임 (Day-0, 멱등성)

1. OS 준비 (preflight)
2. k3s 설치 (server + agent)
3. (airgap) containerd 레지스트리 미러
4. ArgoCD 설치
5. **시크릿 계층 전체** (sealed-secrets controller + SealedSecret 시드)
6. Root Application 적용 후 ArgoCD에 인계

### ArgoCD 책임 (Day-1+)

- 10개 플랫폼 컴포넌트 + Harbor를 sync wave 순서로 배포/유지

## 핵심 결정: 시크릿 계층은 Ansible이 소유한다

원래 sealed-secrets controller(wave -2)와 SealedSecret 리소스(wave -1)는 ArgoCD가 관리했다. 이를 **Ansible 소유로 이전**한다.

이유:

1. **클러스터 이식성**: SealedSecret 암호문은 대상 클러스터 controller 키로만 복호화된다. git에 커밋된 암호문은 새 클러스터에서 무용지물이다. Ansible이 `ansible-vault` 평문을 읽어 → 대상 클러스터 키로 seal → apply 하면 "어느 클러스터에나"가 성립한다.

2. **selfHeal 충돌 제거**: Ansible이 SealedSecret을 직접 apply하는데 ArgoCD도 같은 리소스를 git의 placeholder로 관리하면, `selfHeal: true`가 Ansible이 넣은 실제 값을 placeholder로 되돌린다. 소유권을 한쪽으로 모아 충돌을 원천 제거한다.

3. **개념적 정합성**: 클러스터마다 새로 생성되어야 하는 시크릿은 본질적으로 공유 git App-of-Apps에 속하지 않는다. Day-0 부트스트랩의 일부다.

결과적으로:

- ApplicationSet에서 `platform-system-sealed-secrets`, `platform-infra-secrets` element 제거
- `manifests/security/*.yaml`은 **참조용 템플릿**으로 유지 (키 구성 문서화). ArgoCD가 동기화하지 않는다
- 실제 시드는 `ansible/roles/secrets_seed`가 수행

### 고려했으나 채택하지 않은 대안

- **Sealing 키 이식**: 하나의 master 키를 클러스터 간 재사용하면 커밋된 SealedSecret이 어디서나 풀린다. 코드는 더 적지만 "키 하나로 모든 클러스터"라는 보안 냄새가 있어 배제. (단순 단일 클러스터 운영이라면 합리적 대안)
- **SOPS + age**: 잘 동작하는 SealedSecrets를 새 패턴으로 교체할 만한 이득이 없어 배제(과잉).

## 결과

- 부트스트랩 진입점: `ansible/site.yml` 한 개
- `ansible-playbook site.yml --ask-vault-pass` 한 줄로 Day-0 완료
- 시크릿은 vault에만 평문 존재, git에는 절대 평문 없음
- ArgoCD는 시크릿이 아닌 워크로드에만 집중

### 트레이드오프

- sealed-secrets controller가 GitOps(자동 차트 업그레이드) 밖에 있다. 업그레이드는 Ansible 재실행으로 처리. 포트폴리오/단일 플랫폼 규모에서 수용 가능.
