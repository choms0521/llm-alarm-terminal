# P3 → P4 인계 문서

P3 단계 완료 후 P4 (WebSocket 채널 / claude session 자체의 영속화·resume) 진입 시 알아야 할 사항을 정리한다.

## 1. agent-view 현황

P3에서 agent-view workspace는 영구 첫 탭 + 영구 close 불가능 (`Workspace.canClose == false`) invariant를 보존한다. 메인 컨텐츠 영역은 `AgentDashboardView` (LazyVGrid 카드 그리드)가 표시한다.

### 카드 데이터 흐름

```
GhosttyApp.action_cb (libghostty 임의 thread)
  → DispatchQueue.main.async (main thread hop)
  → SessionActionRouter.dispatch
  → SessionStatusObserver.observe(action:)
  → publishers (preview / needsInput / status)
  → SessionStatusCoordinator (throttle 100ms / fast-lane / removeDuplicates)
  → @Published snapshots dict
  → AgentDashboardView LazyVGrid 카드
```

병렬 trail (viewport polling):
```
ViewportPollingTimer (250ms tick, focused 4Hz / background 1Hz)
  → AgentViewSurfaceProvider.readViewportText (production: GhosttyViewportProvider)
  → ghostty_surface_read_text + defer ghostty_surface_free_text (1:1)
  → SessionStatusObserver.observe(viewportText:)
```

## 2. 기 활용된 reserved field

P2에서 모두 nil로 유지되던 reserved field 중 P3가 활용한 것:

| 필드 | 타입 | P3 사용 |
|---|---|---|
| `Workspace.extraFields` | `[String: AnyCodable]?` | agent-view workspace의 `"agentView.settings"` 키에 `AgentViewSettings` JSON 영속화 |

다음은 여전히 P4+ 단계의 진입 지점이다:

| 필드 | 타입 | 활용 단계 |
|---|---|---|
| `Workspace.pushChannelHints` | `[String: String]?` | P5 (Push Sender) |
| `Workspace.fetchHintMetadata` | `[String: AnyCodable]?` | P10b (Deep link) |
| `Pane.chatRoomId` | `String?` | P6a (Pairing), P9 (chat-room↔pane 바인딩) |
| `Pane.extraFields` | `[String: AnyCodable]?` | P3~P12 forward-compat |

## 3. P3 결정 항목 / 해석 메모

다음 결정 사항은 P4+ 단계에서 변경하지 않는다 (변경 시 P3 acceptance 영향).

- **lifecycle vs agent-status 도메인 분리**: `Session.status` (running/exited)는 P1/P2 lifecycle invariant 보존. agent-view용 동적 상태(idle/working/needsInput/exited)는 별도 `SessionStatusSnapshot` 도메인. SessionStatusCoordinator는 SessionLifecycleHooks의 단일 방향 소비자이며 lifecycle hook으로 agent-status를 push하지 않는다 (단방향 invariant).
- **needsInput false positive 절대 금지**: `NeedsInputPolicyV1` (version `"v1-2026-05"`)이 viewport text의 마지막 80 utf8 바이트 안에서만 매칭. SGR reset prefix `"\u{1b}[0m❯ "` / `"\u{1b}[39m❯ "`만 인정 (bare `❯`는 FP 차단). V2 정책 도입 시 V1 namespace 보존하여 regression 비교.
- **action_cb main thread hop 의무**: libghostty action_cb는 read/write/render thread 중 임의 thread에서 동기 invoke되므로 callback 진입 즉시 `ActionPayload` (Sendable struct)로 copy 후 `DispatchQueue.main.async { SessionActionRouter.shared?.dispatch(...) }`. 포인터 보유 금지.
- **alloc/free 1:1 강제**: `ghostty_surface_read_text` 호출은 반드시 `defer { ghostty_surface_free_text(...) }`. 실제 호출은 `GhosttyViewportProvider.swift` 한 곳에 격리. verifier 4축 leak/RAII 축의 grep target.
- **agent-view extraFields["agentView.*"]** 네임스페이스: sort/filter 설정은 `"agentView.settings"` 키에 JSON 인코딩. master § 4 reserved namespace 정합.

## 4. Plan deviation (P3 detailed plan 대비 변경 사항)

ralplan APPROVE 통과 후 implementation 단계에서 도입된 surgical deviation 2건. 둘 다 testability 또는 정합성을 위한 합리적 조정이며 plan의 본질을 변경하지 않는다.

### D-1. ViewportPollingTimer protocol injection

**원안 (plan § Day 4)**: `Sources/UI/AgentView/ViewportPollingTimer.swift`가 GhosttyKit `ghostty_surface_read_text`/`free_text`를 직접 호출. 종료 조건 §10/§11 grep target도 동일 파일.

**변경**: ViewportPollingTimer는 `AgentViewSurfaceProvider` 프로토콜에 viewport 읽기를 위임하고, 실제 GhosttyKit 호출은 신설된 `GhosttyViewportProvider.swift`가 담당. 종료 조건 §10/§11 grep target이 `GhosttyViewportProvider.swift`로 이동.

**근거**: SessionTests target이 GhosttyKit framework 의존 없이 ViewportPollingTimer의 동적 빈도/focused 전환/app 백그라운드 강등 단위 테스트를 실행할 수 있다. alloc/free 1:1 invariant는 별도 파일에서도 동일하게 grep 검증.

### D-2. FocusedPaneStore Day 4 선행 작성

**원안 (plan § Day 5)**: FocusedPaneStore는 Day 5 산출물.

**변경**: Day 4 ViewportPollingTimer가 focused 판정에 의존하므로 Day 4 commit에 포함하여 미리 작성. Day 5에서 별도 산출물 추가는 없음.

## 5. P3에서 hand-off 예약된 항목

P3 implementation 단계에서 P4+로 미룬 항목.

| ID | 내용 | hand-off 대상 |
|---|---|---|
| H-1 | keyboard navigation (Day 6 종료 조건 §4, §5: right arrow → next card focus, Return → AgentJumpAction.jump) | P4 또는 P9 (UI polish wave) |
| H-2 | master § 4.3 환경 변수 표 등록: `CHAT_TERMINAL_AGENT_POLL_INTERVAL_MS`, `CHAT_TERMINAL_AGENT_PREVIEW_THROTTLE_MS`, `CHAT_TERMINAL_AGENT_PREVIEW_MAX_GRAPHEMES`, `CHAT_TERMINAL_AGENT_DEBUG_LOG`, `CHAT_TERMINAL_AGENT_TELEMETRY_LOG` | master 다음 ralplan 사이클 |
| H-3 | master § 4 reserved namespace에 `"agentView.settings"` 추가 (P3 deviation 5일 unblock 정책) | master 다음 ralplan 사이클 |
| H-4 | xcrun leaks 20 surface × 30분 idle 실측 (Day 4 종료 조건 §13) | P4 wave-2 manual verifier |
| H-5 | TSan 30분 SessionActionRouter.dispatch 알람 0건 (deliberate mode test 영역) | P4 wave-2 manual verifier |

## 6. 진입 체크리스트 (P4 시작 시)

- [ ] master plan § P4 (WebSocket 채널) 상세 계획 작성 → ralplan 합의 → `docs/plans/p4/p4-detailed.html`
- [ ] `lastClaudeSessionId` 보존(SessionManager) 활용한 claude session resume 설계
- [ ] H-2, H-3 master PR 작성 (P3 deviation unblock 정책 5일 안에)
- [ ] H-4, H-5 manual verifier 실행

## 7. 참고

- P3 상세 계획서: `docs/plans/p3/p3-detailed.html`
- P3 합의 이력: `docs/plans/p3/p3-history.md`
- ADR-E 운영화: `docs/adr/E-agent-view-rendering.md`
- P2 → P3 인계: `docs/p2/handoff-to-p3.md`
- master 계획: `docs/plans/work-plan-v4.md`
