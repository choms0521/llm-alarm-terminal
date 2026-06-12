# P6b Walkthrough — lifecycle UI 배선 + Tailscale 진단 UX

본 문서는 P6b Day 3 lifecycle UI(만료 임박 뱃지 + 폐기 버튼)와 Tailscale 사전 진단 UX의
GUI walkthrough 및 자동 검증 결과를 기록한다. secret 평문은 어떤 절차에서도 출력하지 않는다
(master 보안 원칙). 진단 카드는 koreanReason만 노출하며 실 IP는 표시하지 않는다.

---

## Day 3 — lifecycle UI 배선 + 사전 진단 UX

### 산출물

- `Sources/UI/Pairing/PairingModel.swift` — lifecycle 판정 노출(`isExpiringSoon`/`daysRemaining`/
  `isExpired` — DeviceLifecyclePolicy 위임) + `revokeDevice(id:)`(DeviceRevocationCoordinator 경유) +
  Tailscale 진단(`refreshTailscale`/`tailscaleResult`). coordinator/diagnostics 옵셔널 주입.
- `Sources/UI/Settings/PairingSettingsContent.swift` — 디바이스 행 만료 임박/만료/폐기됨 뱃지 +
  폐기 버튼(nosign) + 폐기 확인 다이얼로그 + Tailscale 상태 카드(`TailscaleStatusCard`).
- `Sources/ClaudeAlarmTerminal/AppDelegate.swift` — 데몬 부트스트랩 후
  `DeviceRevocationCoordinator`(store + WSServer + InMemoryPushRevocationSink) +
  `TailscaleDiagnostics`(ProcessTailscaleProbe) 생성·주입.
- `project.yml` — 신규 .swift 파일 없음(기존 파일 수정만, TailscaleStatusCard는
  PairingSettingsContent.swift 내부 정의). excludes 갱신 불필요.

### 설계 결정 — revoke vs remove 구분

- **폐기(revoke)**: `DeviceRevocationCoordinator.revoke`를 경유한다. ① store.revoke로 토큰
  무효화 → ② WSServer.disconnectDevice로 살아있는 연결 즉시 끊기 → ③ push 발신 제외 통지(seam).
  디바이스 항목은 "폐기됨" 상태로 목록에 존속한다. "Device lost" 즉시 무효화도 이 경로와 동일.
- **삭제(remove)**: `DeviceStore.remove`로 항목과 secret을 영구 제거한다. 항목 자체가 사라진다.
- 두 동작 모두 Bearer를 즉시 무효화하지만, revoke는 흔적(폐기됨 뱃지)을 남기고 remove는 남기지 않는다.

### BindStrategy 범위 — Day 3는 loopback 유지

데몬 부트스트랩의 BindStrategy는 loopback 유지다(`ws://127.0.0.1:<port>/`). tailnet opt-in 바인딩은
계획서 Day 4 범위이며, Day 3는 진단 UI callout만 실배선한다(데몬은 진단 결과와 무관하게 loopback 기동).
push 만료 알림은 seam만 예약(미배선, D-4).

### 자동 검증 결과 (executor 직접 수행)

| # | 종료 조건 | 명령 | 결과 |
|---|---|---|---|
| 1 | UI 컴파일 | `xcodegen generate && xcodebuild build -scheme ClaudeAlarmTerminal` | BUILD SUCCEEDED (exit 0) |
| 2a | non-app 비파괴 | `xcodebuild build -scheme SessionVerifier` | BUILD SUCCEEDED |
| 2b | 테스트 타겟 비파괴 | SessionTests + WorkspaceTests + DaemonTests 빌드·실행 | 3개 모두 TEST SUCCEEDED |
| 3 | GUI walkthrough | 아래 "사람 육안 확인 필요 항목" 친람 대기 | 빈 체크박스 (친람 후 채움) |
| 4 | 폐기 왕복 | GUI에서 폐기 → store.find revoked == true + 연결 끊김 | 친람 항목 (4)에서 확인 |
| 5 | secret UI 미노출 | `grep -rn "deviceTokenSecret" Sources/UI/` | 2건 모두 PairingModel(주석 + payload 구성), 신규 UI 0건 |
| - | 회귀 | 3 테스트 타겟 합산 | 183 + 83 + 148 = 414 green (기준선 유지) |

#### 종료 조건 5 — secret UI 미노출 상세

`grep -rn "deviceTokenSecret" Sources/UI/` 결과 2건은 모두 `PairingModel.swift`다.
- line 8: 주석("secret 평문을 @Published로 노출하지 않으며")
- line 84: `PairingPayload(deviceTokenSecret: issued.secretBase64url, ...)` — payload 구성.
  payload는 QR/코드 채널로만 흐르며 어떤 Text/Label에도 표시되지 않는다.

신규 추가 UI(`PairingSettingsContent.swift`의 뱃지/폐기 버튼/`TailscaleStatusCard`)에는
`deviceTokenSecret` 0건이다. Tailscale 카드는 `result.reason`(koreanReason)만 표시하고 실 IP는
노출하지 않는다(`TailscaleState.koreanReason`에 IP 미포함). P6a 판정 기준("주석/payload 구성만,
Text 표시 없음")과 동일하게 통과한다.

#### lifecycle 판정 — Day 1 테스트 커버

만료 임박/만료/남은 일수 판정 코어는 `DeviceLifecyclePolicy`가 보유하며 Day 1 테스트
(`DeviceLifecyclePolicyTests`)가 경계값을 커버한다. PairingModel은 위임만 하므로(@MainActor app
타겟 전용) Day 3 단위 테스트 신설 없이 빌드 게이트 + 친람으로 검증한다.

### 이 머신 환경 — Tailscale Stopped

이 머신의 Tailscale은 Stopped 상태다. `ProcessTailscaleProbe.probe()`가 `status --json`의
BackendState를 "Stopped"로 읽어 `.offline`로 환원하므로, Tailscale 카드는 주황 인디케이터 +
"Tailscale이 오프라인 상태입니다. 로컬 연결만 사용합니다." 사유를 표시한다(미설치라면 "Tailscale이
설치되어 있지 않습니다." 분기). 데몬은 어느 분기든 loopback으로 기동된다.

### 사람 육안 확인 필요 항목 (사용자 친람 후 체크)

다음 항목은 GUI 인터랙션이 필요하므로 체크박스를 비워 두고 친람 후 채운다.

#### 사전 준비

```
APP="/Users/mscho/Library/Developer/Xcode/DerivedData/ClaudeAlarmTerminal-*/Build/Products/Debug/ClaudeAlarmTerminal.app"
open "$APP"
```

- [ ] **(1) 설정 페이지 진입:** 메인 창 좌측 사이드바 하단의 "설정" 버튼을 클릭한다. 본 창 전체가
      설정 페이지로 전환되고 좌측 nav에 "디바이스 페어링"이 기본 선택된다. (보조: Cmd+,)
- [ ] **(2) Tailscale 상태 카드:** 페어링 콘텐츠 상단(데몬 실행 중 callout 아래)에 "원격 접속
      (Tailscale)" 카드가 표시된다. 이 머신은 Tailscale이 Stopped/미설치이므로 **주황** 인디케이터 +
      한국어 사유("...오프라인 상태입니다. 로컬 연결만 사용합니다." 또는 "...설치되어 있지 않습니다...")가
      표시된다. 우측 새로고침(arrow.clockwise) 버튼을 누르면 재진단된다.
- [ ] **(3) secret/실 IP 미노출:** Tailscale 카드에 100.x 실 IP나 base64url secret이 어떤 라벨로도
      노출되지 않음을 확인한다(한국어 사유 문구만 표시).
- [ ] **(4) 디바이스 폐기:** "등록된 디바이스" 카드의 디바이스 행에서 폐기 버튼(nosign 아이콘)을
      누른다. "이 디바이스를 폐기할까요?" 파괴적 확인 다이얼로그가 뜬다. "폐기"를 누르면 행에
      **"폐기됨" 빨강 뱃지**가 나타나고 아이콘이 빨강 xmark로 바뀐다. 폐기 버튼은 사라지고 삭제(휴지통)
      버튼만 남는다.
- [ ] **(5) 만료 임박 뱃지(선택):** 만료가 7일 이내로 임박한 디바이스가 있으면 행에 **"N일 후 만료"
      주황 뱃지**가 표시된다. 이미 만료된 디바이스는 **"만료됨" 빨강 뱃지**가 표시된다. (현행 부트스트랩
      디바이스는 1시간 만료라 임박 뱃지를 즉시 보긴 어렵다 — 만료 후 재진입 시 "만료됨" 관측 가능.)
- [ ] **(6) 삭제 동작 구분 유지:** 휴지통(삭제) 버튼은 별도로 "이 디바이스를 삭제할까요?" 다이얼로그를
      띄우고, 삭제 시 행 자체가 목록에서 사라진다(폐기됨 뱃지와 구분).
- [ ] **(7) 돌아가기:** 좌측 nav 하단의 "← 돌아가기" 버튼으로 메인 화면(HSplitView)에 복귀된다.

### 친람 결과

(사용자 친람 후 기록)

---

## Day 4 — e2e 무효화 검증 + ADR-F + Exit Gate

본 절은 Day 4 자동 검증 결과를 기록한다. Day 4는 모바일 없이 `DaemonDevCLI --lifecycle` + in-process
e2e 테스트로 만료/revoked 토큰의 WS 연결·push 거부를 측정하고, ADR-F 동결 + fetchHint 명세 게이트 +
Exit Gate 측정을 수행한다. secret/실 IP 평문은 어떤 절차에서도 출력하지 않는다.

### 산출물

- `Sources/DaemonDevCLI/main.swift` — `--lifecycle` 모드. 데몬 1개 위에서 (a) 디바이스 A 인증 연결
  → revoke → 끊김, (b) 만료 디바이스 B Bearer connect → 게이트 ② UNAUTHORIZED, (c) revoked A push
  발신 제외를 순차 측정하고 "REVOKE_DISCONNECTED"/"EXPIRED_REJECTED"/"PUSH_REJECTED_REVOKED" 3 신호를
  stdout으로 내보낸다. secret 평문 미출력.
- `Tests/DaemonTests/LifecycleE2ETests.swift` — 만료/revoke(WS+push) 전 경로 in-process e2e 4건.
- `docs/adr/F-tailscale-prerequisite-ux.md` — ADR-F 동결(6 섹션 전부 + Day 0 스파이크 실측 반영).
- `Sources/Daemon/DaemonBootstrap.swift` — tailnet opt-in 바인딩 배선(`resolveBindStrategy()` +
  `tailscaleProbe` 주입). env `CLAUDE_ALARM_BIND_STRATEGY=tailscale`일 때만 진단 → tailscaleIP,
  기본은 loopback 유지(무변경).
- `Tests/DaemonTests/DaemonBootstrapTests.swift` — opt-in 게이트 3건(기본 loopback/opt-in running/
  opt-in offline 폴백).
- `project.yml` — DaemonDevCLI 타겟에 `Sources/Push` 추가(`--lifecycle`이 PushSender/MockPushTransport를
  사용하므로). 신규 UI 파일 없음 — non-app excludes 갱신 불필요.

### 자동 검증 결과 (executor 직접 수행)

| # | 종료 조건 | 명령 | 결과 |
|---|---|---|---|
| 1 | `--lifecycle` exit 0 + 3 신호 | `./daemon-dev-cli --lifecycle` | exit 0, 3 신호 출력(REVOKE_DISCONNECTED/EXPIRED_REJECTED/PUSH_REJECTED_REVOKED) |
| 1b | secret 평문 0건 | `--lifecycle` stdout grep `secret/IP/Bearer/tok.` | 0건 |
| 2 | revoked WS 거부 e2e | `testRevokedConnectionCancelledAndReconnectUnauthorized` | passed (cancelled + 재connect UNAUTHORIZED) |
| 3 | 만료 WS 거부 e2e | `testExpiredDeviceRejectedAtGateTwo` | passed (게이트 ② UNAUTHORIZED + close) |
| 4 | revoked push 거부 e2e | `testRevokedDevicePushExcludedFromSend` | passed (transport 미호출, excludedCount +1) |
| 5 | LifecycleE2ETests green | `xcodebuild test -only-testing:DaemonTests/LifecycleE2ETests` | 4 tests, 0 failures (TEST SUCCEEDED) |
| 6 | ADR-F 6 섹션 | `grep -cE "^## (Decision\|Drivers\|Alternatives\|Why\|Consequences\|Follow-ups)" docs/adr/F-*.md` | 6 |
| 7 | fetchHint 미배선 | `grep -rn "case fetch" Sources/Daemon/WSEnvelope.swift` | 0건 (grep exit 1) |
| 8 | 최종 회귀 | DaemonTests + WorkspaceTests + SessionTests | 152 + 83 + 183 = 418 green (414 기준 + 신규 4) |
| - | 앱 빌드 | `xcodebuild build -scheme ClaudeAlarmTerminal` | BUILD SUCCEEDED |
| - | CLI 빌드 | `xcodebuild build -scheme DaemonDevCLI` | BUILD SUCCEEDED |
| - | secret/실IP 로그 노출 | `grep -rnE "deviceTokenSecret\|100\..." Sources/ \| grep -iE "log\|print\|FileHandle\|os_log"` | 0건 |

#### 종료 조건 1 — `--lifecycle` 3 신호 상세

`daemon-dev-cli --lifecycle` 실행 시 stdout은 정확히 3줄이다:

```
REVOKE_DISCONNECTED
EXPIRED_REJECTED
PUSH_REJECTED_REVOKED
```

exit code 0. 각 신호는 in-process 데몬 위에서 실 경로를 통과한 뒤에만 emit된다 — 신호 ①은
`DeviceRevocationCoordinator.revoke` 후 연결 끊김(상태 전이 cancelled/failed 또는 disconnectedCount
>= 1)을 관측하고, 신호 ②는 만료 디바이스 connect 후 envelope kind=error code=UNAUTHORIZED 수신을
관측하며, 신호 ③은 `PushSender.sendIfNotRevoked`가 revoked 디바이스를 제외(sentCount == 0,
excludedCount == 1)함을 관측한 뒤 emit한다. 어느 단계라도 실패하면 비-0 exit code로 종료한다.

#### 종료 조건 7 — fetchHint 미배선(P7 freeze 대상)

`grep -rn "case fetch" Sources/Daemon/WSEnvelope.swift`는 0건이다(grep exit 1). EnvelopeKind에
`fetch` kind는 P6b에서 추가하지 않는다 — v0.9 스키마를 P7 freeze 전에 흔들지 않기 위함이다(D-5).
스키마·의미는 계획서 §8.2에 "kind=fetch payload `{messageId}` + P7 v1.0 freeze 대상"으로 명세되어
있으며, 코드 배선(kind 추가·핸들러·ring 재조회)은 P7(freeze) + P10b(모바일 송수신)가 맡는다.
참고로 `PushEnvelope.fetchHint: String?`(P5 산출물)은 별개 필드이며, §8의 WS `kind=fetch`와 무관하다.

#### tailnet opt-in 바인딩 — Day 4 부트스트랩 배선

계획서 Day 4 항목 "tailnet opt-in 바인딩 배선"을 `DaemonBootstrap`에 추가했다. `WSServer`의
`BindStrategy`(loopback/tailscaleIP) 분기는 Day 2에 도입됐고, Day 4는 그 분기를 데몬 부트스트랩에서
**진단 결과로 결정하는 opt-in 경로**를 잇는다.

- `DaemonBootstrap.resolveBindStrategy()` — env `CLAUDE_ALARM_BIND_STRATEGY` 게이트:
  - 미설정 또는 `loopback` → loopback(진단 미실행 — 기본 비파괴, Stopped 환경 부팅 지연 회피)
  - `tailscale`(명시 opt-in) → `TailscaleDiagnostics.diagnose()` 실행 → running이면 tailscaleIP,
    그 외 분기는 loopback 폴백
- `DaemonBootstrap`에 `tailscaleProbe` 옵셔널 주입 추가(테스트는 fake probe로 결정론 검증, 미주입 시
  명시 opt-in일 때만 `ProcessTailscaleProbe` 기본 사용).
- 검증: `DaemonBootstrapTests` 3건 추가 — (a) opt-in 없으면 loopback + probe 미호출(진단 미실행),
  (b) opt-in+running → probe 1회 호출 + 진단 IP 바인딩, (c) opt-in+offline → loopback 폴백.

기본 동작은 완전 무변경이다(383/414 비파괴) — env 미설정 시 진단을 돌리지 않고 즉시 loopback으로
진행한다. 이 머신은 Tailscale Stopped이므로 실 100.x 바인딩은 측정 불가하고, Day 0 스파이크가
en0 인터페이스 격리로 메커니즘을 실증했다(`.omc/research/p6b-tailscale-spike.md`).
