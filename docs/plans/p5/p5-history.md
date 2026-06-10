# P5 상세 계획서 — ralplan 합의 이력

본 문서는 `p5-detailed.html`이 ralplan 합의 사이클을 거치며 적용된 surgical edits의 추적 이력입니다. 회귀 추적과 의사결정 감사 목적으로 보존됩니다.

- 대상 본문: `docs/plans/p5/p5-detailed.html`
- 합의 방식: ralplan (Planner -> Architect -> Critic, 순차)
- 결과: 사이클 2에서 **APPROVE** 도달 (plan-documents.md 9 권장 1~3사이클 내)
- 최종 본문: 1,319 lines (history 분리 후)

---

## 사이클 요약

| 사이클 | Planner | Architect | Critic |
|---|---|---|---|
| 1 | v1 초안 (1,230 lines) | SOUND-WITH-CHANGES (ITERATE 5건) | **ITERATE** — 5건 확증 + 신규 2건 + 거짓표적 2건 반증 |
| 2 | v2 (1,307 lines) -> v3 (1,319 lines) | SOUND-WITH-CHANGES (5+2 닫힘, 회귀 1건) | **APPROVE** |

측정성: 약 90% (75% 임계 상회). 한자 0건, 페르소나 누출 0건.

---

## 사이클 1 — Architect/Critic 적출

### Architect (SOUND-WITH-CHANGES) — 근본 진단: 레이어 경계 혼동

ITERATE급 5건. (h) "internal 입력 live 배선"을 daemon seam(GhosttyKit 비의존, DaemonTests 게이팅)과 app glue(surface lazy 생성 타이밍 종속) 두 레이어로 분리하지 않아 컴파일 경계 위반 + silent no-op + false-pass가 동시 발생.

### Critic (ITERATE) — Architect 5건 확증 + 신규 2건 + 반증 2건

| # | 결함 | 등급 | 출처 |
|---|---|---|---|
| M1 | 의사코드 5.4가 DaemonTests 타깃 경계 위반 (Sources/TerminalView 부재, GhosttyTerminalView internal) | MAJOR | Architect 확증 |
| M2 | surface lazy 생성 -> `wireInternalInput` 즉시 조회가 silent no-op | MAJOR | Architect 확증 |
| M3 | `powerObserver`가 `let` 상수라 plan의 재할당 배선 컴파일 불가 + "재배선 불필요" 과소평가 | MAJOR | **Critic 신규** |
| M4 | 호출 대상 `cleanupAllBindings` 미존재 + lastSeq 보존을 "가능"으로만 표기 | MAJOR | **Critic 신규** |
| M5 | Day4/A6 테스트가 신규 `attachInternalSession` 경로 대신 P4 기존 InternalSink 필터만 검증 (false-pass) | MAJOR | Architect 확증 |
| m1 | push trigger/C4 dead-until가 7/9에 1급 항목 없음 | MINOR | Architect 확증 |
| m2 | `PushEnvelope`에 `Codable` 미선언 | MINOR | Critic |
| m4 | JSONEncoder date/format 전략 미고정 (shared spec interop) | MINOR | Critic |
| m5 | `prefix(200).count == 200` 단언 취약성 | MINOR | Critic |
| m6 | 마스터 "5분 grace" 무언 삭제 (supersession 근거 부재) | MINOR | Critic |
| m7 | AppDelegate 인용 라인 부정확 (28~31 -> 29~30) | MINOR | Critic |
| m3 | surface seam 타입 표기 `OpaquePointer?` -> `ghostty_surface_t?`로 통일 권고 | MINOR | Critic (사이클 2에서 회귀 유발) |

**반증된 거짓표적 2건** (advisor 자문 + 1차 소스로 반증):
- OpaquePointer 타입 불일치 -> `typedef void* ghostty_surface_t` (ghostty.h:59)로 동일 타입 확증, 제거.
- JSONEncoder round-trip flaky -> Foundation shortest-round-trippable Double로 정확 왕복, MINOR interop 권고로 강등.

---

## v1 -> v2 deltas (Planner 적용)

| 항목 | 변경 | 본문 위치 |
|---|---|---|
| M1 | 의사코드 5.4를 레이어 (a) daemon seam(DaemonTests 게이팅) / (b) app glue(앱 타깃, 비-게이팅)로 분리. Day 4 산출물에 "seam=Daemon, 어댑터=앱 타깃" 명시 + 분리 callout | 5.4, Day 4 |
| M2 | surface lazy 대응: ViewportPollingTimer polling 재사용으로 첫 non-nil surface attach, guard 실패 시 신호 emit. "Architect가 확정" 3곳을 확정 결정으로 교체 | 5.4, Day 4, Risks |
| M3 | `powerObserver` let->var + 생성 순서(registry->invalidator->observer) 명시. "재배선 불필요" 삭제. Day 5 종료조건에 `grep 'var powerObserver'` | 5.5, Day 5 |
| M4 | `cleanupAllBindings`(미존재) -> 신규 `invalidateAllBindings()`(bindings-only, lastSeq 보존). "보존 가능" -> "반드시 보존". Day 5 `clientCount==N` 단언 | 5.5, Day 5 |
| M5 | A6/Day4 종료조건을 신규 `attachInternalSession`->SerialInputQueue spy 경로 + 직렬화 검증으로 교체 | Day 4 |
| m1 | 7에 D7(push trigger/C4 해소) 추가, 9 Risks에 dead-until-C4 1행, 1/4에 placeholder | 1, 4, 7, 9 |
| m2~m7 | Codable 추가, JSONEncoder 전략(epoch-millis/sortedKeys) 고정, preview 종료조건 `==`->`<=` 분리, supersession 문장, AppDelegate 인용 보정, 타입 표기 통일 | 5.1, Day 1 |
| advisor 추가 | 앱 타깃 컴파일 게이트 — Sources/Push를 앱 타깃에도 등록, `xcodebuild build -scheme ClaudeAlarmTerminal` exit 0을 Day0/Day3/Day6/A8/10에 게이팅 (앱 타깃 (g)/(h) 배선 false-pass 방지) | Day 0/3/6, A8, 10 |
| 정화 | 페르소나 누출 3건 -> 중립 기술 표현 교체 | 1 callout, Option B, Risks |

변경 통계: 1,230 -> 1,307 lines (+77).

---

## 사이클 2 — Architect 재심 회귀 적발

### Architect 재심 (SOUND-WITH-CHANGES)

M1~M5 + Critic 신규 2건 전수 닫힘 확증. 단 **회귀 1건** 적발:

- v2가 m3(타입 표기 통일)을 적용하며 5.4 `SurfaceHandleProviding` protocol 반환 타입을 `OpaquePointer?` -> `ghostty_surface_t?`로 변경.
- 이 protocol은 레이어 (a) Daemon 타깃(GhosttyKit 비의존)에 두는데, `ghostty_surface_t`는 `typedef void*` (GhosttyKit 헤더 전용, ghostty.h:59)라 Daemon 타깃에서 컴파일 불가.
- M1이 닫으려던 바로 그 경계 위반이 타입 변경으로 재발. Critic의 m3 권고가 부른 회귀.

개선 2건(비-블로킹): polling attach idempotency 가드, Day0 Sources/Push 앱 타깃 등록(후자는 v2에 이미 존재함을 확인 -> 추가 수정 불요).

---

## v2 -> v3 deltas (오케스트레이터 직접 정정)

| 항목 | 변경 | 본문 위치 |
|---|---|---|
| 회귀 봉합 | 5.4에 `protocol SurfaceHandleProviding: Sendable { @MainActor func surface(forTab:) -> OpaquePointer? }`를 명시 선언 + typealias bridging 주석 4줄. 앱 타깃 conformer `RegistrySurfaceProvider.surface(forTab:) -> ghostty_surface_t?`(== OpaquePointer?, conformance 성립)는 유지 | 5.4 |
| 개선 #2 | wireInternalInput 폴링(250ms 반복) idempotency: "최초 1회만 attach, 이미 부착 세션 skip(attachedTabs Set 가드)" 노트 추가 | 5.4 |
| 개선 #3 | Sources/Push 앱 타깃 등록 — v2 Day0 산출물에 이미 존재(line 518/539/540) -> 추가 수정 불요 | (확인만) |

변경 통계: 1,307 -> 1,319 lines (+12).

---

## 사이클 2 — Critic 최종 verdict: APPROVE

- 5.4 protocol 타입 회귀 닫힘 (HIGH): protocol `OpaquePointer?` 반환으로 Daemon 타깃 GhosttyKit 비의존 유지. conformer `ghostty_surface_t?`는 typealias 동일성으로 conformance 성립.
- v1 적출 12건 + Architect 재심 회귀 1건 전수 닫힘. 회귀 수정 부작용 없음(actor await 정합 확인: `SessionBindRegistry`는 actor, `invalidateAllAttached() async`가 `await`로 호출).
- self-check 전 항목 통과: 한자 0, 페르소나 누출 0, anchor 1:1, span 균형.
- 잔여 ITERATE 사유 없음.

---

## 정착 절차 (plan-documents.md 8) 적용 기록

1. 본문 인라인 사이클 메타 마커 13건 정화: `(M1)`~`(M5)`, `(m6 supersession)`, `(advisor 렌즈)` x3, 문서 버전 "v1 (Planner 초안)" -> "(ralplan 합의 APPROVE)", `★` 기호 2건.
2. 기술 결정 마커 보존: `(R8)` x3, `C1` x5, `C4` x11, `OpaquePointer` protocol seam x4.
3. 본 `p5-history.md` 생성 (v1->v2->v3 deltas + 사이클 verdict 이력).
4. anchor 유효성 재검증: 정화 후 href <-> id 1:1 정합, 깨진 링크 0건.

`Pn 결정 항목` 마커: 본 P5 본문은 해당 표기를 사용하지 않음(기술 결정은 R8/C1/C4 마커로 추적). 보존 개수 0.

---

## 구현 단계 정정 (Day 4)

§5.4 surface 핸들 seam 타입을 `OpaquePointer?` → `UnsafeMutableRawPointer?`로 정정했다.

- 합의 사이클(Architect/Critic) 내내 `typedef void* ghostty_surface_t`가 Swift `OpaquePointer`로 import된다고 판단했으나, Day 4 앱 타깃 컴파일에서 실제로는 `UnsafeMutableRawPointer`로 import됨이 확인됐다(컴파일러: `ghostty_surface_t' (aka 'UnsafeMutableRawPointer')`). `OpaquePointer`는 불완전 struct 포인터용이고, bare `void*` typedef는 `UnsafeMutableRawPointer`가 된다.
- seam 설계 의도(Daemon 타깃 GhosttyKit 비의존)는 영향 없음 — `UnsafeMutableRawPointer`도 stdlib 타입이라 GhosttyKit import 없이 명명 가능. 타입명만 정정.
- 정정 위치: 본문 §5.4 protocol 선언 + 주석, `Sources/Daemon/InternalSessionWiring.swift`, `Sources/ClaudeAlarmTerminal/InternalInputWiring.swift`.
