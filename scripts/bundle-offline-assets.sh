#!/usr/bin/env bash
# =============================================================================
# bundle-offline-assets.sh — air-gap 오프라인 자산 번들러 (STUB / Mode B 심)
# =============================================================================
# 인터넷이 되는 머신에서 실행하여, 폐쇄망으로 반입할 자산을 한 디렉토리에
# 모은다. 이 스크립트는 현재 골격(stub)이며, 실제 사용 시 각 단계를 채운다.
#
# 전체 air-gap 전략은 docs/adr/0005-airgap-strategy.md를 참조한다.
#
# 산출물 구조 (예):
#   offline-assets/
#   ├── k3s/
#   │   ├── k3s                              # aarch64 바이너리
#   │   ├── k3s-airgap-images-arm64.tar.zst  # k3s 코어 이미지
#   │   └── install.sh
#   ├── images/                              # 플랫폼 컨테이너 이미지 (skopeo)
#   ├── charts/                              # helm chart .tgz
#   └── cli/                                 # helm, kubeseal 바이너리
# =============================================================================
set -euo pipefail

ARCH="${ARCH:-arm64}"
K3S_VERSION="${K3S_VERSION:-v1.31.5+k3s1}"
OUT_DIR="${OUT_DIR:-offline-assets}"

echo "[stub] 이 스크립트는 아직 구현되지 않은 Mode B 심입니다."
echo "[stub] 구현해야 할 단계:"
cat <<'STEPS'

  1. k3s 코어 자산 다운로드
     - https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-arm64
     - https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-airgap-images-arm64.tar.zst
     - https://get.k3s.io (install.sh)

  2. 플랫폼 컨테이너 이미지 미러링 (skopeo copy → 내부 레지스트리 또는 tar)
     - 대상: README의 컴포넌트 표 + 각 chart의 의존 이미지
     - 예: skopeo copy docker://docker.io/bitnamilegacy/postgresql:TAG \
             docker://harbor.internal/bitnamilegacy/postgresql:TAG

  3. Helm chart 다운로드 (helm pull → charts/*.tgz)
     - postgresql, redis, keycloak, kube-prometheus-stack, loki, alloy,
       harbor, cert-manager, sealed-secrets

  4. CLI 바이너리 (helm, kubeseal aarch64)

  5. 전체를 tar로 묶어 반입 매체로 전달

STEPS

echo "[stub] ARCH=${ARCH} K3S_VERSION=${K3S_VERSION} OUT_DIR=${OUT_DIR}"
exit 0
