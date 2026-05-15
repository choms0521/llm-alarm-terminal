# 데스크톱 앱 개선 요구사항 (P3 시연 후 정리) — v2

- **작성일**: 2026-05-14
- **출처**: P3 단계(에이전트 뷰 대시보드) commit 7865d97 완료 직후 실측 시연 결과
- **목적**: P4(WebSocket 채널) / P5(Push) 진입을 보류하고, 데스크톱 앱 자체의 동작과 컨셉을 재정렬한 뒤 진군하기 위한 요구사항 정착
- **상태**: v2 (결정자 확인 완료). ralplan 합의로 정식 **P3.5 phase**로 진화 예정

본 문서는 P3.5 detailed plan(`docs/plans/p3.5/p3.5-detailed.html`) 작성을 위한 입력이며, P3.5 APPROVE 후에는 본 사양서가 reference로만 유지된다.

---

## 1. P3 시연에서 드러난 기존 결함 (이미 R-1 패치로 토벌됨)

| ID | 결함 | 패치 위치 | 출처 |
|---|---|---|---|
| D-1 | Backspace / Enter / Tab / Arrow 등 special key가 `ghostty_surface_text`로 잘못 전달되어 cursor가 advance만 됨. PTY로 정상 control byte가 가지 않음 | `Sources/TerminalView/GhosttyTerminalView.swift:229-353` (`keyAction`, `ghosttyCharacters` 신설, `keyDown` 라우팅을 `ghostty_surface_key`로 교체) | P1 Day 5b부터 누적 |
| D-2 | 한글 IME 자모 분리("ㅇㄴㄹㅇㄴ"). `insertText`가 keyDown 컨텍스트 안에서도 직접 `ghostty_surface_text`를 호출하여 commit 텍스트가 이중 전달 | `Sources/TerminalView/GhosttyTerminalView.swift:546-581` (keyDown 안에서는 accumulator만 채우고 keyAction 경로로 통일) | P1 Day 6 |
| D-3 | `NavigationSplitView(.balanced)`가 사이드바를 좁은 윈도우에서 hidden/collapsed로 렌더 | `Sources/UI/RootView.swift:30-53` (`HSplitView`로 교체, sidebar minWidth 200/idealWidth 240/maxWidth 360) | P2 Day 3 |
| D-4 | bootstrap이 `lastActiveWorkspaceId` 무효 시 normal workspace 먼저 선택. 영구 첫 탭(agent-view) invariant가 visual에서 깨짐 | `Sources/Workspace/WorkspaceManager.swift:55-66` (agent-view → normal → first 순으로 fallback) | P3 Day 5 |

R-1 패치 후 빌드 통과. 결정자 시연 결과는 본 문서 작성 시점 미회신 (R-2 wave 진입 시 동시 검증 예정).

---

## 2. 결정자가 새로 하명한 수정사항

### 2.1 REQ-1. Pane 분할 방향 변경: 상하 → 좌우

현재 P2 산출물은 한 워크스페이스 안에서 pane을 `position: .top` / `.bottom`으로 위아래 분할한다. 결정자 의도는 **좌우 분할(좌 | 우)**이다.

영향:
- `Sources/Workspace/Pane.swift::PanePosition`: `.top` / `.bottom` → `.left` / `.right`
- 분할 layout: `VStack` → `HStack`
- 영속 schema migration: 기존 workspaces.json의 `"top"` → `"left"`, `"bottom"` → `"right"` 1:1 매핑
- 단축키 "Pane 분할" 텍스트는 그대로 유지

레퍼런스(결정자 첨부): IDE처럼 좌측 코드 / 우측 터미널 형태의 좌우 분할.

### 2.2 REQ-2. 각 pane이 멀티탭을 가짐 — **Q-X(a) 확정**

**위치 결정**: 한 **pane 안**에 탭바 (pane이 멀티탭 컨테이너). Ghostty / iTerm2 표준 형태.

기능:
- pane 상단에 탭바 표시 (macOS 표준 탭 UI)
- 탭별 독립 session (PTY + claude/shell 선택)
- 탭 추가 버튼(+)
- 탭별 close 버튼 (REQ-4 참조)
- 탭 전환 단축키: `Cmd+Shift+]` / `Cmd+Shift+[`

영향:
- 새 모델: `Tab { id, sessionId, kind: .claude | .shell, name, createdAt, extraFields }`
- `Pane`: `sessionId: UUID?` 제거 → `tabs: [Tab]` + `activeTabId: UUID?`
- 영속 schema 마이그레이션 필수 (v1 → v2)
- `WorkspaceManager` API: `addTab(workspaceId:paneId:kind:)`, `closeTab(workspaceId:paneId:tabId:)`, `selectTab(workspaceId:paneId:tabId:)`
- `SurfaceRegistry`: pane 단위 → tab 단위로 surface 보유

### 2.3 REQ-3. Claude 매번 재로그인 → CLAUDE_CONFIG_DIR 격리 폐지

**근본 원인 (Anthropic 공식 agent-view 문서 § "상태가 저장되는 위치"에서 확인)**:
> `CLAUDE_CONFIG_DIR`을 설정하면 감독자는 `~/.claude` 대신 해당 디렉토리를 사용하고 자체 세션이 있는 별도의 인스턴스로 실행됩니다.

본 프로젝트의 `SessionSpawnEnv.cleanupStaleClaudeConfigDirs(liveSessionIds:)` 호출이 세션마다 별도 `CLAUDE_CONFIG_DIR`을 격리 생성하고 있다는 결정적 증거다. 이로 인해 사용자의 `~/.claude/credentials` 등이 우회되어 매번 재로그인이 발생.

**결정**: 격리 폐지. 사용자 `~/.claude` 공유.

영향:
- `SessionSpawnEnv` 내 `CLAUDE_CONFIG_DIR` 강제 설정 제거
- `cleanupStaleClaudeConfigDirs` 호출 제거 또는 사용자 명시 opt-in 시에만 동작
- `SessionSpawnEnv.captureUserEnv()` 가 사용자 환경의 `CLAUDE_CONFIG_DIR`을 그대로 propagate (또는 설정하지 않아 default `~/.claude` 사용)
- 사용자 권한 위임: 본 앱이 `~/.claude` 디렉토리에 접근 가능해야 함 (sandboxing 검토 필요)

### 2.4 REQ-4. 탭 close + pane/workspace 자동 정리 — **Q-Y(a) 확정**

- 각 탭에 close 버튼 (macOS 표준 탭 좌측 ×)
- 탭 닫기 단축키: `Cmd+W` (활성 탭 close). 현재 `Cmd+W` = workspace close 매핑은 `Cmd+Shift+W`로 이전
- **마지막 탭 close → pane 자동 사라짐**
- **마지막 pane 사라짐 → workspace 자동 close**
- agent-view는 pane/tab 구조를 가지지 않으므로 본 정책에서 제외 (invariant: agent-view는 영구)

영향:
- `WorkspaceManager.closeTab(...)` 후 `pane.tabs.isEmpty` 검사 → `removePane` 자동 호출
- `removePane` 후 `workspace.panes.isEmpty` 검사 → `removeWorkspace` 자동 호출 (agent-view는 `canClose == false`이므로 자연 보호)
- 단축키 충돌: 현 `Cmd+W` workspace close → `Cmd+Shift+W`로 재매핑

### 2.5 REQ-5. agent-view 컨셉 완전 재설계 — **확정**

**P3 카드 그리드 (`AgentDashboardView`)는 컨셉 자체가 어긋났음.** Anthropic 공식 `claude agents` TUI의 패러다임을 SwiftUI 카드로 옮긴 것이지만, 결정자 원래 의도는 **TUI 영감을 받은 자체 2-pane 통합 콘솔**이었다.

**새 컨셉 (확정)**:
- agent-view는 사이드바 최상단 영구 고정 탭 (기존 invariant 유지)
- agent-view 진입 시 **컨텐츠 영역 = 2-pane horizontal split**:
  - **좌측 (SwiftUI)**: workspace - pane - tab **3단 계층 트리** (`OutlineGroup`). 각 노드에 status 아이콘 + 이름 + 한 줄 요약
  - **우측 (libghostty)**: 좌측에서 선택된 tab의 PTY 터미널 surface (`GhosttyTerminalView`)
- 기본 선택: 트리의 가장 위 첫 세션 자동 선택 (placeholder 없음)
- 풀스크린 모드: 불필요 (보류)

**보존 자산 (P3 인프라 중)**:
- `SessionStatusObserver` + `NeedsInputPolicyV1` + `SessionStatusCoordinator` — 좌측 트리 행의 status 아이콘/색상에 그대로 활용
- `AnsiSGRParser` + `ShellPreviewExtractor` + `Utf8BoundaryTruncator` — 좌측 트리 행의 한 줄 요약에 활용
- `FocusedPaneStore` — 선택된 tab의 surface focus 동기화
- `ViewportPollingTimer` + `GhosttyViewportProvider` — 모든 surface의 viewport 폴링

**폐기 대상 (P3 산출물 중)**:
- `AgentDashboardView` / `AgentCardView` — 카드 그리드 UI
- `AgentSortFilterControls` / `AgentViewSettings` (sort/filter 영속화) — agent-view 트리는 정렬보다 계층 표시가 우선
- `AgentJumpAction` — 트리 클릭이 곧 선택이므로 jump action 불필요

### 2.6 화면 구조 다이어그램 (확정안)

**agent-view 선택 시 (3-pane horizontal split)**:

```
+-------------+-----------------+----------------------------+
| 사이드바     |  좌측 트리       |  우측 선택 세션 터미널      |
| 240px        |   280px            |  남은 폭                     |
|             |                 |                            |
| ★ 에이전트뷰  | ▼ ws alpha       | $ npm test                 |
| ▢ ws alpha   |   ▼ pane 1       | PASS  src/foo.test.ts      |
| ▢ ws beta    |     • tab 1 ∙    | PASS  src/bar.test.ts      |
| ▢ ws gamma   |     • tab 2 ✻    |                            |
| ...          |   ▼ pane 2       | Tests: 12 passed          |
|             |     • tab 1 !    |                            |
| [+ 새 작업]  | ▼ ws beta        | ~/dev/alpha  zsh           |
|             |   ▶ pane 1       |                            |
+-------------+-----------------+----------------------------+
```

**normal workspace 선택 시 (2-pane horizontal split, REQ-1 + REQ-2)**:

```
+-------------+--------------------------------------------+
| 사이드바     |  workspace 의 pane들 (좌우 분할)             |
|             |   ┌──────────────┬──────────────┐          |
| ★ 에이전트뷰  |   │ [탭바: t1|t2]│ [탭바: t1]   │          |
| ★ ws alpha   |   │              │              │          |
| ▢ ws beta    |   │  surface     │  surface     │          |
|             |   │              │              │          |
|             |   └──────────────┴──────────────┘          |
+-------------+--------------------------------------------+
```

상태 아이콘 매핑 (Anthropic agent-view에서 영감):
- `∙` 회색/흐릿 = 유휴
- `✻` 애니메이션 = 작업 중
- `!` 노란색 = 입력 필요 (claude needsInput)
- `✓` 녹색 = 완료
- `✗` 빨간색 = 실패/exited

---

## 3. 우선순위 (확정)

| 순위 | 항목 | 작업 규모 | 비고 |
|---|---|---|---|
| **P0** | REQ-3 `CLAUDE_CONFIG_DIR` 격리 폐지 | S (반나절) | 일상 사용 불가의 직접 원인 |
| **P0** | REQ-1 + REQ-2 + REQ-4 schema 재설계 (pane 좌우, Tab 모델 신설, close 자동 정리) | M (2~3일) | schema migration 한 번에 묶어 처리 |
| **P0** | REQ-5 agent-view 재설계 (2-pane split + 좌측 트리 + 우측 surface) | M (2~3일) | P3 보존/폐기 매핑 따라 수행 |
| **P1** | manual UX walkthrough 정착 (검증 부실 재발 방지) | S (반나절) | master plan v5 진화 시 박을 조항 |
| **P1** | R-1 패치 시연 결과 회신 받아 회귀 확인 | S | 결정자 직접 확인 |
| **P2** | H-1 keyboard navigation (← → 트리 네비 + Enter attach) | S | P3 hand-off에서 이월 |
| **P2** | H-4 leaks 실측 + H-5 TSan 30분 manual verifier | M | P3 hand-off에서 이월 |

총 추정: **5~8일** (P3.5 정식 phase로 운영).

---

## 4. 미해결 점 (P3.5 detailed plan 작성 시 결정)

다음은 ralplan planner가 detailed plan 작성하면서 결정자에게 추가 청취할 항목:

- (Q-α) Tab 모델의 영속 schema v1 → v2 migration 방식: backward-compat 유지(기존 v1 파일 자동 변환) vs hard cut(빈 상태로 시작)
- (Q-β) 좌측 트리의 정렬: 가장 최근 활동순 vs workspace 추가순 vs 사용자 드래그 순
- (Q-γ) 우측 surface가 좌측 트리에서 선택 변경될 때 즉시 교체 vs 페이드 transition
- (Q-δ) Pane 좌우 분할 시 한 workspace당 pane 최대 개수 (현 2개 유지 vs 3개+ 허용)
- (Q-ε) "+ 새 탭" 시 default kind (shell vs claude vs 사용자 sheet)

---

## 5. 작업 형태 (확정)

- **Q-Z(a) ralplan 합의로 정식 P3.5 phase 신설** 확정
- 산출물: `docs/plans/p3.5/p3.5-detailed.html` + `docs/plans/p3.5/p3.5-history.md` (CLAUDE.md 규약)
- master plan v5 진화: P3.5 row 신설 + "manual UX walkthrough 의무화" lessons learned 박기 (P-2)
- Day-by-Day 자율 진행 + Day별 commit (P2/P3 패턴 계승)

---

## 6. 참고

- 마스터 plan: `docs/plans/work-plan-v4.md`
- P3 상세: `docs/plans/p3/p3-detailed.html`
- P3 합의 이력: `docs/plans/p3/p3-history.md`
- P3 → P4 인계: `docs/p3/handoff-to-p4.md`
- ADR-E (에이전트 뷰 렌더링): `docs/adr/E-agent-view-rendering.md`
- Anthropic 공식 agent-view 문서: https://code.claude.com/docs/ko/agent-view
- TUI 영감 블로그: https://www.elancer.co.kr/blog/detail/1092
- R-1 회복 패치 대상 파일:
  - `Sources/TerminalView/GhosttyTerminalView.swift`
  - `Sources/UI/RootView.swift`
  - `Sources/Workspace/WorkspaceManager.swift`
  - `Sources/ClaudeAlarmTerminal/AppDelegate.swift`
  - `Sources/ClaudeAlarmTerminal/main.swift`
