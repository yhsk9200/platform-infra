# platform-infra

OCI Free Tier 2-node k3s 클러스터의 공용 인프라 컴포넌트를 ArgoCD App of Apps 패턴으로 관리하는 GitOps 저장소입니다.

Kubernetes 기반 관찰 가능성, 인증/인가, 컨테이너 레지스트리, 데이터베이스 등 플랫폼 공통 기반 서비스를 선언적으로 배포하고 관리합니다.

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

최초 부트스트랩은 `bootstrap/root-app.yaml`을 수동 1회 적용합니다. 이후 Root Application이 `apps/` 디렉토리의 ApplicationSet과 AppProject를 동기화하고, ApplicationSet이 나머지 모든 자식 Application을 관리합니다.

```
bootstrap/root-app.yaml  (수동 1회 적용)
  └── apps/
      ├── appproject-platform-infra.yaml   (ArgoCD AppProject, wave -10)
      └── platform-appset.yaml             (ApplicationSet, wave -9)
            ├── platform-infra-namespaces
            ├── platform-system-sealed-secrets
            ├── platform-infra-secrets
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

Harbor만 별도 Application으로 분리한 이유는 [ADR-0002](docs/adr/0002-applicationset-vs-individual-apps.md)를 참조합니다.

## Sync Wave

| Wave | Application | 역할 |
|------|-------------|------|
| `-10` | `appproject-platform-infra` | ArgoCD AppProject |
| `-9` | `platform-appset` | ApplicationSet (이 레포의 핵심) |
| `-3` | `platform-infra-namespaces` | 공용 네임스페이스 생성 |
| `-2` | `platform-system-sealed-secrets` | Sealed Secrets controller |
| `-1` | `platform-infra-secrets` | SealedSecret 리소스 배포 |
| `0` | `platform-infra-storage`, `platform-infra-pki`, `platform-system-cert-manager` | PVC, PKI 체인, cert-manager |
| `1` | `platform-db-postgres`, `platform-db-redis` | 공용 데이터베이스 |
| `2` | `platform-iam-keycloak` | 인증/인가 (PostgreSQL 의존) |
| `3` | `platform-monitoring-prometheus` | Prometheus, Grafana, Alertmanager |
| `4` | `platform-monitoring-loki`, `platform-registry-harbor` | 로그 저장소, 컨테이너 레지스트리 |
| `5` | `platform-monitoring-alloy` | 로그 수집기 (Loki endpoint 이후) |

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
├── bootstrap/
│   └── root-app.yaml
├── apps/
│   ├── appproject-platform-infra.yaml
│   ├── platform-appset.yaml             # ApplicationSet (12개 컴포넌트)
│   └── platform-registry-harbor.yaml   # Harbor 단독 Application
├── manifests/
│   ├── namespaces/
│   ├── pki/                             # cert-manager ClusterIssuer 체인
│   ├── security/                        # SealedSecret 리소스
│   └── storage/
├── helm-values/
│   ├── database/
│   ├── iam/
│   ├── monitoring/
│   ├── registry/
│   └── system/
└── docs/
    ├── porting-guide.md
    └── adr/
        ├── 0001-ai-model-simulator-platform.md
        ├── 0002-applicationset-vs-individual-apps.md
        └── 0003-loki-storage-nas-upgrade-path.md
```

## 최초 부트스트랩

신규 클러스터에 배포할 때는 [docs/porting-guide.md](docs/porting-guide.md)의 전체 절차를 따릅니다.

요약:

```bash
# 1. GitHub URL 교체
sed -i "s/<YOUR_GITHUB_USERNAME>/<실제username>/g" \
  bootstrap/root-app.yaml apps/*.yaml

# 2. Harbor externalURL 교체
sed -i "s/<OCI_PUBLIC_IP>/<실제IP>/g" helm-values/registry/harbor-values.yaml

# 3. Root App 적용 (sealed-secrets controller wave -2 배포)
kubectl apply -f bootstrap/root-app.yaml

# 4. sealed-secrets 공개키 취득 후 SealedSecret 전량 재생성
kubeseal --fetch-cert --controller-name=sealed-secrets-controller \
  --controller-namespace=platform-system > pub-cert.pem
# (각 Secret 재생성 → git push → ArgoCD 자동 sync)
```

## SealedSecret 구성

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

## 다음 작업 후보

- SealedSecret 재생성 후 OCI 클러스터 실제 배포 검증
- Keycloak 도메인/TLS 확정 후 prod values 전환
- Platform alerting rule 및 Alertmanager receiver 설계
- Harbor 외부 push/pull 검증
- WireGuard VPN + NAS MinIO 연동 (ADR-0003)
- NetworkPolicy 강화 (Cilium CNI 전환 검토)
