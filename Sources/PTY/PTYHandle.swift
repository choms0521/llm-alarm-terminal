import Darwin
import Foundation

/// Errors that can arise from the PTY spawn pipeline.
public enum PTYError: Error, CustomStringConvertible {
    case openptyFailed(errno: Int32)
    case spawnFailed(errno: Int32)
    case ttySetCtrlFailed(masterFD: Int32, pgrp: pid_t, childPID: pid_t)
    case fcntlFailed(errno: Int32, op: String)
    case argvAllocFailed

    public var description: String {
        switch self {
        case .openptyFailed(let e):
            return "openpty failed (errno=\(e): \(String(cString: strerror(e))))"
        case .spawnFailed(let e):
            return "posix_spawn failed (errno=\(e): \(String(cString: strerror(e))))"
        case .ttySetCtrlFailed(let fd, let pgrp, let pid):
            return "controlling tty not acquired (masterFD=\(fd) tcgetpgrp=\(pgrp) child=\(pid))"
        case .fcntlFailed(let e, let op):
            return "fcntl \(op) failed (errno=\(e))"
        case .argvAllocFailed:
            return "argv allocation failed"
        }
    }
}

/// Immutable handle to a pseudo-terminal master fd and its child process.
///
/// The handle does NOT close `masterFD` on deinit so that ownership stays
/// explicit and the SessionManager (Day 5) can release the fd at the right
/// point in the session lifecycle. Callers must call `close()` exactly once
/// when the session is being torn down.
public struct PTYHandle: Equatable {
    public let masterFD: Int32
    public let childPID: pid_t
    public let slavePath: String

    public init(masterFD: Int32, childPID: pid_t, slavePath: String) {
        self.masterFD = masterFD
        self.childPID = childPID
        self.slavePath = slavePath
    }

    /// Close the master fd. Safe to call multiple times — subsequent calls
    /// return false. The caller is responsible for tracking whether the
    /// child process has been reaped via `waitpid` before closing.
    @discardableResult
    public func closeMaster() -> Bool {
        return Darwin.close(masterFD) == 0
    }
}
