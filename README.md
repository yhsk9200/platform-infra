# platform-infra

OCI Free Tier 2-node k3s 클러스터의 공용 인프라 컴포넌트를 ArgoCD App of Apps 패턴으로 관리하는 GitOps 저장소입니다.

Kubernetes 기반 관찰 가능성, 인증/인가, 컨테이너 레지스트리, 데이터베이스 등 플랫폼 공통 기반 서비스를 선언적으로 배포하고 관리합니다.

**Day-0 부트스트랩은 Ansible(`ansible/site.yml`)이, Day-1+ 지속배포는 ArgoCD가** 담당합니다. `ansible-playbook site.yml` 한 줄로 빈 노드에서 k3s → ArgoCD → 시크릿 → 전체 플랫폼까지 배포됩니다. 책임 경계는 [ADR-0004](docs/adr/0004-ansible-argocd-boundary.md), 폐쇄망(air-gap) 전략은 [ADR-0005](docs/adr/0005-airgap-strategy.md)를 참조합니다.

## 클러스터 환경

| 항목 | 값 |
|------|-----|
| 인스턴스 | OCI VM.Standard.A1.Flex × 2 |
| Architecture | ARM64 (aarch64) |
| CPU | 2 OCPU per node |
| RAM | 12 GB per node |
| Storage | 100 GB NVMe per node |
| OS | Ubuntu 24.04 LTS |
| k3s | v1.31+ |
| CNI | Flannel |
| Ingress | Traefik |

## 배포 구조

Ansible이 k3s·ArgoCD·시크릿을 부트스트랩한 뒤 Root Application을 적용합니다. 이후 Root Application이 `apps/`의 ApplicationSet과 AppProject를 동기화하고, ApplicationSet이 나머지 자식 Application을 관리합니다.

```
ansible/site.yml  (Day-0: k3s + ArgoCD + 시크릿 시드 + root-app 적용)
  └── apps/
      ├── appproject-platform-infra.yaml   (ArgoCD AppProject, wave -10)
      └── platform-appset.yaml             (ApplicationSet, wave -9)
            ├── platform-infra-namespaces
            ├── platform-infra-storage
            ├── platform-infra-pki
            ├── platform-system-cert-manager
            ├── platform-db-postgres
            ├── platform-db-redis
            ├── platform-iam-keycloak
            ├── platform-monitoring-prometheus
            ├── platform-monitoring-loki
            └── platform-monitoring-alloy

      └── platform-registry-harbor.yaml    (Harbor 전용 Application, wave 4)
```

- **시크릿 계층**(sealed-secrets controller + SealedSecret)은 ArgoCD가 아니라 **Ansible이 Day-0에 소유**합니다. 클러스터마다 sealing 키가 다르기 때문입니다 ([ADR-0004](docs/adr/0004-ansible-argocd-boundary.md)).
- **Harbor**만 별도 Application으로 분리한 이유는 [ADR-0002](docs/adr/0002-applicationset-vs-individual-apps.md)를 참조합니다.

## Sync Wave (ArgoCD 관리 범위)

| Wave | Application | 역할 |
|------|-------------|------|
| `-10` | `appproject-platform-infra` | ArgoCD AppProject |
| `-9` | `platform-appset` | ApplicationSet (이 레포의 핵심) |
| `-3` | `platform-infra-namespaces` | 공용 네임스페이스 생성 |
| `0` | `platform-infra-storage`, `platform-infra-pki`, `platform-system-cert-manager` | PVC, PKI 체인, cert-manager |
| `1` | `platform-db-postgres`, `platform-db-redis` | 공용 데이터베이스 |
| `2` | `platform-iam-keycloak` | 인증/인가 (PostgreSQL 의존) |
| `3` | `platform-monitoring-prometheus` | Prometheus, Grafana, Alertmanager |
| `4` | `platform-monitoring-loki`, `platform-registry-harbor` | 로그 저장소, 컨테이너 레지스트리 |
| `5` | `platform-monitoring-alloy` | 로그 수집기 (Loki endpoint 이후) |

> 시크릿 계층(sealed-secrets controller, SealedSecret)은 Ansible `secrets_seed`가 ArgoCD보다 먼저 시드하므로 위 표에 없습니다.

## 네임스페이스

| Namespace | 용도 |
|-----------|------|
| `platform-system` | Sealed Secrets controller |
| `platform-db` | PostgreSQL, Redis |
| `platform-iam` | Keycloak |
| `platform-monitoring` | Prometheus, Grafana, Alertmanager, Loki, Alloy |
| `platform-registry` | Harbor |
| `cert-manager` | cert-manager controller, PKI chain |

## 컴포넌트 및 버전

| 컴포넌트 | Chart | Version |
|---------|-------|---------|
| PostgreSQL | `bitnami/postgresql` | `18.5.19` |
| Redis | `bitnami/redis` | `25.3.11` |
| Keycloak | `bitnami/keycloak` | `25.2.0` |
| Sealed Secrets | `bitnami-labs/sealed-secrets` | `2.18.4` |
| cert-manager | `jetstack/cert-manager` | `v1.17.0` |
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` | `83.6.0` |
| Loki | `grafana-community/loki` | `6.46.0` |
| Alloy | `grafana/alloy` | `1.7.0` |
| Harbor | `goharbor/harbor` | `1.16.2` |

## 스토리지 배치

local-path StorageClass를 사용하며, 워크로드를 두 노드에 분산합니다.

| 노드 | 컴포넌트 | 용량 |
|------|---------|------|
| Node1 | PostgreSQL | 10 GB |
| Node1 | Redis | 5 GB |
| Node1 | Prometheus | 30 GB (15d 보존) |
| Node1 | Grafana | 10 GB |
| Node1 | Alertmanager | 5 GB |
| **Node1 합계** | | **60 GB** |
| Node2 | Loki | 30 GB (14d 보존) |
| Node2 | Harbor registry | 20 GB |
| Node2 | Harbor 기타 | 10 GB |
| **Node2 합계** | | **60 GB** |

## 디렉토리 구조

```
platform-infra/
├── ansible/                             # Day-0 부트스트랩 (k3s + ArgoCD + 시크릿)
│   ├── site.yml                         #   단일 진입점
│   ├── inventory/                       #   노드 IP, group_vars, vault
│   └── roles/                           #   preflight/k3s/argocd/secrets_seed/...
├── scripts/
│   └── bundle-offline-assets.sh         # air-gap 오프라인 번들러 (Mode B 심)
├── bootstrap/
│   └── root-app.yaml                    # 수동 적용용 (Ansible은 템플릿으로 별도 생성)
├── apps/
│   ├── appproject-platform-infra.yaml
│   ├── platform-appset.yaml             # ApplicationSet (10개 컴포넌트)
│   └── platform-registry-harbor.yaml    # Harbor 단독 Application
├── manifests/
│   ├── namespaces/
│   ├── pki/                             # cert-manager ClusterIssuer 체인
│   ├── security/                        # SealedSecret 참조 템플릿 (Ansible이 시드)
│   └── storage/
├── helm-values/
│   ├── database/ iam/ monitoring/ registry/ system/
└── docs/
    ├── porting-guide.md
    └── adr/
        ├── 0001-ai-model-simulator-platform.md
        ├── 0002-applicationset-vs-individual-apps.md
        ├── 0003-loki-storage-nas-upgrade-path.md
        ├── 0004-ansible-argocd-boundary.md
        └── 0005-airgap-strategy.md
```

## 최초 부트스트랩 (딸깍)

```bash
cd ansible

# 1. collection 의존성
ansible-galaxy collection install -r requirements.yml

# 2. 노드 IP / 환경 / 시크릿 설정
vi inventory/hosts.ini
vi inventory/group_vars/all.yml
cp inventory/group_vars/vault.example.yml inventory/group_vars/vault.yml
vi inventory/group_vars/vault.yml && ansible-vault encrypt inventory/group_vars/vault.yml

# 3. 한 줄 부트스트랩 (k3s → ArgoCD → 시크릿 → root-app)
ansible-playbook site.yml --ask-vault-pass
```

수동 절차(Ansible 없이) 및 air-gap 세부는 [docs/porting-guide.md](docs/porting-guide.md)와 [ansible/README.md](ansible/README.md)를 참조합니다.

## SealedSecret 구성

값은 `ansible/inventory/group_vars/vault.yml`(ansible-vault 암호화)에 두고, `secrets_seed` role이 대상 클러스터의 controller 키로 봉인해 적용합니다. git에는 평문도 클러스터별 암호문도 커밋하지 않습니다. `manifests/security/*.yaml`은 키 구성을 보여주는 참조 템플릿입니다.

| Secret | Namespace | 키 | 비고 |
|--------|-----------|-----|------|
| `postgres-db-secret` | `platform-db` | `postgres-password`, `keycloak-password`, `harbor-password` | 공용 PostgreSQL |
| `redis-secret` | `platform-db` | `redis-password` | |
| `keycloak-admin-secret` | `platform-iam` | `admin-password` | |
| `keycloak-db-secret` | `platform-iam` | `keycloak-password` | postgres의 `keycloak-password`와 동일 |
| `grafana-admin-secret` | `platform-monitoring` | `admin-user`, `admin-password` | |
| `harbor-admin-secret` | `platform-registry` | `admin-password` | |
| `harbor-core-secret` | `platform-registry` | `secretKey` | 16자 이상 랜덤 |
| `harbor-db-secret` | `platform-registry` | `password` | postgres의 `harbor-password`와 동일 |

## cert-manager PKI

`manifests/pki/cluster-issuer.yaml`에 3단 자체 서명 체인을 구성합니다.

```
selfsigned-issuer (ClusterIssuer)
  └── platform-root-ca (Certificate, cert-manager ns)
        └── platform-ca (ClusterIssuer) ← 앱에서 이 issuer 참조
```

인증서 발급 시 annotation: `cert-manager.io/cluster-issuer: platform-ca`

도메인/TLS 확정 후 `helm-values/iam/keycloak-values-prod.yaml`으로 전환하면 Keycloak Ingress에 자동 인증서가 발급됩니다.

## 설계 의사결정 기록

- [ADR-0001](docs/adr/0001-ai-model-simulator-platform.md): AI 모델 시뮬레이터 플랫폼 구성 방향
- [ADR-0002](docs/adr/0002-applicationset-vs-individual-apps.md): ApplicationSet vs 개별 Application 파일
- [ADR-0003](docs/adr/0003-loki-storage-nas-upgrade-path.md): Loki 스토리지 NAS MinIO S3 전환 경로
- [ADR-0004](docs/adr/0004-ansible-argocd-boundary.md): Ansible(Day-0)와 ArgoCD(Day-1)의 책임 경계
- [ADR-0005](docs/adr/0005-airgap-strategy.md): 폐쇄망(air-gap) 배포 전략과 범위

## 다음 작업 후보

- SealedSecret 재생성 후 OCI 클러스터 실제 배포 검증
- Keycloak 도메인/TLS 확정 후 prod values 전환
- Platform alerting rule 및 Alertmanager receiver 설계
- Harbor 외부 push/pull 검증
- WireGuard VPN + NAS MinIO 연동 (ADR-0003)
- NetworkPolicy 강화 (Cilium CNI 전환 검토)
