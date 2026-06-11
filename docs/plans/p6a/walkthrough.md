# P6a Walkthrough — Pairing UI (QR + 6자리 코드) + Keychain 실 왕복 실증

본 문서는 P6a Day 3 Pairing UI와 KeychainDeviceStore 실 구현의 GUI walkthrough 및
자동 검증 결과를 기록한다. secret 평문은 어떤 절차에서도 출력하지 않는다(master § 7 보안 원칙).

---

## Day 3 — Pairing UI + Keychain 실 구현

### 산출물

- `Sources/Pairing/KeychainDeviceStore.swift` — DeviceStore protocol 실 구현
  (SecItemAdd/CopyMatching/Update/Delete + kSecClassGenericPassword)
- `Sources/UI/Pairing/PairingModel.swift` — @MainActor ObservableObject
  (코드 발급 / QR payload URL / 6자리 코드 / 만료 카운트다운 / 디바이스 목록)
- `Sources/UI/Pairing/QRImageView.swift` — CIQRCodeGenerator → CIContext → NSImage
- `Sources/UI/Pairing/PairingView.swift` — QR + 6자리 코드 + 카운트다운 + 발급 버튼 + 디바이스 목록
- `Sources/ClaudeAlarmTerminal/AppDelegate.swift` — KeychainDeviceStore 주입 + 페어링 메뉴 진입점
- `project.yml` — 5개 non-app 타겟 excludes에 신규 UI 3파일 추가

### 자동 검증 결과 (executor 직접 수행)

| # | 종료 조건 | 명령 | 결과 |
|---|---|---|---|
| 1 | UI 컴파일 | `xcodegen generate && xcodebuild build -scheme ClaudeAlarmTerminal` | BUILD SUCCEEDED (exit 0) |
| 2a | non-app 비파괴 | `xcodebuild build -scheme SessionVerifier` | BUILD SUCCEEDED |
| 2b | non-app 비파괴 | `xcodebuild build-for-testing -scheme WorkspaceTests` | TEST BUILD SUCCEEDED |
| 2c | 나머지 non-app | PTYVerifier / GhostBridgeVerifier / DaemonDevCLI build | 3개 모두 BUILD SUCCEEDED |
| 4 | Keychain 왕복 | 앱 기동 → `security find-generic-password -s com.choms0521.ClaudeAlarmTerminal.device` | item 존재 (class genp, svce 일치) |
| 5 | secret UI 미노출 | `grep -rn "deviceTokenSecret" Sources/UI/` 화면 표시 경로 | 0건 (주석/payload 구성만, Text 표시 없음) |
| 6 | 전체 회귀 | SessionTests + WorkspaceTests + DaemonTests | 183 + 83 + 110 = 376 green |

#### 종료 조건 4 — Keychain 실 왕복 상세

앱을 dev로 실행하면 `DaemonBootstrap(store: KeychainDeviceStore())`가 인증 게이트용
디바이스 1건을 `upsert`하여 실 Keychain에 item을 생성한다. 앱 종료 후에도 item이
login.keychain-db에 영속됨을 확인했다.

```
$ security find-generic-password -s com.choms0521.ClaudeAlarmTerminal.device
keychain: ".../login.keychain-db"
class: "genp"
    0x00000007 <blob>="com.choms0521.ClaudeAlarmTerminal.device"
    "acct"<blob>="<tokenId UUID>"     # 식별자 — secret 아님
    "svce"<blob>="com.choms0521.ClaudeAlarmTerminal.device"
```

`acct`는 tokenId(식별자)이고 `svce`는 명세 부록 A의 service명과 일치한다. secret 본문
(`v_Data`/`gena` blob)은 출력하지 않았다.

#### QR 렌더 — 코드 레벨 실증

`QRImageView.makeQRImage`와 동일한 경로(CIQRCodeGenerator → CIContext → NSImage)를
독립 실행해 실제 이미지 생성을 확인했다.

```
QR NSImage 생성 성공: 220x220
TIFF 바이트: 193826 (렌더 실증)
```

#### 만료 카운트다운 — 코드 레벨 실증

`PairingModel.updateRemaining`과 동일한 산식(`Int(expiry.timeIntervalSinceNow.rounded(.down))`)을
독립 실행해 1초 단위 감소를 확인했다.

```
t=0 남은초: 299, t=2 남은초: 297, 감소량: 2 → PASS
```

### 사람 육안 확인 필요 항목 (사용자 친람 후 체크)

다음 항목은 GUI 인터랙션(앱 메뉴 클릭 → 페어링 창 → 버튼 클릭)이 필요하므로
체크박스를 비워 두고 친람 후 채운다. 자동 검증으로 진입점 배선(메뉴 항목 →
`openPairingWindow` → `NSHostingView(PairingView)`)과 QR/카운트다운 로직은 이미 실증했다.

#### 사전 준비

```
APP="/Users/mscho/Library/Developer/Xcode/DerivedData/ClaudeAlarmTerminal-*/Build/Products/Debug/ClaudeAlarmTerminal.app"
open "$APP"
```

- [ ] **(1) 페어링 창 진입:** 앱 메뉴(상단 좌측 앱 이름 메뉴) → "디바이스 페어링…"을
      클릭한다. 별도 창("디바이스 페어링")이 열린다.
- [ ] **(2) 코드 발급:** 페어링 창에서 "코드 발급" 버튼을 누른다. QR 코드 이미지가
      렌더되고, 그 아래 6자리 코드("123 456" 형태)가 표시된다.
- [ ] **(3) 카운트다운 감소:** "N초 후 만료" 텍스트의 N이 1초마다 줄어드는 것을 관측한다
      (30초 이하로 떨어지면 주황색으로 바뀐다).
- [ ] **(4) 새 코드 발급:** "새 코드 발급" 버튼을 누르면 QR/6자리 코드/카운트다운이
      새 값으로 갱신된다.
- [ ] **(5) 디바이스 목록:** "등록된 디바이스" 섹션에 디바이스 행이 표시된다
      (이름 + 토큰 앞 8자 마스킹). secret 평문은 어디에도 표시되지 않는다.
- [ ] **(6) secret 미노출 육안 확인:** 페어링 창 전체에서 base64url secret 평문이
      어떤 라벨/텍스트로도 노출되지 않음을 확인한다(QR 이미지와 6자리 코드만 노출).

### 친람 결과

(사용자 육안 확인 후 기록)
