# ADR-0005: 폐쇄망(air-gap) 배포 전략과 범위

## 상태

제안됨 (심만 구현, 본체 미구현)

## 날짜

2026-06-08

## 맥락

이 플랫폼의 원래 목적 중 하나는 **폐쇄망 k8s 클러스터 배포 MVP**다. 그러나 현재 레포는 공개 GitHub + 공개 Helm 레포 + 공개 이미지에 의존하므로 그대로는 폐쇄망에서 동작하지 않는다.

폐쇄망에서 끊어내야 하는 외부 의존:

| 의존 | 현재 | 폐쇄망 |
|------|------|--------|
| ArgoCD git 소스 | 공개 GitHub | 내부 git (Gitea/GitLab) |
| 컨테이너 이미지 | 공개 pull | 내부 레지스트리 |
| Helm chart | 공개 chart repo | 내부 chart repo or git vendoring |
| k3s/CLI 설치 | get.k3s.io | 오프라인 번들 |

## 결정

**"2-mode 심(seam), Mode A 구현" 전략을 채택한다.** online(Mode A)을 완전 구현하되, air-gap(Mode B)이 추가 레이어로 깔끔하게 확장되도록 *변수·토글·역할 골격*을 미리 마련한다.

### 이미 마련된 심

- `deployment_mode: online | airgap` 단일 스위치 (`group_vars/all.yml`)
- `image_registry` 변수 — 내부 레지스트리 주소
- `git_repo_url` 변수 — ArgoCD 소스를 내부 git으로 전환
- `k3s_offline` 토글 — k3s 오프라인 설치 분기
- `registries_mirror` role — **구현 완료**. `/etc/rancher/k3s/registries.yaml`로 containerd 레벨에서 `docker.io`/`quay.io`/`registry.k8s.io`/`ghcr.io`를 내부 레지스트리로 리라이트

### 핵심 인사이트: registries.yaml 미러

이미지 의존을 끊는 데 **helm-values를 일일이 수정하지 않는다.** k3s의 `registries.yaml`로 containerd 레벨에서 레지스트리를 통째로 리라이트하면, 차트/values는 그대로 두고도 내부 레지스트리에서 이미지를 당긴다. 이것이 air-gap 적용 비용을 극적으로 낮춘다.

### 미구현 (실제 폐쇄망 적용 시 채울 범위)

1. `roles/k3s/tasks/offline.yml` — k3s 바이너리/airgap 이미지 tarball 배치
2. `scripts/bundle-offline-assets.sh` — 인터넷 머신에서 자산 번들 생성
3. Helm chart 전달 — registries.yaml은 **이미지만** 리라이트한다. 차트는 별도로 내부 chart repo 또는 git vendoring 필요
4. `secrets_seed`의 helm/kubeseal 설치 — 오프라인 바이너리 경로로 전환

## 명시적 비목표 (포트폴리오 과잉 방지)

다음은 **의도적으로 구현하지 않는다.** 운영 폐쇄망에는 이미 존재하는 전제이며, 이 레포가 책임질 범위가 아니다:

- **seed 레지스트리 자동 기동** (registry:2 등) — 폐쇄망은 이미 컨테이너 레지스트리를 운영한다. 그것을 세우는 것은 플랫폼팀의 Day -1이다.
- **내부 git 서버 자동 기동** (Gitea 등) — 마찬가지로 선재 전제.
- **검증 불가능한 풀 오프라인 번들 테스트** — air-gap 랩 없이는 end-to-end 검증이 불가하므로, 메커니즘(미러/번들 골격)을 보이는 데 집중한다.

이 경계 설정 자체가 "무엇을 만들지 않을지 아는" 판단이다.

## 부트스트랩 레지스트리 역설 (설계 주의)

이 플랫폼은 Harbor(레지스트리)를 *배포*한다. 그러나 Harbor를 배포할 이미지를 당기려면 *이미 레지스트리가 있어야* 한다. 따라서 폐쇄망에는 **플랫폼의 Harbor와는 별개인 부트스트랩 레지스트리**가 선재해야 한다. (원본 프로젝트가 내부 GitLab + 고정 IP Harbor를 별도로 둔 구조가 정확히 이것이다.)

## 결과

- 온라인 데모는 실제로 동작하고(Mode A), 아키텍처는 폐쇄망을 지원하도록 설계되어 있다(Mode B 심 + 본 ADR).
- 실제 폐쇄망 적용 시 위 4개 미구현 범위만 채우면 된다 — 기존 구조 재작업 없음.
