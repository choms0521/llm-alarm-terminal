# P2 → P3 인계 문서

P2 단계 완료 후 P3 (agent-view 대시보드, Pinned First Tab) 진입 시 알아야 할 사항을 정리한다.

## 1. agent-view 현황

P2 에서 agent-view workspace 는 영구 첫 탭으로 sidebar 최상단에 고정되어 있으며, close 가 불가능하다(`Workspace.canClose == false`). 메인 컨텐츠 영역은 placeholder 텍스트 1건을 표시한다.

### 현재 표시되는 placeholder

`Sources/UI/Sidebar/AgentViewPlaceholder.swift`:

```
[icon: person.crop.rectangle.stack]
에이전트 뷰

P3 단계에서 에이전트 대시보드(Pinned First Tab)가 여기에 표시됩니다.
```

### P3 에서 교체할 지점

`Sources/UI/WorkspaceContentView.swift` 의 라우터가 `case .agentView` 분기로 `AgentViewPlaceholder()` 를 렌더링한다. P3 진입 시 본 SwiftUI 뷰를 실제 에이전트 대시보드 컴포넌트로 교체하면 된다(라우터 자체는 수정 불필요).

```swift
switch workspace.kind {
case .agentView:
    AgentViewPlaceholder()    // ← P3 가 이 자리를 실데이터 view 로 교체
case .normal:
    normalContent(workspace)
}
```

## 2. 기 활용된 reserved field

P2 에서는 모두 nil 로 유지되었으나, P3+ 단계의 진입 지점이다.

### Workspace level

| 필드 | 타입 | 활용 단계 |
|---|---|---|
| `pushChannelHints` | `[String: String]?` | P5 (Push Sender) |
| `fetchHintMetadata` | `[String: AnyCodable]?` | P10b (Deep link + fetchHint resolver) |
| `extraFields` | `[String: AnyCodable]?` | P3~P12 (M6 forward-compat catch-all) |

### Pane level

| 필드 | 타입 | 활용 단계 |
|---|---|---|
| `chatRoomId` | `String?` | P6a (Pairing), P9 (chat-room↔pane 1:1 바인딩, master § P9 line 351) |
| `extraFields` | `[String: AnyCodable]?` | P3~P12 (M6 forward-compat) |

P3 가 agent-view 대시보드 데이터를 영속화해야 한다면 `Workspace.extraFields` 의 `agentView.*` 네임스페이스를 사용하거나 별도 ADR amendment 로 신규 reserved field 를 추가한다.

## 3. P2 결정 항목 / 해석 메모

다음 결정 사항은 P3+ 단계에서 변경하지 않는다(변경 시 P2 acceptance 영향).

- **agent-view 정확히 1개 invariant**: `WorkspaceFile.dedupAgentViews()` 가 load 시점에 enforce. P3 가 agent-view 를 복제하거나 다중화하지 않는다.
- **lastClaudeSessionId 보존**: SessionManager 의 `[UUID: String]` 맵에 terminate 시점의 claudeSessionId 가 저장된다. P3 가 직접 활용할 일은 없으나 P4 reconnect 단계에서 lookup.
- **"자동 respawn 안 함" 해석**: 재시작 직후 panes 의 `sessionId` 는 orphan 상태(SessionManager 미보유). UI 의 libghostty surface 가 새 child PTY 를 spawn 하므로 사용자 시각으로는 터미널이 즉시 보이지만, 직전 claude session UUID 컨텍스트를 재이용하지 않는다. P3 가 이 의미를 변경하려면 ralplan 재소집.
- **CHAT_TERMINAL_DEBUG_SURFACE_STATS env**: telemetry 활성 시 1Hz 로 `~/Library/Logs/ClaudeAlarmTerminal/surface-stats.log` 에 기록. master § 4.3 환경 변수 표 등록은 hand-off (L2).

## 4. P2 에서 hand-off 예약된 항목

P2 ralplan 합의 과정에서 P3+ 로 미룬 항목.

| ID | 내용 | hand-off 대상 |
|---|---|---|
| N3 | `paneToLastSessionId` 보조 인덱스 도입 검토 | P3 |
| N4 | `extraFields` 사용 시 migration 코드 추가 | P5 (실제 활용 시점) |
| N5 | `HISTFILE` path sandbox ADR 작성 | P12 (App Sandbox 활성화 시점) |
| L2 | master § 4.3 환경 변수 표에 `CHAT_TERMINAL_DEBUG_SURFACE_STATS`, `CHAT_TERMINAL_WORKSPACE_ROOT`, `CHAT_TERMINAL_MAX_SESSIONS` 등록 | master 다음 ralplan 사이클 |

## 5. 진입 체크리스트 (P3 시작 시)

- [ ] master plan § P3 (agent-view 대시보드) 상세 계획 작성 → ralplan 합의 → `docs/plans/p3/p3-detailed.html` 산출
- [ ] `Sources/UI/Sidebar/AgentViewPlaceholder.swift` 를 실데이터 view 로 교체할 component 명 결정
- [ ] 에이전트 메타데이터(이름, 상태, 알림 등)를 영속화할 schema → `Workspace.extraFields["agentView"]` 또는 별도 `agents.json`
- [ ] agent-view → claude pane 으로의 데이터 흐름 ADR (action 클릭 시 어떤 workspace/pane 으로 이어지는가)

## 6. 참고

- P2 상세 계획서: `docs/plans/p2/p2-detailed.html`
- P2 합의 이력: `docs/plans/p2/p2-history.md`
- P2 수락 기준 walkthrough: `docs/p2-acceptance-log.md`
- ADR-I 적용 내역: `docs/p2/adr-i-application.md`
- PTY env 격리 정책: `docs/p2/env-isolation-policy.md`
- P2 verifier 리포트: `docs/p2/verifier-report.md`
- master 계획: `docs/plans/work-plan-v4.md`
