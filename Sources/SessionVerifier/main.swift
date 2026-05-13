import Darwin
import Dispatch
import Foundation

// Day 5 verifier.
//
// Exercises (no GUI required):
//   1. ClaudeSessionIDExtractor regex — positive + negative paths.
//   2. SessionManager concurrency invariant — two parallel `create` tasks
//      must yield exactly one success and one `maxSessionsReached`.
//   3. End-to-end shell session — spawn a shell, write `exit\n`, observe EOF,
//      verify `terminate` flips status to `.exited`.

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    } else {
        print("OK: \(message)")
    }
}

// MARK: - 1. ClaudeSessionIDExtractor

do {
    var captured: String?
    let extractor = ClaudeSessionIDExtractor { uuid in
        captured = uuid
    }
    let banner = "Welcome to Claude\nSession ID: 12345678-1234-1234-1234-1234567890ab\nReady.\n"
    extractor.feed(Data(banner.utf8))
    check(captured == "12345678-1234-1234-1234-1234567890ab", "extractor.match-positive (got: \(captured ?? "nil"))")
    check(extractor.hasMatched, "extractor.hasMatched after positive")

    // Idempotency: a second banner is ignored.
    var second: String? = nil
    let extractor2 = ClaudeSessionIDExtractor { uuid in
        if second != nil {
            second = "DUPLICATE_\(uuid)"
        } else {
            second = uuid
        }
    }
    extractor2.feed(Data("Session ID: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n".utf8))
    extractor2.feed(Data("Session ID: ffffffff-0000-0000-0000-000000000000\n".utf8))
    check(second == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "extractor.idempotent (got: \(second ?? "nil"))")
}

do {
    var captured: String?
    let extractor = ClaudeSessionIDExtractor { uuid in
        captured = uuid
    }
    let nonsense = "this stream has no session banner anywhere in it.\nPrompt $ ls\n"
    extractor.feed(Data(nonsense.utf8))
    check(captured == nil, "extractor.match-negative (got: \(captured ?? "nil"))")
    check(!extractor.hasMatched, "extractor.no-match-flag")
}

// MARK: - 2. SessionManager concurrency invariant

func runConcurrencyTest() async {
    let manager = SessionManager(maxSessionsOverride: 1)
    let cwd = FileManager.default.currentDirectoryPath

    actor Counter {
        var successes = 0
        var rejections = 0
        var others = 0
        var createdIds: [UUID] = []
        func recordSuccess(_ id: UUID) { successes += 1; createdIds.append(id) }
        func recordRejection() { rejections += 1 }
        func recordOther(_ msg: String) {
            others += 1
            FileHandle.standardError.write(Data("unexpected error in concurrency test: \(msg)\n".utf8))
        }
    }
    let counter = Counter()

    async let a: Void = {
        do {
            let s = try await manager.create(kind: .shell, cwd: cwd, rows: 24, cols: 80)
            await counter.recordSuccess(s.id)
        } catch ManagerError.maxSessionsReached {
            await counter.recordRejection()
        } catch {
            await counter.recordOther(String(describing: error))
        }
    }()
    async let b: Void = {
        do {
            let s = try await manager.create(kind: .shell, cwd: cwd, rows: 24, cols: 80)
            await counter.recordSuccess(s.id)
        } catch ManagerError.maxSessionsReached {
            await counter.recordRejection()
        } catch {
            await counter.recordOther(String(describing: error))
        }
    }()
    _ = await (a, b)

    let s = await counter.successes
    let r = await counter.rejections
    let o = await counter.others
    check(s == 1, "concurrency.exactly-one-success (got: \(s))")
    check(r == 1, "concurrency.exactly-one-rejection (got: \(r))")
    check(o == 0, "concurrency.no-other-errors (got: \(o))")

    // Cleanup: terminate everything we created.
    for id in await counter.createdIds {
        try? await manager.terminate(id: id)
        await manager.remove(id: id)
    }
}

// MARK: - 3. End-to-end shell spawn

func runShellSpawnTest() async {
    let manager = SessionManager(maxSessionsOverride: 1)
    let cwd = FileManager.default.currentDirectoryPath
    let session: Session
    do {
        session = try await manager.create(kind: .shell, cwd: cwd, rows: 24, cols: 80)
    } catch {
        failures.append("shell-spawn create failed: \(error)")
        FileHandle.standardError.write(Data("FAIL: shell-spawn create: \(error)\n".utf8))
        return
    }
    guard let handle = session.ptyHandle else {
        failures.append("shell-spawn ptyHandle nil (external origin expected)")
        FileHandle.standardError.write(Data("FAIL: shell-spawn ptyHandle nil\n".utf8))
        return
    }
    print("OK: shell-spawn created pid=\(handle.childPID) masterFD=\(handle.masterFD)")

    let eofSignal = DispatchSemaphore(value: 0)
    let reader = PTYReader(fd: handle.masterFD, label: "pty.session.verifier")
    let buffer = NSMutableData()
    reader.start(
        onData: { data in
            buffer.append(data)
        },
        onEOF: { _ in
            eofSignal.signal()
        }
    )

    // Give the shell a beat to launch, then ask it to exit.
    try? await Task.sleep(nanoseconds: 200_000_000)
    let exitCmd = "exit\n"
    try? PTYWriter.write(handle.masterFD, Data(exitCmd.utf8))

    let waitResult = eofSignal.wait(timeout: .now() + 3.0)
    reader.stop()
    check(waitResult == .success, "shell-spawn EOF observed within 3s")

    try? await manager.terminate(id: session.id)
    let after = await manager.get(id: session.id)
    check(after?.status == .exited, "shell-spawn terminate->.exited (got: \(String(describing: after?.status)))")
    await manager.remove(id: session.id)
}

// MARK: - driver

let group = DispatchGroup()
group.enter()
Task {
    await runConcurrencyTest()
    await runShellSpawnTest()
    group.leave()
}
group.wait()

if failures.isEmpty {
    print("ALL OK")
    exit(0)
} else {
    FileHandle.standardError.write(Data("FAILED: \(failures.count) check(s)\n".utf8))
    exit(1)
}
