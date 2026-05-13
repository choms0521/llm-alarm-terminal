# Daemon Lifecycle Policy (P1)

P1 ships a single-window AppKit app that hosts one libghostty-owned PTY at a time. This document records the lifecycle policy that the code is expected to honour. Most policy items are coded as hooks today and will be exercised end-to-end in later phases (P4 introduces the WS server and Push sender; P5/P6 expand the background-running surface).

## App Nap / Power Nap

- A single `ActivityScope` instance is held by `SessionManager` while at least one session is alive. The scope wraps `ProcessInfo.beginActivity(options:reason:)` with `.userInitiated`. Per P1 plan §5.2 we deliberately keep the option set minimal — `.idleSystemSleepDisabled`, `.suddenTerminationDisabled`, `.automaticTerminationDisabled` will be OR-combined in P4 when the WS server requires background liveness.
- The scope releases automatically on `deinit`, which fires once `SessionManager.terminate(...)` removes the last session.

## Sleep / Wake

- `PowerEventObserver` subscribes to `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification`. In P1 both handlers only log; they are wired so P4 can plug in WS-attached-state invalidation (per master plan v4 §P5).
- The observer is owned by `AppDelegate` and started during `applicationDidFinishLaunching`. It is stopped on app termination via deinit.

## Lid-close

- macOS posts `willSleep` when the lid closes without an external display. With an external display attached (clamshell mode) the system stays awake.
- P1 does NOT proactively close the master PTY fd when sleep fires. The fd is owned by libghostty's internal PTY (post-Day-5b) which keeps the master/slave pair alive across sleep transitions. The kernel preserves PTY state across sleep; on wake the existing read loop resumes.
- Code-level invariant: no code path under `Sources/` calls `Darwin.close(masterFD)` from a sleep notification. The only `closeMaster()` call site is `PTYHandle.closeMaster()` which the session-terminate flow invokes when the user closes the session. Until then the PTY persists.

## Claude session reuse hook

- `SessionManager.lastClaudeSessionId: String?` records the most recently observed `claudeSessionId` (regex `Session ID: ([0-9a-f-]{36})` from PTY stdout). The value is preserved across `terminate(...)` so a future P4 reconnect path can pass it back to `claude --resume` once that flow is implemented.
- The extractor lives in `Sources/Session/ClaudeSessionIDExtractor.swift` and is unit-tested via `Sources/SessionVerifier/main.swift`. P2 will wire the extractor into the live GUI stream (libghostty's internal PTY makes the byte stream opaque to our code today — a P2 task adds `ghostty_surface_read_text` plumbing to recover it).

## Out-of-scope for P1

- Actual sleep-restoration latency measurement (e.g. PTY read pause < 1s on wake) — measured in P4 after WS reconnect logic exists.
- Push-channel-driven fallback when WS not attached — see master plan §P5.
- Multi-session lifecycle (max=1 today; max=20 in P2).
