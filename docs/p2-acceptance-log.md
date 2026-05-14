# P2 수락 기준 walkthrough 로그

본 문서는 v4 master plan § P2 의 6건 수락 기준(A1~A6)을 본 단계 종료 시점에 walkthrough 한 결과를 기록한다. 각 항목은 검증 일자, 검증 방법, 통과 여부를 명시한다.

## 결과 요약

| # | 수락 기준 | 검증 일자 | 검증 방법 | 결과 |
|---|---|---|---|---|
| A1 | workspace A→B 전환 시 A 의 PTY 유지 | Day 4, Day 5, Day 7, Day 9 | SurfaceRegistry-backed alive invariant + Day 6 cd 비전파 통합 테스트 | OK |
| A2 | 21번째 세션 한국어 에러 + 기존 20개 영향 없음 | Day 2, Day 8 | `ManagerError.maxSessionsReached` 메시지 일치 + concurrent create test | OK |
| A3 | 첫 탭(agent-view) close 불가 | Day 3, Day 8 | `WorkspaceTabRowState.canClose == false` + `validateMenuItem` Cmd+W 차단 | OK |
| A4 | 앱 재시작 후 workspace 복원 + 세션 사라짐 | Day 1, Day 9 | `RestartPersistenceTests` 한국어 이름 정확 복원 + pane.sessionId orphan 보존 | OK |
| A5 | 3번째 pane split 차단 | Day 4 | `canSplit == false` invariant + `PaneSplitButton.disabled` + menu validator | OK |
| A6 | PTY env/cwd 격리 invariant 4종 | Day 2, Day 6 | `MultiWorkspaceIsolationTests` 5 invariants (Invariant 5 HISTFILE 격리 M3 신규) | OK |

전체 6건 모두 OK. P2 단계 통과 정의 충족.

## 항목별 상세

### A1 — workspace 전환 시 PTY 유지

- 검증 코드: `SurfaceLifecycleTests.test_workspaceSwitch_doesNotDestroySurfaces` — registry 가 surface 의 owner 이므로 workspace 전환으로 SwiftUI 트리가 재구성되어도 동일 인스턴스 보존.
- ADR-I cmux 패턴 적용 검증: `PaneSplitTests.test_grep_adrI_forbiddenPatterns_zeroMatches` (hibernate/pause/releaseSurface/occlusionState/surface.destroy/stopRendering/suspendRender/displayLayer=nil 0건).
- Day 6 의 cd 비전파 통합 테스트가 실 PTY 로 동작 정합성 확인.

### A2 — 21번째 세션 한국어 에러

- `ManagerError.maxSessionsReached(currentMax: 20).description` == "최대 세션 개수에 도달했습니다 (N=20). 기존 세션을 종료하세요." (`ErrorDialogTests.test_managerError_maxSessionsReached_descriptionMatchesSpec`).
- `SessionManagerV2Tests.test_concurrentCreate_enforcesMaxSessions_NPlus1` (maxSessions=3, 4 concurrent → 3 success + 1 reject) — N+1 시도 시 기존 세션 영향 없음 (FdLeakTests 도 cumulative cleanup 검증).
- KoreanErrorDialog wrapper 가 NSAlert 로 surface — UI 표시는 manual walkthrough.

### A3 — agent-view close 불가

- `AgentViewCloseInvariantTests.test_state_agentView_canCloseIsFalse_andNoCloseButtonID` (state 분기 검증) — view 가 close 버튼 자체를 렌더링하지 않음.
- `WorkspaceManagerTests.test_removeWorkspace_refusesAgentView_invariant` — manager 레벨 거부.
- `AppDelegate.validateMenuItem(_:)` 가 Cmd+W 액션을 `workspace.canClose` 기준으로 막음.

### A4 — 재시작 후 복원 + 세션 사라짐

- `RestartPersistenceTests.test_normalRestart_preservesKoreanWorkspaceName_andCwd` — 한국어 이름 "내 작업" + cwd "/tmp/내프로젝트A" 정확 복원.
- `RestartPersistenceTests.test_normalRestart_panesAndSessionIds_persistedAsOrphan` — pane.sessionId 가 영속화는 되되 SessionManager 입장에서는 orphan (Day 1 결정 사항).
- 운영 동작(libghostty surface 가 view 출현 시점에 새 child PTY 를 spawn 한다는 점)은 P2 결정으로 수용: "자동 respawn 안 함" 의 의미를 *claude session UUID 재접속 시도 없음* 으로 해석한다. 재시작 직후 보여지는 터미널은 새로 spawn 된 child 이며 직전 claude session 컨텍스트를 이어받지 않는다. 자세한 사항은 `docs/p2/handoff-to-p3.md` 참고.

### A5 — 3번째 pane split 차단

- `PaneSplitTests.test_canSplit_normalWorkspace_twoPanes_false` — 2 pane 확보 후 canSplit == false.
- `PaneSplitTests.test_addPane_thirdPane_rejected` — manager 가 3번째 추가 거부 (count 변화 없음).
- `AppDelegate.validateMenuItem` 의 Cmd+D 분기가 canSplit 으로 비활성.

### A6 — PTY env/cwd 격리

- `MultiWorkspaceIsolationTests` 5 invariants 모두 통과 (Day 6 통합 테스트 4.97s 실 PTY).
- `Tests/SessionTests/PtyTestHarness.swift` (H7) 가 ANSI strip + readUntilQuiet 로 zsh prompt noise 제거.
- `docs/p2/env-isolation-policy.md` 가 invariant 별 회복 절차 명시.

## 단계 통과 정의

> 위 6건 모두 통과(체크) + Day 1~9 의 모든 일자 종료 조건 통과 + verifier 패스 critical 0건.

verifier 4축 결과는 `docs/p2/verifier-report.md` 참조.
