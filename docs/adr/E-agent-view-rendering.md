# ADR-E: agent-view 렌더링 정책

## Status

Accepted — P3 Day 6 (2026-05-14)

## Context

P3 단계에서 agent-view 대시보드는 모든 활성 세션의 카드 그리드를 표시하고, 카드 클릭 시 해당 workspace/pane으로 점프한다. 이 과정에서 다음 4가지 렌더링/메모리/정책 영역의 의사결정이 필요하다.

1. SwiftUI `AttributedString`을 만드는 ANSI SGR 파서의 지원 범위
2. libghostty `ghostty_surface_read_text` 호출 시 메모리 안전 패턴
3. claude 세션의 `needsInput` 감지 정책 버전 관리 전략
4. shell pane의 preview 추출 시 OSC 133 영역 우선순위

본 ADR은 위 4 절에 대한 결정을 기록한다.

## Decision

### (가) SGR 부분집합

agent-view 카드의 `latestPreview`는 `AnsiSGRParser.parse(_:)`이 SwiftUI `AttributedString`으로 변환한다. 지원 코드는 다음 부분집합으로 한정한다.

- `0` (reset), `1` (bold), `22` (no bold)
- `30~37`, `90~97` (foreground basic + bright)
- `40~47`, `100~107` (background basic + bright)
- `38;5;N`, `48;5;N` (256-color palette)
- `38;2;R;G;B`, `48;2;R;G;B` (truecolor)
- `39`, `49` (default fg / bg reset)

미지원 코드(5 blink, 7 reverse, 9 strikethrough 등)는 silently drop한다. raw ESC 바이트는 결과 `AttributedString`에 유출되지 않는다. CR 처리는 `"\r\n"` → `"\n"` 정규화, 단독 `"\r"`은 현재 줄의 출력된 부분 drop.

### (나) read_text와 free_text 1:1 패턴

`ghostty_surface_read_text` 호출은 반드시 `defer { ghostty_surface_free_text(...) }` 와 1:1로 짝지어진다. 이 패턴은 `GhosttyViewportProvider.swift`에 격리되어 있으며 verifier 4축 leak/RAII 축의 grep target이다 (`grep -rc 'ghostty_surface_read_text' Sources/` == `grep -rc 'ghostty_surface_free_text' Sources/`). `ViewportPollingTimer`는 surface text 읽기를 `AgentViewSurfaceProvider` 프로토콜에 위임하므로 단위 테스트가 mock provider로 빈도/focused/app 백그라운드 시나리오를 검증할 수 있다.

### (다) NeedsInput Policy versioning

claude 세션의 입력 대기 감지는 `NeedsInputPolicy` 프로토콜의 versioned 구현으로 운영한다. 현재 버전은 `NeedsInputPolicyV1` (version 식별자 `"v1-2026-05"`)이다. 정책은 viewport text의 마지막 80 utf8 바이트 안에서만 매칭하며, false positive (입력 대기가 아닌데 needsInput 표시)는 금지하고 false negative (입력 대기인데 idle 표시)는 다음 polling tick에서 회수되는 수준으로 허용한다.

V1 매칭 조건:
- white-list 패턴: `"Do you want to apply this change?"`, `"Do you want to proceed?"`, `"Press Enter to continue"`, `"[y/n]"`
- claude REPL prompt marker: `"\u{1b}[0m❯ "`, `"\u{1b}[39m❯ "` (SGR reset prefix 의무 — bare `❯`는 cat 출력 등에서도 등장하므로 FP 차단)

`NeedsInputTelemetry`가 월 trigger 카운터를 보관한다. 월 카운트가 한 번이라도 1 미만이면 v2 정책 bump 후보 (claude CLI 카피 변경 의심) 시그널이다. V2 도입 시 V1은 namespace 보존하여 regression 비교 + telemetry 카운터 추적을 유지한다.

### (라) OSC 133 우선 영역 정책

shell pane의 preview는 `ShellPreviewExtractor.extract(_:)`이 추출한다. 우선순위:

1. **Tier 1 — OSC 133 영역 분석**: viewport text에 `\u{1b}]133;B...\u{1b}\\` 마커가 발견되면 그 뒤부터 `\u{1b}]133;D` (또는 끝)까지가 command 출력 영역으로 식별된다. 이 영역의 마지막 non-prompt line을 preview로 반환한다.
2. **Tier 2 — 전체 텍스트 휴리스틱**: OSC 133 미발견 시 전체 viewport에서 ANSI 시퀀스를 strip 후 마지막 line을 검사한다. line 말미가 prompt marker(`"% "`, `"$ "`, `"❯ "`, `"# "`)로만 끝나면 그 line은 prompt-only로 분류되어 제외되고, 직전 non-empty line이 preview로 반환된다.

RPROMPT 처리: CSI cursor 이동 시퀀스(`...C/A/B/D/H/F/G`)를 만나면 그 line의 잔여는 right margin 영역으로 간주하여 drop. raw `"\r"` 단독은 현재 line의 출력된 부분 drop.

## Drivers

1. **D1 — P1/P2 backward compat 부담 최소화.** P1/P2 verifier 4축 critical 0건 통과 상태를 유지. `Session.status` enum case 변경 시 SessionManager + 7개 테스트가 동시 마이그레이션되어야 하므로 agent-status는 별도 `SessionStatusSnapshot` 도메인에서 다룬다.
2. **D2 — 테스트 가능성.** PTY 없는 환경에서 status/preview 파생 로직 검증. PTY-bound 컴포넌트(GhosttyKit 직접 호출)와 derivation 컴포넌트(파서/policy)를 분리한다.
3. **D3 — 사용자 visible behavior 정확성.** A1~A6 acceptance가 한국어/CR/RPROMPT/needsInput 모두 통과. needsInput strong signal은 throttle bypass로 즉시 전파, preview는 throttle 100ms.

## Alternatives considered

### (가)에 대해

- **풀 ANSI SGR 지원** (5 blink, 7 reverse, 8 conceal, 9 strikethrough 등): 카드 preview는 3 line 이하로 표시되므로 점멸/역상은 UI 의미가 적다. 미지원 silently drop이 충분.
- **외부 라이브러리 도입** (vapor/ANSITerminal 등): SwiftPM 의존 1건 추가 비용 vs 부분집합 자체 구현(~250 lines). 자체 구현 선택.

### (나)에 대해

- **`ViewportPollingTimer.swift`에 GhosttyKit 직접 호출**: 단위 테스트 시 GhosttyKit linkage 필요. 종료 조건 grep target만 유지하는 의미가 약함.
- **결정: protocol injection**. `AgentViewSurfaceProvider`를 ViewportPollingTimer가 보유하고, 실제 GhosttyKit alloc/free는 `GhosttyViewportProvider.swift`가 담당. grep target은 `GhosttyViewportProvider.swift`로 이동 (handoff에 명시).

### (다)에 대해

- **단일 정책 인스턴스**: V2 도입 시 V1 비교 불가능. 정책 변경 회귀 추적 어려움.
- **결정: versioned protocol**. V1 namespace 보존 + monthly telemetry로 bump 후보 시그널 자동 감지.

### (라)에 대해

- **OSC 133 강제**: 사용자 shell이 prompt marker를 emit하지 않으면 preview가 비어버림. 보수적이지 않음.
- **결정: 2-tier (OSC 133 우선, 전체 텍스트 휴리스틱 보조)**. 사용자 환경의 차이를 흡수.

## Consequences

### 긍정적

- `SessionStatusSnapshot`이 별도 도메인이므로 P1/P2 SessionStatus 모델 diff 0줄.
- read_text/free_text 1:1 패턴이 verifier 4축 leak 축의 grep target으로 자동 검증.
- NeedsInputPolicy의 versioning으로 V2 도입 시 회귀 비교 가능.
- OSC 133 미사용 환경(기본 zsh, bash without prompt marking)에서도 카드가 빈 preview 없이 동작.

### 부정적 / 위험

- SGR 부분집합 결정으로 인해 점멸/역상 출력은 그대로 표시되지 않는다. claude CLI 출력이 5 blink를 critical 마커로 사용하기 시작하면 V2 부분집합 재검토 필요.
- protocol injection으로 ViewportPollingTimer.swift 자체에는 ghostty_surface_free_text 키워드가 docstring으로만 등장한다. 종료 조건 grep target이 GhosttyViewportProvider.swift로 이동했음을 P4에 명시한다.
- NeedsInputPolicyV1의 80-byte window가 너무 좁아 multi-line prompt가 절단되는 경우가 발견되면 V2에서 window 확장 검토.

## Follow-ups

- **P4**: claude CLI 출력 회귀 감지 위해 NeedsInputTelemetry monthly 카운터를 push-notification 시그널과 연결.
- **P5**: claudeOnly 필터와 mobile fcm 채널 hint 매핑.
- **P9**: chatRoomId 바인딩 시 pane-level chatRoomId를 카드 metadata에 노출.
- **vendor bump 시**: `ghostty_action_tag_e` 신규 enum case가 추가되면 `SessionActionRouter.unknownActionCount`가 telemetry 시그널을 emit하므로 known tag 매핑 업데이트 필요.

## 참고

- 마스터 계획: `docs/plans/work-plan-v4.md` § P3 (line 124~155), § ADR-E (line 633)
- P3 상세: `docs/plans/p3/p3-detailed.html`
- P3 합의 이력: `docs/plans/p3/p3-history.md`
- 구현 파일: `Sources/Session/AnsiSGRParser.swift`, `Sources/Session/NeedsInputPolicy.swift`, `Sources/Session/ShellPreviewExtractor.swift`, `Sources/UI/AgentView/ViewportPollingTimer.swift`, `Sources/UI/AgentView/GhosttyViewportProvider.swift`
