# P4 Exit Gate to P5 — 검증 기록

대상: P4 상세 계획 (`docs/plans/p4/p4-detailed.html`) §10 Exit Gate to P5.
검증 일자: 2026-06-10. 브랜치: `feat/p4-daemon`.

## 테스트 요약

전체 `DaemonTests` 스위트(8개 클래스 공존): **Executed 44 tests, 0 failures, 0 crashes, 0 warnings**.

```
xcodebuild test -scheme DaemonTests -destination 'platform=macOS'
=> ** TEST SUCCEEDED **  (44 tests / 0 failures)
xcodebuild -scheme DaemonTests build-for-testing 2>&1 | grep -c 'warning:'  => 0
```

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

## 빌드 시스템 메모

- dev CLI 바이너리명은 `daemon-dev-cli` (PRODUCT_NAME, `session-verifier`/`pty-verifier` 규약 일관). 계획서가 가리킨 `DaemonDevCLI` 경로 표기와 다르나 동작은 동일.
- 신규 `.swift` 파일 추가 후 `xcodegen generate`를 먼저 실행해야 빌드 그래프에 편입됨(XcodeGen 정적 스냅샷).
- WS 클라이언트는 `ws://host:port/` URL 엔드포인트로 생성해야 핸드셰이크 성립 (macOS 26). `Sources/Daemon/WSClient.swift` 참조.
