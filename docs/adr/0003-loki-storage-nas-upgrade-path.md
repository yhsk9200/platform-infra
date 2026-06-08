# ADR-0003: Loki 스토리지 — local-path filesystem에서 NAS MinIO S3로의 전환 경로

## 상태

제안됨 (현재 미구현)

## 날짜

2026-06-08

## 맥락

Loki의 로그 데이터는 현재 Node2의 local-path StorageClass를 통해 로컬 디스크에 저장된다 (30GB, 14일 보존).

운영 측면의 제약:
- 노드 장애 시 로그 데이터 손실
- 디스크 용량은 해당 노드의 물리 디스크에 종속
- 장기 보존을 위해 디스크를 늘리려면 노드 재구성 필요

보유 중인 NAS(Synology)는 OCI k3s 클러스터와 별개 네트워크에 있다.

## 선택지

### Option A: local-path filesystem (현재 상태)

장점:
- 설정 단순, 추가 인프라 없음
- k3s 기본 StorageClass 활용

단점:
- 노드 장애 = 로그 손실
- 용량 확장 어려움

### Option B: NAS MinIO S3 backend

OCI 인스턴스와 NAS 사이에 WireGuard VPN을 구성한 뒤, NAS에 MinIO를 설치하고 Loki의 object store backend로 연결한다.

장점:
- 로그 데이터가 클러스터 외부에 보존 → 노드 장애에 독립
- NAS 용량을 활용해 장기 보존 가능 (수백 GB)
- Loki는 S3-compatible backend에 최적화되어 있어 전환이 자연스럽다

단점:
- WireGuard VPN 설정이 선행 작업
- NAS에 MinIO 운영 부담 추가
- OCI ↔ NAS 인터넷 레이턴시 (Loki는 배치 쓰기 방식이라 영향 최소화)

### Option C: Longhorn 분산 스토리지

k3s 2 node에 Longhorn을 설치해 노드 간 복제 PV를 구성한다.

장점:
- 노드 장애 내구성 (복제 인자 2)
- NAS 없이 클러스터 내 HA 가능

단점:
- Longhorn 운영 복잡도
- 각 노드의 일정 CPU/메모리를 Longhorn 데몬에 할당해야 함
- OCI 100GB × 2 = 200GB 풀이지만 복제 인자 2 → 실사용 100GB

## 결정

현재는 **Option A (local-path)**를 유지한다. 포트폴리오 환경에서 운영 단순성을 우선한다.

**Option B**를 장기 upgrade path로 채택한다. 전환 조건:

1. WireGuard VPN이 OCI ↔ NAS 간에 안정적으로 운영됨
2. NAS에 MinIO가 설치되고 S3 endpoint가 준비됨
3. 14일 이상의 로그 보존 필요성이 생김

## 전환 절차 (Option B 채택 시)

```bash
# 1. NAS MinIO에 loki-logs 버킷 생성
# 2. loki-values.yaml 수정:
loki:
  storage:
    type: s3
    s3:
      endpoint: http://<NAS_IP>:9000
      bucketNames:
        chunks: loki-chunks
        ruler: loki-ruler
        admin: loki-admin
      region: us-east-1
      accessKeyId: <MINIO_ACCESS_KEY>
      secretAccessKey: <MINIO_SECRET_KEY>
      s3ForcePathStyle: true
      insecure: true

# 3. ArgoCD sync → Loki Pod 재시작 → 새 로그는 MinIO에 저장
# 4. 기존 filesystem 데이터는 마이그레이션 필요 (또는 보존 기간 만료 후 자동 삭제)
```

MinIO credentials는 SealedSecret으로 관리한다.

## 미결 사항

- NAS 공인 IP 또는 도메인 접근 방식 (직접 접근 vs WireGuard)
- MinIO single-node PoC로 시작할지, 멀티 드라이브 구성할지
- Prometheus metric 데이터도 같이 이전할지 (Thanos/Mimir 검토)
