import Darwin
import Foundation

/// Errors returned by `resolveClaudeBinary()`. The caller (typically
/// `SessionManager.create(kind: .claude, ...)`) is responsible for surfacing a
/// Korean-language NSAlert per the P1 plan §5.3.
public enum BinaryResolveError: Error, CustomStringConvertible {
    case claudeNotFound(searched: [String])

    public var description: String {
        switch self {
        case .claudeNotFound(let searched):
            return "claude binary not found in PATH or fallbacks (searched=\(searched))"
        }
    }
}

/// Locates the `claude` CLI binary.
///
/// Search order (per P1 plan §5.3):
/// 1. Every directory in `$PATH`.
/// 2. `/opt/homebrew/bin/claude` (Apple Silicon brew default).
/// 3. `/usr/local/bin/claude` (Intel brew default).
///
/// Each candidate is verified by running `<candidate> --version` with a
/// 2-second timeout. Only candidates that exit 0 within the timeout count
/// as resolved.
public func resolveClaudeBinary() throws -> String {
    var searched: [String] = []
    let candidates = enumerateClaudeCandidates(searched: &searched)
    for candidate in candidates {
        if verifyExecutableRespondsToVersion(candidate) {
            return candidate
        }
    }
    throw BinaryResolveError.claudeNotFound(searched: searched)
}

/// Lists candidate absolute paths for the `claude` binary without verifying
/// them. Exposed for unit tests; production callers should use
/// `resolveClaudeBinary()` which combines enumeration + verification.
public func enumerateClaudeCandidates(searched: inout [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    let fm = FileManager.default

    func consider(_ path: String) {
        if seen.contains(path) { return }
        seen.insert(path)
        searched.append(path)
        if fm.isExecutableFile(atPath: path) {
            result.append(path)
        }
    }

    let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in pathVar.split(separator: ":", omittingEmptySubsequences: true) {
        consider("\(dir)/claude")
    }
    consider("/opt/homebrew/bin/claude")
    consider("/usr/local/bin/claude")
    return result
}

/// Runs `path --version` with a 2-second hard timeout. Returns true iff the
/// process exits 0. Any non-zero exit code, exception, or timeout returns
/// false.
private func verifyExecutableRespondsToVersion(_ path: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--version"]
    // Pipe stdout/stderr to /dev/null so banners don't clutter logs.
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return false
    }

    let deadline = Date().addingTimeInterval(2.0)
    while process.isRunning && Date() < deadline {
        usleep(20_000) // 20ms poll
    }
    if process.isRunning {
        process.terminate()
        // Give SIGTERM a short window to land before SIGKILL.
        let killDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < killDeadline {
            usleep(20_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        return false
    }
    return process.terminationStatus == 0
}
