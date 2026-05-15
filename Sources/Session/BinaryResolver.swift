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
///
/// P3.5 Day 1 fix: when launched from Xcode (or Finder), the macOS GUI app
/// PATH is restricted to `/usr/bin:/bin:...` and skips the user's shell PATH
/// additions (`~/.local/bin`, `/opt/homebrew/bin`, custom installs in
/// `/Applications/cmux.app/...`, etc). To handle this we also enumerate:
/// 1. Common user-local install paths.
/// 2. The login-shell PATH (`/bin/zsh -lic 'echo $PATH'`) which evaluates
///    `~/.zprofile` / `~/.zshrc` / homebrew shellenv. Cached so we only pay
///    the shell spawn cost once per process.
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

    // 1) Process PATH (GUI-restricted on Xcode launches but still useful when
    //    the app is opened from a terminal that exported its full env).
    let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in pathVar.split(separator: ":", omittingEmptySubsequences: true) {
        consider("\(dir)/claude")
    }

    // 2) Login-shell PATH — covers `~/.zprofile`, brew shellenv, cmux installs.
    if let loginShellPath = readLoginShellPath() {
        for dir in loginShellPath.split(separator: ":", omittingEmptySubsequences: true) {
            consider("\(dir)/claude")
        }
    }

    // 3) Common absolute fallbacks that may not appear in either PATH listing.
    let home = NSHomeDirectory()
    consider("\(home)/.local/bin/claude")
    consider("\(home)/.bin/claude")
    consider("/opt/homebrew/bin/claude")
    consider("/usr/local/bin/claude")
    consider("/Applications/cmux.app/Contents/Resources/bin/claude")
    return result
}

/// Cached login-shell PATH. nil until `readLoginShellPath` runs the first
/// time; sentinel empty string after a failed lookup to avoid retry storms.
private var cachedLoginShellPath: String?
private var loginShellPathLookupTried = false

/// Spawn `/bin/zsh -lic 'echo $PATH'` to recover the user's interactive
/// login PATH. Result is cached for the process lifetime.
private func readLoginShellPath() -> String? {
    if loginShellPathLookupTried { return cachedLoginShellPath }
    loginShellPathLookupTried = true

    let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shellPath)
    process.arguments = ["-lic", "echo $PATH"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return nil
    }

    let deadline = Date().addingTimeInterval(2.0)
    while process.isRunning && Date() < deadline {
        usleep(20_000)
    }
    if process.isRunning {
        process.terminate()
        usleep(200_000)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
    cachedLoginShellPath = path.isEmpty ? nil : path
    return cachedLoginShellPath
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
