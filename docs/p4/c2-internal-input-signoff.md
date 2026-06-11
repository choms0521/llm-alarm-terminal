# C2 검증 이연 — `.internal` inactive surface printable 입력 주입 (Day 5 종료조건 #5)

## 대상 종료조건

P4 상세 계획 Day 5 종료조건 #5 / Acceptance A10 일부:

> inactive(비-focus) internal surface에 printable `ghostty_surface_text` 주입 후
> `ghostty_surface_read_text`로 반영 확인: `XCTAssertTrue(viewport.contains(injected))` (C2 런타임 확증)

이 조건은 실 libghostty surface에 텍스트를 주입한 뒤 그 surface의 그리드를 다시 읽어
반영 여부를 확인하는 **런타임 read-back** 검증이다.

## 경험적 발견 — 헤드리스 검증 불가

C2 read-back은 `DaemonTests`(헤드리스 xctest)나 독립 tool로 검증할 수 없다. 근거는 다음과 같다.

| 사실 | 근거 (file:line) |
|---|---|
| surface 생성은 실 NSView 포인터를 요구한다 (`ghostty_surface_config_s.platform.macos.nsview`) | `ghostty.h:449`, `GhosttyTerminalView.swift:118~143` (`cfg.platform.macos.nsview = Unmanaged.passUnretained(self)`) |
| `ghostty_app_new`는 ~80줄 규모의 완성된 runtime config(wakeup/action/clipboard/close_surface 콜백)를 요구한다 | `GhosttyApp.swift:118~190` |
| 그리드 렌더·갱신은 Metal render target과 ghostty 이벤트 루프(wakeup tick)에 의존한다 | `GhosttyTerminalView` (NSView + Metal), `ghostty_app_new` runtime |
| 코드베이스에 헤드리스 surface 생성 전례가 없다 (`GhostBridgeVerifier`는 `ghostty_init`+`config_new/free`까지만) | `Sources/GhostBridgeVerifier/main.swift` |

즉 surface 생성과 `read_text` 그리드 반영은 앱 GUI 컨텍스트(window + NSView + Metal +
이벤트 루프)에 본질적으로 묶여 있어, 테스트 타깃이나 standalone tool에서 재현할 수 없다.
DaemonTests 타깃은 의도적으로 GhosttyKit-free이며(SessionTests와 동일하게 ghostty 파일 제외),
이 경계를 유지한다.

## 입력 경로 자체는 실 구현이며 컴파일 확증됨

read-back만 이연하며, **입력 코드 경로의 구성요소는 mock이 아니라 실 ghostty 호출**이다.

- `Sources/TerminalView/GhosttySurfaceInjector.swift` — `PrintableTextInjecting`를 구현하고
  `ghostty_surface_text(surface, ptr, len)`를 호출한다(IME 커밋 경로 `GhosttyTerminalView.insertText`와 동일 API).
- `InternalSink`(`Sources/Daemon/InputSink.swift`)는 control byte를 걸러내고(C1) printable만
  injector로 전달한다.
- 앱 타깃(`ClaudeAlarmTerminal`) 빌드가 `GhosttySurfaceInjector` 포함 `** BUILD SUCCEEDED **`
  (real errors 0) — 실 ghostty 입력 경로가 컴파일됨을 확증.
- `InternalSink`의 순서 보존·control 미지원 신호는 `SerialInputQueueTests`(Day 4)에서 mock
  injector로 green.

### 미배선 사실 (CRITICAL — sign-off 전제)

**`InternalSink(injector: GhosttySurfaceInjector(surface))`는 P4에서 live 세션에 배선된 적이 없다.**
Sources/ 전역에서 두 타입의 생성 위치는 테스트뿐이며(`grep -rn "InternalSink(\|GhosttySurfaceInjector("
Sources/` => 테스트 외 0건), 데몬의 유일한 세션 배선 헬퍼 `attachExternalSession`은 `ExternalSink`만
부착한다. 또한 데몬(`WSServer`/`SessionDaemon`)은 앱(`ClaudeAlarmTerminal`)이 시작 시 기동하지 않으며,
dev CLI(`--serve-probe`)·테스트 프로세스에서만 기동된다.

따라서 `SerialInputQueue → InternalSink → GhosttySurfaceInjector(live surface)` 경로와 앱-launch
데몬은 **P5에서 배선될 예정**이다. 아래 수동 sign-off 절차는 **그 P5 배선이 존재한 이후에야 수행
가능**하다 — 현 시점에는 주입을 구동할 live 코드가 없으므로 실행할 수 없다.

## 수동 sign-off 절차 (Exit Gate 이연 항목)

**선행조건 (P5)**: 본 절차는 P5에서 (1) 앱 시작 시 데몬 기동과 (2) live tab surface에
`InternalSink(injector: GhosttySurfaceInjector(surface))` 부착이 배선된 이후에 수행한다. 현 P4
상태에서는 구동 코드가 없어 실행 불가하다.

배선 완료 후, 다음 절차로 C2 런타임 반영을 앱에서 수동 확인하고 결과를 기록한다.

1. 앱을 빌드·실행한다: `xcodebuild -scheme ClaudeAlarmTerminal ... build` 후 산출 `.app` 실행.
2. 워크스페이스에 탭 2개를 만든다(탭 A 활성, 탭 B 비활성/비-focus).
3. 데몬 입력 경로(`SessionDaemon` → `InternalSink` → `GhosttySurfaceInjector`)로 **비활성 탭 B의
   surface**에 printable 문자열(예: `injected-가나다`)을 주입한다.
4. 탭 B로 전환하여 주입 문자열이 화면(그리드)에 반영되었는지 육안 확인한다. 또는
   `ghostty_surface_read_text`로 읽어 포함 여부를 확인한다.
5. **관찰 기록**(빈칸을 실제 값으로 채울 것):
   - 주입 문자열: `__________`
   - 탭 B 그리드/`read_text` 관찰 결과: `__________`
   - 판정(반영됨/안 됨): `__________`
   - 검증 일자: `__________`

## 근거 및 선례

- 본 이연은 P3.5 `W-3-1 수동 sign-off` 선례(헤드리스로 검증 불가한 GUI 런타임 항목을 수동
  sign-off로 이연)와 동일한 처리이다. `~/.claude` project memory `project_p3.5_deferred_debt` 참조.
- 모호한 "정상 동작 확인" 표기를 금지하는 plan-documents 규약에 따라, 본 sign-off는 실제 주입
  문자열과 관찰 결과를 명시적으로 기록해야 통과로 인정한다.
