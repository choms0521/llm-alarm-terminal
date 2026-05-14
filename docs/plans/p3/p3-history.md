# P3 상세계획서 — ralplan 합의 변경 이력

본 문서는 `p3-detailed.html`이 ralplan 합의 사이클(v1 → v2 → v3)을 거치며 적용된 surgical edits의 추적 이력입니다. v3가 최종 APPROVE 본이며, 본 history는 회귀 추적과 의사결정 감사 목적으로 보존됩니다.

---

## v1 → v2 deltas (Architect REQUEST-REVISION 대응)

Architect v1 검토에서 **REQUEST-REVISION** 판정과 함께 surgical edit 4건(CRITICAL 1 + HIGH 2 + MED 1) + 추가 권고 6건이 식별되었습니다. v1 본문 구조와 RALPLAN-DR 결정 사항(Option C / 2-trail hybrid / AttributedString SGR parser / AgentJumpAction+FocusedPaneStore)은 모두 ACCEPT 받았으며, 재구조화 없이 외과적 수정 17건을 적용했습니다.

### v1 → v2 적용 표

| ID | 심각도 | 적용 결과 |
|---|---|---|
| **SE-1** | CRITICAL | **action_cb main thread hop 명시.** vendor/ghostty/src/apprt/embedded.zig:267-287 의 Zig `self.opts.action(...)` 가 호출자 thread 에서 동기 invoke 되므로 action_cb는 main thread 보장 없음. D3-3 Trail A 코드 spec에 `DispatchQueue.main.async` 강제 패턴 명시 + ActionPayload Sendable + 포인터 보유 금지 + Day 4 종료 조건에 `grep -A 10 'action_cb:' ... \| grep -c 'DispatchQueue.main.async' >= 1` + Thread Sanitizer 30분 알람 0건 Exit Gate 추가. |
| **SE-2(a)** | HIGH | **viewport polling 동적 빈도화.** 정적 250ms × 20 surface = 80Hz main thread 부담 해소. `ViewportPollingTimer.focusedIntervalMs = 250` / `backgroundIntervalMs = 1000`. focused-only 4Hz + 19 background × 1Hz = 평균 23Hz (정적 80Hz 대비 71% 절감). ADR-E에 "polling 빈도 조정은 surface state mutation이 아니므로 P2 ADR-I cmux invariant 위반 아님" 명문화. |
| **SE-2(b)** | HIGH | **needsInput fast-lane (throttle bypass).** D3-4 SessionStatusCoordinator를 3-publisher 분리: previewSubject.throttle(100ms) + needsInputSubject.removeDuplicates() (throttle 없음) + statusSubject.removeDuplicates(by:). Day 4 종료 조건에 "1초 invocation 23±3", "needsInput fast-lane <20ms", "preview throttle 100건 ≤12회" 측정 가능 검증 추가. Risks #1, #4 mitigation 강화. |
| **SE-3** | MED | **NeedsInputPolicy versioned + telemetry + ❯ FP 강화.** D3-2에 `NeedsInputPolicy` protocol + `NeedsInputPolicyV1` (version "v1-2026-05", patterns 4종 + claudePromptMarker `"\u{1b}[0m❯ "`) + `NeedsInputTelemetry` monthly counter 추가. claude REPL prompt 단독 ❯ FP 차단 (SGR reset prefix 조건). ADR-E (다) "NeedsInput Policy versioning" 절 신규 (count<1 시 v2 bump 시그널, V1 namespace 보존, FP escalation HIGH priority). |
| **SE-4(a)** | MED | **`ghostty_surface_free_text` defer 의무 명시.** D3-3 Trail B `ViewportPollingTimer.poll` 코드 spec에 `var text = ghostty_text_s(); let ok = ghostty_surface_read_text(...); defer { ghostty_surface_free_text(surface, &text) }` 패턴 강제. ADR-E (나) "read_text/free_text 1:1 leak invariant" 절 신규. Day 4 종료 조건에 `grep -n 'defer.*ghostty_surface_free_text'` + `grep -c read_text == grep -c free_text` + 20 surface × 30분 idle leaks 0 추가. Risks 표에 R6 (ghostty_text_s leak) 신규 행 추가. |
| **SE-4(b)** | MED | **master § 4 reserved namespace + § 4.3 환경변수 표 등록 PR을 Exit Gate 의무로 격상.** 단순 hand-off 약속이 아닌 PR 머지 의무로 명문화. master plan ralplan 별도 사이클 (max 2) 합의 의무. |
| **권고 1** | LOW | **D3-1 결정 사유 callout.** Option C 선택 사유에 "lifecycle terminate path에 agent-status 동기 갱신 의무를 부과하지 않음. lifecycle hook이 발행한 onSessionTerminated 이벤트를 SessionStatusCoordinator가 main thread에서 단방향 소비하여 snapshot.agentStatus = .exited로 전이" 1줄 추가. P2 actor isolation invariant 보존 명시. |
| **권고 2** | LOW | **ADR-E (가) 지원 SGR 코드 부분집합 표 작성.** Reset 0 / Style 1,3,4,7,22,23,24,27 / Foreground 30~37,39,90~97 / Background 40~47,49,100~107 / 256-color 38;5;N,48;5;N / Truecolor 38;2;R;G;B,48;2;R;G;B. 미지원 (blink 5,6 / font 10~19 / framed 51 / encircled 52 / overline 53 / proportional 26,50)은 silently drop + DEBUG log. |
| **권고 3** | LOW | **Day 5 종료 조건에 makeFirstResponder 검증 추가.** AgentJumpAction.jump 호출 후 mock NSView.becomeFirstResponder 호출 횟수 == 1 XCTAssertEqual. `Sources/TerminalView/GhosttyTerminalView.swift:209-215` 호출 의무 grep + 단위 검증. |
| **권고 4** | LOW | **ADR-E (라) OSC 133 우선 정책 명시.** `OSC 133;A` (prompt start) / `;B` (command start) / `;C` (output start) / `;D` (command end) 가 viewport text에 존재 시 prompt 영역 직접 식별. 없으면 fallback heuristic. modern shell (zsh osc133 plugin, fish 3.4+, bash custom PROMPT_COMMAND) 호환. |
| **권고 5** | LOW | **Day 3 종료 조건에 ZWJ emoji grapheme prefix 단위 테스트 추가.** `Utf8BoundaryTruncator.truncate("a👨‍👩‍👧‍👦b", maxGraphemes: 2) == "a👨‍👩‍👧‍👦"` 가족 emoji 1 grapheme 보존. `String.prefix(maxLength)` vs `String.unicodeScalars.prefix` 차이 명시. |
| **권고 6** | LOW | **Principles 1번에 단방향 invariant 추가.** "SessionStatusCoordinator는 SessionLifecycleHooks의 단일 방향 소비자이며, lifecycle hook으로 agent-status를 push하지 않는다 (단방향 invariant)." Principle 6 신규 추가 (C ABI alloc/free 1:1 강제). Principles 총 5개 → 6개로 확장. |

### v1 → v2 변경 통계

CRITICAL 1건 + HIGH 3건 + MED 6건 + LOW 7건 = 총 17건 surgical edits 적용. 재구조화 없음 (TOC 1 항목 추가, 일자 카드 6개 유지). Deferred 0건 — 모든 REQUEST-REVISION 항목이 v2에 반영됨.

### Architect v2 verification 결과

| 질문 | 판정 |
|---|---|
| Q1 (SE-1 action_cb main thread hop) | PASS |
| Q2 (SE-2 동적 polling + needsInput fast-lane) | PASS |
| Q3 (SE-3 NeedsInputPolicy versioned + FP 강화) | PASS |
| Q4 (SE-4 free 의무 + namespace PR) | PASS |

**Architect 최종 verdict: APPROVE-FOR-CRITIC**

---

## v2 → v3 deltas (Critic ITERATE 대응)

v2를 Critic이 평가한 결과 5축 본체 측정성은 86.3% (90% 임계 미달이나 75% 합격선 통과)이며, deliberate mode 의무 2축(Pre-mortem 3 시나리오 + 확장 테스트 4영역)이 명시 부재로 ITERATE 사유에 해당. 추가로 R5 mitigation 부정확과 Exit Gate 외부 PR 의존 trackability 부재가 CONCERN으로 식별. surgical edit 4건 + Minor 5건 + Gap 5건 + Ambiguity 3건 = 총 18건 외과적 수정으로 v3 작성.

### v2 → v3 적용 표

| ID | 심각도 | 적용 결과 |
|---|---|---|
| **SE-1** | CRITICAL | **§ 6.5 Pre-mortem 3 시나리오 신규 섹션** (deliberate mode 의무). 시나리오 A (libghostty bump → ABI breakage): trigger = vendor 업데이트, 증상 = ViewportPollingTimer crash/preview 깨짐, 사전 방어 = `GHOSTTY_API_VERSION` assert + defer free_text 1:1 회귀 + ADR-E (나) 체크리스트, 회복 = polling 일시 정지 + 한국어 warning toast. 시나리오 B (claude CLI 카피 변경 → FN 100%): trigger = 30일 무 telemetry trigger, 증상 = needsInput 카운트 0, 사전 방어 = NeedsInputTelemetry monthly counter + 30일 무 trigger 알람, 회복 = NeedsInputPolicyV2 작성 + A/B comparison 1주 + V1 deprecated. 시나리오 C (30 세션 동시, max=20 invariant 위반): trigger = JSON 직접 수정 또는 코드 회귀, 증상 = 메인 스레드 점유 폭발, 사전 방어 = SessionIndex.size > 20 detect + polling 정지 + ADR-E (나) 20 surface ceiling enforcement + SessionManager.maxSessions assert, 회복 = telemetry detect + 한국어 안내 + max=20 정렬 후 polling 재개. TOC sidebar에 § 6.5 항목 추가. |
| **SE-2** | MAJOR | **§ 6.7 확장 테스트 4영역 매트릭스 신규 섹션** (deliberate mode 의무). Unit (Day 1~3 + Day 6): NeedsInputPolicyV1Tests 28건 + Utf8BoundaryTruncatorTests 8건 + ShellPreviewExtractorTests 12건 + AnsiSGRParserTests 14건 + SessionStatusObserverTests 12건 + AgentSortFilterControlsTests + Korean/Emoji corpus 100건. Integration (Day 4~5): SessionStatusCoordinator 3-publisher × SessionStatusObserver × ViewportPollingTimer chain + AgentDashboardIntegrationTests 6 카드 시나리오 + AgentJumpAction × FocusedPaneStore × surfaceRegistry. E2E (Day 6): `make e2e-p3` 실 libghostty + 실 child PTY 1건, XCUITest 또는 P10 통합 harness reuse. Observability (Day 4 + Day 6): NeedsInputTelemetry monthly log (`CHAT_TERMINAL_AGENT_TELEMETRY_LOG=1`) + TSan 30분 알람 0 + xcrun leaks 20 surface × 30분 idle 0 + verifier 4축 critical 0건. TOC sidebar에 § 6.7 항목 추가. |
| **SE-3** | CONCERN | **R5 row mitigation 정확화.** 기존 "hash short-circuit (변경 시만 SGR 파서 호출)"은 perf optimization일 뿐 race mitigation이 아님이 식별. v3에서 4단계로 분리: (1) ViewportPollingTimer는 main thread에서만 read_text 호출 (race mitigation primary), (2) libghostty가 main thread 호출 시 fragment-safe 보장 (vendor cmux 패턴 embedded.zig:1629), (3) hash short-circuit은 SGR 파서 부담 절감 perf optimization으로 명시 분리, (4) 잘린 결과 cache 회귀 방지 — 1초 내 hash 5회 이상 변경 시 telemetry log emit. D3-3 Trail A의 main thread hop 코드 spec과 cross-reference. |
| **SE-4** | CONCERN | **Exit Gate 외부 PR 의존 2건 fallback 정책 명문화.** master § 4 reserved namespace + § 4.3 환경변수 표 PR 2건을 "Soft requirements" 별도 섹션으로 분리. 5일 unblock 정책 사유 (a)(b)(c) 명시: (a) extraFields `agentView.*` prefix는 P2 forward-compat catch-all (Workspace.swift:108~131 M6 decoder)로 기능 차단 0건, (b) P4 진입 시 sub-ralplan 다음 사이클에서 일괄 반영 가능, (c) 환경 변수 표는 docstring + 부록 A로 보강. unblock 발동 시 handoff-to-p4.md "master PR debt: 2건" 등재 의무. plan-level architectural decision (ad-hoc workaround 아님)으로 명시. |
| **m1** | Minor | **Day 2 한국어 byte 깨짐 정량 기준.** "200 grapheme 한국어/이모지 corpus 100건 / `validateUTF8` 0 fail" XCTAssertEqual. `Tests/Fixtures/korean-emoji-corpus.txt` 산출물 추가. |
| **m2** | Minor | **Day 5 AgentStatusBadge 4종 status 한국어 라벨 매트릭스.** idle="활성" / working="작업 중" / needsInput="입력 필요" / exited="종료됨" 모두 명시 + accessibilityLabel 단위 XCTAssertEqual 4종. |
| **m3** | Minor | **Day 6 verifier 4축 4건 명령 explicit 명시.** (1) immutable `grep -rnE '(var) +[A-Z]'` → 0건, (2) error 한국어 i18n `KoreanErrorCatalog.code(from:)` 매핑 5/5, (3) leak (`FdLeakTests` 20 iter + `xcrun leaks` 0 + `grep -c read_text == grep -c free_text`), (4) actor isolation `grep -rn 'nonisolated' Sources/Session/` → 0건. |
| **m4** | Minor | **미지원 SGR silently drop OSLog target 명시.** `OSLog(subsystem: "com.choms0521.ClaudeAlarmTerminal", category: "AgentView.SGR").debug(...)` 로 emit. release build 자동 suppress. |
| **m5** | Minor | **Combine throttle 시그니처 prose 추가 명시.** D3-4에 `Publisher.throttle(for: Scheduler.SchedulerTimeType.Stride, scheduler: Scheduler, latest: Bool)` 산문화. `latest: true` 의미 명시. |
| **G1** | Gap | **셸 working 판정 500ms 단순화 정책 강조.** "최근 500ms 안에 PTY output(viewport text 변경 또는 action_cb) 이 있으면 working, 없으면 idle". 자식 프로세스 PID/상태 조회는 P4+ deferred. FN-tolerant 부작용 명시 (백그라운드 cron-style 자식 프로세스가 출력 없이 working 상태일 때 idle 표시 수용). |
| **G2** | Gap | **점프 후 agent-view invariant 회귀 검증.** `AgentJumpAction.jump(...)` 호출 100회 반복 후 `manager.workspaces.filter { $0.kind == .agentView }.count == 1` XCTAssertEqual + agent-view canClose == false 보존 XCTAssertFalse. AgentViewInvariantTests에 1건 추가. |
| **G3** | Gap | **NeedsInputTelemetry 월 카운터 reset 시점 정의.** "현재 month-of-year ≠ 마지막 record 시점의 month-of-year" 정의 (`record(now:)` 코드 spec에 명시). 2026-05 record×3 + 2026-06 record×1 → 06월 count==1 단위 검증. |
| **G4** | Gap | **AttributedString desktop 전용 + P4 envelope raw SGR 보존.** ADR-E (가)에 "본 SGR 파서와 AttributedString 사용은 desktop (macOS) 전용. P4 envelope payload (모바일/WS 서버 전달)는 raw SGR sequence를 보존하며, AttributedString 변환은 데스크톱 카드 렌더 시점에만 적용. 모바일 측 렌더러는 자체 SGR 파서 또는 plain strip 선택권" 명시. |
| **G5** | Gap | **action_cb unknown tag pass-through 정책.** 4개 known tag (RING_BELL, COMMAND_FINISHED, PROGRESS_REPORT, PROMPT_TITLE) 외 미래 신규 tag 등장 시 SessionActionRouter는 warn log emit (OSLog category `AgentView.Router`) + telemetry counter `unknownActionCount` 증가 + dispatch 미수행. vendor bump 호환성 확보. panic 또는 router reject 금지. |
| **Q1** | Ambiguity | **"focused" 정의 명시.** D3-3 Trail B 코드 spec에 "pane이 focused 라는 것은 (i) `manager.selectedID == workspaceId` 이고 `FocusedPaneStore.focused[workspaceId] == paneId`, (ii) `NSApp.isActive == true` 두 조건 모두 만족하는 상태이다. app 백그라운드 시 모든 surface가 background fallback (1Hz)으로 강등" 명문화. |
| **Q2** | Ambiguity | **OSC 133 우선 정책 적용 범위 명시.** ADR-E (라)에 "OSC 133 marker가 viewport text 안에 1개 이상 존재 시, 해당 marker로 둘러싸인 영역만 OSC 133 우선 정책으로 prompt 영역을 추출한다. marker 외부의 텍스트는 fallback heuristic으로 처리. 즉 viewport가 OSC 133 영역과 raw text 영역 혼재 시 두 정책이 영역별로 공존" 명시. |
| **Q3** | Ambiguity | **grep 비교 대상 범위 명시.** Day 4 종료 조건 + Exit Gate에 "`grep -rc 'ghostty_surface_read_text' Sources/` == `grep -rc 'ghostty_surface_free_text' Sources/` (vendor/ 경로 제외)" 명시. vendor의 SurfaceView_AppKit.swift 8건 호출은 비교 대상에서 제외. |
| **Minor (축 2)** | Minor | **ADR-E mini-libghostty embed 거부 사유 1줄 보강.** "terminal state machine internal copy를 카드 preview 용으로 별도 운영하는 비용이 카드 UX 향상 대비 불균형, P3 효과 대비 비용 과다" 명시. P12+ deferred. |

### v2 → v3 변경 통계

CRITICAL 1건 + MAJOR 1건 + CONCERN 2건 + Minor 6건 + Gap 5건 + Ambiguity 3건 = 총 18건 surgical edits 적용. 재구조화 없음 (TOC 2 항목 신규 추가: § 6.5 Pre-mortem, § 6.7 확장 테스트 4영역 매트릭스). Deferred 0건.

### 측정성 비율 변화 (v2 → v3)

| 축 | v2 | v3 | 차이 |
|---|---|---|---|
| 축 1 Principle-Option Consistency | 92% | 95% | +3 |
| 축 2 Fair Alternatives | 87% | 92% | +5 |
| 축 3 Risk Mitigation Clarity | 78% | 91% | +13 |
| 축 4 Testable Acceptance Criteria | 89.5% | 93.4% | +3.9 |
| 축 5 Concrete Verification Steps | 85% | 92% | +7 |
| D1 Pre-mortem 3 시나리오 | 0% | 100% | +100 |
| D2 확장 테스트 4영역 | 50% | 100% | +50 |
| **본체 평균 (축 1~5)** | **86.3%** | **92.7%** | **+6.4** |

### Architect v3 verification 결과

| 질문 | 판정 |
|---|---|
| Q1 (§ 6.5 Pre-mortem 3 시나리오) | PASS |
| Q2 (§ 6.7 확장 테스트 4영역) | PASS |
| Q3 (R5 mitigation 정정) | PASS |
| Q4 (SE-4 Exit Gate fallback 정책) | PASS |
| Q5 (Minor/Gap/Ambiguity 13건) | PASS |

**Architect 최종 verdict: APPROVE-FOR-CRITIC**

### Critic v3 재평가 결과

| 축 | v2 판정 | v3 판정 |
|---|---|---|
| 1. Principle-Option Consistency | PASS | **PASS** |
| 2. Fair Alternatives | PASS-with-concern | **PASS** |
| 3. Risk Mitigation Clarity | CONCERN | **PASS** |
| 4. Testable Acceptance Criteria | PASS | **PASS** |
| 5. Concrete Verification Steps | PASS-with-concern | **PASS** |
| D1. Pre-mortem 3 시나리오 | FAIL | **PASS** |
| D2. 확장 테스트 4영역 | CONCERN | **PASS** |

**7축 모두 PASS**. 본체 측정성 92.7% + deliberate 2축 100%.

**Critic 최종 verdict: APPROVE — P3 v3 ralplan 합의 통과**

---

## 합의 사이클 요약

| 라운드 | 단계 | 결과 |
|---|---|---|
| 1 | Planner v1 → Architect v1 검토 | REQUEST-REVISION (SE-1~SE-4 + 추가 권고 6건) |
| 1 | Planner v2 작성 | surgical edits 17건 외과적 반영 |
| 1 | Architect v2 재검토 | APPROVE-FOR-CRITIC (Q1~Q4 PASS) |
| 1 | Critic v2 평가 | ITERATE (deliberate mode 2축 미달) |
| 2 | Planner v3 작성 | surgical edits 18건 외과적 반영 |
| 2 | Architect v3 verification | APPROVE-FOR-CRITIC (Q1~Q5 PASS) |
| 2 | **Critic v3 재평가** | **APPROVE** (7축 모두 PASS, 측정성 92.7%) |

ralplan 사이클 budget 2.5회 소진 (5회 한도 내).

---

## ADR 최종 합의 sign-off (Critic 발행)

### Decision
P3 (agent-view 대시보드, Pinned First Tab) 상세 계획서 v3를 ralplan 합의 최종안으로 채택. agent-view 카드 그리드 + needsInput 시각 큐 + 카드 클릭 점프 + 셸 preview 처리 + 영속화 + ADR-E (agent-view 렌더링 + 인터랙션 정책)을 6일(1.0+1.0+1.0+1.2+1.0+1.0) 일정으로 구현.

핵심 architectural decisions 8건:
- D3-1: Option C — Session 모델 무변경 + SessionStatusSnapshot 별도 struct (lifecycle terminate path 비결합 invariant)
- D3-2: NeedsInputPolicy versioned + telemetry + ❯ FP 강화 (SGR reset prefix `\u{1b}[0m❯ ` 조건)
- D3-3: PTY output 2-trail hybrid (Trail A action_cb main thread hop + Trail B 동적 polling 250/1000ms + defer free_text 강제)
- D3-4: SessionStatusCoordinator 3-publisher 분리 (preview throttle 100ms / needsInput throttle bypass / status removeDuplicates)
- D3-5: ANSI SGR parser SwiftUI AttributedString 채택 (ADR-E 4개 절: SGR 부분집합 / read_text-free_text 1:1 / NeedsInput versioning / OSC 133 우선)
- D3-6: AgentJumpAction + FocusedPaneStore + becomeFirstResponder (`GhosttyTerminalView:209-215` anchor)
- D3-7: 셸 preview OSC 133 우선 + 3-조건 conjunction fallback
- D3-8: `extraFields["agentView.sort/filter"]` 영속화 + master § 4 reserved namespace PR Soft requirement (5일 unblock fallback)

### Drivers
- D1 (P1/P2 backward compat 최소화): Option C가 Session 모델 0줄 diff로 충족.
- D2 (테스트 가능성): 4 영역 매트릭스(Unit/Integration/E2E/Observability)로 확장. 측정성 92.7%.
- D3 (사용자 visible 정확성): A1~A6 acceptance criteria + 한국어/ZWJ emoji UTF-8 무결 + needsInput FN 허용 FP 금지.

추가 driver (deliberate mode):
- D-deliberate-1 (실패 가정 backward reasoning): § 6.5 Pre-mortem 3 시나리오.
- D-deliberate-2 (E2E + Observability 가시성): § 6.7 확장 테스트 4영역 매트릭스.

### Alternatives Considered

**Session 모델 확장 전략 3 옵션**:
- Option A (Session.status enum 세분화 idle/working/needsInput/exited): **거부** — lifecycle terminate path 결합 발생, P1/P2 backward compat 부담 최대.
- Option B (Session에 agentStatus 신규 필드 추가): **거부** — Session 모델 변경이 P1/P2 backward compat 부담(D1 위반).
- Option C (SessionStatusSnapshot 별도 struct, **채택**): cons "신규 컴포넌트 SessionStatusStore 추가 — 코드 표면적 ↑" 솔직 명시. D1+D2+D3 모두 충족.

**ADR-E SGR parser 3 옵션**:
- plain strip: **거부** — SGR escape sequence drop 시 사용자 visible 정보 손실.
- mini-libghostty embed: **거부** — 초기 구현 부담 + libghostty offscreen render 미보장 + terminal state machine internal copy 별도 운영 비용 불균형.
- SwiftUI AttributedString (**채택**): SGR 부분집합 표 명시 + 미지원 SGR silently drop + DEBUG log.

### Consequences

**Accepted**:
- 신규 컴포넌트 SessionStatusStore + SessionStatusCoordinator + ViewportPollingTimer 추가로 코드 표면적 증가 (~9 신규 file).
- ViewportPollingTimer 동적 빈도(focused 250ms / background 1000ms) 평균 23Hz로 정적 80Hz 대비 71% 절감하나 메인 스레드 부담 0은 아님.
- master plan § 4 reserved namespace + § 4.3 환경변수 표 PR 2건은 P3 main 머지 후 5일 내 unblock 정책 적용.
- NeedsInputPolicyV1 carrier 한국어/claude CLI 카피 변경 회귀 가능성은 NeedsInputTelemetry monthly counter + 30일 무 trigger 알람으로 detect, V2 bump 정책으로 회복.
- libghostty ABI breakage 시 ViewportPollingTimer는 graceful degradation (polling 일시 정지 + warning toast) 경로 명시.

**Trade-offs**:
- Session 모델 무변경 결정은 lifecycle 도메인과 agent-status 도메인 분리 invariant를 영구화.
- SwiftUI AttributedString 채택은 desktop 전용 결정 — P4 envelope payload는 raw SGR 보존.
- hash short-circuit은 race mitigation이 아닌 perf optimization으로 라벨 분리 — 실 race 방어는 main thread hop primary.

### Follow-ups

1. **master plan ralplan 사이클**: § 4 reserved namespace 표에 `agentView.sort` / `agentView.filter` 등록 + § 4.3 환경변수 표에 신규 6개 등록. 5일 미머지 시 P4 진입 unblock 정책 발동 + handoff-to-p4.md debt 등재.

2. **ADR-E 작성 후 별도 합의**: `docs/adr/E-agent-view-rendering.md` 5 섹션 + 4 절을 P3 Day 6에 산출 후 별도 ralplan 사이클(max 2). master ADR catalog (work-plan-v4.md line 633)에 등재.

3. **E2E child PTY 권한 CI 환경 명시**: `make e2e-p3` target이 GitHub Actions macOS-15 runner 등에서 `forkpty(3)` sandbox 제약 가능. Day 6 자연 흡수 가능하나 명시 권장 — Day 6 executor가 CI environment matrix (local / CI runner) 동시 검증 절차 명시 권장.

4. **Pre-mortem 시나리오 회복 경로 발동 기록**: NeedsInputPolicy V2 bump 발동 / SessionIndex.size > 20 detect 발동 / libghostty ABI breakage 발동 시 P3 verifier report에 기록 의무. 향후 phase에서 회귀 추적.

5. **Open Questions (P3 implementation 단계에서 자연 해소)**:
   - OQ1: `surfaceRegistry.acquireExisting(paneId:)` nil 반환 시 UX → Day 5 결정.
   - OQ2: NeedsInputPolicyV1 `[y/n]` case-insensitive 처리 → Day 2 결정.
   - OQ3: OSC 133 fallback heuristic 발동 조건 → ADR-E (라) 작성 시 결정.

6. **handoff-to-p4.md 작성 의무**: Day 6 산출물에 P3 → P4 인계 사항 (lastClaudeSessionId 활용 시점 / master PR debt 2건 / SessionStatusCoordinator의 P4 envelope reuse 정책 / AnsiSGRParser 영역 한정) 명시.

---

## 회귀 self-check 결과

- ☑ SE-1 (§ 6.5) 와 SE-2 (§ 6.7) 신규 섹션이 TOC sidebar에 정합 추가됨 (`p3-detailed.html` 의 `<aside class="toc">` 에 반영)
- ☑ SE-3 R5 mitigation 정정과 D3-3 Trail A 의 `DispatchQueue.main.async` 강제 패턴 cross-check 완료. 모순 0건.
- ☑ SE-4 fallback 정책과 P2 `Workspace.swift:108~131` extraFields catch-all decoder 정합. 모순 0건.
- ☑ 본문 메타 표기 grep self-check: `// SE-`, `// v2 → v3`, `정정`, `v1 → v2`, `delta`, `surgical edit` 문자열 본문 0건. 변경 통계는 본 history.md에만 존재.

---

## 참고 reference

- 본문: `docs/plans/p3/p3-detailed.html` (v3 최종 APPROVE 본)
- 마스터 계획: `docs/plans/work-plan-v4.md` § P3 (line 124~155), § ADR-E (line 633)
- P2 인계: `docs/p2/handoff-to-p3.md`
- P1 디자인 시스템 reference: `docs/plans/p1/p1-detailed.html`
- P2 디자인 시스템 reference: `docs/plans/p2/p2-detailed.html`
- P2 history 형식 reference: `docs/plans/p2/p2-history.md`
- ralplan 합의 산출물 규약: `~/.claude/rules/plan-documents.md`
