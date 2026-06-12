# Open Questions

상세 계획서 작성·합의 과정에서 도출된 미해결 항목을 단일 위치에서 추적한다.
각 항목은 결정 시점(단계) + 결정 내용 + 영향을 명시한다.

## P6b (토큰 lifecycle + Tailscale 통합) - 2026-06-12

### Architect v2 검토로 확정된 결정 (참고)
- [x] claim 승격 책임 위치 — **데몬 레이어 `DevicePromotionCoordinator` 확정**. UI측 승격 hook은 claim 미경유로 dead path(정상 디바이스 5분 만료 버그). revoke Coordinator와 대칭 설계. `PairingSession.issue(payload:deviceId:)` 시그니처 보강 + `onClaimed` 콜백 + `DeviceStore.promote(id:to:)` 원자 동작 메서드 추가 동반 (v3에서 `find(byDeviceId:)` 기반 read-modify-write 대신 채택 — revoked no-op으로 부활 차단). UI는 refreshDevices polling으로 stale 흡수
- [x] revoke 역인덱스 다중 연결 — **`[deviceId: Set<clientId>]` 확정**. 같은 Bearer 동시 N연결을 단일 매핑이 덮어쓰는 누출 회귀 차단. `disconnectDevice`가 집합 전체 cancel
- [x] Coordinator "원자성" — **"순서 보장 다단계"로 정정**. 원자 트랜잭션 아님. store.revoke 선행이 사이 구간 재연결을 verifier가 거부해 안전. throw 가능 지점은 store.revoke뿐

### 미해결 (후속 단계 결정)
- [ ] Tailscale IP 변동 자동 재바인딩 — 현재는 진단 + 수동 재시작. 무중단 자동 재바인딩은 post-MVP로 이연. ADR-F에 명문화됨 — 사용자 경험상 IP 변동이 잦으면 우선순위 상향 필요
- [ ] `fetch.response` kind 형식 (전용 kind vs `output` 재전송) — P7 freeze 결정 대상. P6b는 의미만 명세(§8.2). 모바일 본문 보강(P10b)이 의존
- [ ] ring buffer drop 시 fetch 응답 형식 (에러 code vs 빈 본문+플래그) — P7 freeze 결정. drop-and-mark 한국어 표시(P10b)와 정합 필요
- [ ] `messageId` 발급 형식 (u64-string vs UUID vs 복합키) — P7 freeze 결정. ADR-A의 "데스크톱 단조 발급" 전제 + seq u64-string 규칙과 정합되어야
- [ ] push 만료 알림 발신 호출자 — 만료 7일 전 push 알림은 P6b에서 seam만 예약(D-4). 실 발신은 모바일 수신부(P10a) + push trigger(D-7, C4 해소) 후. UI callout은 P6b에서 실배선
- [ ] revoked push 발신 제외 필터의 실 호출자 — P6b는 `sendIfNotRevoked` 필터 로직 + 단위 검증만. 실 push 발신 경로(D-7 dead-until-C4)는 P6+/S1이 배선
- [x] D-1 옵션 최종 확정 — Day 0 스파이크가 비-loopback 바인딩의 인터페이스 격리를 실증해 **옵션 A(Tailscale IP 바인딩) 확정** (`.omc/research/p6b-tailscale-spike.md`). C(`tailscale serve`) 폴백 불요. 전제 조건(Running 게이트 + listener `.waiting` 표면화)은 Day 2/4에 배선 완료
