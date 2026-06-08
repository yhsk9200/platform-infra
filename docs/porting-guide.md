# Porting Guide — 신규 클러스터 배포 절차

OCI VM.Standard.A1.Flex (ARM64) 기반 2-node k3s 클러스터에 이 레포를 배포하는 전체 순서입니다.

## 환경 요구 사항

| 항목 | 값 |
|------|-----|
| Node1 (Server) | OCI VM.Standard.A1.Flex, 2 OCPU, 12 GB RAM, 100 GB NVMe, Ubuntu 24.04 aarch64 |
| Node2 (Agent) | 동일 사양 |
| k3s 버전 | v1.31 이상 |
| ArgoCD 버전 | v2.12 이상 (ApplicationSet List Generator goTemplate 지원) |
| kubeseal 버전 | v0.27 이상 |

---

## Phase 0: ARM64 이미지 검증

배포 전 bitnamilegacy 이미지가 aarch64 멀티아치 매니페스트를 포함하는지 확인합니다.

```bash
docker manifest inspect docker.io/bitnamilegacy/postgresql:17.5.0-debian-12-r0 \
  | python3 -c "import json,sys; [print(p['architecture']) for p in json.load(sys.stdin).get('manifests', [])]"

docker manifest inspect docker.io/bitnamilegacy/redis:7.4.3-debian-12-r0 \
  | python3 -c "import json,sys; [print(p['architecture']) for p in json.load(sys.stdin).get('manifests', [])]"

docker manifest inspect docker.io/bitnamilegacy/keycloak:26.3.3-debian-12-r0 \
  | python3 -c "import json,sys; [print(p['architecture']) for p in json.load(sys.stdin).get('manifests', [])]"
```

출력에 `arm64`가 포함되지 않으면 아래 대체 이미지를 values 파일에 지정합니다.

| 컴포넌트 | 대체 이미지 |
|---------|-----------|
| PostgreSQL | `docker.io/postgres:17-alpine` |
| Redis | `docker.io/redis:7-alpine` |
| Keycloak | `quay.io/keycloak/keycloak:26.1.4` (bitnami chart 구조 변경 필요) |

---

## Phase 1: k3s 클러스터 설치

### Node1 (Server)

```bash
# TLS SAN에 공인 IP와 사설 IP를 포함한다
curl -sfL https://get.k3s.io | sh -s - \
  --tls-san <NODE1_PUBLIC_IP> \
  --tls-san 10.0.1.113 \
  --disable traefik \   # 또는 활성화 유지 (ingress로 활용)
  --node-name node1-server

# Agent 접속 토큰 확인
sudo cat /var/lib/rancher/k3s/server/node-token
```

### Node2 (Agent)

```bash
K3S_TOKEN=<TOKEN_FROM_NODE1>
K3S_URL=https://10.0.1.113:6443  # Node1 사설 IP 사용

curl -sfL https://get.k3s.io | K3S_URL=$K3S_URL K3S_TOKEN=$K3S_TOKEN sh -s - \
  --node-name node2-agent
```

### kubeconfig 설정

```bash
# Node1에서
sudo cat /etc/rancher/k3s/k3s.yaml | \
  sed 's/127.0.0.1/<NODE1_PUBLIC_IP>/' > ~/.kube/config
chmod 600 ~/.kube/config

# 클러스터 확인
kubectl get nodes -o wide
```

---

## Phase 2: ArgoCD 설치

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# ArgoCD admin 초기 비밀번호 확인
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

ArgoCD UI 접근: `kubectl port-forward svc/argocd-server -n argocd 8080:443`

---

## Phase 3: GitHub 레포 URL 교체

레포를 GitHub에 push한 뒤 아래 파일에서 `<YOUR_GITHUB_USERNAME>`을 실제 username으로 교체합니다.

```bash
YOUR_GH_USER=<실제_GitHub_username>

# 교체 대상 파일
sed -i "s/<YOUR_GITHUB_USERNAME>/${YOUR_GH_USER}/g" \
  bootstrap/root-app.yaml \
  apps/appproject-platform-infra.yaml \
  apps/platform-appset.yaml \
  apps/platform-registry-harbor.yaml
```

---

## Phase 4: Harbor externalURL 교체

```bash
OCI_PUBLIC_IP=<Node1_공인_IP>

sed -i "s/<OCI_PUBLIC_IP>/${OCI_PUBLIC_IP}/g" \
  helm-values/registry/harbor-values.yaml
```

---

## Phase 5: SealedSecret 재생성

### 공개키 취득

먼저 `bootstrap/root-app.yaml`을 적용해 sealed-secrets controller(wave -2)를 배포한 뒤 진행합니다.

```bash
kubectl apply -f bootstrap/root-app.yaml

# sealed-secrets controller가 Running 될 때까지 대기 (~2분)
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=sealed-secrets \
  -n platform-system --timeout=120s

# 공개키 취득
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=platform-system \
  > pub-cert.pem
```

### 각 Secret 재생성

비밀번호 값을 결정한 뒤 아래 명령어로 재생성합니다. `pub-cert.pem`은 `.gitignore`에 포함되어 있으므로 커밋되지 않습니다.

```bash
# PostgreSQL (keycloak-password와 harbor-password는 다른 Secret과 값이 동일해야 함)
kubectl create secret generic postgres-db-secret \
  --namespace=platform-db \
  --from-literal=postgres-password='<POSTGRES_PW>' \
  --from-literal=keycloak-password='<KEYCLOAK_DB_PW>' \
  --from-literal=harbor-password='<HARBOR_DB_PW>' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml \
  > manifests/security/postgres-sealed-secret.yaml

# Redis
kubectl create secret generic redis-secret \
  --namespace=platform-db \
  --from-literal=redis-password='<REDIS_PW>' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml \
  > manifests/security/redis-sealed-secret.yaml

# Keycloak admin
kubectl create secret generic keycloak-admin-secret \
  --namespace=platform-iam \
  --from-literal=admin-password='<KEYCLOAK_ADMIN_PW>' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml \
  > manifests/security/keycloak-sealed-secret.yaml

# Keycloak DB (postgres-db-secret의 keycloak-password와 동일 값)
kubectl create secret generic keycloak-db-secret \
  --namespace=platform-iam \
  --from-literal=keycloak-password='<KEYCLOAK_DB_PW>' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml \
  > manifests/security/keycloak-db-sealed-secret.yaml

# Grafana
kubectl create secret generic grafana-admin-secret \
  --namespace=platform-monitoring \
  --from-literal=admin-user='admin' \
  --from-literal=admin-password='<GRAFANA_PW>' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml \
  > manifests/security/grafana-sealed-secret.yaml

# Harbor admin
kubectl create secret generic harbor-admin-secret \
  --namespace=platform-registry \
  --from-literal=admin-password='<HARBOR_ADMIN_PW>' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml \
  > manifests/security/harbor-sealed-secret.yaml

# Harbor core secret key (16자 이상 랜덤 문자열)
HARBOR_SECRET_KEY=$(openssl rand -base64 16 | tr -d '=+/')
kubectl create secret generic harbor-core-secret \
  --namespace=platform-registry \
  --from-literal=secretKey="${HARBOR_SECRET_KEY}" \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml \
  >> manifests/security/harbor-sealed-secret.yaml

# Harbor DB (postgres-db-secret의 harbor-password와 동일 값)
kubectl create secret generic harbor-db-secret \
  --namespace=platform-registry \
  --from-literal=password='<HARBOR_DB_PW>' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml \
  > manifests/security/harbor-db-sealed-secret.yaml
```

재생성 후 Git 커밋:

```bash
git add manifests/security/
git commit -m "reseal: regenerate SealedSecrets for new cluster"
git push
```

---

## Phase 6: 전체 배포

ArgoCD가 GitOps로 나머지 App을 자동 배포합니다. sync wave 순서대로 배포되는지 확인합니다.

```bash
# ArgoCD App 상태 모니터링
argocd app list
# 또는
kubectl get applications -n argocd -w
```

예상 배포 순서:

| Wave | App | 예상 소요 |
|------|-----|---------|
| -10 | AppProject | 즉시 |
| -9 | ApplicationSet | 즉시 |
| -3 | platform-infra-namespaces | 즉시 |
| -2 | platform-system-sealed-secrets | ~1분 |
| -1 | platform-infra-secrets | 즉시 |
| 0 | storage, pki, cert-manager | ~2분 |
| 1 | postgres, redis | ~3분 |
| 2 | keycloak | ~3분 |
| 3 | prometheus | ~5분 |
| 4 | loki, harbor | ~5분 |
| 5 | alloy | ~1분 |

---

## Phase 7: 서비스 접근 확인

```bash
# Grafana
kubectl port-forward svc/platform-monitoring-kube-prometheus-stack-grafana \
  -n platform-monitoring 3000:80

# Keycloak admin console
kubectl port-forward svc/platform-iam-keycloak \
  -n platform-iam 8080:80

# Harbor (ingress 사용)
# http://harbor.<OCI_PUBLIC_IP>.nip.io
```

---

## 스토리지 배치 참고

| 노드 | 컴포넌트 | PVC 크기 |
|------|---------|---------|
| Node1 | PostgreSQL | 10 GB |
| Node1 | Redis | 5 GB |
| Node1 | Prometheus | 30 GB |
| Node1 | Grafana | 10 GB |
| Node1 | Alertmanager | 5 GB |
| Node2 | Loki | 30 GB |
| Node2 | Harbor (registry) | 20 GB |
| Node2 | Harbor (기타) | 15 GB |

local-path는 처음 마운트된 노드에 바인딩됩니다. 각 노드에 할당되어야 할 워크로드가 올바른 노드에 스케줄되는지 확인하고, 필요하면 nodeSelector 또는 nodeAffinity를 추가합니다.
