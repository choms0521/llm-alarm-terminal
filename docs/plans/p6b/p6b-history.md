# P6b 상세 계획서 — ralplan 합의 이력

본 문서는 `p6b-detailed.html`이 ralplan 합의 사이클을 거치며 적용된 surgical edits의 추적 이력입니다. 회귀 추적과 의사결정 감사 목적으로 보존됩니다.

- 합의 모드: deliberate (인증·보안 — pre-mortem + 4축 확장 테스트 의무)
- 사이클: 3주기 (Planner v1 → Architect → v2 → Architect → v3 → Architect → Critic APPROVE)
- 판정 이력: Architect ISSUES ×2 → 사실상 SOUND(MINOR 1) → Critic **APPROVE** (2026-06-12)

## 착수 전 사용자 확정 결정

계획 작성 전 4개 설계 분기를 사용자에게 천거하여 확정받았다.

| # | 결정 | 채택 | 기각 대안 |
|---|---|---|---|
| D-1 | tailnet 노출 전략 | Tailscale IP(100.x) 바인딩 | `0.0.0.0`+인증 단층(공격 표면), `tailscale serve` 프록시(운영 복잡도 — 비교 대안으로 본문 보존) |
| D-2 | revoke 후 기존 연결 | 즉시 끊기 | 다음 envelope 거부(누출 창 무한정) |
| D-3 | pending 토큰 처리 | claim 시 승격 (발급=pending 5분) | 코드 만료 시 폐기 sweep(경쟁/누락) |
| D-4 | 만료 7일 전 알림 매체 | 데스크톱 UI callout 실배선 + push seam 예약 | push 단독(모바일 수신부 부재로 dead) |

## v1 → v2 deltas (Architect 1차: CRITICAL 1 + MAJOR 2 + MINOR 3)

| 심각도 | 지적 | 수정 |
|---|---|---|
| CRITICAL | claim 승격 hook(`promoteOnClaim`)이 UI측 PairingModel에 있으나 claim 소비는 데몬측 WSServer — 호출 경로가 없는 dead path. 정상 페어링 디바이스가 5분 후 만료 | 승격을 데몬 레이어 `DevicePromotionCoordinator`로 1점 수렴(revoke Coordinator와 대칭). `PairingSession.issue(payload:deviceId:)` 시그니처 보강 + claim 성공 시 `onClaimed(deviceId:)` 콜백. UI는 refreshDevices polling으로 추종(역방향 통지 채널 신설 금지 — P6a 채널 분리 보존). D-3 옵션 표에 승격 책임 위치 sub-결정(A1 데몬/A2 UI) 추가 |
| MAJOR | `deviceToClient: [UUID: UUID]` 단일 매핑 — 같은 Bearer 동시 2연결 시 두 번째 승격이 첫 연결을 덮어써 revoke가 일부만 끊음(누출 창) | `deviceToClients: [UUID: Set<UUID>]` 다중 매핑 + `disconnectDevice` 집합 전체 순회 cancel + "같은 Bearer 2연결 → revoke → 둘 다 .cancelled, disconnectedCount == 2" 종료 조건 추가 |
| MAJOR | Coordinator "원자성" 주장이 실제 3단계 순차 실행과 모순 | "순서 보장 다단계(원자 아님)"로 전부 정정 + store.revoke 선행 안전 논증(사이 구간 재연결은 verifier `!revoked` 거부) + `disconnectedCount` testable 카운터 + 부분 실패 정책(throw 가능 지점은 store.revoke뿐) 명시 |
| MINOR | IP 변동 시 기존 발급 wsEndpoint stale 미기록 | ADR-F Consequences에 "재바인딩 후 재페어링 필요(payload는 발급 시점 IP 고정)" 추가 |
| MINOR | WSServer init 변경이 기존 8개 호출부를 깨는 경로 | `strategy: BindStrategy = .loopback` 기본값 인자 명시(8개 호출부 무변경) |
| self-check | "DeviceStore protocol 무변경" 주장 2곳이 find 추가와 모순(Planner 자체 색출) | "기존 메서드 무변경 + find 1개 추가"로 3곳 정정 |

분량: 1,485 → 1,561 lines.

## v2 → v3 deltas (Architect 2차: CRITICAL 1 + MAJOR 1 + MINOR 1)

| 심각도 | 지적 | 수정 |
|---|---|---|
| CRITICAL | v2가 도입한 promote가 `revoked: false`를 하드코딩 + find→upsert 비원자 read-modify-write — revoke와 쓰기-쓰기 경쟁 시 폐기된 디바이스가 30일 active로 부활(TOCTOU). revoke는 store 원자 메서드인데 promote만 Coordinator 비원자라는 원자성 수준 비대칭이 근본 원인 | `DeviceStore.promote(id:to:)`를 revoke와 대칭인 store 동작 메서드로 추가 — **revoked면 no-op**, InMemory는 actor 메서드 내 자연 원자, Keychain은 tokenId 조회→revoked 확인→SecItemUpdate를 메서드 안에 묶음. Coordinator는 1줄 위임. "revoke 후 promote가 revoked 유지 + expiresAt 미갱신" 경쟁 테스트를 Day 1 종료 조건에 추가 |
| MAJOR | `DevicePromotionCoordinator`가 mutating struct — `@Sendable` onClaimed 콜백이 캡처 불가, promotedCount가 값 복사본에 갇혀 테스트 어서션 불가. revoke Coordinator와 비대칭 | 두 Coordinator 모두 **actor**로 통일 — promotedCount actor 격리, 콜백에서 `await coordinator.promote(deviceId:)`. disconnectedCount는 WSServer 단일 출처 유지(중복 카운터 배제) |
| MINOR | revoke↔promote 경쟁이 Risk 표·pre-mortem에 누락 | Risk 1행 + pre-mortem 시나리오 2b("폐기한 디바이스가 마침 claim 중이라 되살아남") 추가 — 3 시나리오 → 4 시나리오 (TOC/개요/§7.1/Exit Gate 4곳 정합) |

분량: 1,561 → 1,621 lines.

## v3 → 최종 (Architect 3차: 잔존 MINOR 1 / Critic APPROVE: 비차단 권고 2)

| 출처 | 지적 | 수정 |
|---|---|---|
| Architect MINOR | DaemonDevCLI `--pair`가 PairingModel 미경유라 pending upsert 발급 시퀀스가 누락되면 promote가 미존재 no-op — e2e 위양성 위험 | Day 1 산출물에 드라이버 발급 시퀀스(`deviceId 생성 → pending store.upsert → issue(payload:deviceId:)` 인라인 재현) 명시 |
| Critic 권고 1 | 부채 지점 라인 인용 불일치(`50~59` vs `48~83`) | `48~84` + 핵심 라인(51 30일 부여, 59 upsert)으로 통일 |
| Critic 권고 2 | `excludedCount`를 "PushSender 선례"로 표기 — 기존 메서드로 오인 가능 | "P6b 신규 — 기존 rejectedCount 패턴 차용"으로 정정 |

Architect 3차에서 신규 점검 4항목(promote의 secret 보존, deviceId 인과 정합, protocol 7메서드 양 conformer 구현 가능성, 기존 383 테스트 무파손 — Tests 내 DeviceStore 별도 conformer 0건 실측) 전부 SOUND. Principle 위반 0건.

## Critic 최종 평가 (APPROVE)

- 8개 기준 전부 PASS: Principle-Option 일관성 / 공정한 대안 비교(옵션 C 장점 정직 인정 후 기각) / Risk 완화 구체성(11행 전부 Day 종료 조건 연결) / 수락 기준 측정성(A1~A13 구체 명령+명시 결과, 모호 표현 0건) / Day별 종료 조건 측정성 90%+ / deliberate 의무(pre-mortem 4 시나리오 3축 + 4축 테스트) / 형식 규약(11섹션 순서, 1,621 lines, 한자·페르소나 0건) / 실행 가능성(8개 호출부 무변경 실측, 383 비파괴 산식)
- 잔존 권고는 전부 비차단이며 본 이력 표의 "v3 → 최종"에 반영 완료
