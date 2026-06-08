# Ansible — Day-0 부트스트랩

k3s 클러스터를 프로비저닝하고 ArgoCD까지 설치한 뒤 플랫폼 배포를 ArgoCD에 인계하는 "딸깍" 부트스트랩입니다.

책임 경계(왜 Ansible과 ArgoCD를 나눴는가)는 [ADR-0004](../docs/adr/0004-ansible-argocd-boundary.md)를 참조하세요.

## 무엇을 하나

| Play | Role | 역할 |
|------|------|------|
| 1 | `preflight` | OS 준비 (swap off, 커널 모듈, sysctl, /etc/hosts) |
| 2 | `registries_mirror` | (airgap 전용) containerd 레지스트리 미러 |
| 3 | `k3s` (server) | k3s server 설치, kubeconfig/토큰 추출 |
| 4 | `k3s` (agent) | agent join |
| 5 | `argocd` | ArgoCD 설치 |
| 5 | `secrets_seed` | sealed-secrets controller + vault→seal→apply |
| 5 | `platform_bootstrap` | Root Application 적용 → ArgoCD 인계 |

이후는 ArgoCD가 sync wave 순서로 10개 컴포넌트 + Harbor를 배포합니다.

## 사전 준비

```bash
# 1) collection 의존성 설치
ansible-galaxy collection install -r requirements.yml

# 2) inventory의 노드 IP / SSH 키 설정
vi inventory/hosts.ini

# 3) 환경 변수 확인 (모드, 버전, git/registry 주소)
vi inventory/group_vars/all.yml

# 4) 시크릿 vault 작성 + 암호화
cp inventory/group_vars/vault.example.yml inventory/group_vars/vault.yml
vi inventory/group_vars/vault.yml          # 실제 비밀번호 입력
ansible-vault encrypt inventory/group_vars/vault.yml
```

## 실행 (Mode A — online)

```bash
ansible-playbook site.yml --ask-vault-pass
```

완료 후:

```bash
export KUBECONFIG=$PWD/kubeconfig        # k3s server play가 생성
kubectl get applications -n argocd -w     # 동기화 진행 관찰
```

## Mode B — air-gap

현재 air-gap은 **심(seam)만 구현**되어 있습니다. 동작 골격:
- `deployment_mode: airgap` 설정 시 `registries_mirror`가 활성화되고 `k3s` 설치가 오프라인 분기를 탑니다.
- 단, `roles/k3s/tasks/offline.yml`과 `scripts/bundle-offline-assets.sh`는 stub이며 실제 구현이 필요합니다.

전략과 미구현 범위는 [ADR-0005](../docs/adr/0005-airgap-strategy.md)에 정리되어 있습니다.

## 부분 실행 (tags 대신 play 한정)

```bash
# 시크릿만 다시 시드
ansible-playbook site.yml --ask-vault-pass --limit k3s_server \
  --start-at-task "SealedSecret 생성 및 적용"
```
