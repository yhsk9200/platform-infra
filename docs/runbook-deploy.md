# Runbook — OCI 인스턴스 배포

OCI Free Tier 2-node k3s 클러스터에 이 플랫폼을 **처음부터 끝까지** 배포하는 운영 절차서입니다. 위에서 아래로 순서대로 수행하면 됩니다.

- 자동화 범위: Ansible(`ansible/site.yml`)이 k3s·ArgoCD·시크릿·root-app까지 수행 (Day-0)
- 수동 범위: OCI 콘솔 작업(인스턴스/보안목록), 환경 변수·시크릿 입력, 접근 확인
- 설계 배경: [ADR-0004](adr/0004-ansible-argocd-boundary.md), [ADR-0005](adr/0005-airgap-strategy.md)

```
[Phase 0] 사전 점검(OCI 콘솔·이미지) → [Phase 1] 컨트롤 노드 →
[Phase 2] 설정 입력 → [Phase 3] 부트스트랩 실행 →
[Phase 4] 검증 → [Phase 5] 서비스 접근 → [Phase 6] 사후 작업
```

체크리스트가 필요하면 각 Phase 끝의 `✅ 완료 기준`을 확인하세요.

---

## Phase 0 — 사전 점검 (OCI 콘솔 + 이미지)

### 0-1. 인스턴스 확인
- Node1(server), Node2(agent): VM.Standard.A1.Flex, Ubuntu 24.04 aarch64
- 각 노드의 **공인 IP**, **사설 IP**(예: 10.0.1.113 / 10.0.1.69) 기록

### 0-2. OCI 보안 목록 / NSG (★ 클라우드 방화벽 — 반드시 수동)

호스트 iptables는 Ansible이 처리하지만, **OCI 클라우드 방화벽은 콘솔에서 직접 열어야** 합니다. VCN → Security List(또는 NSG)에 아래 **Ingress** 규칙을 추가합니다.

| Source | Protocol | Port | 용도 |
|--------|----------|------|------|
| `10.0.1.0/24` (VCN CIDR) | **All Protocols** | - | 노드 간 통신 (flannel VXLAN 8472/udp, kubelet 10250, API 6443) — **필수** |
| 내 IP/32 | TCP | 22 | SSH |
| 내 IP/32 | TCP | 6443 | 외부에서 kubectl (선택) |
| `0.0.0.0/0` 또는 내 IP | TCP | 80, 443 | Ingress (Harbor/Keycloak) |

> VCN CIDR 전체 허용 규칙이 없으면 **2-node 클러스터 네트워킹이 동작하지 않습니다.** flannel VXLAN이 막혀 pod 간 통신·DNS가 실패합니다.

### 0-3. ARM64 이미지 검증 (1순위 리스크)

Bitnami 무료 카탈로그 폐지로 `bitnamilegacy` 이미지를 쓰는데, aarch64 매니페스트가 있는지 확인합니다.

```bash
for img in \
  docker.io/bitnamilegacy/postgresql:18.5.0-debian-12-r0 \
  docker.io/bitnamilegacy/redis:7.4.1-debian-12-r0 \
  docker.io/bitnamilegacy/keycloak:26.3.3-debian-12-r0 \
  docker.io/bitnami/sealed-secrets-controller:0.27.1 ; do
  echo "== $img"
  docker manifest inspect "$img" | grep -A2 '"platform"' | grep arm64 \
    && echo "  arm64 OK" || echo "  !! arm64 매니페스트 없음 — 대체 이미지 필요"
done
```

`arm64 매니페스트 없음`이 나오면 [porting-guide.md](porting-guide.md) Phase 0의 대체 이미지(postgres/redis 공식 alpine, keycloak quay.io)로 해당 values를 교체합니다.

**✅ 완료 기준**: 보안목록에 VCN CIDR All-Protocols 규칙 존재, 4개 이미지 arm64 확인.

---

## Phase 1 — 컨트롤 노드 준비

Ansible은 Linux에서 실행됩니다. 컨트롤 노드 선택지:

| 선택 | 장점 | 비고 |
|------|------|------|
| **Node1 자체** (권장) | 사설 IP로 바로 도달, 추가 장비 불필요 | Node1에 ansible 설치, 자기 자신도 SSH 또는 `ansible_connection=local` |
| 별도 Linux/WSL | 노드와 분리 | 두 노드의 공인 IP + SSH 키 필요 |

```bash
# (컨트롤 노드에서) 의존성
sudo apt update && sudo apt install -y ansible git
git clone https://github.com/yhsk9200/platform-infra.git
cd platform-infra/ansible
ansible-galaxy collection install -r requirements.yml

# 노드 SSH 접속 확인 (키 경로는 inventory에서 지정)
ssh -i ~/.ssh/oci_k3s.pem ubuntu@<NODE1_IP> 'echo node1 ok'
ssh -i ~/.ssh/oci_k3s.pem ubuntu@<NODE2_IP> 'echo node2 ok'
```

**✅ 완료 기준**: `ansible --version` 동작, 두 노드 SSH 성공.

---

## Phase 2 — 설정 입력

### 2-1. 인벤토리 (`ansible/inventory/hosts.ini`)
노드 IP와 SSH 키를 실제 값으로:
```ini
[k3s_server]
node1 ansible_host=10.0.1.113
[k3s_agent]
node2 ansible_host=10.0.1.69
[k3s_cluster:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/oci_k3s.pem
```
> Node1을 컨트롤 노드로 쓰면 `node1`에 `ansible_connection=local`을 붙여도 됩니다.

### 2-2. 공통 변수 (`ansible/inventory/group_vars/all.yml`)
- `deployment_mode: online`
- `k3s_server_private_ip`: Node1 사설 IP
- `k3s_external_apiserver`: 외부에서 kubectl 쓰면 Node1 **공인 IP**, 아니면 사설 IP 유지
- `cluster_node_cidr`: VCN 서브넷(기본 `10.0.1.0/24`) 확인

### 2-3. 시크릿 vault
```bash
cp inventory/group_vars/vault.example.yml inventory/group_vars/vault.yml
vi inventory/group_vars/vault.yml          # 모든 CHANGE_ME 교체
ansible-vault encrypt inventory/group_vars/vault.yml
```

### 2-4. Harbor 외부 주소
`helm-values/registry/harbor-values.yaml`의 `<OCI_PUBLIC_IP>`를 Node IP로 교체(nip.io):
```bash
sed -i "s/<OCI_PUBLIC_IP>/<실제공인IP>/g" ../helm-values/registry/harbor-values.yaml
git -C .. commit -am "set harbor externalURL" && git -C .. push   # ArgoCD가 git에서 읽음
```
> ArgoCD는 git에서 values를 읽으므로 이 변경은 **커밋·push** 해야 반영됩니다.

**✅ 완료 기준**: vault 암호화됨, harbor 주소 커밋됨, all.yml IP 정확.

---

## Phase 3 — 부트스트랩 실행

```bash
cd platform-infra/ansible
ansible-playbook site.yml --syntax-check        # 문법 사전 점검
ansible-playbook site.yml --ask-vault-pass      # 실제 실행
```

플레이 진행 (예상 5~10분, 이후 ArgoCD 동기화 15~20분):

| Play | 내용 | 멱등성 |
|------|------|--------|
| preflight | swap/모듈/sysctl/**호스트 iptables**/hosts | ✅ |
| registries_mirror | (airgap만) 스킵됨 | - |
| k3s server | Node1 설치, kubeconfig→컨트롤노드 | ✅ |
| k3s agent | Node2 join | ✅ |
| argocd | 설치(server-side apply) | ✅ |
| secrets_seed | sealed-secrets + vault 시드 | ✅ |
| platform_bootstrap | root-app 적용 → ArgoCD 인계 | ✅ |

실패 시 같은 명령을 다시 실행해도 안전합니다(멱등).

**✅ 완료 기준**: 플레이북이 `failed=0`으로 종료, 마지막에 ArgoCD admin 비번 출력.

---

## Phase 4 — 검증

```bash
export KUBECONFIG=$PWD/kubeconfig      # k3s server play가 생성한 파일

kubectl get nodes -o wide              # 2개 Ready, ARM64
kubectl get applications -n argocd     # 모두 Synced / Healthy 목표
kubectl get pods -A | grep -vE 'Running|Completed'   # 비정상 pod만 출력(없어야 정상)
```

컴포넌트별 상태:
```bash
kubectl get pods -n platform-db          # postgres, redis
kubectl get pods -n platform-iam         # keycloak
kubectl get pods -n platform-monitoring  # prometheus/grafana/loki/alloy
kubectl get pods -n platform-registry    # harbor
kubectl get clusterissuer                # platform-ca True
```

> **Harbor는 `Healthy + OutOfSync`로 남을 수 있습니다** — chart 특성상 알려진 diff(ADR-0002). UI·push/pull이 되면 정상으로 간주합니다.

**✅ 완료 기준**: nodes 2 Ready, Harbor 외 Applications Synced+Healthy, 비정상 pod 없음.

---

## Phase 5 — 서비스 접근

공인 도메인/TLS 확정 전이므로 port-forward로 확인합니다.

```bash
# ArgoCD UI (admin / 플레이북 출력 비번)
kubectl -n argocd port-forward svc/argocd-server 8080:443
#   → https://localhost:8080

# Grafana (admin / vault의 grafana 비번)
kubectl -n platform-monitoring port-forward \
  svc/platform-monitoring-kube-prometheus-stack-grafana 3000:80
#   → http://localhost:3000  (Explore에서 Loki 로그 확인)

# Keycloak admin (admin / vault의 keycloak admin 비번)
kubectl -n platform-iam port-forward svc/platform-iam-keycloak 8081:80
#   → http://localhost:8081

# Harbor (admin / vault의 harbor 비번) — ingress 직접
#   → http://harbor.<OCI_PUBLIC_IP>.nip.io
```

**✅ 완료 기준**: ArgoCD/Grafana/Keycloak/Harbor UI 로그인 성공.

---

## Phase 6 — 사후 작업

### Harbor push/pull (HTTP insecure registry)
TLS 미적용이므로 Docker 클라이언트에 insecure 등록:
```bash
# /etc/docker/daemon.json
{ "insecure-registries": ["harbor.<OCI_PUBLIC_IP>.nip.io"] }
# sudo systemctl restart docker
docker login harbor.<OCI_PUBLIC_IP>.nip.io
```

### 시크릿 로테이션
`vault.yml` 값 변경 후 secrets_seed만 재실행:
```bash
ansible-playbook site.yml --ask-vault-pass --limit k3s_server \
  --start-at-task "SealedSecret 생성 및 적용"
# 해당 워크로드 pod restart로 반영
```

---

## 트러블슈팅

| 증상 | 원인 | 조치 |
|------|------|------|
| agent가 server에 join 실패 | OCI 보안목록 VCN CIDR 미허용 | Phase 0-2 규칙 추가 |
| pod 간 통신/DNS 실패, CoreDNS CrashLoop | flannel VXLAN(8472/udp) 차단 | 보안목록 + 호스트 iptables(preflight) 확인 |
| `ImagePullBackOff` (postgres/redis/keycloak) | bitnamilegacy arm64 매니페스트 없음 | Phase 0-3 대체 이미지로 values 교체 |
| postgres/redis Pod Pending(PVC) | 노드 디스크 부족 또는 local-path 미동작 | `kubectl get pvc -A`, 노드 `df -h` |
| ArgoCD app OutOfSync 지속(Harbor 제외) | git 미반영 | values 변경 후 commit·push 확인 |
| Harbor `OutOfSync` | 알려진 chart diff | 정상 — UI/push 동작하면 무시 |
| ClusterIssuer not ready | cert-manager webhook 미기동 | `kubectl get pods -n cert-manager`, 재sync |
| 외부 kubectl 6443 연결 불가 | 보안목록 6443 미허용 / 사설 IP kubeconfig | 보안목록 + `k3s_external_apiserver`=공인 IP |

진단 명령:
```bash
kubectl describe pod <pod> -n <ns>           # 이벤트 확인
kubectl logs <pod> -n <ns>
sudo k3s kubectl get events -A --sort-by=.lastTimestamp | tail -30
sudo systemctl status k3s          # (server) / k3s-agent (agent)
sudo iptables -L INPUT -n --line-numbers | head   # ACCEPT 규칙 확인
```
