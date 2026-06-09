# P4 상세 계획 — ralplan 합의 이력

본 문서는 `p4-detailed.html`이 ralplan 합의 사이클을 거치며 적용된 surgical edits의 추적 이력입니다. 회귀 추적과 의사결정 감사 목적으로 보존됩니다.

대상 phase: 마스터 계획 `docs/plans/work-plan-v4.md` line 156~184 (P4. WebSocket 서버 + 인프로세스 데몬 골격). 합의 워크플로: Planner → Architect → Critic (사이클 2회). 최종 판정: **APPROVE** (차단 결함 0).

---

## 합의 경로 요약

| 사이클 | 산출 | Architect | Critic | 결과 |
|---|---|---|---|---|
| 1 | Planner v1 (564줄) | ITERATE (6항목) | ITERATE (6 확증 + 신규 CRITICAL 2) | v2 편집목록 12건 도출 |
| 2 | Planner v2 (605줄) | ITERATE (D1/D2 신규 2) | **APPROVE** (D1/D2 해소 확증, 회귀 0) | v3 (610줄) 확정 → `docs/` 정착 |

핵심 수렴 설계: seq-string codec, message-boundary drop ring buffer, Option A single-writer 큐(sink 경계 유지), origin 비대칭 2-sink(external FD / internal libghostty), `Utf8StreamAccumulator`(출력 chunk 경계 재조립), Day 0 C4 feasibility spike.

---

## 사이클 1 — v1 리뷰 (Architect + Critic 동시 ITERATE)

### Architect v1 (6항목, 코드 확증)

| # | 항목 | severity | 근거 |
|---|---|---|---|
| 1 | §1 Goal 과대표기("input/output 송수신") | MAJOR | 실사용 100% `.internal`(`WorkspaceCoordinator.swift:39,94,177` createInternal), internal 출력 deferred |
| 2 | C4 미해결 + 책임 phase 부재 | MAJOR | `ghostty.h:1018~1027` 콜백 set에 raw output tap 부재 |
| 3 | control-byte 입력 hand-wave | CRITICAL | `GhosttyTerminalView.swift:412~414` control은 libghostty가 keycode+mods 인코딩, ESC 다중 byte 역매핑 불가 |
| 4 | ExternalSink 데이터 손실 + actor 블로킹 | CRITICAL | raw `Darwin.write` 반환값 폐기, masterFD `O_NONBLOCK`(`PTYSpawner.swift:42`)이라 실제 유실. `PTYWriter`(`:160`) 이미 존재 |
| 5 | UTF-8 출력 누산기 누락 | CRITICAL | `PTYReader.swift:34` lowWater 1로 chunk 경계 분할, `Utf8BoundaryTruncator`는 truncate 유틸 |
| 6 | 테스트 과대주장 | MAJOR | A7은 단일 소스 intra-queue FIFO만, R8 cross-origin 미검증 |

Synthesis: external 골격 유지 + Goal 정직화 + C4/C2/Z2를 Day 0 spike로 전진.

### Critic v1 (Architect 6 전수 동의 + 신규 적발)

- **C-1 [CRITICAL]** 빌드 시스템 불일치: 프로젝트는 XcodeGen(`project.yml`) + xcodebuild인데 검증 명령 8건이 SwiftPM(`swift run/test/build`) → 단 하나도 실행 불가.
- **C-2 [CRITICAL]** 신규 6개 타깃 project.yml 등록 step 부재 → 산출물 컴파일 불가.
- **C-3 [MAJOR]** `validateMonotonic` unwired dead-check (호출지점/lastSeq 보유자 미명시).
- **C-4 [MAJOR]** pause/resume dead-spec (정의만, 동작/종료조건 0).
- **C-5/C-6 [MINOR]** print grep 거짓음성, 형식.

### v1 → v2 deltas (통합 편집목록 12건)

| 우선 | # | 편집 | 출처 |
|---|---|---|---|
| P0 | 1 | swift → xcodebuild 전수 전환(8건) | C-1 |
| P0 | 2 | Day 0 project.yml 타깃 등록 + scheme + xcodegen | C-2 |
| P0 | 3 | control-byte 정직화: InternalSink printable-only + `INTERNAL_CONTROL_INPUT_UNSUPPORTED` + ADR-P4-4 | Arch#3 |
| P0 | 4 | ExternalSink가 `PTYWriter.write` 재사용(데이터 손실 0) + 블로킹 severity 분리 | Arch#4 |
| P0 | 5 | `Utf8StreamAccumulator` 신설 + A9 강제 mid-multibyte split 테스트 | Arch#5 |
| P1 | 6 | §1 Goal 정직화(internal=printable 입력만) | Arch#1 |
| P1 | 7 | C4 feasibility spike Day 0 전진 + P7 freeze 게이트 | Arch#2 |
| P1 | 8 | `validateMonotonic` 호출지점(`SessionBindRegistry.ingestInbound` + per-client lastSeq) | C-3 |
| P1 | 9 | pause/resume reserved 명문화(round-trip만) | C-4 |
| P1 | 10 | 테스트 과대주장 시정(A7 cross-origin 한계, A1/A5 split 한계, A9/A10) | Arch#6 |
| P2 | 11 | Risks 신규 위험 2건(EAGAIN 손실, 타깃 미등록) | C-5 |
| P2 | 12 | print grep 수정 + warning xcodebuild 측정 | C-5 |

변경 통계: 564줄 → 605줄. swift 명령 8 → 0. Day 6 → 7(Day 0 추가). 신규 ADR 1건(P4-4). 신규 컴포넌트 1건(`Utf8StreamAccumulator`).

---

## 사이클 2 — v2 리뷰 (Architect ITERATE → Critic APPROVE)

### Architect v2 (12항목 전수 해소 확인, surgical edit 부작용 2건 적발)

- **D1 [MAJOR]** effort 산술 자가당착: Day 합 8.5일 > "L 5~8일" 상한 (Day 0 추가 시 envelope 미재기준).
- **D2 [MAJOR]** ExternalSink hard-failure 에러 방출 미배선: `catch { /* */ }` 빈 주석, InternalSink `onUnsupported`와 비대칭 → `PTYWriter.write` throw(`PTYError.fcntlFailed`) 삼키면 silent drop 회귀.
- 비차단: `Utf8StreamAccumulator` carry 무한 적체(비후행 malformed byte) robustness 메모.

### v2 → v3 deltas

| # | 편집 | 출처 |
|---|---|---|
| D1 | Day 0 소요 1일 → 0.5일(C4 spike는 document-specialist 병렬 위임). Day 합 8.0일. Effort 라벨 정합 + contingency 6~10일(`work-plan-v4.md:585`) 참조 | Arch v2 D1 |
| D2-a | ExternalSink에 `onError: (String) -> Void` 콜백 추가(InternalSink 대칭) | Arch v2 D2 |
| D2-b | catch에서 `onError("PTY_WRITE_FAILED")` 발행(silent drop 차단) | Arch v2 D2 |
| D2-c | Day 5 종료조건: `PTYWriter.write` throw mock 주입 시 `PTY_WRITE_FAILED` 정확히 1회 | Arch v2 D2 |
| D2-d | §7 schema error code에 `PTY_WRITE_FAILED` 등재 | Arch v2 D2 |
| D2-e | Risks 표: hard-failure를 onError 직접 검증으로 승격 | Arch v2 D2 |
| R | `Utf8StreamAccumulator` carry 상한(4 byte) + U+FFFD flush + Day 5 종료조건 + Risks 1행 | Arch v2 robustness |

변경 통계: 605줄 → 610줄. Day 합 8.5 → 8.0일(L 5~8 정합). ExternalSink 에러 콜백 배선(silent drop 회귀 종결). carry edge robustness 3영역 일관.

### Critic v2 (최종 게이트) — APPROVE

- D1/D2/robustness 전부 해소 확증. 사이클 1의 12개 항목 회귀 0. swift 0, 한자 0, 측정성 100%.
- 차단 결함 0. 비차단 MINOR 3건은 `docs/` 정착 punch-list로 처리(4번째 사이클 ROI 미달, ralplan §9).

### 정착 punch-list (v3 → docs/ 적용 완료)

| # | MINOR | 정착 처리 |
|---|---|---|
| 1 | 버전 라벨 stale("v2 초안") | 제목/서술 "v3 (Critic APPROVE)"로 갱신 |
| 2 | line 인용("163~184") | P4 절 실제 line 156~184로 정정(Effort 행 585는 정확) |
| 3 | 의사코드 String/enum 혼용 | §5.3 구현 메모 추가(구현 시 `DaemonErrorCode` enum 통일 권고) |

---

## 합의 비용

- 합의 사이클: 2회 (Planner 1 + Architect 2 + Critic 2). ralplan 비용 가이드(§9) 1~3 사이클 범위 내, 5회 상한 미만.
- 사이클 1에서 빌드 시스템 불일치(C-1) + 타깃 미등록(C-2)을 사전 적발하여, 구현 단계에서 빌드 불가 명령으로 검증을 시도하는 함정을 회피.

## 참고 (합의 사이클 원본 리뷰)

사이클별 상세 리뷰는 합의 진행 중 `.omc/plans/`에 보존되었다(정착 시 정리). 본 history가 그 deltas를 통합 보존한다.
- Architect v1 / Critic v1 / Architect v2 / Critic v2 리뷰 전문.
