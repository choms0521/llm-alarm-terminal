# P5.5 Walkthrough — agent-view 세션 공유 실증

본 문서는 P5.5 agent-view 인터랙티브 스플릿의 GUI walkthrough 및 재부모화 스파이크
결과를 기록한다. 재부모화는 코드베이스에 선례 없는 미검증 가정이므로 Day 2 게이트가
단계 성패의 1차 분기다.

---

## Day 2 — 재부모화 스파이크 (게이트)

### 검증 목적

`SurfaceRegistry.acquireExisting(id:)` 이 반환한 NSView 를 워크스페이스 탭 컨테이너에서
agent-view 우측 호스트 컨테이너로 옮길 때, AppKit 이 자동 재부모화하면서 같은 NSView
인스턴스(= 같은 libghostty surface = 같은 PTY/scrollback)를 보존하는지 확인한다.

### 스파이크 방식 — 코드 레벨 실증 (자동화 완료)

`Tests/SessionTests/SurfaceRegistryInvariantTests.swift` 에 재부모화 메커니즘을 NSView
레벨에서 직접 검증하는 스파이크 테스트를 작성하여 자동 실행했다.

핵심은 두 가지 가정이다.

- **가정 1 (SurfaceRegistry 동일 인스턴스):** 같은 id 에 대해 항상 같은 NSView 를 반환.
- **가정 2 (AppKit 재부모화):** NSView 를 다른 superview 의 `addSubview` 로 넣으면 AppKit
  이 이전 superview 에서 자동 제거하고 view 인스턴스를 보존.

`test_reparent_addSubviewMovesViewBetweenContainers` 가 다음 시나리오를 모사·검증한다.

1. 워크스페이스 탭 컨테이너(부모 A)에 surface 를 `acquire` 후 `addSubview`.
2. agent-view 진입을 모사: `acquireExisting` 으로 같은 인스턴스를 가져와 우측 호스트
   컨테이너(부모 B)에 `addSubview`.
3. AppKit 이 부모 A 에서 자동 제거하고 부모 B 로 이동(`superview === B`, A.subviews.count == 0).
4. 워크스페이스 탭 복귀를 모사: 다시 부모 A 로 재부모화 — 여전히 동일 인스턴스.

`test_reparent_doesNotCreateSecondSurface` 는 재부모화 전후로 `registry.activeCount` 가
1 로 불변임을 확인하여 두 번째 surface 가 생성되지 않음(ADR-I)을 보증한다.

### 스파이크 결과 — 성공

```
xcodebuild test -scheme SessionTests -only-testing:SessionTests/SurfaceRegistryInvariantTests
=> Executed 7 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

| 가정 | 검증 테스트 | 결과 |
|---|---|---|
| 1 (a) acquire 후 acquireExisting 동일 인스턴스 | `test_acquireThenAcquireExisting_returnsSameInstance` | PASS |
| 1 (b) acquireExisting 2회 동일 인스턴스 | `test_acquireExisting_twice_returnsSameInstance` | PASS |
| 1 (c) 미등록 id nil | `test_acquireExisting_unregisteredId_returnsNil` | PASS |
| 1 (d) release 후 contains false + acquireExisting nil | `test_release_thenContainsFalse_andAcquireExistingNil` | PASS |
| 1 (보강) acquireExisting 은 등록 미유발 | `test_acquireExisting_doesNotRegister` | PASS |
| 2 (재부모화) addSubview 컨테이너 간 이동 + 동일 인스턴스 보존 | `test_reparent_addSubviewMovesViewBetweenContainers` | PASS |
| 2 (재부모화) 신규 surface 미생성(activeCount 불변) | `test_reparent_doesNotCreateSecondSurface` | PASS |

**판정: 재부모화 메커니즘 성립 (코드 레벨 게이트 통과).** `addSubview` 의 자동 재부모화는
AppKit 의 계약된 동작이며 본 코드베이스의 NSView 에서도 그대로 성립함을 실증했다.
libghostty surface 는 NSView 에 1:1 결속(ADR-I)이므로 동일 NSView 인스턴스가 보존되면
surface(따라서 PTY/scrollback)도 보존된다. fallback(read-only 미러) 전환 불필요.

> **근거 요약:** 재부모화는 추측이 아니라 AppKit `addSubview(_:)` 의 문서화된 동작이다
> (한 view 는 한 번에 하나의 superview 만 가지며, addSubview 시 이전 superview 에서
> 자동 제거). 스파이크는 이 동작이 SurfaceRegistry 가 반환한 인스턴스에 대해 실제로
> 성립함을 코드로 못박았다.

### 사람 육안 확인이 필요한 잔여 항목 (GUI walkthrough)

코드 레벨 게이트는 통과했으나, **라이브 터미널의 scrollback/포커스 보존**은 실제 GUI 에서
육안 확인이 필요하다. 단, agent-view 우측 호스트(`AgentTerminalHostView`)를 실제 화면에
배선하는 것은 Day 3(`AgentSplitView` 조립 + `WorkspaceContentView.agentView` 케이스 교체)
범위다. 따라서 라이브 GUI 시나리오는 Day 3 walkthrough 에서 수행한다.

Day 3 조립 완료 후 다음을 사람이 육안으로 확인해야 한다.

1. **세션 공유(라이브 입력):** agent-view 에서 트리의 한 tab 을 클릭 → 우측에 같은 세션의
   라이브 터미널이 표시됨(신규 셸이 아님). 우측에서 `echo hello` 입력 후, 같은 tab 의
   워크스페이스 탭으로 이동하면 그 입력/출력이 그대로 보임.
2. **scrollback 보존:** 워크스페이스 탭에서 스크롤백을 쌓은 뒤 agent-view 로 전환 → 우측에
   같은 scrollback 이 보임(빈 화면/새 셸 아님).
3. **재부모화(동시 표시 불가):** agent-view 에서 본 tab 이 우측에 mount 된 동안, 같은 tab 의
   워크스페이스 탭으로 전환하면 우측에서 사라지고 워크스페이스 탭 쪽에 나타남. 다시
   agent-view 복귀 시 우측으로 돌아오며 scrollback 유지.
4. **lazy spawn:** 한 번도 열지 않은 tab 을 agent-view 우측에서 처음 클릭 → 신규 셸이
   spawn 되고, 이후 그 tab 은 워크스페이스 탭과 공유됨.
5. **graceful EmptyState:** 우측 mount 중인 tab 의 세션이 종료(`.exited`)되거나 closeTab/
   closeWorkspace 되면 우측이 EmptyState 로 전환됨(크래시/빈 surface 잔존 없음).

> 보조 검증(자동화 가능): `CHAT_TERMINAL_DEBUG_SURFACE_STATS=1` 로 앱 실행 시
> `~/Library/Logs/ClaudeAlarmTerminal/surface-stats.log` 의 `surf=N` 이 agent-view 진입/이탈
> 전후로 동일함을 확인(재부모화는 surface count 를 증가시키지 않음). Day 3 에서 수행.

---

## Day 3 — 조립 완료 + GUI walkthrough

Day 3 에서 `AgentSplitView`(좌측 `AgentTreeView` + 우측 `AgentTerminalHostView`)를
조립하고 `WorkspaceContentView` 의 agent-view 케이스를 closure 주입으로 교체했다.
카드 그리드 UI 자산(`AgentDashboardView`/`AgentCardView`/`AgentSortFilterControls`/
`AgentViewSettings`/`AgentJumpAction`/`AgentDashboardViewModel`)은 옵션 C 대로 폐기했다.

### 자동 검증 결과 (executor 직접 수행)

| 항목 | 절차 | 결과 |
|---|---|---|
| 빌드 무결성(A10) | `xcodegen generate` → `xcodebuild build -scheme ClaudeAlarmTerminal` | exit 0, `** BUILD SUCCEEDED **` |
| 전체 테스트(A7) | SessionTests 181 / WorkspaceTests 83 / DaemonTests 70 | 전부 `** TEST SUCCEEDED **`, 실패 0건 |
| dangling 수렴(A11) | `xcodebuild test -only-testing:SessionTests/AgentSplitSelectionTests` | Executed 6 tests, 0 failures |
| legacy 키 흡수 | `xcodebuild test -only-testing:WorkspaceTests/SchemaCodecTests` (`agentView.settings` 포함 JSON 디코드) | Executed 14 tests, 0 failures (디코드 에러 0건) |
| 폐기 완료(A6) | `grep -rlE "AgentDashboardView\|AgentCardView\|AgentSortFilterControls\|AgentJumpAction" Sources/ Tests/` | 0건 |
| 앱 실행 + surface telemetry | `CHAT_TERMINAL_DEBUG_SURFACE_STATS=1 open -n ClaudeAlarmTerminal.app` 후 surface-stats.log 확인 | 정상 부팅(크래시 없음), `mem=95MB surf=1` 1Hz 기록 확인(ADR-I telemetry live) |

### 사람 육안 확인 필요 항목 (사용자 친람 후 체크)

아래는 라이브 GUI 에서 사람이 직접 클릭하며 확인해야 하는 항목이다. 각 단계는
"무엇을 클릭해 무엇을 확인하는지"를 명시한다. 자동화 불가(libghostty 렌더 + PTY
입출력의 육안 관찰)이므로 체크박스는 비워 두고 친람 후 채운다.

#### 사전 준비

1. 터미널에서 `CHAT_TERMINAL_DEBUG_SURFACE_STATS=1` 환경 변수로 앱을 실행한다.
   (또는 빌드 산출물을 `open -n` 으로 직접 실행)
2. 좌측 사이드바에서 normal workspace 를 하나 이상 만들고, 각 workspace 의 탭에서
   Claude/셸 세션을 한두 개 띄워 둔다(우측에서 공유 확인할 라이브 세션 확보).
3. 사이드바에서 "에이전트 뷰"(person.crop.rectangle 심볼)를 클릭해 agent-view 에 진입한다.

- [ ] **(1) 세션 공유 — 라이브 입력:** agent-view 좌측 트리에서 한 tab 을 클릭한다.
  → 우측 호스트에 그 세션의 라이브 터미널이 뜬다(빈 화면/새 셸이 아님). 우측에서
  `echo hello` 를 입력한 뒤, 사이드바에서 같은 세션의 normal workspace 로 이동한다.
  → 그 workspace 탭에 `echo hello` 입력/출력이 그대로 보인다(같은 PTY 공유 확인).

- [ ] **(2) scrollback 보존:** normal workspace 탭에서 `seq 1 100` 등으로 스크롤백을
  충분히 쌓는다. → 사이드바에서 agent-view 로 전환하고 트리에서 그 tab 을 클릭한다.
  → 우측에 같은 scrollback(1~100)이 보인다(빈 화면/리셋 아님).

- [ ] **(3) 재부모화 — 동시 표시 불가:** agent-view 에서 한 tab 이 우측에 mount 된
  상태에서, 사이드바로 같은 세션의 normal workspace 로 전환한다. → 그 workspace 탭에
  세션이 나타난다(우측 호스트는 agent-view 를 떠났으므로 화면에서 사라짐). 다시
  agent-view 로 복귀해 같은 tab 클릭 → 우측으로 돌아오며 scrollback 이 유지된다.
  보조: `surface-stats.log` 의 `surf=N` 값이 agent-view 진입/이탈 전후로 동일하다
  (재부모화는 surface 개수를 늘리지 않음).

- [ ] **(4) lazy spawn:** 한 번도 연 적 없는 tab(예: 새로 추가했지만 아직 안 연 셸)을
  agent-view 트리에서 처음 클릭한다. → 우측에 신규 셸이 spawn 된다(프롬프트가 새로
  뜸). 이후 사이드바에서 그 tab 의 normal workspace 로 이동하면 같은 셸이 공유된다.

- [ ] **(5) graceful EmptyState:** 우측에 mount 중인 tab 의 세션을 종료한다(`exit`
  입력으로 `.exited`, 또는 사이드바에서 해당 workspace close). → 우측이 EmptyState
  ("좌측 트리에서 세션을 선택하세요")로 전환된다(크래시/빈 surface 잔존/검은 화면
  없음). 트리에서 다른 유효 tab 을 클릭하면 우측이 그 세션으로 정상 복귀한다.

- [ ] **(6) navigation 분기(A8, R8):** 사이드바에서 다른 normal workspace 를 클릭한다.
  → agent-view 좌측 트리에서 그 workspace 노드가 expand 되지만, 우측 호스트의 선택
  세션(selectedTabId)은 바뀌지 않는다(사이드바 클릭 = expand 만). 트리에서 tab 을
  직접 클릭해야 우측이 교체된다.
