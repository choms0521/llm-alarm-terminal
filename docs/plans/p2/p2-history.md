# P2 상세계획서 — ralplan 합의 변경 이력

본 문서는 `p2-detailed.html`이 ralplan 합의 사이클(v1 → v2 → v3)을 거치며 적용된 surgical edits의 추적 이력입니다. v3가 최종 APPROVE 본이며, 본 history는 회귀 추적과 의사결정 감사 목적으로 보존됩니다.

---

## v1 → v2 deltas (Critic ITERATE 대응)

Critic ITERATE 판결과 Architect 의견을 받아 v1 초안에 surgical edits 24건을 적용했습니다. 재구조화는 수행하지 않았으며, 모든 변경은 외과적 수정입니다. 적용 통계: **HIGH 7건 + MAJOR 6건 + MED 8건 + LOW 3건 = 총 24건**.

| ID | 심각도 | 적용 결과 |
|---|---|---|
| **H1** | HIGH | **chatRoomId를 Workspace에서 Pane으로 이동.** §5.1 Pane 구조체에 `let chatRoomId: String?` 추가 + Workspace에서 제거. §7.1 JSON 예시 위치 갱신 (pane 내부로). §7.3 Reserved Fields 표에 Location 컬럼 추가하여 chatRoomId 행을 `Pane`으로 명시 + master § P9 line 351 "채팅룸은 데스크톱의 특정 pane에 1:1로 바인딩" 근거 인용. Principle 5 위반 해소. |
| **H2** | HIGH | **replaceItem 에러 silent swallow 해소.** §5.3의 `_ = try? FileManager.default.replaceItem(...)`를 명시적 `try ... moveItem` 체인으로 변경 (3-파일 정책의 일부). save() 시그니처 throws 유지. Day 1 종료 조건에 "H2 save() 에러 surface: 호출부가 한국어 에러 dialog/log로 surface (silently swallow 0건)" 항목 추가. |
| **H3** | HIGH | **lastClaudeSessionId 타입 일관성.** §5.2 SessionManager에 주석 추가: "P1 max=1 일 때는 단일 Optional, P2 max=N 일 때는 [sessionId: String] dictionary로 확장 — actor 시그니처/메서드 동일 유지, fork 아닌 자연 확장". Day 5 종료 조건의 `lastClaudeSessionId[workspaceId][paneId]` 표기를 `lastClaudeSessionId[sessionId]`로 정정. |
| **H4** | HIGH | **P2 에러 카탈로그 + "Agent View" i18n 누설 제거.** §7.1 JSON 예시 및 Day 9 기술 노트의 "Agent View" → "에이전트 뷰"로 한국어화. Day 8 산출물에 P2-scope 에러 카탈로그 미니 표(5개 키)와 master § 4.2 UPPER_SNAKE 코드와의 1:1 매핑 (L3 통합). |
| **H5** | HIGH | **A2 산술 정정 + 단축키 정책.** §8 표 A2 행을 "11 workspace × 평균 2 pane으로 20 세션 (agent-view 1 + normal 10 × 2)"으로 정정. Day 8 단축키에 **Cmd+Opt+Up/Down** = 워크스페이스 순환 추가. §4 Architecture Diagram 직후 단축키 보충 표 신설하여 11개 이상 workspace 도달 가능함을 명시. |
| **H6** | HIGH | **Day 6 invariant 1 의미 정정.** master § P2 line 114 "workspace 실행 시점에 캡처한 user env 스냅샷" 의미를 반영하여 envSnapshot 캡처 시점을 "pane spawn 시점" → "workspace 생성 시점"으로 변경. §5.1 Workspace에 `let envSnapshot: [String: String]` 필드 추가. §5.2 SessionManager.create() 시그니처를 `(workspace: Workspace, ...)`로 변경하여 workspace.envSnapshot을 base로 사용. Day 6 invariant 1 검증 절차를 "workspace 생성 후 외부 user rc 변경이 후속 pane에 영향 없음"으로 정정. |
| **H7** | HIGH | **Day 6 PTY assert harness 산출물 명시.** Day 6 산출물에 `Tests/Helpers/PtyTestHarness.swift` 추가 — spawn → master fd write → 100~300ms read with timeout → ANSI CSI strip (regex `\x1b\[[0-9;]*[a-zA-Z]`) → assert. Day 6 예상 소요 1.0~1.5일 → 1.5~2.0일로 확장 (컨틴전시 밴드 0.5일 사전 할당). |
| **M1** | MAJOR | **actor head-of-line stall 명시 + Day 2 fairness 게이트.** §5.2의 `terminateAll`를 `withTaskGroup`으로 병렬화. §9 Risks 표에 신규 행 추가 (위험/가능성/영향/완화/책임 5컬럼). Day 2 종료 조건에 "20-pane terminateAll wall-clock 5초 이내, 동시 create() suspension ≤ 200ms" fairness-stall metric 추가. |
| **M2** | MAJOR | **claude-config dir cleanup hook.** §5.4에 `SessionSpawnEnv.cleanupStaleClaudeConfigDirs(liveSessionIds:)` helper 추가 — live 세션 미매칭 AND mtime 7일+ 디렉터리만 삭제. Day 9 종료 조건에 부팅 직후 1회 호출 검증 추가. §9 Risks 표에 신규 행("claude-config 디렉터리 무한 누적") 추가. |
| **M3** | MAJOR | **Day 6 Invariant 5 신설 (HISTFILE 격리).** §5.4에 `SessionSpawnEnv.zshHistoryDir(workspaceId:, paneId:)` helper 추가. §5.2 create()에 `envSnapshot["HISTFILE"] = histDir + "/history"` 라인 추가. Day 6 종료 조건에 Invariant 5 통합 테스트 추가 (두 셸 pane의 history 분리). |
| **M4** | MAJOR | **workspaces.json.tmp 복구 정책 + 3-파일 atomic write.** 단순 atomic write → 3-파일 정책으로 격상: `.json` (정상) / `.tmp` (in-progress) / `.bak` (직전 정상본). §5.3 WorkspaceStore.load() 진입부에 .tmp 정리 + .bak 복구 로직 추가 (한국어 warn 로그 동반). §5.3 save()도 3-파일 흐름으로 변경. §7.5에 복구 정책 명시. Day 9 종료 조건에 "kill -9 후 .bak으로 복원 + warn 로그 1줄" 검증 추가. |
| **M5** | MAJOR | **Day 7 메모리 leak 검증을 `leaks` 명령으로 변경.** 메모리 차분 100MB 게이트 제거 → `xcrun leaks <pid>` 출력 leak count == 0 + Xcode Instruments Allocations strong reference cycle 0건으로 게이트 격상. |
| **M6** | MAJOR | **extraFields preservation으로 forward compatibility.** §5.1 Workspace + Pane 양쪽에 `let extraFields: [String: AnyCodable]?` 필드 추가. §7.2 Migration policy에 "decode 시 unknown field를 extraFields map에 보존, encode 시 그대로 직렬화"를 명시. §7.3 Reserved Fields 표에 extraFields 행 추가. §9 Risks의 JSON 충돌 row mitigation에 M6 forward-compat 명시. |
| **MED1** | MED | **Vertical demo checkpoint 표.** §3 진입부에 표 추가 — Day 5 demo (create→spawn→close 종단), Day 9 demo (재시작 영속화 walkthrough), Day 1/2/6/7은 infrastructure days로 demo 없음을 honest disclosure. |
| **MED2** | MED | **load() decode invariant guard.** §5.3 WorkspaceStore.load() 코드에 추가: agent-view 0개면 자동 생성, 2개+ 면 첫 번째만 유지 + 한국어 warn 로그. |
| **MED3** | MED | **Day 4/Day 7 ADR-I grep 패턴 확장.** 기존 `(hibernate|pause|releaseSurface)`에 `surface\.destroy|stopRendering|suspendRender|displayLayer.*nil` 패턴 추가. Day 4 종료 조건 + Day 7 종료 조건 양쪽 갱신. |
| **MED4** | MED | **Day 5 fd leak 시나리오 idle/active 분기.** 100회 close/open 중 짝수번은 idle close, 홀수번은 `echo "test"` 후 close하여 active state도 커버. |
| **MED5** | MED | **Day 3 default workspace cwd 명시.** default normal workspace의 cwd = `CHAT_TERMINAL_WORKSPACE_ROOT` (env 미설정 시 `$HOME`). 부록 A와 정합. |
| **MED6** | MED | **Day 8 IME 회귀 검증 추가.** 종료 조건에 "한국어 IME composition('안녕하세요' 입력) 중 단축키 modifier 키(Cmd, Opt)가 composition을 깨지 않음 — UI 통합 테스트로 검증" 추가. |
| **MED7** | MED | **측정성 ambiguity 정리.** Day 2 #1 종료 조건의 grep 정규식을 구체화 (`grep -E '^\s*(public\s+)?func\s+(create|terminate|get|terminateAll|updateClaudeSessionId)'`). Day 9 verifier "critical 0건"을 4가지 항목으로 명시: (1) immutable 위반 0, (2) error handling 누락 0, (3) leak 0 (M5 기준), (4) actor data race 0 (TSan). |
| **MED8** | MED | **한국어 UI 라벨 정책.** Day 8 산출물에 한국어 button/menu label 정책 추가 (예: "+ workspace" → "워크스페이스 추가", "Split Pane" → "팬 분할"). 단축키 modifier 표기는 macOS 표준 유지. |
| **L1** | LOW | **AnyCodable 의존성 명시.** Day 1 종료 조건에 추가: "Package.swift에 Flight-School/AnyCodable 의존 등록. Decision A1: P2 v2부터 외부 패키지 채택, 인하우스 6줄 구현 대안은 거부." |
| **L2** | LOW | **부록 A에 master § 4.3 갱신 hand-off 메모.** "본 v2 적용 후 master § 4.3 표에 `CHAT_TERMINAL_DEBUG_SURFACE_STATS` 등록을 다음 master plan ralplan 사이클에 hand-off"를 callout으로 추가. |
| **L3** | LOW | **i18n 키 컨벤션 통일.** H4 안에 통합 처리됨 — Day 8 i18n 카탈로그 표에 master § 4.2 UPPER_SNAKE 코드와 lower.snake 키의 1:1 매핑 명시. |

### v1 → v2 변경 통계

HIGH 7건 + MAJOR 6건 + MED 8건 + LOW 3건 = 총 24건 surgical edits 적용. 재구조화 없음 (TOC 1 항목 추가, 일자 카드 9개 유지, h2 섹션 1개 추가). Deferred 0건 — 모든 ITERATE 항목이 v2에 반영됨.

---

## v2 → v3 deltas (Critic ITERATE 2차 대응)

v2를 Critic이 재평가한 결과 H6(envSnapshot 시점 변경) propagation 회귀 3건 + 신규 MAJOR 결함 1건이 발견되었습니다. v3은 이를 surgical하게 정정하고, deferred 항목 3건은 후속 단계(P3 hand-off / P5 migration / P12 sandbox ADR)로 이관합니다.

| ID | 심각도 | 적용 결과 |
|---|---|---|
| **R1** | HIGH 회귀 | **Day 2 envSnapshot 캡처 시점 v1 의미 잔존 정정.** Day 2 기술 노트의 "env snapshot 시점: workspace 생성 시점이 아니라 각 세션 spawn 시점" 문구를 "workspace 생성 시점에 한 번 캡처하여 `Workspace.envSnapshot`에 저장. `SessionManager.create()`는 `workspace.envSnapshot`을 base로 dict copy하여 각 세션에 전달. claude는 `CLAUDE_CONFIG_DIR` override, shell은 `HISTFILE` override(M3) 추가 적용"으로 정정. Day 2 종료 조건의 "ProcessInfo.environment dict snapshot" 표기도 "workspace.envSnapshot base + HISTFILE override" XCTAssertEqual 검증으로 정정. §5.1/§5.4 cross-ref 추가. |
| **R2** | MAJOR 회귀 | **§5.2 create() 코드의 미선언 변수 `workspaceId` 참조 정정.** H6에서 함수 시그니처를 `(workspaceId: UUID, ...)` → `(workspace: Workspace, ...)`로 변경했으나 본문의 `Session(... workspaceId: workspaceId, ...)` 라인이 미정정 상태로 남아 있었음 (지역 변수 부재 컴파일 에러 유발 가능). `workspaceId: workspace.id`로 정정. |
| **N2** | MAJOR 신규 | **terminateAll의 withTaskGroup actor reentrancy로 activityScope premature release 결함 차단.** v2의 M1 패턴 `[weak self] + try? await self?.terminate(id:)`은 child task가 actor를 재진입하여 `terminate()`를 호출하므로, 마지막 세션 종료 전에 `sessions.allSatisfy { .exited } → activityScope = nil` 분기가 발동할 위험. v3에서 패턴 전면 교체: (Step 1) actor 안에서 PTY 자원 추출 → (Step 2) child task는 actor 진입 없이 `kill/waitpid/close`만 수행 → (Step 3) 모든 child task `await` 완료 후 actor 안에서 단일 pass로 상태 갱신 + activityScope 체크. §5.2 코드 18줄 surgical 교체. §9 Risks 표에 신규 행(N2) 추가. Day 2 종료 조건에 invariant 추가: "`activityScope == nil iff sessions.allSatisfy { .exited }`. terminateAll 진행 중간에 activityScope이 미리 nil이 되지 않음을 polling 단위 테스트로 검증 (reentrancy 발현 0건)." |
| **R3** | LOW 회귀 | **Day 1 reserved field 위치 명세 갱신.** Day 1 기술 노트의 "Reserved fields: pushChannelHints, chatRoomId, fetchHint" 표현이 모델 소속(Workspace vs Pane)을 명시하지 않아 v1 잔재로 chatRoomId의 위치 오해 가능. "Workspace level — pushChannelHints/fetchHintMetadata; Pane level — chatRoomId (master § P9 line 351 1:1 바인딩)"로 명시적 분리. H1 정정의 propagation 완결. |
| **N6** | LOW 권고 | **컨틴전시 표 이중 계상 해소.** Day 6 effort가 v2에서 1.0~1.5일 → 1.5~2.0일로 0.5일 사전 흡수되었으나 컨틴전시 표의 "PTY env/cwd 격리 누설" Day 6 트리거(0.5일)가 동일 시나리오를 또 할당. 컨틴전시 표에서 해당 행 제거 + 상한선 callout에 "Day 6 effort 자체에 0.5일 사전 흡수됨, PtyTestHarness 작성 시간 포함" 주석 추가. 컨틴전시 총합 2일 상한 유지 보장. |
| **N3** | MED deferred | **P4 reconnect lookup 의미 약화 — Deferred to P3 hand-off.** H3 정정 후 `lastClaudeSessionId[sessionId]` 1-level 표기로 변경되었으나 P4 reconnect 시 sessionId → paneId 역매핑이 필요. P2에서는 정정 없이 P4 hand-off 문서에 이관 노트로 기록: "P4에서 reconnect 시 paneId 기반 lookup이 필요하면 `SessionManager.lastClaudeSessionId` 옆에 보조 인덱스 `paneToLastSessionId: [UUID: UUID]`를 추가하여 paneId → 가장 최근 sessionId 매핑을 보존하는 방안 검토." |
| **N4** | MED deferred | **`extraFields` round-trip은 forward-compat 안전망 — Deferred to P5 migration.** §7.2 Migration policy에 "extraFields는 unknown field silently drop 방지 안전망일 뿐이며, 외부 도구가 미리 채운 정식 필드의 round-trip 보장은 P5+ 정식 추가 시 migration 코드로 처리"를 1줄 추가 권고됨. v3에서는 deltas 표 기록으로 한정하고 본문 §7.2 추가는 P5 migration 작성 시점에 처리. |
| **N5** | LOW deferred | **HISTFILE path 권한 검증 ADR — Deferred to P12 sandbox ADR.** M3에서 `HISTFILE=~/Library/Caches/ClaudeAlarmTerminal/zsh_history/...`로 격리하였으나, P12 릴리스 단계에서 App Sandbox 활성화 가능성을 평가할 때 Caches 디렉터리 권한 검증이 필요. v3에서는 본문 영향 없음. P12 ADR(가칭 ADR-J — sandbox 평가)에서 처리. |

### v2 → v3 변경 통계

v1 → v2: 24건 (HIGH 7 + MAJOR 6 + MED 8 + LOW 3) / **v2 → v3: 5건 적용 (HIGH 회귀 R1 + MAJOR 회귀 R2 + MAJOR 신규 N2 + LOW 회귀 R3 + LOW 권고 N6) + 3건 deferred (N3 → P3 hand-off, N4 → P5 migration, N5 → P12 sandbox ADR).** 누적 총 29건 적용 + 3건 deferred. 재구조화 없음 (TOC 1 항목 추가, h3 sub-section 1개 추가).
