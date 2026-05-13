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
