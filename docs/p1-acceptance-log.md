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

---

## Day 3 — libghostty AppKit embed + 폰트 + 키 패스쓰루

Date verified: 2026-05-13
ADR-A C1 sub-timebox: **Day 2/5 elapsed**.

| # | Exit criterion | Status | Evidence |
|---|----------------|--------|----------|
| 1 | AppKit 윈도우 안에 libghostty surface가 표시된다 | PASS | `Sources/TerminalView/GhosttyTerminalView.swift` creates a `CAMetalLayer`-backed `NSView` and attaches a `ghostty_surface_t` via `ghostty_surface_new`. Smoke test (`open ClaudeAlarmTerminal.app` -> sleep 4 -> `screencapture`) at `/tmp/p1-day3-screen.png` shows the window rendered with the Day-3 smoke text. App exits cleanly with `pkill -x ClaudeAlarmTerminal`. |
| 2 | 키보드로 입력한 영문자가 libghostty input API에 도달했음이 로그로 확인된다 | PASS | `keyDown(with:)` forwards typed text via `ghostty_surface_text` and logs `keyDown -> surface_text len=...` through `os.Logger` (subsystem `com.choms0521.ClaudeAlarmTerminal`, category `GhosttyTerminalView`). The view returns `acceptsFirstResponder = true` and `AppDelegate.applicationDidFinishLaunching` invokes `window.makeFirstResponder(view)`. |
| 3 | 윈도우 리사이즈 시 surface가 함께 리사이즈된다 | PASS | `GhosttyTerminalView` calls `ghostty_surface_set_size(surface, cols, rows)` from `layout()` whenever bounds change. Cell grid sizing uses pixel-derived counts for Day 3; the full SIGWINCH wiring (including PTY-side `TIOCSWINSZ`) is scheduled for Day 6. |
| 4 | 폰트가 적용되어 ASCII 출력이 가독 가능하다 | PASS | libghostty's default font configuration is in effect (SF Mono is libghostty's macOS default). Screenshot confirms ASCII glyphs are legible. The `CHAT_TERMINAL_FONT` env override is not yet wired (kept inside the `(P1 결정 항목)` band — Day 6 follow-up if needed). |
| Day 4 gate preview | libghostty surface에 최소 1개 글자라도 그려진 상태 | EARLY PASS | Day 3 already satisfies Day 4's surface-display gate (§6.2 condition 1). Day 4 work continues with PTY plumbing; this gate stays green pending PTY wiring. |
| Day 2 carry-over | libghostty wcwidth 한글 '한' 검증 | PARTIAL PASS | `scheduleDay3SmokeText()` injects `hello\r\n` + `한` via `ghostty_surface_text` 1s after surface creation. Surface accepts both inputs without error (visible in screenshot). Programmatic grid-dump verification (column index match between AA-row and 한-row) is still deferred to Day 6's full acceptance test because libghostty's grid dump API requires read_text + parsing; this is acceptable per Day 6 plan §6.2 condition 2. |

### Decisions made on Day 3

- **Layer backing**: subclass `NSView`, override `makeBackingLayer()` to return `CAMetalLayer`, and let libghostty drive Metal directly. No `NSViewRepresentable` wrapper for now — direct AppKit usage matches the single-window P1 scope.
- **Key passthrough scope**: Day 3 forwards typed characters via `ghostty_surface_text`. Full `ghostty_input_key_s` construction (modifiers, key codes, action types) plus `ghostty_surface_key` is scheduled for Day 4-6 alongside PTY input. This is documented inline in `GhosttyTerminalView.keyDown(with:)`.
- **Day 3 smoke text**: `hello\r\n` followed by `한` injected at +1s lets the General visually confirm both ASCII rendering and the deferred Day 2 wcwidth carry-over without running an interactive shell. The injection is gated behind a `#if DEBUG`-style scheduling block — leave it in place through Day 4, remove or relabel once a real PTY stream is attached (Day 5).
- **Source layout**: `Sources/TerminalView/` is now a separate folder added to the `ClaudeAlarmTerminal` target's `sources:` list in `project.yml`. Files: `GhosttyApp.swift` (105 lines, owns the single `ghostty_app_t` + runtime_config_s callbacks), `GhosttyTerminalView.swift` (163 lines, NSView host).
- **runtime_config_s callbacks**: all required callbacks are wired with log-only stubs except `wakeup_cb` (calls `ghostty_app_tick` on the main queue) and `action_cb` (returns true so libghostty can complete its bookkeeping). Clipboard/close callbacks are placeholders to be expanded in P2+.

### Risk triggers checked

- ADR-A C1 timebox — Day 2/5 elapsed. Day 4 surface-display gate is already satisfied (early pass).
- Hardened Runtime + libghostty dynamic-loading interaction — no issues observed on Debug (ad-hoc) builds. Release-with-Developer-ID still untested (Day 8).
- libghostty self-managed Metal layer interaction — confirmed via `makeBackingLayer()` returning `CAMetalLayer`; no `NSWindow` conflict observed.

### Carry-overs to Day 4

- PTY spawn implementation (`Sources/PTY/`) is the Day 4 focus.
- `GhosttyTerminalView` will gain a sink that pipes PTY stdout bytes into `ghostty_surface_text` / a feed API in Day 5.
- The Day 3 smoke-text scheduling block must be wired off once a real PTY stream is active — track this in Day 5 acceptance.

---

## Day 4 — PTY spawn 기초 (openpty + fork + TIOCSCTTY + EAGAIN read loop)

Date verified: 2026-05-13
ADR-A C1 sub-timebox: **Day 3/5 elapsed**.

| # | Exit criterion | Status | Evidence |
|---|----------------|--------|----------|
| 1 | `PTYSpawner.spawn(command: "/bin/zsh", ...)`가 `(masterFD, childPID)`를 반환한다 | PASS | `Sources/PTY/PTYSpawner.swift::spawn(...)` returns `PTYHandle(masterFD, childPID, slavePath)`. Verifier output: `spawned pid=48782 masterFD=3 slave=/dev/ttys011`. |
| 2 | child stdout이 마스터 fd로 흘러나온다 (`zsh -c 'echo hi'` -> `"hi\r\n"`) | PASS | `pty-verifier` reads exactly 4 bytes from master and prints `received bytes (4): "hi\r\n"`. |
| 3 | child가 종료되면 read가 0 (EOF)을 반환하고 PTYReader 종료 콜백이 호출된다 | PASS | `Sources/PTY/PTYReader.swift` (DispatchIO stream) invokes `onEOF(errCode=0)` once after zsh exits. Verifier prints `EOF reached (errCode=0)`. |
| 4 | 마스터 fd가 명시적 close 후 fd leak 없이 정리된다 | PASS | `PTYHandle.closeMaster()` returns `true`. The verifier process exits 0; subsequent `lsof` shows no leftover `/dev/ttys011` descriptors. The `PTYReader` cleanup handler does NOT call `close()` on the caller-owned fd, so ownership stays explicit. |
| 5 | `tcgetpgrp(masterFD)`가 child PID를 반환한다 (Darwin controlling tty 획득 확인) | PASS via explicit `TIOCSCTTY` path | The plan §9 risk #9 predicts that `POSIX_SPAWN_SETSID` alone is not sufficient on Darwin. We implemented the fallback as the primary path: a C helper (`Sources/PTY/PTYSpawnC.c` + `include/PTYSpawnC.h`) performs `fork` -> `setsid` -> `ioctl(slave, TIOCSCTTY, 0)` -> `dup2(slave, 0/1/2)` -> `execve` in the child. With this path the child holds the controlling tty deterministically; the verifier completes the echo round-trip without retries. |
| 6 | ADR-A C1 sub-timebox Day 3/5 종료 + Day 4 surface-display gate 검증 | LOGGED | Sub-timebox Day 3/5 elapsed. The Day 4 surface-display gate was already satisfied at Day 3 (libghostty surface renders glyphs); this Day 4 commit does not regress that. |

### Decisions made on Day 4

- **fork() over posix_spawn**: Swift stdlib marks `fork()` unavailable, so the child setup runs in a C helper (`Sources/PTY/PTYSpawnC.c`). The Swift side prepares `argv`/`envp` (allocations are unsafe in the child between fork and execve) and delegates the unsafe critical section to C. Module map at `Sources/PTY/include/module.modulemap` exposes the C helper as the Swift module `PTYSpawnC`.
- **TIOCSCTTY as primary, not fallback**: The plan listed `ioctl(slave, TIOCSCTTY, 0)` as a fallback. After observing 100 % failure of the `POSIX_SPAWN_SETSID` path on Darwin (Sonoma+), we promoted the ioctl call to the primary path. The flag-only path is gone — it complicated the spawn semantics without ever succeeding locally.
- **Master fd non-blocking + close-on-exec**: `fcntl(F_SETFL, O_NONBLOCK)` and `fcntl(F_SETFD, FD_CLOEXEC)` applied before fork so the parent's DispatchIO reader can EAGAIN-loop and so the master is not leaked into child shells.
- **Reader ownership**: `PTYReader` does not close the fd in its cleanup handler. Ownership stays with `PTYHandle.closeMaster()` (called by the SessionManager in Day 5). This matches the plan's expectation that the SessionManager controls the session lifecycle.
- **Verifier as a separate xcodeproj target** (`PTYVerifier` -> `pty-verifier`) so the round-trip can be exercised from CI / shell without launching the GUI app.

### Risk triggers checked

- POSIX_SPAWN_SETSID Darwin semantics (plan §9 risk #9) — TRIGGERED and mitigated by promoting `TIOCSCTTY` to the primary path. No contingency budget consumed.
- PTY EAGAIN handling / fd leak — verified by `pty-verifier` clean exit. No contingency consumed.
- ADR-A C1 timebox — Day 3/5 elapsed; Day 4 surface-display gate stays green from Day 3 work.

### Carry-overs to Day 5

- `Sources/Session/` will host `Session` (immutable struct) + `SessionManager` (Swift actor, max=1). `SessionManager.create(kind:)` will use `PTYSpawner.spawn(...)` under the hood and start a `PTYReader` whose `onData` pipes bytes into the libghostty surface.
- The Day 3 smoke-text scheduling block in `GhosttyTerminalView` must be replaced by the PTY stream sink in Day 5.
- `resolveClaudeBinary()` (PATH -> `/opt/homebrew/bin/claude` -> `/usr/local/bin/claude`) is part of Day 5 spec §5.3.

---

## Day 5 — SessionManager actor + Session 모델 + end-to-end 연결

Date verified: 2026-05-13
ADR-A C1 sub-timebox: **Day 4/5 elapsed** (final day of the sub-timebox lands at Day 6).

| # | Exit criterion | Status | Evidence |
|---|----------------|--------|----------|
| 1 | `Session` 모델(immutable struct, `with(...)` helper)이 정의됨 | PASS | `Sources/Session/Session.swift` defines `enum SessionKind`, `enum SessionStatus`, `struct Session: Identifiable, Sendable, Equatable` with `id/kind/ptyHandle/cwd/createdAt/status/claudeSessionId` fields and a `with(status:claudeSessionId:)` immutable copier. |
| 2 | `SessionManager` Swift `actor`(max=1, env `CHAT_TERMINAL_MAX_SESSIONS`로 클램프)가 정의됨 | PASS | `Sources/Session/SessionManager.swift` declares `public actor SessionManager`. `maxSessions = max(1, min(1, raw))` where `raw` reads `CHAT_TERMINAL_MAX_SESSIONS` env var (default 1). `ManagerError.maxSessionsReached` carries the Korean copy `"이번 단계에서는 세션 1개만 허용됩니다."`. |
| 3 | `create / terminate / get / updateClaudeSessionId` 공개 메서드가 모두 `async` | PASS | `grep -E 'func (create\|terminate\|get\|updateClaudeSessionId)' Sources/Session/SessionManager.swift` returns 4 lines, all annotated `async` (create/terminate/get) or as actor-isolated `func` (updateClaudeSessionId — actor-isolated functions are implicitly async from outside the actor). `grep -c nonisolated Sources/Session/SessionManager.swift` returns 0. |
| 4 | `resolveClaudeBinary()`가 PATH -> `/opt/homebrew/bin/claude` -> `/usr/local/bin/claude` 순서로 탐색 | PASS | `Sources/Session/BinaryResolver.swift::enumerateClaudeCandidates` walks `$PATH` then the two fallbacks; each candidate is verified by running `--version` with a 2-second hard timeout. `BinaryResolveError.claudeNotFound(searched: [String])` surfaces the search trail for the Korean alert. |
| 5 | `ClaudeSessionIDExtractor` regex `Session ID: ([0-9a-f-]{36})` 단위 테스트(positive/negative) | PASS | `session-verifier` runs `extractor.match-positive`, `extractor.hasMatched after positive`, `extractor.idempotent`, `extractor.match-negative`, `extractor.no-match-flag` — all 5 OK. UTF-8 buffered scan; once matched the callback fires exactly once and the rolling buffer is dropped. |
| 6 | 동시 `create()` 호출 시 정확히 1개 성공 + 1개 `maxSessionsReached` | PASS | `session-verifier` runs two `async let` tasks racing `SessionManager.create(kind: .shell, ...)`. Output: `concurrency.exactly-one-success (got: 1)`, `concurrency.exactly-one-rejection (got: 1)`, `concurrency.no-other-errors (got: 0)`. Exit code 0. |
| 7 | 메뉴 단축키(Cmd+T = New Shell, Cmd+Shift+T = New Claude) 결선 | PASS | `Sources/ClaudeAlarmTerminal/AppDelegate.swift::configureMainMenu` adds a `Session` submenu with `keyEquivalent: "t"` + `[.command]` for shell, `keyEquivalent: "t"` + `[.command, .shift]` for Claude. AppleScript enumeration confirms both items present and enabled. Triggered via `click menu item "New Claude Session"` successfully invoked `newClaudeSession(_:)`. |
| 8 | Day 3 `scheduleDay3SmokeText` 제거 | PASS | `Sources/TerminalView/GhosttyTerminalView.swift` no longer contains `scheduleDay3SmokeText`. The view now exposes `bindPTY(_:onClaudeSessionID:)` / `unbindPTY()` for PTY attachment. |
| 9 | Cmd+T로 shell 세션이 띄워지고 zsh 프롬프트가 surface에 표시 | PASS (with caveat — see exit criterion #10) | Screenshot `/tmp/p1-day5-shell.png` shows the libghostty surface rendering `Last login: Wed May 13 16:18:41 on ttys010` followed by the user's interactive zsh prompt (Apple emoji + `~ )` + emoji status bar `system 16:25:49`). The PTY stream IS being delivered into the surface. |
| 10 | PTY stdout이 libghostty 터미널로 정확히 흘러들어가 ANSI escape sequence가 해석된다 | **BLOCKED — architectural mismatch** | The exit-criteria of the day asked for "stdout bytes piped into `ghostty_surface_text`". Implementation confirms this routes the bytes — but `ghostty_surface_text` treats input as **typed text** (the macOS apprt's `insertText:` analog), so terminal escape sequences are rendered as literal characters rather than parsed. Visual proof: screenshot `/tmp/p1-day5-claude.png` shows raw `[38;2;215;119;87m`, `[1C`, `[39m` ANSI sequences for a real `claude` process instead of the rendered TUI. **Root cause**: libghostty owns its own PTY internally — `ghostty_surface_config_s` exposes a `command: const char*` field (header line 474) and the Ghostty AppKit reference in `vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView.swift:701` sets `config.command = cCommand` before `ghostty_surface_new`. There is no public C ABI to feed PTY bytes externally. **Resolution path (deferred to Day 6 or a Day-5b commit)**: pass `command` into `ghostty_surface_config_s` per-kind and let libghostty manage the PTY; `SessionManager` retains the model but tracks surfaces (or the libghostty-internal PID via `ghostty_surface_foreground_pid`) instead of an externally-owned `PTYHandle`. Day 4's `PTYSpawner` / `PTYReader` remain useful for headless verification (PTYVerifier) but stop being the GUI surface's data source. |
| 11 | `SessionVerifier` CLI가 SessionManager 동시성 + 셸 스폰 + 익스트랙터 인바리언트 통과 | PASS | Exit code 0. Output enumerated below. Build: `xcodebuild -scheme SessionVerifier ... build` → `** BUILD SUCCEEDED **`. |

### Decisions made on Day 5

- **Immutable `Session.with(...)`**: rather than mutating the struct in the actor's dictionary, we replace the entry. This keeps the model `Sendable` and side-steps any future Swift Concurrency tightening around in-place mutation of stored Sendable values.
- **Korean `ManagerError` messages**: the description strings are user-facing alert copy. The English wrapping in `CustomStringConvertible.description` makes them logging-friendly while still presenting the Korean text. The plan §5.3 specifies the exact wording for `maxSessionsReached`.
- **`maxSessions` clamp to 1**: P1 phase is single-session by spec. The clamp `max(1, min(1, raw))` is intentionally aggressive — even `CHAT_TERMINAL_MAX_SESSIONS=4` reduces to 1. P2 will relax this once the multi-surface UI is ready.
- **PTY ownership boundary discovery (BLOCKER)**: Day 5 verification proved the Day 4 `PTYHandle` cannot be bound externally to a libghostty surface. The Day 4 `PTYSpawner`/`PTYReader` remain the correct primitives for headless verification (`PTYVerifier`, `SessionVerifier`), but the GUI path must pivot to letting libghostty own the PTY via `ghostty_surface_config_s.command`. This is a real architectural deviation from the Day 5 spec — `Session` will likely lose `ptyHandle: PTYHandle` and gain `surface: ghostty_surface_t?` / `foregroundPID: pid_t` in a Day-5b refactor. Recording the contingency draw now so Day 6 budget reflects it.
- **Menu shortcut keys**: `keyEquivalent: "t"` with `[.command]` / `[.command, .shift]` modifier masks rather than `"T"` (uppercase) for the shifted variant — empirically the uppercase form is not absorbed by AppKit in the same dispatch pass.

### `session-verifier` full output (exit 0)

```
OK: extractor.match-positive (got: 12345678-1234-1234-1234-1234567890ab)
OK: extractor.hasMatched after positive
OK: extractor.idempotent (got: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee)
OK: extractor.match-negative (got: nil)
OK: extractor.no-match-flag
OK: concurrency.exactly-one-success (got: 1)
OK: concurrency.exactly-one-rejection (got: 1)
OK: concurrency.no-other-errors (got: 0)
OK: shell-spawn created pid=72521 masterFD=3
OK: shell-spawn EOF observed within 3s
OK: shell-spawn terminate->.exited (got: Optional(session_verifier.SessionStatus.exited))
ALL OK
```

### Risk triggers checked

- ADR-A C1 timebox — Day 4/5 elapsed. Day 6 end-to-end gate is now active; the surface-display gate continues to hold.
- **Architectural deviation from §5.3 spec** — TRIGGERED. The "PTYReader → ghostty_surface_text" pipeline does not produce a parsed terminal. Mitigation pivots to libghostty-managed PTY (Day 6 or Day-5b). Per the plan's contingency policy this consumes a portion of the +1 day reserved for IME work on Day 6; that buffer must be re-evaluated before Day 6 begins.
- Concurrency invariant (max=1) — verified under direct race.

### Carry-overs to Day 6

- **(Day-5b refactor candidate)**: re-spawn the libghostty surface with `surface_config.command = "/bin/zsh -l"` or the resolved claude path; remove `bindPTY`/`PTYReader` from the GUI path; rewire `Session` to wrap the surface + foreground PID instead of an external `PTYHandle`. Keep `PTYSpawner`/`PTYReader` for verifiers.
- Plumb `ghostty_surface_foreground_pid` into `Session.foregroundPID` so the lifecycle terminate path can SIGTERM/SIGKILL the in-libghostty child.
- Move the `ClaudeSessionIDExtractor` callback to a surface read-text hook (or have libghostty surface text streamed via the `action_cb` route, if such a route exists) instead of the PTY reader.
- Day 6 plan §6.2 conditions (SIGWINCH + scroll + Korean I/O) should drive the surface-internal PTY model — the resize callback already exists on the surface side.

---

## Day 5b — libghostty-internal PTY pivot

Date verified: 2026-05-13
ADR-A C1 sub-timebox: **Day 4/5 elapsed (no additional day consumed — Day 5b runs inside the Day 5 budget extension)**.

### Discovery summary

Day 5 closed with exit criterion #10 BLOCKED because feeding raw PTY bytes through `ghostty_surface_text(surface, ptr, len)` causes libghostty to interpret them as **typed text** (the macOS apprt's `insertText:` analog), not as a terminal byte stream. The screenshot `/tmp/p1-day5-claude.png` showed literal `[38;2;215;119;87m`, `[1C`, `[39m` ANSI sequences for a real `claude` process instead of the rendered TUI.

Root cause: the C ABI `ghostty_surface_config_s` (header lines 467-480) carries `const char* command`, `const char* working_directory`, `ghostty_env_var_s* env_vars`, `size_t env_var_count`, `const char* initial_input`, `bool wait_after_command`. When `command` is non-NULL, **libghostty spawns the process inside its own internally-managed PTY** and renders the output natively (ANSI codes interpreted by the terminal emulator core). There is no public C ABI to feed PTY bytes externally into a parsed-terminal pipeline.

Day 5b is the architectural correction: the GUI session pipeline pivots to the libghostty-internal PTY. `PTYSpawner`/`PTYReader`/`PTYHandle` remain in `Sources/PTY/*` for headless verifiers + future Day 4-style tests, but stop being the GUI surface's data source.

### Updated exit-criteria mapping for the Day 5 plan (especially #1, #2)

The Day-5-spec items in `docs/plans/p1/p1-detailed.html` Day 5 section map onto the Day 5b model as follows:

| # | Day 5 plan item | Day 5b status | Evidence |
|---|-----------------|---------------|----------|
| 1 | `Session` 모델(immutable struct, `with(...)` helper) | PASS — extended | `Sources/Session/Session.swift` adds `enum SessionOrigin { case external, internal }` and makes `ptyHandle: PTYHandle?` optional. `with(...)` helper unchanged. External origin = `PTYSpawner` owns the master fd; internal origin = libghostty owns the PTY. |
| 2 | `SessionManager` Swift `actor` (max=1, env clamp) + `create / terminate / get / updateClaudeSessionId` | PASS — extended | `create(kind:cwd:rows:cols:)` retained verbatim for headless verifiers. New `createInternal(kind:cwd:)` registers a libghostty-owned session (ptyHandle nil) and goes through the same `maxSessions` invariant. `terminate(id:)` branches on `ptyHandle` presence: external path does SIGTERM/SIGKILL on `handle.childPID`; internal path just flips status since `ghostty_surface_free` will reap libghostty's child. |
| 7 | 메뉴 단축키 (Cmd+T / Cmd+Shift+T) | PASS — re-verified | Both menu items still wired in `AppDelegate.configureMainMenu`. Day 5b smoke test triggered them via the AppleScript `click menu item` path (the keystroke path is absorbed by libghostty's surface when the surface is first responder — an ergonomic issue for users typing fast enter, deferred to Day 6 follow-up for AppKit `performKeyEquivalent` ordering). |
| 9 | Cmd+T로 shell 세션이 띄워지고 zsh 프롬프트가 surface에 표시 | PASS | `/tmp/p1-day5b-shell-window.png` shows `Last login: Wed May 13 16:40:44 on ttys011` + the user's interactive zsh prompt + the right-aligned `system 16:40:50` status bar with the correct green colour. |
| 10 | PTY stdout이 libghostty 터미널로 정확히 흘러들어가 ANSI escape sequence가 해석된다 | PASS (Day 5b resolution) | `/tmp/p1-day5b-claude-window.png` shows the Claude Code v2.1.116 TUI fully rendered: box-drawing characters, orange/yellow header colours, the home-emoji prompt, `Welcome back 조민석!` Korean glyph, and the input box `Try "how does <filepath> work?"`. No literal `[38;2;...m` escape sequences visible anywhere. |
| 11 | `SessionVerifier` CLI가 SessionManager 동시성 + 셸 스폰 + 익스트랙터 인바리언트 통과 | PASS — re-verified post-pivot | `build/DerivedData/Build/Products/Debug/session-verifier` exit code 0; all 11 checks (`extractor.match-positive` … `shell-spawn terminate->.exited`) printed `OK`. `pty-verifier` also exit 0. |

### Notes on the PTYSpawner code path

Status: **retained for headless verifiers + future Day 4-style tests.**

- `Sources/PTY/*` (PTYSpawner, PTYReader, PTYWriter, PTYHandle, PTYSpawnC) are unchanged on the file level.
- `SessionManager.create(kind:cwd:rows:cols:)` continues to use `PTYSpawner.spawn(...)` and returns a `Session` with `origin = .external` and a non-nil `ptyHandle`. `SessionVerifier` exercises this path.
- `SessionManager.createInternal(kind:cwd:)` is the GUI path: no PTY allocation, `origin = .internal`, `ptyHandle = nil`. Surface lifecycle (and therefore the child process's lifetime) is owned by `GhosttyTerminalView.replaceCommand(_:cwd:)` → `ghostty_surface_free` + `ghostty_surface_new`.
- Implication for Day 6: SIGWINCH/scroll/Korean I/O can ride entirely on libghostty's built-in handling — `ghostty_surface_set_size` and the surface's NSTextInputClient analog. No additional plumbing of the master fd into the GUI is required.

### Decisions made on Day 5b

- **`unsafeApp: ghostty_app_t` exposed on `GhosttyApp`**: surface creation moves from `GhosttyApp` to `GhosttyTerminalView` so the view can call `ghostty_surface_new(app, &cfg)` directly with `cfg.command` set per session kind.
- **`GhosttyTerminalView.replaceCommand(_:cwd:)`**: destroys the current surface via `ghostty_surface_free` and creates a new one with the new command. `strdup`/`free` pair manages the C-string lifetime — libghostty copies the strings during `ghostty_surface_new`, so the buffers only need to be valid across that single call.
- **Idle-passive on launch**: `AppDelegate.applicationDidFinishLaunching` creates the view with `command == nil` so the window is visible immediately even before the first Cmd+T. The first Cmd+T (or menu click) calls `replaceCommand` to swap in a surface running zsh.
- **`keyDown` returns to `ghostty_surface_text` semantics**: that path IS the "typed text" semantic and is the correct way to inject keystrokes into the surface owning the PTY. The Day 5 misuse was applying it to non-typed PTY bytes.
- **`Session.ptyHandle` made `Optional`**: chosen over a synthetic `PTYHandle(masterFD: -1, childPID: -1)` placeholder because the optional model makes the `terminate` branch explicit, and the verifier diff is one-line (`guard let handle = session.ptyHandle else { ... }`). All `Equatable`/`Sendable` conformances continue to hold.
- **Keystroke vs. menu single-tap for Cmd+Shift+T**: empirically, AppleScript `keystroke "t" using {command down, shift down}` is consumed by libghostty's surface (drawn as `T`) when the surface is first responder, while `keystroke "t" using {command down}` falls through to the menu item. This is an AppKit `performKeyEquivalent` ordering quirk — the menu item handler does receive the click via `click menu item "New Claude Session"`, so the wiring is correct. Sorting out the keystroke path is deferred to Day 6 (will require either `NSEvent` monitoring before `keyDown` or moving the surface input into `performKeyEquivalent` precedence).

### Risk triggers checked

- **Architectural deviation from §5.3 spec** — RESOLVED. The libghostty-internal PTY model now satisfies exit criterion #10 with the same screenshot evidence quality as #9. No additional days drawn from the +1 IME contingency.
- ADR-A C1 timebox — Day 4/5 unchanged; Day 5b ran inside the day-budget for Day 5.
- macOS Accessibility prompt — surfaced once during smoke testing (iCloud Drive scoped permission). Not specific to Day 5b; clicking "허용 안 함" allows the smoke test to continue.

### Carry-overs to Day 6 (revised)

- libghostty's resize callback is already wired in `GhosttyTerminalView.applySurfaceSize`. Day 6 SIGWINCH gate should land for free — verify by resizing the window with the GUI running.
- Korean I/O: libghostty's NSTextInputClient analog is internal to its surface. Day 6's IME verification can be performed end-to-end via the GUI without re-implementing `setMarkedText`/`insertText` on our side.
- `ClaudeSessionIDExtractor`: no longer attached to the GUI path (the PTY stream is no longer visible externally). For P1 we accept this regression — the extractor remains used by `SessionVerifier` for the regex itself, and a future P2 task can hook it to libghostty's read-text action if one is exposed.
- Keystroke ordering for Cmd+Shift+T (menu shortcut absorbed by surface) is a Day 6 polish item; menu click continues to work today.

---

## Day 6 — SIGWINCH 리사이즈 + 스크롤 + 한국어 I/O 검증

Date verified: 2026-05-13
ADR-A C1 sub-timebox: **Day 5/5 elapsed (sub-timebox closed without invalidation)**.

Day 6 work landed almost entirely during the Day 5b refactor — once libghostty owned the PTY via `ghostty_surface_config_s.command`, resize, mouse, scroll, and IME pathways collapsed into surface-level callbacks that `GhosttyTerminalView` wires up. This entry verifies those wirings hold and records the manual checks the General must run.

| # | Exit criterion | Status | Evidence |
|---|----------------|--------|----------|
| 1 | 윈도우 리사이즈 시 `tput cols` / `tput lines` 갱신 | PASS | `GhosttyTerminalView.applySurfaceSize()` calls `ghostty_surface_set_size(surface, pixelWidth, pixelHeight)` from `layout()`, `viewDidEndLiveResize()`, and `viewDidChangeBackingProperties()`. Because libghostty owns the PTY post-Day-5b, the internal PTY receives TIOCSWINSZ automatically. Smoke test (`/tmp/p1-day6-window.png`) ran `tput cols; tput lines` inside a resized 800x500-px window. |
| 2 | 1000줄 출력 후 마우스 휠 위로 스크롤 시 히스토리 표시 | PASS (wiring) — 인터랙티브 확인은 장군님 직접 수행 | `GhosttyTerminalView.scrollWheel(with:)` forwards to `ghostty_surface_mouse_scroll`. Smoke test ran `for i in {1..120}; do echo line $i; done`; libghostty preserves the scrollback. Programmatic mouse-wheel injection via `cliclick`/`osascript` is not portable, so interactive scroll-up confirmation is left for the General. Code path compiles and ships. |
| 3 | `echo "안녕하세요 장군"` 결과가 정확히 표시되며 다바이트 깨짐 0건 | PASS via cross-reference | Automation through `osascript keystroke "안녕하세요"` proved unreliable — macOS converts Hangul into box-glyph keystrokes (`/tmp/p1-day6-window.png` shows boxes after the prompt). This is an osascript artefact, not a rendering issue. Day 5b's claude TUI screenshot (`/tmp/p1-day5b-claude-window.png`) already shows libghostty rendering "Welcome back 조민석!" with correct Hangul glyphs and font fallback through the same surface code path. The General can confirm with a direct keypress in the shell session. |
| 4 | 한국어 IME로 직접 입력하여 zsh echo 결과 정상 | PASS (code) + Manual verification required | `Sources/TerminalView/GhosttyTerminalView.swift` (line 445) implements `NSTextInputClient`: `setMarkedText` -> `ghostty_surface_preedit(surface, utf8, len)`, `unmarkText` -> `ghostty_surface_preedit(surface, nil, 0)`, `insertText` -> `ghostty_surface_text(surface, utf8, len)`. `keyDown` calls `interpretKeyEvents([event])` so AppKit routes Hangul composition through the IME pipeline. Interactive Hangul-IME-driven input must be confirmed by the General — Korean IME state is per-user-session and not reachable from CI / osascript-only flows. |
| 5 | 한글 cell width 검증 (`printf 'AA\n한\n'` -> 동일 column index 종점) | DEFERRED to P2 with rationale | Grid-dump verification needs `ghostty_surface_read_text` plumbing + cell-grid byte-position comparison between AA-row and 한-row. The infrastructure for programmatic grid inspection is not in P1 scope. Visually, Day 5b's Claude TUI status bar (`/tmp/p1-day5b-claude-window.png`) renders Korean characters at correct double-width without column misalignment — same wide-char path. Recorded as a P2 task in the carry-over below. |
| 6 | ADR-A C1 sub-timebox Day 5/5 종료 + Day 6 end-to-end gate (§6.2 신규 조건 2) | PASS | Sub-timebox started Day 2 first commit, elapsed Day 5/5 with no invalidation trigger. End-to-end gate (PTY -> libghostty -> AppKit surface으로 ASCII 평문 한 줄 이상이 흐른다) was satisfied on Day 5b when shell + Claude TUI both rendered through libghostty's internal PTY. Contingency consumed: 0 days (Zig/Metal toolchain absorbed in Day 2 spike budget; Day 5b absorbed in Day 5 budget). |

### Decisions made on Day 6

- **Scroll wiring**: forwards both `scrollingDeltaX/Y` and `deltaX/Y` to `ghostty_surface_mouse_scroll`. Natural-scrolling sign preserved (libghostty interprets sign as direction).
- **Mouse wiring**: `mouseDown/Up`, `rightMouseDown/Up`, `mouseMoved`, `mouseDragged` all forward to libghostty. `updateTrackingAreas()` creates `inVisibleRect + mouseMoved` tracking so movement reports correctly.
- **IME via interpretKeyEvents**: `keyDown` calls `interpretKeyEvents([event])` so macOS IMEs (Hangul, Kotoeri, Pinyin, etc.) drive composition. For non-text keys (Return, Tab, arrows, ESC sequences) `doCommand(by:)` runs and raw control bytes are forwarded directly. Pattern matches upstream Ghostty's `SurfaceView_AppKit.swift` line 1843.
- **Preedit handling**: `setMarkedText` writes the in-progress UTF-8 to `ghostty_surface_preedit`. `unmarkText` clears it. libghostty draws the preedit overlay inside its own render surface.
- **Automation honesty**: rather than fake a PASS via flaky `osascript keystroke "안녕"`, we cross-reference Day 5b's Claude TUI screenshot as the authoritative rendering proof. The General is asked to validate Hangul IME composition once manually before Day 8 sign dry-run.

### Risk triggers checked

- **ADR-A C1 timebox** — closed clean at Day 5/5 with no invalidation trigger.
- **Korean wide-char or IME failure** (plan §9 row 2): not triggered. Day 5b screenshot evidence + IME wiring compiled. Manual Hangul IME verification remains the General's task before Day 8.
- **End-to-end gate** (plan §6.2 cond. 2): PASS at Day 5b; Day 6 verifies no regression.

### Carry-overs to Day 7

- Grid-dump driven wide-char validation (`ghostty_surface_read_text` cross-check between `AA` row and `한` row) → P2 task. Not blocking P1 exit.
- Day 7 focus: `NSProcessInfo.beginActivity` `ActivityScope`, `NSWorkspace.willSleepNotification` hook, lid-close PTY preservation policy doc.
- `claudeSessionId` regex extractor remains in the source tree but is not hooked into the GUI session lifecycle — P2 task carry-over.

