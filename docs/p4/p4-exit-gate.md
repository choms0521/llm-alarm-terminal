# P4 Exit Gate to P5 — 검증 기록

대상: P4 상세 계획 (`docs/plans/p4/p4-detailed.html`) §10 Exit Gate to P5.
검증 일자: 2026-06-10. 브랜치: `feat/p4-daemon`.

## 테스트 요약

전체 `DaemonTests` 스위트(8개 클래스 공존): **Executed 44 tests, 0 failures, 0 crashes, 0 warnings**.

```
xcodebuild test -scheme DaemonTests -destination 'platform=macOS'
=> ** TEST SUCCEEDED **  (44 tests / 0 failures, 0 crashes)
```

### 경고(warning) — 정직성 메모

P4 코드(`Sources/Daemon`, `Sources/DaemonDevCLI`, `Sources/TerminalView/GhosttySurfaceInjector.swift`,
`Tests/DaemonTests`) 한정 경고: **0건**.

종료조건 #4의 "build-wide `grep -c 'warning:'` == 0"은 **robust하게 충족 불가**하다. 빌드 전역을
clean 컴파일하면 기존 코드베이스의 Swift 6 language-mode 경고 4건이 표출된다(모두 P4 미수정 파일):

- `Sources/Session/Session.swift:39` — `Session`의 `ptyHandle`이 non-Sendable `PTYHandle` 보유
- `Sources/UI/AgentView/AgentJumpAction.swift:22` — `Handler` 적합성이 main actor 경계 교차
- `Sources/UI/AgentView/ViewportPollingTimer.swift:40` (x2) — nonisolated에서 `NSApp`/`isActive` 참조

이들은 incremental 캐싱 시 재컴파일되지 않아 0으로 보일 뿐이며 P4 도입분이 아니다(git: 세 파일 P4
브랜치 미수정). P4는 경고를 추가하지 않았다. 전역 Swift 6 경고 정리는 별도 작업으로 권고한다.

| 클래스 | 범위 | Day |
|---|---|---|
| EnvelopeCodecTests | seq u64 string(2^53+1), 9 kind, malformed/nonMonotonic, 비-UTF8 거부 | 1 |
| SessionRingBufferTests | 경계 drop, BUFFER_OVERFLOW_DROPPED 1회 래치, 리셋 | 2 |
| SessionBindTests | loopback bind, NON_MONOTONIC_SEQ, disconnect 정리/PTY 생존, 10회 기동 | 3 |
| SerialInputQueueTests | 2-executor strict FIFO, 단일 consumer, control 미지원 | 4 |
| Utf8StreamAccumulatorTests | 경계 재조립, malformed U+FFFD | 5 |
| RoundTripTests | external 출력 라운드트립, INTERNAL_OUTPUT_UNSUPPORTED, PTY_WRITE_FAILED | 5 |
| AcceptanceTests | end-to-end A1 라운드트립, A2 flood drop-mark | 6 |
| DaemonSmokeTests | 빌드 그래프 시드 | 0 |

## Exit Gate 체크리스트 (§10)

- [x] Day 0: project.yml 신규 타깃 등록 + `xcodegen generate`/`build-for-testing` exit 0 (A0). C4 spike 옵션 3개 (`docs/p4/c4-output-tap-spike.md`).
- [x] Envelope codec v0.9 + 9 kind 라운드트립(pause/resume round-trip) + seq string(2^53+1) green.
- [x] SessionRingBuffer 메시지 경계 drop + BUFFER_OVERFLOW_DROPPED 1회 래치 green.
- [x] WS server loopback listen + session.start bind + per-client seq 모노토닉 wire 거부 + disconnect 시 attach 정리/PTY 생존 green. (loopback-only: pid-scoped `lsof` 127.0.0.1 LISTEN x1, 비-loopback 0 — `--serve-probe`로 실측.)
- [x] SerialInputQueue 2-executor strict FIFO + 동시 write 구조 금지 + A7 intra-queue 순서 green.
- [x] external 입출력 라운드트립(한국어/emoji) + `Utf8StreamAccumulator` 강제 split 재조립(A9) + internal printable 입력 주입 green. (단 C2 read-back은 아래 부채 참조.)
- [x] internal 미지원 능력 명시 신호(A10): INTERNAL_OUTPUT_UNSUPPORTED / INTERNAL_CONTROL_INPUT_UNSUPPORTED / PTY_WRITE_FAILED green.
- [x] dev CLI 라운드트립/flood 데모 exit 0: `daemon-dev-cli --roundtrip` (`가나다` x2), `daemon-dev-cli --flood` (`BUFFER_OVERFLOW_DROPPED` x1).
- [x] WS envelope v0.9 공통 필드 안정 — P5 push envelope base로 재사용 가능.

## 명시 부채 (P5+ 이월)

| # | 부채 | 근거 | 이월처 |
|---|---|---|---|
| (a) | `.internal` byte-faithful 출력 미지원 (C4) — INTERNAL_OUTPUT_UNSUPPORTED | ADR-P4-3, `docs/p4/c4-output-tap-spike.md` 결정 게이트 | P7 freeze 전 결정 게이트 |
| (b) | `.internal` control byte 입력 미지원 (C1) — INTERNAL_CONTROL_INPUT_UNSUPPORTED | ADR-P4-4 | internal 출력 tap phase |
| (c) | C2 런타임 read-back 수동 sign-off (헤드리스 검증 불가, 입력 경로는 실 구현·컴파일 확증) | `docs/p4/c2-internal-input-signoff.md`, W-3-1 선례 | 수동 sign-off |
| (d) | R8 cross-origin 비추월 P4 미검증 (external에 GUI keystroke 경로 부재) | A7 caveat | internal 실사용 wiring phase |
| (e) | output 포워딩 FIFO best-effort (Task-per-envelope hop) — P4는 단일 메시지만 | `ExternalSessionWiring.swift` 주석 | P5 serial 출력 포워더 |
| (f) | `PTYWriter` EAGAIN usleep spin 고부하 블로킹 | §9 Risks | DispatchIO write 전환 검토 |

## Phase 4 다관점 검증 패널 (2026-06-10)

architect / security-reviewer / code-reviewer 3개 병렬 심사 — **전원 APPROVE, CRITICAL/HIGH 0건**.

### 즉시 토벌한 결함 (이 커밋에서 수정)

| 출처 | 결함 | 조치 |
|---|---|---|
| architect MEDIUM | `isControl`가 단일바이트(`< 0x20`)만 탐지 → 다바이트 ESC/CSI를 printable로 오인 | 탐지를 `InputItem.containsControl`(바이트 기반, `< 0x20` 또는 `0x7f`)로 이관, `InternalSink`가 권위. 다바이트 ESC 테스트 추가 |
| code-reviewer MEDIUM | `testTeardownPendingZero` 공허(detach가 nil 처리 → 누수 관측 불가) | drain 후 `pendingCount == 0`을 detach 전에 단언(실 itemDrained 검증) |
| code-reviewer MEDIUM | `droppedCount` 항상 1인데 `droppedSinceReset` 누적이 wire에 미반영(dead) | dead `droppedSinceReset` 제거, 단일 overflow 마커(`droppedCount:1`)로 정직화 + 주석. `code`를 `DaemonErrorCode` 통일 |
| code-reviewer LOW | 깨진 `session.start` sessionId 시 무응답(클라이언트 hang) | `MALFORMED_PAYLOAD` error 발행 |
| code-reviewer LOW | drop mark 값 미단언 | `droppedCount:1` 값 단언 추가 |

### 이연 결함 (부채로 명시)

| 출처 | 결함 | 이월처 |
|---|---|---|
| security MEDIUM | `SerialInputQueue` AsyncStream 무한 버퍼(`.unbounded`) — 로컬 DoS/heap | P6 (원격 노출 전). 단순 drop은 입력 손실이라 backpressure/overflow-signal 설계 필요 |
| security MEDIUM | `PTYWriter` EAGAIN usleep spin 비취소성 — consumer wedge | 부채 (f). DispatchIO write 전환 |
| security LOW | 동시 연결 수 cap / idle timeout 부재 | P6 |
| security LOW | monotonic seq는 연결내 순서 보장일 뿐 cross-connection replay guard 아님 | P6 (인증 도입 시) |
| architect/code LOW | ring buffer가 live 출력 경로 미통합(데모/단위테스트 전용) | P5 (정렬·버퍼 출력) |
| architect/code LOW | `ExternalSessionWiring` 단일 세션 구조(masterFD 캡처) | P5 (다세션 fd 조회) |
| code-reviewer LOW | `session.exit`/`session.terminated` wire teardown 미처리 | P5 |
| code-reviewer LOW | `OutputTap.seq` vestigial(서버가 재stamp), `ResumeOnce`/`OnceFlag` 중복 | 정리 cosmetic, P5 |
| code-reviewer LOW | `droppedCount` 정확 per-episode 카운트 | P7 wire freeze 결정 |

전수 재검증: 수정 후 전체 `DaemonTests` 스위트 재실행 green(아래 갱신).

## 빌드 시스템 메모

- dev CLI 바이너리명은 `daemon-dev-cli` (PRODUCT_NAME, `session-verifier`/`pty-verifier` 규약 일관). 계획서가 가리킨 `DaemonDevCLI` 경로 표기와 다르나 동작은 동일.
- 신규 `.swift` 파일 추가 후 `xcodegen generate`를 먼저 실행해야 빌드 그래프에 편입됨(XcodeGen 정적 스냅샷).
- WS 클라이언트는 `ws://host:port/` URL 엔드포인트로 생성해야 핸드셰이크 성립 (macOS 26). `Sources/Daemon/WSClient.swift` 참조.
