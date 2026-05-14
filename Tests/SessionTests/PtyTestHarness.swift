import Foundation
import Darwin

/// H7: PTY 기반 통합 테스트의 공통 helper.
///
/// - `readUntilQuiet`: non-blocking master fd 에서 `quietWindow` 동안 더 이상 byte 가 오지 않을 때까지 읽음.
/// - `stripANSI`: zsh prompt 의 색상/커서 escape 시퀀스 제거.
/// - `writeCmd`: command + 개행 을 fd 에 write (EAGAIN 처리는 `PTYWriter.write` 가 수행).
enum PtyTestHarness {

    /// fd 에서 데이터를 누적 읽음. 총 `timeout` 까지, 또는 `quietWindow` 동안 read 가 0 이면 종료.
    /// PTYSpawner 가 master fd 를 `O_NONBLOCK` 으로 설정하므로 `read(2)` 는 EAGAIN 즉시 반환.
    static func readUntilQuiet(
        fd: Int32,
        timeout: TimeInterval = 1.0,
        quietWindow: TimeInterval = 0.15
    ) -> String {
        var buffer = Data()
        let start = Date()
        var lastDataAt = Date()
        let chunkSize = 4096
        var raw = [UInt8](repeating: 0, count: chunkSize)

        while Date().timeIntervalSince(start) < timeout {
            let n = raw.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, chunkSize)
            }
            if n > 0 {
                buffer.append(raw, count: n)
                lastDataAt = Date()
            } else if n == 0 {
                // EOF
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    if !buffer.isEmpty,
                       Date().timeIntervalSince(lastDataAt) >= quietWindow {
                        break
                    }
                    usleep(20_000)  // 20ms
                } else {
                    break
                }
            }
        }
        return String(data: buffer, encoding: .utf8) ?? ""
    }

    /// ANSI CSI 이스케이프 시퀀스 제거. `\x1b\[[0-9;]*[a-zA-Z]` 패턴.
    static func stripANSI(_ input: String) -> String {
        let pattern = "\\x1b\\[[0-9;]*[a-zA-Z]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
    }

    /// "command\n" 을 fd 에 write.
    static func writeCmd(_ fd: Int32, _ command: String) throws {
        try PTYWriter.write(fd, Data((command + "\n").utf8))
    }

    /// 테스트 격리용 — 사용자의 ~/.zshrc 가 invariant 검증을 오염시키지 않도록 빈 ZDOTDIR 디렉터리 생성.
    /// `Workspace.envSnapshot` 에 합쳐 사용한다.
    static func minimalShellEnv(zdotdirParent: URL) throws -> [String: String] {
        let zdotdir = zdotdirParent.appendingPathComponent("zdotdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        // 빈 .zshenv / .zshrc 를 만들어 사용자의 글로벌 zsh config 로딩을 방지.
        try Data().write(to: zdotdir.appendingPathComponent(".zshenv"))
        try Data().write(to: zdotdir.appendingPathComponent(".zshrc"))
        return [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": "/bin/zsh",
            "TERM": "xterm-256color",
            "LANG": "ko_KR.UTF-8",
            "ZDOTDIR": zdotdir.path
        ]
    }

    /// 임시 작업 디렉터리 (테스트 정리 시 호출부가 삭제).
    static func makeTempDir(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
