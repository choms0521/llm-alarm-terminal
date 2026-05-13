# P1 Acceptance Log

Day-by-day record of exit-criteria verification for the P1 phase. Each entry stays in the file even after later days advance, so the final Day 8 walkthrough can re-check the chain.

Source plan: `docs/plans/p1/p1-detailed.html`.

---

## Day 1 — Xcode 부트스트랩 + Developer ID 준비

Date verified: 2026-05-13

| # | Exit criterion | Status | Evidence |
|---|----------------|--------|----------|
| 1 | Xcode Cmd+R로 앱 실행 시 빈 `NSWindow`가 표시된다 | PASS | CLI smoke test: `open <app>` launched PID 39473; AppKit window initialized via `AppDelegate.applicationDidFinishLaunching`; process exited cleanly on `SIGTERM`. |
| 2 | `xcodebuild -scheme ClaudeAlarmTerminal build`가 CLI에서 성공한다 | PASS | `scripts/build.sh debug` reports `** BUILD SUCCEEDED **`; arm64 Mach-O produced at `build/DerivedData/Build/Products/Debug/ClaudeAlarmTerminal.app/Contents/MacOS/ClaudeAlarmTerminal`. |
| 3 | `security find-identity -v -p codesigning`이 Developer ID Application 인증서를 1개 이상 반환한다 | PASS | Identity `9664AC2F8CA4159E0BE405D1047A185D04BF549E "Developer ID Application: minseok cho (9ADWM2H336)"` present; Team ID `9ADWM2H336` recorded in `docs/build-setup.md`. |
| 4 | `xcrun notarytool history --keychain-profile <profile>`이 인증 오류 없이 실행된다 | PENDING (manual) | `claude-alarm-terminal-notary` profile not yet stored. The General must run `xcrun notarytool store-credentials` per `docs/build-setup.md` step 3, after which the criterion is expected to pass. Contingency budget (0.5d) reserved if the profile cannot be created. |

### Decisions made on Day 1

- **Project layout**: SwiftPM-style source layout under `Sources/ClaudeAlarmTerminal/` combined with an xcodegen-generated `.xcodeproj` so that `xcodebuild archive` is available for Day 8 while keeping the spec under version control as `project.yml`.
- **macOS deployment target**: `14.0` (Sonoma) — matches the plan's `NSProcessInfo.beginActivity` baseline.
- **Architecture**: `arm64` only.
- **App Sandbox**: disabled in `Resources/ClaudeAlarmTerminal.entitlements` (PTY spawn requires unsandboxed child processes per the plan).
- **Hardened Runtime**: enabled at the project level (`ENABLE_HARDENED_RUNTIME=YES`). Additional entitlements (e.g., `disable-library-validation`) deferred to Day 2 spike results.
- **Code-signing**: ad-hoc for Debug, Manual `Developer ID Application` for Release — actual archive sign deferred to Day 8.

### Risk triggers checked

- libghostty timebox (ADR-A C1) — not yet active (starts Day 2).
- Developer ID/keychain-profile risk — partially active: profile not registered, so the 0.5d contingency is on standby; not consumed.

### Carry-overs to Day 2

- Confirm Zig toolchain version compatibility with the pinned Ghostty commit (`vendor/ghostty/PINNED_COMMIT`). Local environment has `zig 0.16.0`; plan suggests `0.13.x or current stable`.
- Add `vendor/ghostty/` and `scripts/build-libghostty.sh`.
- Begin ADR-A C1 sub-timebox countdown ("Day 1/5 elapsed").

---

## Day 2 — libghostty 클론 + XCFramework 빌드 + Swift 바인딩 스파이크

Date verified: 2026-05-13
ADR-A C1 sub-timebox: **Day 1/5 elapsed** (Day 2 first commit recorded).

| # | Exit criterion | Status | Evidence |
|---|----------------|--------|----------|
| 1 | `scripts/build-libghostty.sh`가 XCFramework(또는 동등 static lib)를 산출한다 | PASS | `scripts/build-libghostty.sh release` produces `Frameworks/GhosttyKit.xcframework` (536MB, universal macos-arm64_x86_64 + ios-arm64 + ios-arm64-simulator slices). Static archive `ghostty-internal.a` + `Headers/ghostty.h` + `Headers/module.modulemap`. |
| 2 | Swift에서 libghostty 인스턴스를 alloc/dealloc하는 단위 테스트가 통과한다 | PASS | `Sources/GhostBridgeVerifier/main.swift` (21 lines, under the 30-line ceiling) calls `ghostty_init` -> `ghostty_config_new` -> `ghostty_config_free`. Binary `build/.../ghost-bridge-verifier` exits 0 printing `OK: ghostty_init + config_new/free round-trip succeeded`. |
| 3 | 핀된 commit hash가 `PINNED_COMMIT` 파일에 기록되어 있다 | PASS | `vendor/ghostty/PINNED_COMMIT` = `b0f8276658fbcc75318d2125d40146074a3fc505` (Ghostty `main` HEAD captured at Day 2 first build). |
| 4 | libghostty의 IME composition 처리 책임 위치가 spike 결과로 명확히 판정되었다 | DECIDED — **우리 책임** | `vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` line 1841 declares `extension Ghostty.SurfaceView: NSTextInputClient`. `setMarkedText` (line 1865) / `insertText` (line 1993) are implemented Swift-side. libghostty receives composed text via `ghostty_surface_text` and preedit hints via `ghostty_surface_preedit` but does not own composition state. **Mitigation**: we will adopt the same pattern in Day 3+; the +1 day contingency reserved for Day 6 IME work is held but partial reuse of Ghostty's NSTextInputClient implementation is expected to reduce its consumption. |
| 5 | libghostty wcwidth 마이크로 검증 (30줄 미만 프로그램) | DEFERRED to Day 3 (with rationale) | A standalone wcwidth check that injects '한' into a libghostty surface requires `ghostty_app_new` + a fully populated `ghostty_runtime_config_s` callback table (clipboard, action, surface lifecycle), which exceeds the 30-line budget by a wide margin. Verifying the static archive linked, the C ABI is callable, and the renderer compiled (Metal shaders built successfully). The full grid-dump verification will run on Day 3 when the AppKit window owns a real `ghostty_surface_t`. This deferral is recorded as a Day 2 risk-trigger note and does NOT activate ADR-A C1 contingency yet. |
| 6 | ADR-A C1 libghostty sub-timebox(Day 2~Day 6, 5d) 카운트다운의 Day 1/5가 종료됨이 일지에 기록된다 | LOGGED | Sub-timebox Day 1/5 elapsed at Day 2 first build success. Day 4 surface-display gate and Day 6 end-to-end gate are not yet active. |

### Decisions made on Day 2

- **Pinned commit**: `b0f8276658fbcc75318d2125d40146074a3fc505` (Ghostty 1.3.2-dev).
- **Zig toolchain**: `zig@0.15` (0.15.2 keg-only at `/opt/homebrew/Cellar/zig@0.15/0.15.2/bin/zig`). Ghostty's `build.zig.zon` declares `minimum_zig_version = "0.15.2"` and explicitly rejects 0.16.x via `requireZig`.
- **Build prerequisite**: Xcode 26's Metal Toolchain (704.6 MB) was downloaded via `xcodebuild -downloadComponent MetalToolchain` because Ghostty's renderer compiles Metal shaders during the static build step. This is now a documented setup step for fresh machines.
- **XCFramework strategy**: build Ghostty's native `-Demit-xcframework=true` target, then `cp -R vendor/ghostty/macos/GhosttyKit.xcframework Frameworks/`. The host xcodeproj links against `Frameworks/GhosttyKit.xcframework` with `embed: false` because the framework's primary artifact is a static archive (`ghostty-internal.a`), which is link-time only and cannot be codesigned.
- **Required system frameworks** discovered during Swift link: `Carbon`, `IOSurface`, `Metal`, `MetalKit`, `CoreText`, `CoreGraphics`, `QuartzCore`, `AVFoundation`, `UserNotifications`, plus `-lc++` for the embedded ImGui / glslang / spirv_cross C++ object files.
- **Entitlement update**: added `com.apple.security.cs.disable-library-validation = true` to `Resources/ClaudeAlarmTerminal.entitlements` because Ghostty's static archive contains code paths that perform dynamic loading on macOS. Required for Hardened Runtime + ad-hoc signing to coexist on local debug builds.

### Risk triggers checked

- ADR-A C1 timebox — Day 1/5 elapsed, no gate activated yet.
- libghostty Swift binding API — usable; the existing Ghostty Swift sources can be partially reused. No contingency consumed.
- Zig toolchain mismatch — initial attempt with Zig 0.16.0 failed loudly via Ghostty's `requireZig`; corrected by switching to brew's `zig@0.15` formula. No contingency consumed (handled inside the spike budget).
- Metal Toolchain missing — Xcode 26 ships without Metal compilers preinstalled. Resolved by `xcodebuild -downloadComponent MetalToolchain`. No contingency consumed.

### Carry-overs to Day 3

- Use `Frameworks/GhosttyKit.xcframework` from the main app target — already wired in `project.yml`.
- Adopt the NSTextInputClient pattern from `vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` when implementing key passthrough + IME on Day 3+.
- Day 3 must satisfy the deferred wcwidth check as part of the surface-display gate work (Day 4 is the hard deadline for any visible surface).
