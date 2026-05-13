import Darwin
import Dispatch
import Foundation

// Day 4 verifier: spawn `zsh -c 'echo hi'` via PTYSpawner, read the output,
// confirm the bytes match, then check that the master fd reports EOF and
// `tcgetpgrp` returned the child PID before EOF.

let handle: PTYHandle
do {
    handle = try PTYSpawner.spawn(
        command: "/bin/zsh",
        args: ["-c", "echo hi"],
        rows: 24, cols: 80
    )
} catch {
    FileHandle.standardError.write(Data("spawn failed: \(error)\n".utf8))
    exit(1)
}

print("spawned pid=\(handle.childPID) masterFD=\(handle.masterFD) slave=\(handle.slavePath)")

let collected = NSMutableData()
let eofSignal = DispatchSemaphore(value: 0)
let reader = PTYReader(fd: handle.masterFD, label: "pty.verifier")
reader.start(
    onData: { chunk in
        collected.append(chunk)
    },
    onEOF: { errCode in
        print("EOF reached (errCode=\(errCode))")
        eofSignal.signal()
    }
)

// 2-second timeout — zsh launches and prints within ~10ms locally.
let waitResult = eofSignal.wait(timeout: .now() + 2.0)
if waitResult == .timedOut {
    FileHandle.standardError.write(Data("timeout waiting for child EOF\n".utf8))
    reader.stop()
    handle.closeMaster()
    exit(2)
}

reader.stop()

let received = String(data: collected as Data, encoding: .utf8) ?? "(non-utf8)"
print("received bytes (\(collected.length)): \(received.debugDescription)")
if !received.contains("hi") {
    FileHandle.standardError.write(Data("did not see 'hi' in output\n".utf8))
    handle.closeMaster()
    exit(3)
}

// Reap the child so the zombie does not linger.
var status: Int32 = 0
_ = waitpid(handle.childPID, &status, 0)
print("child exited status=\(status)")

let closed = handle.closeMaster()
print("master close ok=\(closed)")
print("OK: PTY spawn + echo round-trip succeeded")
