# Development Master Plan v2 — 남은 단계 개념 정리

문서 작성일: 2026-06-11 (P5.5 편입: 2026-06-11)
기반 문서: `docs/plans/work-plan-v4.md` (마스터 단계 분해)
성격: **개념 위주 요약**. 각 단계의 상세 구현 계획(day-by-day)은 단계 진입 시 ralplan으로 별도 작성한다(`docs/plans/p5.5/`, `docs/plans/p6a/` 등).

---

## 1. 현재 위치

| 단계 | 상태 |
|------|------|
| P1 단일 PTY + libghostty | 완료 |
| P2 다중 세션 + 워크스페이스 탭 + 분할 | 완료 |
| P3 / P3.5 agent-view 대시보드 + 탭 시스템 | 완료 (REQ-5 P5.5에서 CLOSED, W-3-1 1건 잔존, §5) |
| P4 WS 서버 + 인프로세스 데몬 골격 | **완료 — PR #1 main 병합** (Copilot 리뷰 6건 수정 포함) |
| P5 Push Sender + FCM/APNs 골격 (mock-first) | **완료 — PR #2 main 병합** (Copilot 리뷰 10건 수정 포함) |

P5까지 데스크톱 데몬의 코어 파이프라인(PTY ↔ WS envelope ↔ Push seam)이 mock 수준에서 end-to-end 검증된 상태다. 실 외부 인프라(FCM/APNs)와 페어링/보안 계층이 남아 있다.

---

## 2. 남은 단계 한눈에

```
[현재] → P5.5 → P6a → P6b → S1 → [P7 PROTOCOL FREEZE GATE] → P8 → P9 → P10a → P10b → P11 → P12
         └────────── 데스크톱 ──────────┘   └─ 공유 ─┘   └─────────── 모바일 ───────────┘  └ 릴리스 ┘
```

| 단계 | 이름 | 사이드 | Effort(계획) |
|------|------|--------|--------------|
| **P5.5** | **에이전트뷰 인터랙티브 스플릿 (트리 + 라이브 터미널)** | desktop | 3~5일 |
| P6a | Pairing UI + 토큰 발급 (QR + 6자리 코드) | desktop | 3~5일 |
| P6b | 토큰 lifecycle + Tailscale 통합 | desktop | 3~4일 |
| S1 | Mini-spike: 실 FCM/APNs wire 검증 | desktop | 1~2일 |
| P7 | Protocol Freeze Gate (envelope v1.0 동결) | shared | 3~5일 |
| P8 | 모바일 기반: Expo + SQLite + WS 클라이언트 | mobile | 4~6일 |
| P9 | 모바일 페어링 UX + 워크스페이스/채팅룸 | mobile | 6~9일 |
| P10a | 모바일 FCM/APNs 수신 + dedupe | mobile | 4~6일 |
| P10b | Deep link + fetchHint + 알림 탭 | mobile | 3~5일 |
| P11 | 모바일 폴리시 + 에러 카탈로그 + 한국어 i18n | mobile | 3~5일 |
| P12 | 릴리스: 사이닝 + 노타라이즈 + 가이드 | both | 3~5일 |

핵심 순서 원칙 (work-plan-v4 §2):
- **데스크톱(P6b까지) 완성 전에 모바일을 시작하지 않는다** — protocol drift 방지.
- **P7 freeze gate를 통과해야 모바일 진입** — TS codec ↔ Swift codec이 동일 fixture corpus에 대해 라운드트립 일치.
- S1에서 wire 미통과 시 P5/P6 코드로 되돌아가 정렬한다.

---

## 3. 단계별 개념 요약

### P5.5. 에이전트뷰 인터랙티브 스플릿 (워크스페이스 트리 + 라이브 터미널)

agent-view를 카드 그리드에서 **좌우 스플릿 작업 화면**으로 진화시킨다. 좌측은 workspace → pane → tab(세션) 계층 트리, 우측은 트리에서 클릭한 세션의 **라이브 터미널**이 즉시 뜨는 호스트 영역. 여러 셸을 agent-view 안에서 직접 오가며 작업할 수 있다.

- **세션 공유가 핵심 요구**: 우측에 뜨는 터미널은 새 셸이 아니라 **기존 세션 그대로**(같은 PTY, 같은 scrollback). 근거 — ADR-I 구조상 `SurfaceRegistry`가 모든 터미널 NSView의 owner라서 화면 재구성과 무관하게 surface가 생존하며, `acquireExisting(id: tabId)`로 같은 NSView를 다른 컨테이너에 재부모화한다. 컨테이너 간 재부모화는 기존 탭 전환(동일 컨테이너 내 surface 교체)과 다른 신규 동작이므로 P5.5 Day 2에서 `SurfaceRegistryInvariantTests` 스파이크 + GUI walkthrough로 검증했다
- 좌측 트리 데이터는 `WorkspaceManager.workspaces` + `SessionStatusCoordinator.snapshots`(status 뱃지) 재사용 — 신규 모델 불필요
- 우측 호스트: `acquireExisting`으로 선택 세션의 뷰를 mount하는 NSViewRepresentable + 재부모화 규율(워크스페이스 탭 복귀 시 뷰 반환). 다중 세션 동시 표시(우측 분할)는 각 세션이 독립 surface라 가능
- 기존 카드 그리드/점프는 보존 또는 트리로 흡수(상세 계획에서 결정)
- **P3.5 보류 부채 REQ-5(agent-view 재설계)를 본 단계가 흡수**

**알려진 제약 (설계 시 명시할 것)**:
1. 같은 세션의 **동시 미러링 불가** — 1 surface = 1 NSView. agent-view 우측과 원래 워크스페이스 탭에 동시에 띄울 수 없고, 탭 전환 시 뷰가 따라 이동한다(한 번에 한 탭만 보이는 현 UI에서는 실사용 충돌 없음)
2. 한 번도 열린 적 없는 탭은 surface가 lazy 미생성 — 클릭 시점 생성(이때는 신규 spawn)이며 `PaneTerminalView.buildCommand`의 공용 추출이 선행 리팩터링
3. 리사이즈 공유 — 같은 PTY라 우측 pane 크기로 SIGWINCH가 가고, 워크스페이스 복귀 시 재리사이즈된다(세션 공유의 본질적 결과)

- **Side**: desktop / **Effort**: 3~5일 / **Dependencies**: P3.5(탭 시스템), ADR-I
- 진입은 관례대로 ralplan 상세 계획서(`docs/plans/p5.5/`)부터

### P6a. Pairing UI + 토큰 발급

데스크톱이 모바일 디바이스를 신뢰 목록에 올리는 입구. **QR 원샷**과 **6자리 코드**(5분 만료) 두 경로를 평등하게 제공한다.

- 페어링 payload: `{ pairingId, deviceTokenSecret, wsEndpoint, pushChannelHint, expiresAt }`
- Device registry 초안: Keychain 저장, `Device { id, name, fcmToken?, apnsToken?, expiresAt, revoked }`
- WS 인증 시작: 모든 WS 연결에 `Authorization: Bearer` 필수, 미인증 즉시 close
- **ADR-A 작성**: `chatRoomId` 발급 주체(모바일 vs 데스크톱) + 데몬 재시작 시 sessionId invalidate 정책 — P7 freeze 전 반드시 확정
- 검증 컨셉: 모바일 없이 curl/스크립트로 디바이스를 흉내내어 토큰 등록 → WS 라운드트립

### P6b. 토큰 lifecycle + Tailscale 통합

발급한 토큰에 수명과 폐기 경로를 부여하고, WS endpoint를 tailnet에 노출한다.

- 30일 만료 + 만료 7일 전 알림 + 수동 revoke 리스트 UI + "Device lost" 즉시 무효화
- Tailscale은 **system service 의존**(tsnet 미사용). `tailscale status` 사전 진단 + 한국어 안내
- fetchHint endpoint(`kind=fetch, messageId`): push 수신 후 모바일이 본문을 보강하는 채널
- 검증 컨셉: 만료/revoked 토큰의 연결·push가 모두 즉시 거부됨을 확인

### S1. Mini-spike — 실 FCM/APNs wire 검증

P5의 mock transport를 실 wire에 1회 통과시키는 보안/통신 핸드셰이크 spike. 모바일 없이 더미 디바이스 토큰을 사용한다.

- FCM HTTP v1: 401/INVALID_ARGUMENT 응답이면 인증(OAuth2) + 인코딩 경로 통과로 판정
- APNs HTTP/2: `BadDeviceToken` 응답이면 .p8 JWT 서명 + HTTP/2 경로 통과로 판정
- P5에서 이연한 **D1~D5가 여기서 해소** (Firebase 프로젝트/.p8 발급, Keychain 등록, 실 transport 구현, ADR-D 최종화 포함)
- 산출: `docs/spikes/s1-wire.md` 검증 기록 (키/토큰 본문은 로그 마스킹)

### P7. Protocol Freeze Gate

모바일 진입 전 마지막 관문. WS envelope과 Push envelope을 **v1.0으로 동결**한다.

- 명세서 2건: `docs/protocols/ws-envelope-v1.0.md`, `push-envelope-v1.0.md` (kind/code 카탈로그, 한국어 에러 메시지, seq u64-string 규칙)
- TypeScript codec 패키지(`packages/protocol`) 신설 — 모바일이 의존할 contract
- Fixture corpus(한국어/emoji/4KB 경계/seq overflow/전체 kind)에 대해 **TS ↔ Swift 라운드트립 byte-identical**
- 동결 후에는 add-only(v1.1 가산)만 허용. P4/P5의 v0.9 잔재를 v1.0으로 정렬
- freeze 실패 시 재작업 budget 3~5일 별도

### P8. 모바일 기반 (Expo 부트스트랩)

React Native + Expo(Managed) 앱의 골격. UI보다 데이터/연결 기반에 집중한다.

- SQLite 스키마 v1(`workspaces, chat_rooms, messages, pairings`) + 멱등 마이그레이션
- `expo-secure-store` 토큰 보관, `packages/protocol` 의존
- WS 클라이언트: tailnet 연결 + Bearer 헤더 + seq/ack 추적 — envelope 1개 라운드트립이 데모
- 개발용 수동 페어링(토큰 텍스트 붙여넣기)으로 시작. 정식 페어링 UX는 P9

### P9. 모바일 페어링 UX + 워크스페이스/채팅룸 모델

모바일의 정보 구조가 완성되는 단계. **채팅룸 = 데스크톱 pane 1:1 바인딩**이 핵심 개념.

- QR 스캔 + 6자리 코드 입력 두 페어링 화면
- 워크스페이스 목록 → 채팅룸 목록 → 채팅룸 화면(메시지 리스트 + 입력창 + WS attach)
- 셸 pane은 카드로 표시하되 MVP에서는 입력 비활성(read-only 정책)
- 채팅룸 ↔ pane lifecycle 매트릭스: pane 종료 → `closed`, 외부 kill → `terminated`, 데몬 재시작 → `orphaned`(메시지는 모두 영속)
- 무한 스크롤 + SQLite 영속화(1000건 seed에서 jank-free)

### P10a. 모바일 push 수신 + dedupe

푸시 채널이 양 끝에서 완결되는 단계.

- Android: FCM 라이브 수신(실기기). iOS: 시뮬레이터 `.apns` drag-drop 검증(실기기는 post-MVP)
- push payload → envelope 디코드 → `chatRoomId` 라우팅 → SQLite append
- **같은 메시지가 WS와 push 양쪽으로 도착해도 1회만 저장** — dedupe key(ADR-C) + 동시 write 정책(ADR-H) + SQLite WAL 모드
- ADR-B(Expo Managed 유지 vs Bare eject)를 이 단계 시작 시 확정

### P10b. Deep link + fetchHint

"알림 탭 → 정확한 채팅룸 → 부족분 보강"의 hybrid 송수신 완결.

- 알림 탭 deep link 라우팅 + WS `kind=fetch`로 본문 보강
- ring buffer drop-and-mark 시그널을 채팅룸에 한국어로 표시
- WS attached 시 데스크톱이 push를 skip하는지 통합 검증(P5 정책의 실전 확인)

### P11. 모바일 폴리시 + 한국어 i18n 완성

기능 추가가 아니라 품질 마감 단계.

- error code 카탈로그 ↔ 모바일 i18n 사전 1:1 연결, 영어 기본 메시지 노출 0건
- 토큰 만료/revoke/Device lost의 graceful UI 흐름
- 연결 상태 표시(connected/reconnecting/unreachable/unauthorized/revoked)
- 접근성(동적 폰트, 다크 모드) + i18n lint(미사용/미정의 키 검사)

### P12. 릴리스

- 데스크톱: `xcodebuild archive` → notarize(keychain-profile) → staple → `.dmg` (P1에서 dry-run 통과해 둠)
- 모바일: Android APK + iOS 시뮬레이터 빌드 (스토어 제출은 out of scope)
- 사용자 가이드/운영 가이드/릴리스 노트 — 가이드만 보고 처음 사용자가 페어링을 완주할 수 있어야 한다
- FCM/APNs 키가 릴리스 빌드에 포함되지 않도록 빌드 스크립트에서 강제

---

## 4. P5가 P6+/S1로 이연한 항목 (D1~D7)

P5는 mock-first로 닫혔고, 아래 7건이 측정 가능한 종료 기준과 함께 1급 기록되어 있다(`docs/plans/p5/p5-detailed.html` §7).

| # | 항목 | 해소 시점 |
|---|------|-----------|
| D1 | 실 FCM HTTP v1 transport (Firebase 프로젝트/서비스 계정) | S1 |
| D2 | 실 APNs HTTP/2 transport (.p8 발급) | S1 |
| D3 | 실 디바이스/시뮬레이터 push 수신 (모바일 클라이언트 필요) | P10a |
| D4 | ADR-D 최종 결정 (APNs HTTP/2 native vs 외부 라이브러리) | S1 |
| D5 | S1 wire validation (on-wire 4KB/한국어 boundary 검증) | S1 |
| D6 | `chatRoomId` 실 매핑 source (현재 sessionId placeholder) | P6a |
| D7 | **push trigger source** — internal output tap(C4) 해소 + `PushSender` 첫 production caller 배선 | P6+ (C4 해소 후) |

> D7 보충: P5의 `PushSender`는 의도된 dead-until-C4 seam이다. internal 세션의 output tap이 `INTERNAL_OUTPUT_UNSUPPORTED`(C4)로 막혀 있어 "새 Claude 메시지 감지 → send()" 호출자가 아직 없다. 테스트는 envelope 직접 주입으로 전 경로를 검증해 두었다.

---

## 5. 잔존 부채 (단계 외 트래킹)

| 부채 | 내용 | 비고 |
|------|------|------|
| C2 sign-off | internal-input 수동 sign-off (`docs/p4/c2-internal-input-signoff.md`) — GUI 실행 후 수동 절차 | P5 Exit Gate 9번 미체크 상태 |
| C4 | internal 세션 output tap 미지원 — D7의 전제조건 | 해소 시 push trigger 배선 가능 |
| P3.5 REQ-5 | agent-view 재설계 보류분 | **CLOSED (2026-06-11)** — P5.5 Day 3 완료로 인터랙티브 스플릿(트리 + 라이브 터미널) 흡수. 카드 그리드 폐기(옵션 C) |
| P3.5 W-3-1 | 수동 sign-off 보류분 | 독립 보류 (잔존) |
| master 수락기준 #1/#2 | 실 디바이스/시뮬레이터 push 수신 — P5 닫힘에 문서화된 gap | S1/P10a에서 해소 |

---

## 6. 미결 ADR 목록 (작성 시점 순)

| ADR | 주제 | 작성 단계 |
|-----|------|-----------|
| ADR-A | `chatRoomId` 발급 주체 + sessionId lifetime | P6a (P7 전 동결 필수) |
| ADR-F | Tailscale prerequisite UX (모바일 설치/로그인 안내) | P6b/P8 |
| ADR-D | APNs HTTP/2 라이브러리 (stub 작성됨, 최종화 잔존) | S1 |
| ADR-G | Workspace sync model (full pull vs delta) | P7 |
| ADR-B | Expo Managed vs Bare eject | P10a |
| ADR-C | push dedupe key (`messageId` vs `sessionId+seq`) | P10a |
| ADR-H | foreground 동시 수신 정책 (WS ↔ push 동시 write) | P10a |
| — | error code catalog 최종 확정 | P7 |

---

## 7. 횡단 원칙 (전 단계 공통)

- **Korean-safe**: 모든 자르기/preview/drop은 UTF-8 메시지 경계에서만. 위반은 수락 기준 위반
- **보안**: 키/토큰은 Keychain(데스크톱)/secure-store(모바일) 전용, 코드·로그 노출 금지. env에는 Keychain item ID만. 키 누출 시 rotation 절차는 work-plan-v4 §4.5
- **Reserved fields over premature features**: E2E 암호화, fan-out, 세션 resume은 reserved 필드로만 예약
- **Vertical slice**: 모든 단계는 자체 end-to-end 데모를 가진다. 수평 레이어 단계 금지

---

## 8. 참고 문서

- 마스터 분해 원본: `docs/plans/work-plan-v4.md`
- 완료 단계 상세: `docs/plans/p1/` ~ `docs/plans/p5/` (각 `pN-detailed.html` + `pN-history.md`)
- P4 exit gate / 부채 표: `docs/p4/p4-exit-gate.md`
- 다음 상세 계획 위치(예정): `docs/plans/p6a/p6a-detailed.html`
