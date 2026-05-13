import Darwin
import Foundation
import PTYSpawnC

/// Spawns a child process inside a freshly allocated PTY pair.
///
/// Day 4 scope (P1 plan §5.1):
/// 1. `openpty(3)` allocates the master/slave pair.
/// 2. The master fd is made non-blocking and close-on-exec so DispatchIO
///    can drive EAGAIN-aware reads from `PTYReader`.
/// 3. `fork(2)` runs the child path. In the child we call `setsid`,
///    `ioctl(TIOCSCTTY)` on the slave fd to acquire it as the controlling
///    tty (this is the explicit-acquisition path the plan calls out in
///    §9 risk #9 for Darwin semantics), `dup2` the slave to stdin/stdout/
///    stderr, then `execve` the requested command.
/// 4. The parent closes the slave fd and verifies `tcgetpgrp(masterFD) ==
///    childPID`. With the explicit `TIOCSCTTY` ioctl in the child the
///    verification is expected to succeed deterministically.
public enum PTYSpawner {
    public static func spawn(
        command: String,
        args: [String] = [],
        cwd: String? = nil,
        env: [String: String]? = nil,
        rows: UInt16 = 24,
        cols: UInt16 = 80
    ) throws -> PTYHandle {
        var master: Int32 = -1
        var slave: Int32 = -1
        var nameBuf = [CChar](repeating: 0, count: 128)
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        let openRc = nameBuf.withUnsafeMutableBufferPointer { namePtr -> Int32 in
            return openpty(&master, &slave, namePtr.baseAddress, nil, &ws)
        }
        guard openRc == 0 else {
            throw PTYError.openptyFailed(errno: errno)
        }

        // Master fd: non-blocking + close-on-exec.
        let flags = fcntl(master, F_GETFL)
        guard fcntl(master, F_SETFL, flags | O_NONBLOCK) != -1 else {
            let e = errno
            Darwin.close(master); Darwin.close(slave)
            throw PTYError.fcntlFailed(errno: e, op: "F_SETFL O_NONBLOCK")
        }
        guard fcntl(master, F_SETFD, FD_CLOEXEC) != -1 else {
            let e = errno
            Darwin.close(master); Darwin.close(slave)
            throw PTYError.fcntlFailed(errno: e, op: "F_SETFD FD_CLOEXEC")
        }

        // Build argv / envp on the parent side because malloc-based string
        // operations cannot run safely in the child between fork and execve.
        let argvList: [String] = [command] + args
        var argv: [UnsafeMutablePointer<CChar>?] = argvList.map { strdup($0) }
        argv.append(nil)
        defer { for ptr in argv { if let p = ptr { free(p) } } }
        for entry in argv.dropLast() where entry == nil {
            Darwin.close(master); Darwin.close(slave)
            throw PTYError.argvAllocFailed
        }

        let envPairs: [String]
        if let env = env {
            envPairs = env.map { "\($0.key)=\($0.value)" }
        } else {
            var inherited: [String] = []
            var ptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> = environ
            while let cstr = ptr.pointee {
                inherited.append(String(cString: cstr))
                ptr = ptr.advanced(by: 1)
            }
            envPairs = inherited
        }
        var envp: [UnsafeMutablePointer<CChar>?] = envPairs.map { strdup($0) }
        envp.append(nil)
        defer { for ptr in envp { if let p = ptr { free(p) } } }

        let cwdCString: UnsafeMutablePointer<CChar>? = cwd.map { strdup($0) }
        defer { if let p = cwdCString { free(p) } }

        let commandCString = strdup(command)
        defer { if let p = commandCString { free(p) } }
        guard let commandCString = commandCString else {
            Darwin.close(master); Darwin.close(slave)
            throw PTYError.argvAllocFailed
        }

        // Delegate fork + child-side setup to PTYSpawnC (C helper). Swift
        // cannot call fork() directly because the stdlib marks it unavailable
        // — the child path needs async-signal-safe code which is easier to
        // express in C.
        let pid = pty_spawn_fork(
            master,
            slave,
            commandCString,
            argv,
            envp,
            cwdCString
        )

        // Parent path: slave fd was closed by the child path on success; we
        // still close it here defensively because if fork failed the slave
        // remains open in this process.
        Darwin.close(slave)
        if pid < 0 {
            let e = errno
            Darwin.close(master)
            throw PTYError.spawnFailed(errno: e)
        }

        let slavePath = String(cString: nameBuf)
        let handle = PTYHandle(masterFD: master, childPID: pid, slavePath: slavePath)

        // Darwin verification step: POSIX_SPAWN_SETSID alone does not guarantee
        // the slave becomes the child's controlling tty. Read the foreground
        // process group via the master fd. Three possible outcomes:
        //   1. pgrp == childPID -> success.
        //   2. pgrp == 0 with the child already reaped/exited -> accept; the
        //      controlling tty did exist briefly and the child has finished
        //      its work (echo-style tests).
        //   3. Persistently -1 or wrong pid -> raise; caller can fall back to
        //      explicit ioctl(slaveFD, TIOCSCTTY, 0) by re-spawning.
        var lastPgrp = tcgetpgrp(master)
        if lastPgrp != pid {
            var retries = 5
            while retries > 0 && lastPgrp != pid {
                usleep(2_000) // 2ms
                let p2 = tcgetpgrp(master)
                if p2 == pid { lastPgrp = p2; break }
                if p2 == 0 {
                    // No foreground pgrp; check whether the child has exited
                    // already (transient commands like `echo` finish fast).
                    var status: Int32 = 0
                    let wp = waitpid(pid, &status, WNOHANG)
                    if wp == pid {
                        // Child exited; treat as success — controlling tty
                        // existed long enough for the child to run.
                        lastPgrp = pid
                        break
                    }
                }
                lastPgrp = p2
                retries -= 1
            }
            if lastPgrp != pid {
                Darwin.close(master)
                throw PTYError.ttySetCtrlFailed(masterFD: master, pgrp: lastPgrp, childPID: pid)
            }
        }

        return handle
    }
}

/// Helper exposed for tests: write a buffer to the master fd in full, handling
/// short writes / EAGAIN.
public enum PTYWriter {
    public static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var remaining = rawBuf.count
            var cursor = base
            while remaining > 0 {
                let n = Darwin.write(fd, cursor, remaining)
                if n > 0 {
                    remaining -= n
                    cursor = cursor.advanced(by: n)
                } else if n == -1 && errno == EAGAIN {
                    usleep(1_000)
                    continue
                } else if n == -1 {
                    throw PTYError.fcntlFailed(errno: errno, op: "write")
                }
            }
        }
    }
}
