# Claude Alarm Terminal — Master Work Plan v4

문서 작성일: 2026-05-13
대상: macOS 데스크톱 터미널 + React Native 모바일 채팅 앱
스코프: v4 마스터 단계 분해 (각 단계의 상세 구현 계획은 별도 문서로 분리)

---

## 0. RALPLAN-DR Summary

### Principles

1. **Desktop-first vertical slice.** 모바일 작업을 시작하기 전에 데스크톱이 단독으로 동작하는 완성품이어야 합니다. 데스크톱 자체로 가치(다중 Claude 세션 + 일반 셸 + agent-view)가 성립해야 합니다.
2. **Protocol freeze before cross-side work.** WS envelope v1.0과 Push envelope v1.0은 모바일 단계 진입 전에 라운드트립 검증을 통과해야 합니다. 동결 이후에는 마이너 버전 추가만 허용합니다.
3. **Vertical slice per phase, not horizontal layers.** 각 단계는 자체적인 end-to-end 데모(UI + 데이터 흐름 + 검증)를 제공합니다. "WS만", "UI만" 같은 수평 레이어 단계를 만들지 않습니다.
4. **Boundary-only deferral.** 범위 밖 결정(Codex/Gemini, E2E 암호화, fan-out, 세션 resume)은 단계 안에서 우회 구현을 만들지 않고 envelope/스키마에 예약 필드만 남겨 둡니다.
5. **Korean-safe by default.** 모든 PTY/링버퍼/preview 자르기는 UTF-8 메시지 경계에서만 수행합니다. 한국어 다바이트 손상이 발생하면 단계 수락 기준 위반으로 간주합니다.

### Decision Drivers (Top 3)

1. **Desktop-first build order (primary).** 모바일은 데스크톱이 보내는 envelope에 의존하므로 데스크톱 완성이 mobile blocker입니다. 데스크톱 완성 전 모바일을 시작하면 protocol drift와 양쪽 재작업이 발생합니다.
2. **Single-developer cognitive load.** Apple Silicon Mac 한 대 + Android 실기기 + iOS 시뮬레이터 환경에서 데스크톱/모바일을 동시에 진행할 경우 컨텍스트 스위칭 비용이 크고 protocol drift 가능성이 큽니다.
3. **Push infrastructure는 FCM/APNs 외부 의존이라 검증 비용이 큼.** Push sender(데스크톱)는 모바일 단계 이전에 단독으로 검증 가능해야 하며, 모바일 단계 진입 후에야 발견되는 push schema 결함은 비용이 매우 큽니다.

### Viable Options Considered

**Option A (선택): Strict Desktop-First, Protocol Freeze Gate, Mobile-Last.**
- 데스크톱 5~7개 단계 완성 → protocol freeze 단계 → 모바일 3~5개 단계 → 릴리스 단계.
- 장점: protocol drift 위험 최소화, 각 단계가 단독 가치 제공, 데스크톱 사용자는 모바일 없이도 가치를 얻음, mobile 단계가 명확한 contract 위에서 작업.
- 단점: 모바일 사용자에게 가치가 가는 시점이 늦음, 데스크톱-모바일 통합 이슈를 마지막에 한 번에 발견.

**Option B: Interleaved (데스크톱 phase ↔ mobile phase 교차).**
- 데스크톱 foundation → mobile foundation → 데스크톱 agent-view → mobile UI → ...
- 장점: 양쪽 사이드의 contract 충돌을 일찍 발견.
- 단점: 단일 개발자에게 컨텍스트 스위칭 비용이 큼, protocol이 동결되지 않은 채 mobile이 envelope을 가정하면 양쪽 재작업, "데스크톱 단독으로 동작" 목표가 흐려짐.

**Option C: Mobile-First Prototype (mock 데스크톱 위에서 모바일 UX 먼저).**
- mock WS server를 만들고 모바일 UX를 먼저 완성.
- 장점: 모바일 UX의 가치 가설을 일찍 검증.
- 단점: mock server가 곧 시뮬레이션 부채가 됨, 실제 PTY/Claude CLI/Tailscale 통합 시 가정과 실재 사이의 갭이 크게 드러남, 데스크톱이 spec에서 PRIMARY로 명시됨.

**선택: Option A.** 데스크톱-퍼스트가 spec에 명시된 primary priority이며, single-developer 환경에서 protocol drift와 컨텍스트 스위칭 비용을 가장 잘 통제합니다. Option B의 "이른 contract 충돌 발견"은 protocol freeze 게이트의 라운드트립 테스트로 대체할 수 있습니다.

### 단계 개수 및 분포

- 데스크톱: 7개 단계 (P1, P2, P3, P4, P5, P6a, P6b)
- Wire-validation mini-spike: 1개 단계 (S1)
- Protocol freeze 게이트: 1개 단계 (P7)
- 모바일: 5개 단계 (P8, P9, P10a, P10b, P11)
- 릴리스: 1개 단계 (P12)
- **합계: 15개 단계(서브 페이즈 + mini-spike 포함). 마스터 페이즈 카운트로는 12개(P1~P12).**

---

## 1. Phase List

### P1. 데스크톱 기반: 단일 PTY + libghostty 통합

- **Goal**: AppKit 윈도우 1개 안에서 libghostty 기반 터미널 뷰가 단일 PTY(claude 또는 zsh)를 렌더링합니다. 다중 세션·workspace·tab은 아직 없습니다.
- **Side**: desktop
- **Scope (in)**:
  - Swift + AppKit 프로젝트 부트스트랩(Xcode project, Developer ID 서명 준비).
  - libghostty Swift 바인딩 통합 (단일 인스턴스).
  - PTY abstraction: `Session { id, kind: claude|shell, ptyHandle, cwd, createdAt }`.
  - PTY spawn: `claude` CLI 또는 `$SHELL`을 cwd에서 실행.
  - 키 입력/리사이즈(SIGWINCH)/스크롤 wiring.
  - 종료 처리: PTY EOF → 세션 상태 `exited`, claude의 경우 `claudeSessionId` 보존(메모리).
  - 환경 변수 로딩: `CHAT_TERMINAL_MAX_SESSIONS` (이 단계에서는 1로 강제), `CHAT_TERMINAL_WORKSPACE_ROOT` (이 단계에서는 cwd로만 사용).
  - Daemon lifecycle 정책 골격: `NSProcessInfo.processInfo.beginActivity(options:)`로 백그라운드 작업 보호, Power Nap 스케줄 hook 지점 확보, lid-close 시 PTY 핸들 유지(파일디스크립터 + child PID 보존) 정책 코드 레벨 명세.
- **Out of scope**: workspace tab, agent-view, multi-pane split, WS 서버, pairing, Push.
- **Key deliverables**:
  - libghostty 위에 동작하는 단일 터미널 뷰.
  - `Session` 모델 + `SessionManager` 골격(`create`, `terminate`, `get` 만 지원, max=1).
  - 코드사이닝/노타라이즈 hook이 빌드 스크립트에 자리 잡음(이 단계에서는 dry-run).
- **Acceptance criteria**:
  - 앱 실행 → 빈 윈도우 → "New Claude session" 단축키 → claude CLI 프롬프트 표시 → 입력/출력/한국어/SIGWINCH 정상.
  - "New Shell session"으로 zsh 세션도 동일하게 동작.
  - 세션 종료 시 윈도우는 유지되고 세션 상태가 `exited`로 기록됨.
  - `xcodebuild` + `xcrun notarytool` keychain-profile dry-run이 에러 없이 완료.
- **Dependencies**: 없음.
- **Risk callouts**:
  - libghostty Swift 바인딩의 안정성/API 변경: 단계 시작 시 commit pin.
  - PTY + Korean(UTF-8) wide-character 렌더링 깨짐: 수락 기준에 한국어 입력/출력 명시.
  - Developer ID 인증서/keychain-profile 미준비로 빌드 sign 실패: P1에서 dry-run만이라도 통과시켜 P6 부담을 분산.
- **Effort**: L (5~8일).

### P2. 다중 세션 + 워크스페이스 탭 + 가로 분할(최대 2 pane)

- **Goal**: 사이드바 탭 = workspace, workspace 내부에 최대 2개의 가로 분할 pane. 각 pane은 생성 시점에 claude/shell 중 하나를 선택. `CHAT_TERMINAL_MAX_SESSIONS` (기본 20)이 실효성을 가짐.
- **Side**: desktop
- **Scope (in)**:
  - `Workspace { id, name, cwd, panes: [Pane], createdAt, kind: 'agent-view' | 'normal' }`.
  - `Pane { id, sessionId, kind: claude|shell, position: top|bottom }`.
  - Workspace API: `workspace.list`, `workspace.create(cwd, name?)`, `workspace.recent` (in-memory, persisted JSON).
  - 첫 번째 탭은 항상 `agent-view` 종류로 생성되며 닫기/제거 UI가 없음(단, P3까지는 placeholder 콘텐츠 OK).
  - Vertical sidebar tab UI: 탭 선택, 새 workspace 생성(`+`), workspace close (agent-view 제외).
  - Pane split: 한 workspace에서 두 번째 pane을 만들 때 pane type chooser(claude vs shell), 가로 분할 고정. 세 번째 pane 생성 시도는 UI에서 비활성화.
  - SessionManager 확장: `maxSessions` enforce, 도달 시 명확한 한국어 에러("최대 세션 개수에 도달했습니다 (N=20). 기존 세션을 종료하세요.").
  - 세션-pane lifecycle: pane 닫기 → 세션 종료. workspace 닫기 → workspace 내 모든 세션 종료. claude `claudeSessionId` 메모리 보존.
  - 키보드 단축키: workspace 전환, pane 포커스 전환, pane split, pane close.
- **Out of scope**: agent-view 실데이터(P3), WS/pairing/push.
- **Key deliverables**:
  - Vertical sidebar + tab system.
  - Pane split + 2-pane horizontal layout.
  - SessionManager v1 (multi-session, max enforcement, lifecycle hooks).
  - workspace 상태의 JSON 영속화 (앱 재시작 시 workspace 목록 복원, 단 세션은 복원하지 않음 — out of scope for resume).
- **Acceptance criteria**:
  - workspace A(cwd: ~/projA)에서 claude pane + shell pane → 둘 다 정상 동작 → workspace B(cwd: ~/projB) 생성 → 전환해도 A의 PTY는 유지.
  - 21번째 세션 생성 시 한국어 에러 다이얼로그 표시, 기존 20개 세션은 영향 없음.
  - 첫 번째 탭(agent-view)에는 close 버튼이 없음(invariant).
  - 앱 재시작 후 workspace 목록은 복원되고, 세션은 모두 사라진 상태로 시작(설계 대로).
  - 세 번째 pane split 시도가 UI에서 막힘.
  - PTY env/cwd 격리 invariant:
    - 셸 pane의 env는 workspace 실행 시점에 캡처한 user env 스냅샷이며 다른 pane에 누설되지 않음.
    - pane 내부 `cd`/`export` 결과는 그 pane에 한해 적용되고 동일 workspace의 다른 pane이나 다른 workspace로 전파되지 않음.
    - 새 pane 생성 시 cwd는 `workspace.cwd`이며 직전 pane의 cwd를 상속받지 않음.
    - claude pane은 `CLAUDE_CONFIG_DIR` 격리를 유지(세션마다 독립 config 디렉터리 노출).
- **Dependencies**: P1.
- **Risk callouts**:
  - SessionManager의 동시성(여러 PTY가 동시에 read/write할 때 actor isolation): Swift `actor`/`@MainActor` 경계 설계 명세화.
  - JSON 영속화 스키마가 향후 단계(P5의 push 채널 매핑)와 충돌할 가능성: P2의 영속화 스키마에 reserved 필드 두기.
- **Effort**: L (6~9일).

### P3. agent-view 대시보드(Pinned First Tab)

- **Goal**: 첫 번째 탭이 모든 workspace의 모든 세션을 카드로 보여 주는 unified Claude Code Agent View. 카드 클릭 시 해당 workspace 탭 + pane으로 점프.
- **Side**: desktop
- **Scope (in)**:
  - Session state model 확장: `Session.status: idle | working | needsInput | exited`, `latestPreview: string (≤200 chars, UTF-8 message-boundary safe)`, `lastActivityAt: Date`.
  - 상태 감지: claude 세션의 경우 PTY output 패턴(프롬프트 readiness, "I need your input" 류 시그널)을 정규식이 아니라 message-boundary 디텍터로 식별. 셸 세션은 항상 `idle` 또는 `working`(자식 프로세스 실행 중)으로 단순화.
  - agent-view UI: 카드 그리드, 카드 = (workspace 이름, pane kind, status badge, latestPreview, lastActivityAt, "Open" 액션).
  - 카드 클릭 → 해당 workspace 탭 활성화 + 해당 pane 포커스.
  - agent-view 자체는 PTY가 없는 special workspace; close 불가, cwd 없음, sidebar 첫 번째 위치 고정.
  - 카드 자동 갱신(폴링 아님, SessionManager가 발행하는 lightweight event를 SwiftUI/Combine으로 구독).
  - 렌더링 및 인터랙션 정책은 ADR-E 참조: SwiftUI AttributedString 기반 ANSI SGR/CR 파싱, 키보드 네비게이션, 정렬(default: lastActivityAt desc) 및 status 필터, needsInput 시각 큐.
- **Out of scope**: 카드에서 직접 입력 전송(이건 모바일의 역할), WS/Push, 한 카드에서 여러 모바일 디바이스 표시.
- **Key deliverables**:
  - `SessionStatusObserver` 컴포넌트 (PTY output → status/preview).
  - agent-view SwiftUI view + 카드 컴포넌트 + 점프 액션.
  - 첫 번째 탭 invariant test (UI test에서 close 시도가 막힘을 확인).
- **Acceptance criteria**:
  - 3개의 workspace에 각각 claude pane + shell pane → agent-view에서 6개의 카드 표시, 각 카드의 latestPreview는 한국어 포함 시에도 깨지지 않음(UTF-8 경계 검증).
  - claude가 "Do you want to apply this change? [y/n]" 같은 readiness signal을 출력하면 카드 status가 `needsInput`으로 바뀜.
  - 카드 클릭 → 정확한 workspace + pane으로 점프하고, 점프 후 active workspace의 마지막 포커스가 카드의 pane으로 설정됨.
  - agent-view 탭에 close 버튼이 없고, 키보드 단축키로도 close되지 않음.
  - 셸 pane preview 추출 invariant:
    - zsh prompt 재그리기, `\r`(carriage return), `RPROMPT`(우측 prompt) 처리 시 preview에 raw escape sequence가 노출되지 않음.
    - prompt 텍스트 자체는 preview에서 제외하고, "마지막 의미있는 출력 줄" 휴리스틱을 적용(공백/프롬프트만 있는 줄 skip).
    - 한국어가 포함된 셸 출력 줄도 UTF-8 메시지 경계 보존.
- **Dependencies**: P1, P2.
- **Risk callouts**:
  - PTY output에서 "needs input" 신호를 안정적으로 추출하는 휴리스틱이 약함: 첫 버전은 보수적으로(false negative 허용, false positive 금지) 설계.
  - 카드 자동 갱신이 메인 스레드를 점유: 이벤트 발행 빈도 throttle.
- **Effort**: M (4~6일).

### P4. WebSocket 서버 + 인프로세스 데몬 골격 (foreground only)

- **Goal**: 앱 내부에 데몬(WS 서버 + SessionManager 연결)을 인프로세스로 띄우고, 로컬에서 WS 클라이언트가 envelope을 통해 session input/output을 송수신할 수 있게 합니다. 아직 Tailscale/pairing/push는 없습니다.
- **Side**: desktop
- **Scope (in)**:
  - In-process daemon: 앱 시작 시 WS server를 loopback(127.0.0.1) 임의 포트에 listen.
  - WS envelope v0.9 (preview, freeze는 P7에서). Fields: `seq u64 string`, `ackSeq u64? string`, `actor {deviceId, userId?}`, `kind`, `code?`, `payload`. Kind set: `input, output, session.start, session.exit, session.terminated, ack, error, pause, resume`.
  - In-memory ring buffer per session(~500 messages), **message-boundary drop-and-mark** (UTF-8 safe). Drop 발생 시 `kind=error, code=BUFFER_OVERFLOW_DROPPED` envelope을 한 번 발행.
  - Envelope codec (Swift): encode/decode, seq 모노토닉성 검증.
  - Session bind API: WS client가 `kind=session.start` envelope로 특정 sessionId에 attach.
  - 시퀀스: WS client `input` → SessionManager PTY write → PTY output → WS client `output` 스트림.
  - PTY single-writer queue: SessionManager는 `actor` 또는 직렬 큐로 PTY write를 직렬화. 데스크톱 키보드 입력과 모바일 WS 입력이 동시에 도착할 때의 우선순위/락 정책을 명시(FIFO + per-pane lock, 데스크톱 keystroke는 동일 큐에 enqueue되며 추월 없음). 동일 sessionId에 대한 2개 이상의 동시 write는 금지.
  - Loopback에서 동작하는 dev CLI(swift package 또는 Node 스크립트) 클라이언트 1개로 라운드트립 데모.
- **Out of scope**: Tailscale 노출, pairing, Push sender, mobile.
- **Key deliverables**:
  - WS server (loopback) 통합.
  - Envelope codec v0.9 + 단위 테스트(서로 다른 kind, Korean payload, seq overflow string encoding).
  - Ring buffer + drop-and-mark + drop event emit.
  - Dev CLI 라운드트립 데모 스크립트.
- **Acceptance criteria**:
  - 로컬 CLI에서 workspace A의 claude pane에 attach → 한국어 입력 → 출력이 envelope 스트림으로 도착 → drop-and-mark 시그널이 buffer 강제 overflow 테스트에서 1회만 발행.
  - seq는 u64 string으로 직렬화/역직렬화 라운드트립 OK (큰 값 포함, e.g., 2^53+1).
  - WS 클라이언트 비정상 종료 → 서버 측 attach 상태가 정리되고 PTY는 계속 살아 있음.
  - Envelope codec 단위 테스트 (한국어 / emoji / 부분 UTF-8 boundary) 통과.
- **Dependencies**: P1~P3.
- **Risk callouts**:
  - seq를 number로 직렬화하면 JS 측 53-bit precision 손실 → 이미 string 결정. P4 codec 테스트에 명시.
  - Drop-and-mark가 메시지 경계가 아닌 byte 경계에서 발생하면 한국어 손상 → P4 단위 테스트의 핵심 케이스.
- **Effort**: L (5~8일).

### P5. Push Sender + FCM/APNs 인프라 골격

- **Goal**: 데스크톱 데몬이 mock 모바일 디바이스(FCM/APNs 콘솔 + .apns 시뮬레이션)로 push envelope을 전송할 수 있게 합니다. 모바일 클라이언트는 아직 없습니다.
- **Side**: desktop (+ shared push envelope spec)
- **Scope (in)**:
  - Push envelope v0.9 (freeze는 P7): `sessionId, messageId, preview (≤200 chars, message-boundary), chatRoomId, timestamp, fetchHint`. ≤4KB push limit 준수 검증기 포함.
  - PushSender component: FCM HTTP v1 API (Android), APNs HTTP/2 (iOS) 인증 + 발송.
  - 서비스 계정/Key는 macOS Keychain에 저장, 환경 변수로 path 또는 keychain item ID 지정 (`CHAT_TERMINAL_FCM_KEY_ID`, `CHAT_TERMINAL_APNS_KEY_ID`).
  - Foreground/background 정책: WS attached client가 있으면 push 발송 skip(설정 가능); 없으면 발송. (foreground 사용자: WS 스트림, background 사용자: push.)
  - Daemon lifecycle 정책 적용: 시스템 슬립/lid-close 진입 시 WS attached 판정이 즉시 "not attached"로 평가되어, spec이 정의한 정상 경로(WS 미연결 → push 송신)가 정확히 발동. `NSWorkspace.willSleepNotification`/`didSleepNotification` 신호로 attached 상태를 명시적으로 무효화.
  - `chatRoomId` 개념을 데몬 측에서 reserved field로 처리(아직 매핑 source가 없으므로 sessionId와 동일 값으로 placeholder).
  - PushSender 단위 테스트는 FCM/APNs를 mock transport로 대체(실제 발송은 통합 테스트로 따로 분리).
- **Out of scope**: pairing flow, mobile 측 push 수신, fetchHint resolver API(P6에서 다룸).
- **Key deliverables**:
  - Push envelope codec + 단위 테스트 (4KB 한도, message-boundary preview, 한국어 포함).
  - PushSender (FCM transport + APNs transport).
  - Push policy: "WS attached이면 skip" 토글 + 설정 UI(설정 화면 진입점만, 최소).
  - 통합 테스트 fixture: 실제 FCM 콘솔 / Xcode `.apns` drag-drop 매뉴얼 절차서.
- **Acceptance criteria**:
  - dev 데몬에서 trigger → FCM 테스트 디바이스/콘솔이 push 수신 → preview 한국어 정상.
  - APNs simulator(`.apns` drag-drop)로 iOS simulator가 push 수신 → preview 정상.
  - 4KB 초과 payload가 자동으로 거부되고 sender가 에러 로깅 (drop이 아니라 명시적 거부).
  - WS attached일 때 push가 발송되지 않음을 통합 테스트가 검증.
  - 데스크톱 lid-close → 5분 경과 시점에 attached 판정이 정확히 무효화되어 push 송신 경로가 발동(시스템 슬립 시뮬레이션 또는 NSWorkspace 슬립 노티 emit으로 검증).
- **Dependencies**: P4.
- **Risk callouts**:
  - FCM/APNs key 관리: 사용자 secret leakage 가능 → Keychain 전용, 코드/로그에 직접 노출 금지.
  - APNs HTTP/2 라이브러리 선택(Swift 네이티브 vs 외부 패키지): P5 시작 시 PoC 1일.
  - 4KB 한도가 message-boundary 잘림 후에도 깨질 가능성: validator를 codec 안에 둠.
- **Effort**: M (4~7일).

### P6a. Pairing UI + 토큰 발급 (QR + 6자리 코드)

- **Goal**: 데스크톱 측에서 두 가지 페어링 경로(QR 원샷 + 6자리 코드 입력)를 발급하고, 디바이스 토큰을 Keychain에 저장합니다. tailnet 노출과 토큰 lifecycle 정책은 P6b에서 다룹니다.
- **Side**: desktop
- **Scope (in)**:
  - Pairing UI: 설정 화면 안에 "Add device" → QR 코드 생성 + 6자리 코드 동시 표시. QR은 일회용, 6자리 코드는 만료(예: 5분).
  - Pairing payload: `{ pairingId, deviceTokenSecret, wsEndpoint(tailnet host:port), pushChannelHint, expiresAt }`. 모바일이 이 payload + `fcmToken/apnsToken`을 데몬에 등록.
  - 데몬 토큰 store(초안): Keychain 저장, `Device { id, name, createdAt, lastSeenAt, fcmToken?, apnsToken?, expiresAt, revoked: bool }`.
  - WS auth: 모든 WS 연결은 `Authorization: Bearer <deviceTokenSecret>` 헤더 필수. 미인증 → close.
  - `chatRoomId` 매핑 source: pairing 시 모바일이 chatRoomId를 발급해 데스크톱에 등록 (또는 데스크톱이 sessionId를 1:1 매핑). 결정은 ADR-A에서 확정 후 P6a에 적용.
- **Out of scope**: 토큰 만료/revocation/lost 흐름(P6b), Tailscale 통합(P6b), 모바일 측 pairing UI(P9).
- **Key deliverables**:
  - Pairing UI(QR + code) + 토큰 발급 흐름.
  - Device registry 초안(만료/revoked 필드는 보존하되 lifecycle 동작은 P6b).
  - WS auth middleware(만료/revoked 분기는 P6b).
  - chatRoomId 매핑 ADR-A 문서.
- **Acceptance criteria**:
  - 데스크톱이 QR/code 발급 → curl/Node 스크립트로 모바일을 흉내내어 토큰 등록 → loopback WS 연결 → envelope 라운드트립 OK.
  - 미인증 토큰으로 연결 시 즉시 close + 한국어 에러 envelope.
  - 6자리 코드 만료(5분) 검증: 만료 후 등록 시도 거부.
  - QR 일회용 검증: 동일 QR 두 번 사용 시 두 번째는 거부.
- **Dependencies**: P4, P5.
- **Risk callouts**:
  - chatRoomId 발급 주체 결정이 protocol freeze에 영향 → ADR-A는 P7 진입 전에 반드시 작성.
  - 토큰 secret이 QR에 평문으로 들어감 → QR은 일회용이고 짧은 만료. 화면 캡처 risk는 사용자 가이드에 명시.
- **Effort**: M (3~5일).

### P6b. 토큰 lifecycle (만료/revoke/lost) + Tailscale 통합

- **Goal**: 30일 토큰 만료, 만료 7일 전 알림, 수동 revocation 리스트 UI, "Device lost" 액션, 그리고 Tailscale system service를 통한 tailnet WS endpoint 노출을 완성합니다.
- **Side**: desktop
- **Scope (in)**:
  - 토큰 lifecycle: 30일 만료, 만료 7일 전 알림, 수동 revocation 리스트 UI, "Device lost" 액션 (즉시 invalidate + push channel 제거).
  - Tailscale system service 의존: `CHAT_TERMINAL_TAILSCALE_HOST` (선택). 데몬 시작 시 tailnet host:port를 WS endpoint로 advertise. tsnet은 사용하지 않음.
  - WS auth middleware 확장: 만료/revoked 분기, 닫힘 코드와 한국어 에러 envelope 매핑.
  - Tailscale 사전 진단(`tailscale status`) + 한국어 안내 메시지(데스크톱 설정 화면). 모바일 측 prerequisite UX는 ADR-F에서 확정.
  - fetchHint endpoint: push 수신 후 모바일이 호출할 수 있는 WS 메시지(`kind=fetch, messageId`).
- **Out of scope**: 모바일 측 pairing UI/구현(P9), 다중 디바이스 fan-out, mini-spike S1.
- **Key deliverables**:
  - Device lifecycle UI(만료 알림, revoke, "Device lost").
  - Tailscale endpoint 통합 + 사전 진단.
  - WS auth middleware(만료/revoked 완성).
  - fetchHint endpoint 명세.
- **Acceptance criteria**:
  - 만료된 토큰으로 연결 시 즉시 close + 한국어 에러 envelope.
  - Revocation 후 해당 디바이스의 push도 즉시 끊김.
  - "Device lost" 액션 후 같은 토큰으로의 어떤 연결도 거부.
  - Tailscale 미설치/미로그인 상태에서 명확한 한국어 에러 메시지(앱 크래시 없음).
  - fetchHint 호출이 envelope round-trip OK(P7 freeze 전 시그니처 안정).
- **Dependencies**: P6a.
- **Risk callouts**:
  - Tailscale system service 부재 시 사용자 경험: 사전 진단 + 한국어 안내. 모바일 prerequisite UX는 ADR-F.
- **Effort**: M (3~4일).

### S1. Mini-spike — Real wire validation (FCM + APNs)

- **Goal**: P6b 종료 직후 P7 freeze gate 진입 전에, 데스크톱 PushSender가 실제 FCM/APNs 트랜스포트를 통과한다는 사실을 더미 디바이스 토큰으로 1회 검증합니다. 페이로드 인코딩과 인증 경로가 실 wire에서 작동함을 확인하는 보안/통신 핸드셰이크 spike입니다.
- **Side**: desktop
- **Scope (in)**:
  - 데스크톱 → 실제 FCM HTTP v1 API → 더미 Android 디바이스 토큰. 401/INVALID_ARGUMENT 응답으로 인증 + envelope 구조가 wire를 통과함을 확인.
  - 데스크톱 → 실제 APNs HTTP/2 → 더미 iOS 디바이스 토큰. `BadDeviceToken` 응답으로 인증(.p8 + key ID + team ID)과 envelope이 wire를 통과함을 확인.
  - 통신 로그(요청/응답 헤더, 응답 코드) 기록 — payload 본문은 토큰 노출 방지를 위해 마스킹.
- **Out of scope**: 실 모바일 디바이스 라이브 푸시 수신(P10a/post-MVP), 실제 푸시 표시 검증.
- **Key deliverables**:
  - FCM/APNs wire-level 핸드셰이크 검증 스크립트.
  - 검증 결과 기록(`docs/spikes/s1-wire.md`).
- **Acceptance criteria**:
  - FCM v1 send 호출이 401/INVALID_ARGUMENT 외의 어떤 transport 레벨 에러도 발생시키지 않음(OAuth2 토큰 발급 OK, JSON 인코딩 OK).
  - APNs HTTP/2 send 호출이 `BadDeviceToken` 외의 transport 에러 없음(JWT 서명 OK, HTTP/2 streams OK).
  - envelope 구조가 P5에서 정의한 v0.9 형식 그대로 직렬화되어 wire에 올라감.
- **Dependencies**: P6b.
- **Risk callouts**:
  - 실제 키 자료(서비스 계정 JSON, .p8)는 Keychain에 남기되 spike 동안만 사용. 로그에 토큰/키 본문 노출 금지.
- **Effort**: S (1~2일).

### P7. Protocol Freeze Gate (WS Envelope v1.0 + Push Envelope v1.0)

- **Goal**: WS envelope과 Push envelope을 v1.0으로 동결하고, TypeScript codec과 Swift codec이 동일한 fixture 집합에 대해 라운드트립 일치를 보장합니다. 이 게이트를 통과해야 모바일 단계로 진입합니다.
- **Side**: shared
- **Scope (in)**:
  - WS envelope v1.0 명세서(`docs/protocols/ws-envelope-v1.0.md`) 작성: 모든 kind, code 카탈로그, 한국어 에러 메시지 catalog, seq/ackSeq u64-string 규칙, drop-and-mark 시그널, `clientId` reserved 필드(fan-out 예약).
  - Push envelope v1.0 명세서(`docs/protocols/push-envelope-v1.0.md`) 작성: 모든 필드, 4KB 한도, message-boundary preview 규칙, fetchHint 포맷.
  - TypeScript codec 패키지(monorepo `packages/protocol`) 작성: encode/decode + 타입 정의.
  - Swift codec(Desktop 안의 모듈)이 같은 fixture 디렉터리를 읽어 라운드트립.
  - Fixture corpus: 한국어/emoji/긴 메시지/seq overflow/4KB 경계/drop-and-mark/모든 kind/모든 error code를 망라.
  - CI 워크플로(또는 로컬 스크립트): TS encode → JSON fixture → Swift decode → 재 encode → byte-identical 확인 (그리고 반대 방향).
- **Out of scope**: 새로운 protocol feature(E2E encryption, fan-out)는 reserved 필드로만 처리.
- **Key deliverables**:
  - 두 envelope의 v1.0 명세서 (frozen, semver 시작).
  - TS protocol 패키지.
  - Swift protocol 모듈 (P4/P5에서 만든 v0.9 codec을 v1.0으로 정합화).
  - Fixture corpus + 라운드트립 테스트.
- **Acceptance criteria**:
  - 모든 fixture가 TS↔Swift 라운드트립에서 byte-identical (혹은 정규화 후 identical, 정규화 규칙도 명세).
  - Error code catalog의 모든 코드가 한국어 메시지 매핑을 가짐.
  - 명세서가 reviewable form으로 docs에 들어가 있고, 변경 기록이 시작됨(v1.0 frozen, 이후는 v1.1 가산).
  - P4/P5에서 만든 v0.9 잔재(필드 누락, 임시 이름)가 모두 v1.0으로 정렬.
- **Dependencies**: P4, P5, P6 (특히 ADR-A의 chatRoomId 결정).
- **Risk callouts**:
  - P4/P5의 v0.9가 spec 변경을 강요할 가능성: P7 시작 시 desktop 코드 변경 budget(약 2일) 미리 잡아 둠.
  - Fixture corpus가 모든 한국어 경계를 커버하지 못할 가능성: corpus를 generative property test로 보강.
- **Effort**: M (3~5일).

### P8. 모바일 기반: Expo 부트스트랩 + SQLite + Secure Store + WS 클라이언트 골격

- **Goal**: React Native + Expo(Managed) 앱이 부트 → 로컬 SQLite 스키마 마이그레이션 → 임시 페어링 토큰을 secure-store에 저장 → 데스크톱 데몬(tailnet)에 WS 연결 → 라운드트립 envelope 1개 송수신.
- **Side**: mobile
- **Scope (in)**:
  - Expo Managed 프로젝트 부트스트랩, iOS + Android target.
  - `expo-sqlite` 스키마 v1: `workspaces, chat_rooms, messages, pairings`. 마이그레이션 러너.
  - `expo-secure-store` 헬퍼: 토큰 저장/로드/삭제.
  - `packages/protocol` TS 패키지 의존 (P7 산출물).
  - WS client: tailnet host:port 연결, `Authorization: Bearer` 헤더, envelope 인코딩, seq 추적, ack 흐름.
  - 개발용 "Manual pairing" 화면: 토큰을 텍스트로 붙여넣어 한 디바이스 페어링 흉내.
  - 최소 화면: 페어링 입력 → 연결 상태 → 임시 raw envelope 로그 화면.
- **Out of scope**: 실제 QR/code pairing UX, chat room UI, push 수신, eject to Bare.
- **Key deliverables**:
  - Expo 프로젝트 + iOS sim + Android 실기기 빌드.
  - SQLite 스키마 v1 + 마이그레이션 테스트.
  - Secure-store wrapper.
  - WS client 모듈 + 라운드트립 데모 화면.
- **Acceptance criteria**:
  - iOS simulator + Android 실기기 모두 빌드/실행 성공.
  - 텍스트 토큰으로 페어링 → tailnet host:port WS 연결 → 첫 envelope (ping/output 흐름) 정상.
  - SQLite 마이그레이션이 멱등(여러 번 실행해도 동일 결과).
  - 비행기 모드 → 연결 실패 → 한국어 에러 메시지 표시 (앱 크래시 없음).
- **Dependencies**: P7.
- **Risk callouts**:
  - Managed Expo에서 native 모듈(특히 push)이 막힐 가능성: P8에서는 push를 다루지 않지만, P10 진입 시 Bare eject 트리거 결정 기준을 P8 끝에 문서화.
  - iOS simulator의 네트워크 ↔ Tailscale 호환성: P8에 PoC.
- **Effort**: M (4~6일).

### P9. 모바일 페어링 UX + 워크스페이스/채팅룸 모델

- **Goal**: 모바일이 QR 스캔(또는 6자리 코드 입력)으로 데스크톱과 페어링하고, 워크스페이스 → 채팅룸 계층을 구성합니다. 채팅룸은 데스크톱의 특정 pane(claude 또는 shell, MVP는 claude 중심)에 1:1로 바인딩됩니다.
- **Side**: mobile
- **Scope (in)**:
  - QR 스캐너(`expo-camera`/`expo-barcode-scanner`) 화면 + 6자리 코드 입력 화면(두 가지 페어링 경로).
  - 페어링 payload 검증 → `pairings` 테이블에 저장 → secure-store에 token secret 저장.
  - 페어링 시 디바이스가 자체 발급한 `chatRoomId`를 데스크톱에 등록(또는 ADR-A 결정에 따라 데스크톱 발급 ID를 수신).
  - 워크스페이스 목록 화면: 데스크톱 `workspace.list` 호출 → SQLite에 캐시.
  - 채팅룸 목록 화면(워크스페이스 안에서): 해당 워크스페이스의 pane들을 채팅룸으로 표시. Shell pane도 카드로는 표시하되 MVP에서는 "Coming soon" 상태(입력 가능 여부 토글로 처리).
  - 채팅룸 화면 골격: 메시지 리스트 + 입력창 + WS attach (claude pane만 MVP 활성, shell pane 입력은 비활성).
  - 메시지 영속화: 수신 envelope → `messages` 테이블 append.
  - 무한 스크롤 페이지네이션(SQLite query).
  - Chat room ↔ pane lifecycle 매트릭스:

    | 데스크톱 이벤트 | 모바일 채팅룸 동작 | 메시지 보존 |
    |----------------|-------------------|-------------|
    | pane 정상 종료(claude exit) | 채팅룸 상태 `closed` 배지, 입력창 disabled, 한국어 안내 | 영속(읽기 가능) |
    | workspace 닫기 | 해당 workspace 하위 모든 채팅룸 `closed` | 영속 |
    | session.terminated(외부 kill) | 채팅룸 `terminated` 배지, 입력 disabled | 영속 |
    | 데몬 재시작으로 sessionId 소실 | 채팅룸 `orphaned` 상태, 재페어링 시 새 sessionId 매핑 시도 | 영속(이전 메시지) |
    | claude resume(out of scope) | 향후 단계에서 reserved 필드로 처리 | — |
- **Out of scope**: Push 수신, agent-view (모바일에는 없음), chat room rename sync.
- **Key deliverables**:
  - QR + 코드 페어링 화면.
  - 워크스페이스/채팅룸 네비게이션.
  - 채팅룸 화면 + 무한 스크롤.
  - SQLite 메시지 저장.
- **Acceptance criteria**:
  - 데스크톱 QR 스캔 → 페어링 성공 → 워크스페이스 목록 표시 → claude pane 채팅룸 진입 → 입력/한국어 출력 정상 라운드트립.
  - 6자리 코드 입력 경로도 QR 경로와 동일하게 동작.
  - 앱 재시작 후 페어링 토큰/메시지 영속.
  - 1000개 메시지 SQLite seed 후 무한 스크롤이 60fps에 가까운 부드러움(엄밀한 fps 측정이 아니라도 jank-free 수락).
  - shell pane은 채팅룸 목록에 표시되되 입력창은 disabled + 한국어 안내.
  - 비행기 모드 → 모든 화면이 한국어로 graceful degradation.
- **Dependencies**: P8.
- **Risk callouts**:
  - `chatRoomId` 매핑(ADR-A)이 P7에 동결됐어도 모바일에서 corner case 발견 가능: P9 초반 1일을 ADR-A 재검토에 할당.
  - QR scanner permission flow가 iOS sim/Android 실기기에서 다름: 둘 다 수동 QA 체크리스트.
- **Effort**: L (6~9일).

### P10a. 모바일 FCM + APNs 통합 + dedupe

- **Goal**: 모바일이 FCM(Android) / APNs(iOS) push를 수신하여 envelope을 디코드하고 `messageId`(또는 ADR-C에서 정한 키)로 중복 제거한 채 SQLite에 append합니다. Bare eject 결정(ADR-B), dedupe key 결정(ADR-C), 동시 수신 정책(ADR-H)을 확정합니다.
- **Side**: mobile (+ desktop integration validation)
- **Scope (in)**:
  - Android: `expo-notifications` + FCM(또는 `react-native-firebase` if Bare가 필요해진다면). Bare eject 결정은 ADR-B에서 확정.
  - iOS: APNs (Expo push proxy를 사용하지 않고 직접 APNs 토큰 등록 가능 여부 결정; ADR-B).
  - 페어링 흐름 확장: fcmToken/apnsToken을 페어링 envelope에 포함.
  - Push payload 처리: payload에서 envelope을 디코드 → `chatRoomId`로 라우팅 → SQLite append → 채팅룸 UI 갱신.
  - 동시 수신/중복 제거: ADR-C에서 정의한 dedupe key 적용. ADR-H는 foreground 시점 WS handler ↔ push handler 동시 SQLite write 정책(중복 keying, WAL 모드, drop 정책)을 확정.
  - SQLite WAL 모드 enable(동시 write 안전성).
  - iOS는 시뮬레이터-only 검증: Xcode `.apns` drag-drop으로 fixture 검증.
  - Android 실기기에서 진짜 FCM 라이브 검증.
- **Out of scope**: 알림 탭 deep link 흐름(P10b), fetchHint round-trip(P10b), 토큰-by-token 백그라운드 스트리밍.
- **Key deliverables**:
  - FCM/APNs 통합 + 토큰 등록 흐름 완성.
  - Push payload codec 적용 + dedupe.
  - ADR-B(Managed vs Bare), ADR-C(dedupe key), ADR-H(foreground 동시 수신 정책) 문서.
  - iOS sim push fixture 절차서 + Android 실기기 라이브 검증 기록.
- **Acceptance criteria**:
  - Android 실기기: 데스크톱 데몬 trigger → push 수신 → 채팅룸에 메시지 머지 → 한국어 정상.
  - iOS sim: `.apns` drag-drop → 동일 머지 흐름 검증.
  - 같은 `messageId`(또는 ADR-C 키)가 push와 WS 양쪽에서 도착하면 단 한 번만 SQLite append.
  - SQLite WAL 모드에서 동시 write가 트랜잭션 손상 없이 처리됨(부하 테스트).
- **Dependencies**: P9.
- **Risk callouts**:
  - Expo Managed의 push 제약: P10a 시작 시 ADR-B 결정.
  - iOS 라이브 검증 미시행 상태에서 실기기 동작 불확실: 시뮬레이션 + post-MVP TODO 명시.
- **Effort**: M (4~6일).

### P10b. Deep link + fetchHint + 알림 탭 흐름

- **Goal**: 사용자가 알림을 탭하면 정확한 채팅룸으로 deep link되고, 부족한 콘텐츠를 `fetchHint`로 가져와 envelope 라운드트립으로 보강합니다. Hybrid send-via-Tailscale / receive-via-Push 동작이 완결됩니다.
- **Side**: mobile (+ desktop integration validation)
- **Scope (in)**:
  - 알림 탭 → 해당 채팅룸으로 deep link → 부족한 메시지는 WS `kind=fetch` 호출로 보강.
  - WS 복귀 시 ring buffer drop-and-mark 시그널을 채팅룸에 한국어로 표시.
  - foreground/background 천이 처리: WS attached 상태 천이가 ADR-H 정책에 맞게 동작.
- **Out of scope**: 토큰-by-token 백그라운드 스트리밍, E2E 암호화, 다중 디바이스 fan-out.
- **Key deliverables**:
  - Deep link 라우터 + 채팅룸 도착 정확성.
  - fetchHint round-trip 데모.
  - Hybrid 송수신 통합 시나리오 자동/수동 QA 체크리스트.
- **Acceptance criteria**:
  - Android 실기기: 알림 탭 → 정확한 채팅룸 진입 → fetchHint 호출로 full payload 보강 → 한국어 정상.
  - iOS sim: 동일 흐름 검증.
  - 비행기 모드에서 push가 끊긴 동안의 메시지는 WS 복귀 시 fetch로 보강(또는 ring buffer drop-and-mark 시그널이 채팅룸에 한국어로 표시).
  - WS attached일 때 데스크톱이 push 발송을 skip하는지 통합 검증.
- **Dependencies**: P10a.
- **Risk callouts**:
  - Deep link permission(iOS Universal Links / Android App Links) 사전 셋업 필요: P10b 첫 0.5일 PoC.
- **Effort**: M (3~5일).

### P11. 모바일 폴리시 + 에러 카탈로그 + 한국어 i18n 완성

- **Goal**: 모바일의 모든 화면/에러 경로가 한국어 i18n 카탈로그를 따르고, 토큰 만료/revocation/Tailscale unreachable/디바이스-lost 흐름이 graceful하게 처리됩니다. 셸 pane MVP 정책(읽기만/disabled)이 한국어로 일관되게 안내됩니다.
- **Side**: mobile
- **Scope (in)**:
  - `packages/protocol`에 정의된 error code catalog를 모바일 i18n 사전과 연결.
  - 토큰 lifecycle UI: 만료 임박(7일), 만료, 수동 revocation 흐름.
  - 연결 상태 표시: connected / reconnecting / unreachable / unauthorized / revoked.
  - 셸 pane 채팅룸: read-only로 표시 + "이 룸은 셸 세션이며 현재 입력은 지원하지 않습니다" 안내.
  - 설정 화면: 페어링 목록, 디바이스 이름 변경(로컬), unpair 액션, "Device lost" 액션.
  - 접근성: 기본 동적 폰트 사이즈 대응, 다크 모드 대응.
- **Out of scope**: Chat room rename sync to desktop, E2E 암호화 UI, fan-out 디바이스 관리.
- **Key deliverables**:
  - i18n 카탈로그(모바일).
  - 에러/연결 상태 UI 컴포넌트.
  - 셸 pane read-only 정책 적용.
- **Acceptance criteria**:
  - 모든 에러 경로가 한국어 메시지로 처리되고, 영어 기본 메시지가 사용자에 노출되지 않음.
  - 토큰 만료 시뮬레이션 → 자동 unpair UI 표시 → 재페어링 flow로 안내.
  - 셸 pane 룸 진입 시 read-only 안내가 표시되며 입력창은 비활성.
  - QA 체크리스트 통과 (iOS sim + Android 실기기 양쪽).
- **Dependencies**: P10.
- **Risk callouts**:
  - i18n 사전이 단계별로 누락된 키를 노출할 수 있음: P11에 lint(미사용/미정의 키 검사) 포함.
- **Effort**: M (3~5일).

### P12. 릴리스 단계: 코드사이닝 + 노타라이즈 + 앱 번들 + 사용자 가이드

- **Goal**: 데스크톱 앱을 Developer ID 인증서로 sign + notarize하여 외부 배포 가능한 `.app`/`.dmg` 생성. 모바일은 internal distribution(TestFlight internal 또는 ad-hoc Android APK) 형태로 사용자에게 전달. App Store/Play Store 공식 배포는 out of scope.
- **Side**: both
- **Scope (in)**:
  - Desktop: `xcodebuild archive` → `xcrun notarytool submit` (keychain-profile) → staple → `.dmg` 패키징.
  - 환경 변수/Tailscale 의존성/Keychain 설정 가이드(`docs/setup-desktop.md`).
  - 모바일: Android APK(Expo `eas build --profile preview` 또는 Bare에 따라 `gradlew assembleRelease`). iOS는 simulator 빌드 산출물 + 페어링 가이드.
  - 사용자 가이드(`docs/user-guide.md`): 한국어, 페어링/세션 관리/Push 정책/iOS 제약 명시.
  - 운영 가이드(`docs/operations.md`): 로그 위치, ring buffer overflow 시 대응, 토큰 revocation 절차.
  - 릴리스 노트 v1.0.
- **Out of scope**: 자동 업데이트, 텔레메트리, App Store/Play Store 제출.
- **Key deliverables**:
  - 서명+노타라이즈된 `.app` + `.dmg`.
  - Android APK.
  - 사용자/운영 가이드 + 릴리스 노트.
- **Acceptance criteria**:
  - 다른 macOS 머신(가능하면 별도 사용자 계정)에서 `.dmg` 더블클릭 → Gatekeeper 통과 → 정상 실행.
  - APK가 Android 실기기에서 설치/실행.
  - 가이드만 보고 페어링이 처음 사용자에게도 끝까지 진행 가능 (셀프 워크스루로 검증).
- **Dependencies**: P11.
- **Risk callouts**:
  - notarytool 실패(엔타이틀먼트/sandboxing 이슈): P1에서 dry-run을 미리 통과시켜 두기.
  - APNs/FCM key가 릴리스 빌드에 잘못 포함될 위험: 빌드 스크립트에서 key path를 빌드 산출물 외부로 강제.
- **Effort**: M (3~5일).

---

## 2. Order Constraint (Critical)

```
P1 → P2 → P3 → P4 → P5 → P6a → P6b → S1 → [P7: PROTOCOL FREEZE GATE] → P8 → P9 → P10a → P10b → P11 → P12
```

- **데스크톱(P1~P6b)은 모바일 작업 시작 전 반드시 완성**됩니다. 이 시점에서 데스크톱은 단독 가치를 갖습니다(다중 Claude/셸 세션, agent-view, pairing UI까지). 모바일이 없어도 데스크톱 사용자에게 finished product.
- **S1 mini-spike**: P6b 종료 직후 P7 진입 전에 FCM/APNs wire validation을 수행. wire 미통과 시 P5/P6 작업으로 되돌아가서 정렬.
- **P7 protocol freeze gate**: TS codec ↔ Swift codec 라운드트립이 fixture corpus 전체에 대해 통과해야 P8 진입. 통과 실패 시 desktop 단계로 되돌아가서 정렬.
- **모바일(P8~P11)**: P7 이후에 진입. 각 단계는 vertical slice를 갖고(각각 한국어 i18n + 에러 + UI까지) 단독 데모 가능.
- **P12 릴리스**: 양쪽이 모두 완성된 뒤 통합 릴리스.

병렬 가능 윈도우(선택적, single-developer라 권장 아님):
- P5 (Push Sender) ↔ P6a (Pairing UI): 서로 독립이며 P6b 진입 전까지 병렬 가능. 단, 단일 개발자라면 직렬 권장.

---

## 3. Phase Decomposition Principles

- **Vertical slice within each side.** 데스크톱은 각 단계마다 자체 demo(UI + 데이터 흐름 + 검증)를 제공합니다. 모바일도 동일. "WS만 동작", "SQLite만 동작" 같은 수평 레이어 단계를 만들지 않습니다.
- **Cross-side integration only at the freeze gate.** 데스크톱과 모바일은 P7에서만 envelope contract로 만납니다. 그 외에는 서로의 진행을 차단하지 않습니다.
- **Korean-safe at every boundary.** 메시지 자르기, drop-and-mark, push preview는 모두 UTF-8 message-boundary 검증을 수락 기준에 포함합니다.
- **Reserved fields over premature features.** 범위 밖 기능(fan-out, E2E 암호화, 세션 resume)은 envelope/스키마에 reserved 필드만 두고 단계 안에서는 구현하지 않습니다.

---

## 4. Cross-Cutting Concerns

### 4.1 한국어 i18n 카탈로그

- 위치: `packages/protocol/i18n/ko.json` (공유), `desktop/Resources/ko.lproj` (Swift bundle), 모바일 `assets/i18n/ko.json`.
- 에러 코드와 한국어 메시지가 1:1 매핑. 영어 기본 메시지 노출 금지.
- P7에서 catalog가 freeze되고, 이후 단계에서 새 키는 add-only.

### 4.2 에러 카탈로그

- 형식: `{ code: string, severity: info|warning|error, koMessage: string, recoveryHint?: string }`.
- 주요 코드(예시, 최종 목록은 P7에서 확정):
  - `BUFFER_OVERFLOW_DROPPED` — 링버퍼 overflow로 메시지 단위 drop 발생.
  - `AUTH_EXPIRED` — 토큰 만료.
  - `AUTH_REVOKED` — 토큰 revoke됨.
  - `TAILSCALE_UNREACHABLE` — Tailscale system service 미동작/미연결.
  - `MAX_SESSIONS_REACHED` — `CHAT_TERMINAL_MAX_SESSIONS` 한도.
  - `PUSH_PAYLOAD_TOO_LARGE` — 4KB 한도 초과.
  - `SHELL_PANE_INPUT_NOT_SUPPORTED` — 셸 pane 모바일 입력 제한 (MVP 정책).

### 4.3 환경 변수

| 변수 | 기본값 | 사용 단계 |
|------|--------|----------|
| `CHAT_TERMINAL_MAX_SESSIONS` | 20 | P2~ |
| `CHAT_TERMINAL_WORKSPACE_ROOT` | `$HOME` | P2~ |
| `CHAT_TERMINAL_TAILSCALE_HOST` | (선택) | P6~ |
| `CHAT_TERMINAL_FCM_KEY_ID` | (필수, Keychain item ID) | P5~ |
| `CHAT_TERMINAL_APNS_KEY_ID` | (필수, Keychain item ID) | P5~ |
| `CHAT_TERMINAL_LOG_LEVEL` | `info` | P1~ |

### 4.4 로깅 및 관측성

- 데스크톱: `~/Library/Logs/ClaudeAlarmTerminal/*.log`, 일자별 로테이션.
- 모바일: 인앱 로그 화면(개발 모드만), 프로덕션은 SQLite의 `events` 테이블에 최근 100건.
- 민감 정보(토큰, FCM/APNs key) 로깅 금지. 코드 리뷰 체크리스트에 포함.

### 4.5 보안

- 토큰: macOS Keychain(데스크톱), `expo-secure-store`(모바일).
- WS auth: Bearer token + 토큰 lifecycle (만료/revocation/lost).
- Tailscale에 의존: tailnet 외부 접근 차단.
- E2E 암호화는 deferred(post-MVP); push payload가 Google/Apple을 통과한다는 사실을 사용자 가이드에 명시.
- **FCM/APNs key 누출 대응 rotation 절차** (운영 가이드 `docs/operations.md`에서 상세 명세):
  - FCM 서비스 계정 JSON 누출 감지 시: Google Cloud Console에서 서비스 계정 키 재발급 → Keychain item 업데이트 → 모든 디바이스의 push 채널 invalidation 신호 emit → 사용자에게 재페어링 안내(한국어). 이전 키는 즉시 폐기.
  - APNs `.p8` key 누출 감지 시: Apple Developer Account에서 새 key 발급 → 기존 key revoke → Keychain item 교체 → 모든 디바이스 push 채널 invalidation → 재페어링 강제. team ID/key ID 변경 사항 환경 변수 반영.
  - 두 경우 모두: 누출 시점 ± 24h 로그 보존, `events` 테이블에 incident 기록, 신규 키 적용 후 mini-spike S1 절차 재수행하여 wire 검증.

### 4.6 FCM/APNs 인프라 셋업

- Firebase 프로젝트 + APNs key 발급은 P5 진입 직전 1일 PoC로 진행.
- 서비스 계정 JSON + APNs `.p8` 키는 Keychain에 저장하고 환경 변수에는 path/ID만 노출.

### 4.7 Effort Calendar (with contingency)

각 단계의 effort 추정치에 1.2 배 contingency를 곱한 calendar 환산, ADR 작성 시간 별도 가산, 그리고 P7 freeze 실패 시 재작업 budget을 분리해 트래킹합니다.

| 단계 | 기본 effort | × 1.2 contingency | 비고 |
|------|-----------|------------------|------|
| P1 | 5~8일 | 6~10일 | dry-run notarize 포함 |
| P2 | 6~9일 | 7~11일 | actor 경계 명세 포함 |
| P3 | 4~6일 | 5~7일 | ADR-E 작성 +1일 |
| P4 | 5~8일 | 6~10일 | single-writer 큐 설계 포함 |
| P5 | 4~7일 | 5~9일 | ADR-D 작성 +0.5일, mini-spike S1 별도 |
| P6a (Pairing UI + 토큰 발급) | 3~5일 | 4~6일 | ADR-A 작성 +1일 |
| P6b (토큰 lifecycle + Tailscale) | 3~4일 | 4~5일 | ADR-F 작성 +0.5일 |
| Mini-spike S1 (real wire) | 1~2일 | 2일 | P6b → P7 사이 |
| P7 (freeze gate) | 3~5일 | 4~6일 | freeze 실패 재작업 budget 3~5일 별도 |
| P8 | 4~6일 | 5~7일 | — |
| P9 | 6~9일 | 7~11일 | chat-room↔pane 매트릭스 포함 |
| P10a (FCM/APNs + dedupe) | 4~6일 | 5~7일 | ADR-B/C/H 작성 +1.5일 |
| P10b (deep link + fetchHint) | 3~5일 | 4~6일 | — |
| P11 | 3~5일 | 4~6일 | i18n lint 포함 |
| P12 | 3~5일 | 4~6일 | 사용자/운영 가이드 포함 |

- 기본 effort 합산(상한): 약 64일 × 1.2 = 약 77일 ≈ 약 15.4 working weeks
- ADR 작성 가산(약 4.5일) + Mini-spike S1(2일) + freeze 실패 재작업 budget(최대 5일) = 약 11.5일 추가
- **달력 목표: 14 working weeks (기본) + 4 weeks contingency = 총 18 weeks.** Single-developer 환경에서 컨텍스트 스위칭/검증 비용을 흡수.

---

## 5. ADR-lite Block

### ADR: Phase Decomposition for Claude Alarm Terminal v4

- **Status**: Accepted (master plan v4).
- **Date**: 2026-05-13.

**Decision**: 12-phase plan with strict desktop-first ordering (P1~P6 데스크톱 → P7 protocol freeze gate → P8~P11 모바일 → P12 릴리스). 각 단계는 vertical slice이며 cross-side 통합은 P7에서만 발생.

**Drivers (top 3)**:
1. Desktop-first build order는 spec의 primary priority이며, 데스크톱 단독 완성품이 모바일과 무관하게 가치를 가져야 합니다.
2. Single-developer 환경에서 컨텍스트 스위칭 비용을 통제하기 위해 직렬 desktop → mobile 순서를 선택.
3. WS/Push envelope의 protocol drift 위험을 P7 freeze gate로 흡수하여 mobile 단계가 명확한 contract 위에서 진행되도록 함.

**Alternatives considered**:
- *Interleaved (Option B)*: 데스크톱/모바일 교차 진행. → 단일 개발자에 컨텍스트 비용 큼, envelope drift 위험. 거부.
- *Mobile-first prototype (Option C)*: mock 데몬 위 모바일 UX 선행. → 시뮬레이션 부채, spec primary priority 위반. 거부.

**Consequences accepted**:
- 모바일 사용자에게 가치가 가는 시점이 늦어집니다. 데스크톱 단독으로도 가치가 있어야 한다는 spec 요구를 만족하므로 수용.
- 데스크톱-모바일 통합 이슈는 P7 freeze gate + P10 통합 검증에서 한 번에 발견됩니다. 단계별 통합 누락 위험은 freeze gate의 fixture corpus와 P10 통합 테스트로 흡수.
- 셸 pane 모바일 입력은 MVP에서 disabled(read-only)로 시작합니다. 모바일 셸 UX는 향후 단계로 분리.
- iOS APNs 라이브 검증은 시뮬레이터 + `.apns` drag-drop에 의존합니다. 실기기 검증은 디바이스 확보 시점으로 deferred.

**Follow-ups for detailed phase plans to resolve**:
- **ADR-A** (P6a에서 작성, P7 freeze 직전 동결): `chatRoomId` 발급 주체 — 모바일 발급 vs 데스크톱 발급, 그리고 `ourSessionId`의 lifetime(인프로세스 데몬 재시작 시 invalidate 정책)을 확정합니다.
- **ADR-B** (P10a 시작 시): Expo Managed 유지 vs Bare eject. FCM/APNs native 모듈 요구사항이 Managed 한도를 넘으면 eject.
- **ADR-C** (P10a): Push 중복 dedupe key — `messageId` 단독 vs `sessionId + seq` 보강. ADR-H와 함께 결정.
- **ADR-D** (P5): APNs HTTP/2 Swift 라이브러리 선택(네이티브 vs 외부 패키지).
- **ADR-E** (P3): agent-view 렌더링 + 인터랙션 — 렌더링은 SwiftUI AttributedString(ANSI SGR 파서) vs mini-libghostty embed vs plain strip 중 택1. 인터랙션은 키보드 네비게이션, 정렬(default `lastActivityAt` desc), status 필터, `needsInput` 시각 큐 정책을 명시. 수락 기준: 한국어 + ANSI SGR + `\r` 처리 통과.
- **ADR-F** (P6b/P8): Tailscale prerequisite UX — 모바일 첫 페어링 단계에서 Tailscale 앱 설치/로그인/MagicDNS active 상태 reachability probe 수행. 미설치 시 App Store/Play Store 딥링크 + 한국어 안내. 사용자 가이드(`docs/user-guide.md`)에 설치 prerequisite 섹션 추가.
- **ADR-G** (P7): Workspace sync model — `workspace.list` 응답 스키마 freeze. 데스크톱에서 workspace 변경 발생 시 WS notification envelope(`kind=workspace.changed`) emit. 모바일 reconnect 시 full pull vs delta sync 선택을 명시.
- **ADR-H** (P10a): Mobile foreground 동시 수신 정책 — WS handler ↔ push handler 동시 SQLite write 시 SQLite WAL 모드 enable, foreground 수신 정책(push drop / `messageId` dedupe / 둘 다 로깅) 중 택1. dedupe key는 ADR-C와 통합 결정.
- **ADR-I** (P2): libghostty surface 자원 관리 정책 — cmux 패턴 채택(각 세션마다 독립 `ghostty_surface_t` 인스턴스 생성, hibernate/pause/release 로직 없음). 비가시 surface는 PTY read + scrollback + atlas texture를 그대로 유지하며 AppKit `displayLayer` 호출 부재로만 GPU 자원 idle. 근거: cmux `Sources/GhosttyTerminalView.swift` 직접 정탐 결과 hibernate 코드 0줄, `occlusionState` 사용처 2건은 모두 디버그 telemetry. Apple Silicon Mac 16GB+ 기준 20 세션 시 약 400~600MB 메모리 부담은 수용 범위. 운영 telemetry는 `CHAT_TERMINAL_DEBUG_SURFACE_STATS=1` 환경변수로 cmux의 `DebugRenderStats` 패턴을 모방하여 활성화. 20 세션 동시 운영 시 메모리 압박 보고가 들어오면 P4+에서 hibernate 재검토.
- **Error code catalog 확정** (P7): 위 4.2의 코드 목록을 최종화.
- **iOS 실기기 검증 시점**: post-MVP TODO로 등록.

---

## 6. Self-Check

문서 전반의 우회 표현 사용 여부 검사 결과:

- 우회/임시 구현을 의미하는 표현(앞 글자 f/w/s로 시작하는 슬롭 키워드 3종)의 사용처: 0건.
- QR 페어링과 6자리 코드 페어링은 spec이 정의한 두 가지 정상 경로이며, 우회 경로가 아닙니다(평등한 두 경로로 기술).
- 한국어 i18n은 영어 기본 메시지를 노출하지 않으며, 우회용 영어 텍스트 레이어를 만들지 않습니다.
- WS 미연결 시 push 송신, lid-close 시 push 송신은 spec이 정의한 정상 경로(WS 스트림 ↔ push 송신의 명시적 양분)이며, 우회 layer가 아닙니다.

스펙 정의(우회 구현 금지) 관점에서의 위반: 없음.

### v4 → v5 deltas

v4 → v5 deltas applied (12 items): R1(ADR-E agent-view 렌더링/인터랙션), R2(Daemon lifecycle 정책 — beginActivity + lid-close PTY 보존), R3(Effort 1.2× contingency + 18-week 캘린더), R4(ADR-F Tailscale prerequisite UX), R5(P2 PTY env/cwd 격리 invariant), R6(ADR-G Workspace sync model), R7(P6→P6a/P6b 분할, P10→P10a/P10b 분할, P9 chat-room↔pane 매트릭스), R8(P4 PTY single-writer 큐 + 우선순위), R9(ADR-H Mobile foreground 동시 수신 정책 + SQLite WAL), R10(P3 셸 pane preview prompt/CR 처리), R11(4.5에 FCM/APNs key rotation 절차), R12(Mini-spike S1 wire validation).

