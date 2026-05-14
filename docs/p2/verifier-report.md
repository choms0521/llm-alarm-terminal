# P2 Verifier 리포트 — 4축 critical 0건

본 리포트는 Day 9 종료 조건 MED7 의 4축 verifier 패스 결과이다. 각 축의 검증 절차와 발견 사항(있는 경우)을 기록한다.

## 결과 요약

| 축 | 검증 대상 | 검증 절차 | Critical | Major | 비고 |
|---|---|---|---|---|---|
| 1. Immutable | Workspace / Pane / Session / WorkspaceFile | grep + Codable 패턴 검토 | **0** | 0 | 모두 `let` + `with(...)` 빌더 |
| 2. Error handling | throw 경로 메시지 한국어 i18n | grep + KoreanErrorCatalog 매핑 | **0** | 0 | 5종 ErrorCode 모두 카탈로그 매핑 |
| 3. Leak / RAII | PTY masterFD / childPID / surface | `FdLeakTests` 20 iter + `SurfaceLifecycleTests` | **0** | 0 | iter 20 후 fd drift ≤ 5, registry baseline 0 복원 |
| 4. Actor isolation | SessionManager 직렬화 | grep `nonisolated` + async invariant | **0** | 0 | nonisolated 0건, 5 mutating method 모두 async |

## 1. Immutable invariant

### 검증 절차

```
grep -rnE '(var) +[A-Z]' Sources/Workspace/Workspace.swift Sources/Workspace/Pane.swift Sources/Session/Session.swift
```

결과: 0건. (`SchemaCodecTests.test_grepInvariant_...` 자동 검증.)

### 발견 사항

- 모든 모델 struct 의 stored property 가 `let`. mutation 은 `with(...)` 빌더로 새 인스턴스 반환.
- `extraFields: [String: AnyCodable]?` 는 reference internal 을 가지나, AnyCodable 의 내부 값이 외부에서 mutate 될 경로가 없다(모든 acquire 는 decoder 가 새로 생성).

## 2. Error handling 한국어 i18n

### 검증 절차

`Sources/UI/Errors/KoreanErrorDialog.swift` 의 `KoreanErrorCatalog`:

- `ErrorCode.allCases` 5종 모두 `messages[i18nKey]` 에 한국어 메시지 보유.
- `code(from:)` 매핑: `ManagerError.maxSessionsReached`, `WorkspaceStoreError.writeFailed`, `BinaryResolveError.claudeNotFound`.
- `ErrorDialogTests` 8건 모두 통과.

### 발견 사항

- `cwd_inaccessible` 의 `{path}` placeholder substitution 정상 동작 (`test_cwdInaccessible_paramSubstitution`).
- `Errors.strings` (Resources/ko.lproj/) 도 동일 5 키 보유 — i18n form-preservation 목적.
- `ManagerError.notFound` / `.spawnFailed` 는 catalog 미매핑(Day 8 spec 외 에러) — KoreanErrorDialog 가 fallback `localizedDescription` 표시.

## 3. Leak / RAII

### 검증 절차

- `FdLeakTests.test_iterations_externalPty_doesNotLeakFds_idleAndActive` — 20회 PTY 반복 spawn/terminate/remove 후 `/dev/fd` drift ≤ 5.
- `SurfaceLifecycleTests.test_20surfaces_createAndReleaseAll_returnsToZero` — registry 20 surface 등록/release 후 activeCount == 0.
- `SessionManager.terminate` polling `WNOHANG` 패턴이 xctest harness 의 SIGCHLD reaper 환경에서도 hang 없이 종료.

### 발견 사항

- `xcrun leaks <pid>` Instruments Allocations 풀 실측은 manual walkthrough 영역 (단위 테스트로 자동 검증 불가). FdLeakTests 가 fd 차원에서 leak indicator 제공.

## 4. Actor isolation invariant

### 검증 절차

```
grep nonisolated Sources/Session/SessionManager.swift
```

결과: 0건.

```
grep -E '(public\s+)?func\s+(create|terminate|get|terminateAll|updateClaudeSessionId)\s*\(' Sources/Session/SessionManager.swift
```

결과: 모든 매칭 라인에 `async` 키워드 포함 (`SessionManagerV2Tests.test_grepInvariant_...` 자동 검증).

### 발견 사항

- `terminateAll(inWorkspace:)` 의 3-Step 패턴이 in-actor extract → out-of-actor kill (withTaskGroup) → in-actor cleanup 로 reentrancy 회피.
- `SessionManagerV2Tests.test_activityScope_releasesAfter_terminateAll_invariant` 가 invariant `activityScope == nil iff sessions.allSatisfy(.exited)` 검증.
- `SessionManagerV2Tests.test_terminateAll_doesNotStall_concurrentCreate_M1` 가 head-of-line stall 회피 검증 (concurrent create elapsed < 1.0s).

## 종합

4축 모두 critical 0건. Day 9 종료 조건 MED7 충족. P2 단계 통과 정의의 verifier 요건 만족.

remaining manual walkthrough (Day 9 후속):
- `xcrun leaks <pid>` 풀 측정 (M5)
- 단축키 / 다이얼로그 UI 시각 검증 (MED6 IME composition)
- 21번째 세션 한국어 다이얼로그 실 표시 캡처

manual 검증은 P3 진입 전 walkthrough 세션에서 일괄 처리한다.
