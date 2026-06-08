# ADR-0002: ApplicationSet vs 개별 Application 파일

## 상태

채택됨

## 날짜

2026-06-08

## 맥락

`platform-infra`는 App of Apps 패턴을 사용한다. 자식 Application을 관리하는 방식으로 두 가지 선택지가 있다.

**Option A: 개별 Application YAML 파일** (`apps/*.yaml` 마다 1개 파일)

```
apps/
├── platform-db-postgres.yaml
├── platform-db-redis.yaml
├── platform-iam-keycloak.yaml
...
```

- 각 Application을 독립적으로 읽고 편집할 수 있다
- 파일 수 = 컴포넌트 수 → 새 컴포넌트 추가 시 파일 추가 필요
- repoURL, syncPolicy 등 공통 필드가 모든 파일에 반복된다
- 공통 필드(예: repoURL)를 변경할 때 모든 파일을 수정해야 한다

**Option B: ApplicationSet (List Generator)**

```
apps/
└── platform-appset.yaml   (전체 관리)
```

- repoURL, syncPolicy 등 공통 필드를 한 곳에서 관리
- 새 컴포넌트 = generators.list.elements에 1개 항목 추가
- Git 레포 URL 변경 시 한 파일만 수정
- goTemplate으로 git manifest app / Helm app을 분기 처리 가능
- 파일을 열면 전체 배포 구성을 한눈에 볼 수 있다

## 결정

ApplicationSet(List Generator)을 채택한다. `apps/platform-appset.yaml` 파일 하나가 12개 컴포넌트를 관리한다.

주요 이유:

1. **repoURL 단일 관리**: 이 레포는 포트폴리오 레포로 GitHub URL을 사용한다. URL 변경 시 한 곳만 수정하면 된다.
2. **컴포넌트 추가 용이성**: 새 인프라 컴포넌트를 추가할 때 element 1줄 추가와 values 파일만 작성하면 된다.
3. **전체 배포 구성 가시성**: 한 파일에서 sync wave, 차트 버전, values 경로를 모두 볼 수 있다.

## Harbor 분리 이유

Harbor만 `apps/platform-registry-harbor.yaml`로 별도 분리했다.

Harbor chart는 `StatefulSet.spec.volumeClaimTemplates` 등 ArgoCD가 조정할 수 없는 불변 필드를 동적으로 변경한다. 이를 처리하려면 `Application.spec.ignoreDifferences`가 필요하다.

ApplicationSet template에서 `ignoreDifferences`를 조건부로 렌더링하려면 goTemplate의 복잡한 중첩 구조가 필요하다. 이는 가독성을 크게 떨어뜨리고, 유지보수 부담을 높인다.

Harbor 1개 예외를 위해 전체 template을 복잡하게 만들기보다 Harbor만 독립 파일로 분리하는 것이 더 명확하다. 이 결정은 "단순함을 위한 의도적 예외"이며 패턴 위반이 아니다.

향후 ApplicationSet이 `ignoreDifferences`를 element 단위로 완전히 지원하면 재통합을 검토한다.

## 결과

- `apps/platform-appset.yaml`: 12개 컴포넌트 (Harbor 제외)
- `apps/platform-registry-harbor.yaml`: Harbor 전용 Application (ignoreDifferences 포함)
- `apps/appproject-platform-infra.yaml`: AppProject (ArgoCD 리소스이므로 ApplicationSet과 별도)
