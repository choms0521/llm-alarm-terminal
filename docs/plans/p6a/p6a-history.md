# P6a 상세 계획서 — ralplan 합의 이력

본 문서는 `p6a-detailed.html`이 ralplan 합의 사이클을 거치며 적용된 surgical edits의 추적 이력입니다. 회귀 추적과 의사결정 감사 목적으로 보존됩니다.

- 합의 절차: Planner → Architect → Critic, 총 4주기 (deliberate 모드 — 보안/인증 영역)
- 최종 판정: **APPROVE** (Critic 4주기, 2026-06-11)
- 분량 추이: v1 1,210줄 → v2 1,299줄 → v3 1,315줄 → v4 1,334줄

## 주기 요약

| 주기 | Planner | Architect | Critic |
|------|---------|-----------|--------|
| 1 | v1 초안 | SOUND-WITH-CONCERNS (BLOCKER 2, MAJOR 2, MINOR 4) | ITERATE (정정 지시 8건) |
| 2 | v2 정정 (8건 반영) | SOUND-WITH-CONCERNS (BLOCKER 0, 신규 MAJOR 1, MINOR 3) | ITERATE (정정 지시 4건) |
| 3 | v3 정정 (4건 반영) | SOUND-WITH-CONCERNS (신규 MAJOR 1: FIFO cross-소비) | ITERATE (정정 지시 3건) |
| 4 | v4 정정 (nonce 도입, 3건 + Architect MINOR 3건 반영) | **SOUND** (BLOCKER/MAJOR 0) | **APPROVE** |

## v1 → v2 deltas

| 영역 | v1 | v2 | 분류 |
|------|----|----|------|
| §5.3 게이트 ② | envelope self-asserted `actor.deviceId` 검증 (동어반복 — 유효 토큰 탈취자가 해당 deviceId를 적으면 통과) | carry-over 일치 증명 (`pendingAuth` 등록 → 첫 envelope 시간창 일치 + secret 대조 → 승격). 채워질 수 없는 `connectionBearer[clientId]` 매핑 제거 | C1 (BLOCKER) |
| §5.3 handleMessage 순서 | 인증을 decode/seq 검사 뒤에 배치 (미인증 연결이 registry seq·PTY 부수효과 오염 가능) | decode → 게이트 ②(인증) → ingestInbound(seq) → bind 순서 고정, "인증 미통과 시 registry 미진입" 명문화, Day 2 종료 조건에 seq 불변 어서션 | C2 (BLOCKER) |
| §5 claim wire | pairing claim endpoint가 산문으로만 언급, 요청/응답 스키마 부재 | §5.5 신설 — `pairing.claim`/`pairing.response` EnvelopeKind 2종 + JSON payload 스키마 + claim 채널 격리 원칙(claim은 연결을 승격하지 않음), Exit Gate에 P7 freeze 대상 편입 명시 | M1 (MAJOR) |
| Principle 3 | "envelope payload 평문 금지" (claim 응답의 secret 전송과 자기모순 가능) | "운영 envelope(input/output/ack 등) payload" 한정, `pairing.response`를 명시적 예외(페어링 전용·loopback 한정·일회성)로 명문화 | M2 (MAJOR) |
| Day 2 마이그레이션 grep | `WSClient(` 만 검사 (raw NWConnection 직접 사용 테스트 2종 누락) | `NWProtocolWebSocket.Options|NWConnection(to:` 확장 + `BootstrapWSClient`/`WSTestClient` Bearer 마이그레이션 명시 산출물화 | M3 |
| §5.1 DeviceStore | protocol에 `find(byTokenId:)` 누락 (verifier 의사코드와 모순) | `func find(byTokenId: String) async throws -> Device?` 추가, upsert 시 옛 secret replace 명문화 | m1 |
| 게이트 ① 선택 근거 | "자원/리소스 절약" (loopback에서 무가치 — Architect 스틸맨) | "P6b tailnet 대비 + 인증 격리점 선확보"로 교정 | m2 |
| 보강 | — | carry-over 시간창 10초(부록 A `PENDING_WINDOW`), pane 영속 P9 책임 적시, pre-mortem 시나리오 4(claim replay/재페어링 무효화) 추가 | m3·m4·gap |

## v2 → v3 deltas

| 영역 | v2 | v3 | 분류 |
|------|----|----|------|
| §5.3 토큰 운반 매체 | 게이트 ② 의사코드가 첫 envelope에서 Bearer 추출(`bearerTokenId(env)`/`bearer(env)`) — WS 핸드셰이크 헤더 첨부 명세와 자기모순 (헤더로 보낸 토큰은 envelope 바이트에 부재, WSEnvelope에 토큰 필드도 없음) | **토큰은 핸드셰이크 `additionalHeaders` 단일 매체, 첫 envelope에는 다시 싣지 않음**(WSEnvelope 스키마 무변경). 게이트 ①이 헤더 Bearer를 구조 분해해 `(tokenId, presentedSecret)`를 pendingAuth에 carry, 게이트 ②는 첫 envelope 도착 사실을 트리거로 consumePending 후 constant-time secret 대조. line 449 "envelope에 Bearer 동봉" 허구 의존성 교정. 옵션 B 폴백에도 동일 carry 규약 | MAJOR-1 |
| Acceptance | 운반 매체 검증 항목 부재 | A12 신설 — 첫 envelope payload에 토큰/secret 문자열 부재 XCTAssertFalse + 헤더 Bearer 제거 시 인증 실패. Day 2 종료 조건에도 동일 측정 추가 | MAJOR-1 propagate |
| Day 2 동시성 테스트 | 순차 시나리오만 측정 | 동일 tokenId 2연결 동시 핸드셰이크 → 정확히 1연결만 승격 XCTAssertEqual 추가, consumePending first-consume-wins 원자성 명문화 | MINOR-1 |
| SDK callout | 옵션 A/B 인증 실패 신호 차이 미명세 | 옵션 A는 핸드셰이크 무신호 reject, 옵션 B는 UNAUTHORIZED 에러 envelope 후 close — 진단 신호 분기 명시 | MINOR-2 |

## v3 → v4 deltas

| 영역 | v3 | v4 | 분류 |
|------|----|----|------|
| 게이트 ① 의사코드 | `registerPending(tokenId:secret:at:)` — pendingAuth 키가 tokenId | `X-Pair-Nonce` 헤더(클라이언트가 연결마다 신규 무작위 생성) 추출 + `isNonceRegistered` 중복 거부 + `registerPending(nonce:tokenId:secret:at:)` — 키=nonce | C1 (CRITICAL) |
| 게이트 ② 의사코드 | `consumePending(within:)` — connection 식별 인자 없이 "시간창 내 가장 오래된 항목" FIFO 소비. 서로 다른 토큰의 동시 핸드셰이크 시 identity 교차 바인딩(시나리오 X), 가짜 Bearer 편승자의 무자격 승격(시나리오 Y) 성립 | 첫 envelope payload가 echo한 nonce로 `consumePending(nonce:within:)` — 그 connection의 항목만 소비. nonce 미echo/미등록 UNAUTHORIZED. nonce는 일회성 공개값이라 payload echo가 Principle 3과 무관 | C1 |
| §5.3 callout ×2 + 시간창 callout | "도착 사실 자체가 증명" / "first-consume-wins" / "가장 오래된 항목 점유" | "nonce echo 일치 증명" / "nonce 일치 항목만 점유·제거(1회 소비, replay 방지)" | C1 |
| 전 영역 propagate | tokenId 등록 + 도착 사실 소비 서술 | nonce 키 등록 + nonce echo 매칭 — §1 Scope/Deliverable/Dependencies, §2.1 P1, §2.3 옵션 A·B·선택 근거, §4 ASCII 다이어그램, Day 2 기술 노트(WSClient nonce 생성·첨부·echo 마이그레이션), §7.2, pre-mortem 4, 부록 A 등 13곳 | C1 propagate |
| Day 2 종료 조건 / Acceptance | 동일 tokenId 2연결 1행, A12까지 | 기존 행은 nonce 중복/미echo 거부 검증으로 의미 보존 + 서로 다른 토큰 Ta≠Tb 동시 핸드셰이크 → 각 connection이 자신의 tokenId로 승격·identity 교차 0건 XCTAssertEqual 신규, A13 신설 | MINOR-1 |
| 시간창 callout | secret 메모리 위생 미명세 | "pendingAuth의 presentedSecret은 consume 또는 만료 즉시 메모리에서 폐기(참조 해제)하고 어떤 경로로도 로그하지 않는다" 추가 | MINOR-2 |
| nonce 명세 (Architect 4주기 MINOR 흡수) | 형식/엔트로피/echo 위치 미명세 | nonce = `SecRandomCopyBytes` 16바이트 base64url, 충돌(reject) 시 재생성. echo 위치 = `session.start` payload JSON `"nonce"` 필드 합류, 타 kind 선도착 시 UNAUTHORIZED | MINOR |
| §6 ADR-A | "pane이 영속이면 보존"만 서술 | pane 영속(workspace JSON persistence)은 P2 스키마가 보장, chatRoomId의 모바일 배선 책임은 P9에 있음을 명시 | 경미 |
| §10 Exit Gate | "A1~A11 수락 기준 전부 통과" | "A1~A13"으로 산술 갱신 (Critic 비차단 권고) | 라벨 |

## 변경 통계

- 총 정정 지시: 1주기 8건 + 2주기 4건 + 3주기 3건 + Architect 4주기 MINOR 3건 + 비차단 라벨 1건 = **19건**
- 핵심 수렴 서사: WS 인증 게이트 ②의 "connection ↔ 핸드셰이크 결합" 문제가 4주기에 걸쳐 정면 해소됨 — v1 `connectionBearer`(채워질 수 없는 매핑) → v2 "envelope Bearer 재운반"(스키마/Principle 3 충돌) → v3 "FIFO 익명 매칭"(cross-소비 표면) → v4 **클라이언트 자기-식별 nonce**(`X-Pair-Nonce` 헤더 등록 + 첫 envelope echo 매칭). SDK가 제공하지 않는 connection 식별자를 클라이언트가 공급하는 구조로 종결
- 역할 분리 확립: nonce = connection 식별(일회성 공개값), secret = 인증 실질(constant-time 대조) — nonce 노출이 인증을 약화시키지 않음

## 미해결 이연 항목 (계획 본문에 반영된 상태로 종결)

- claim 채널의 pre-auth 본질 — loopback + 일회성 + rate-limit으로 제한, P6b tailnet 노출 시 재평가 (본문 §5.5·D-5에 명시)
- wsEndpoint=loopback의 P6b tailnet 전환 시 재페어링 비용 — P6b 계획에서 확정 (Device.expiresAt 자연 만료 흡수 검토)
- Day 0 스파이크 실패 시 옵션 B 폴백 — 폴백 결정을 Day 2 착수 전 확정, carry 규약은 양 옵션 동일하므로 dead code 없음 (본문 §5.3에 명시)
- nonce 캡처 위협 모델 — loopback 패킷 캡처/메모리 읽기는 root 전제라 신규 표면 아님, P6b에서 전송 채널 암호화로 자연 해소
