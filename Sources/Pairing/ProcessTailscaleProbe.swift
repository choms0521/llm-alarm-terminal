import Foundation

/// TailscaleProbing 실 구현(§5.5a, D-1 옵션 A). Process로 `tailscale status --json` /
/// `tailscale ip -4`를 호출하고 출력을 파싱해 TailscaleState 4분기로 환원한다. protocol 뒤에
/// 격리돼 있어 단위 테스트는 fake로 4분기를 결정론적으로 검증한다(이 struct의 파싱 헬퍼는
/// static이라 Process 없이도 단위 검증 가능).
///
/// 실행 파일 부재(launch throw)는 .notInstalled. BackendState로 로그인/오프라인을 가른다.
/// 핵심 함정(Day 0 스파이크): Stopped여도 `ip -4`는 저장된 100.x를 반환하므로, BackendState ==
/// "Running"을 먼저 게이트한 뒤에만 .running으로 환원한다 — 그러지 않으면 utun이 내려간 주소에
/// 바인딩해 listener가 .waiting에 무한 대기한다.
public struct ProcessTailscaleProbe: TailscaleProbing {
    /// tailscale CLI 실행 파일 경로(부록 A CLAUDE_ALARM_TAILSCALE_CLI_PATH). 경로만 보유하며
    /// secret·IP가 아니다. nil이면 표준 후보 경로를 순서대로 탐색한다.
    let cliPath: String?

    /// 표준 tailscale CLI 후보 경로(설치 방식별). Intel Homebrew / Apple Silicon Homebrew /
    /// Tailscale.app 번들 순으로 탐색한다.
    static let candidatePaths = [
        "/usr/local/bin/tailscale",                                   // Intel Homebrew
        "/opt/homebrew/bin/tailscale",                                // Apple Silicon Homebrew
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",       // Tailscale.app 번들
    ]

    public init(cliPath: String? = nil) {
        self.cliPath = cliPath
    }

    public func probe() async -> TailscaleState {
        guard let executable = resolveCLIPath() else {
            return .notInstalled   // 후보 경로 어디에도 실행 파일이 없다.
        }
        // 1) status --json으로 BackendState 판정. launch 실패 = 미설치.
        guard let statusJSON = try? Self.run(executable: executable, args: ["status", "--json"]) else {
            return .notInstalled
        }
        let backend = Self.backendState(statusJSON)   // "Running"/"NeedsLogin"/"Stopped"...
        switch backend {
        case "NeedsLogin":
            return .notLoggedIn
        case "Running":
            break
        default:
            return .offline   // Stopped/NoState/파싱 실패 등은 오프라인으로 묶는다.
        }
        // 2) Running이면 ip -4로 100.x 1줄 획득. 획득 실패 시 offline로 보수적 폴백.
        guard let ipOut = try? Self.run(executable: executable, args: ["ip", "-4"]),
              let ip = Self.firstTailscaleIP(ipOut) else {
            return .offline
        }
        return .running(ip: ip)   // 로그는 100.x 마스킹(A13). 실 IP는 메모리에만.
    }

    /// 주입 경로가 있으면 그것만, 없으면 후보 경로 중 실제 존재하는 첫 항목을 반환한다.
    /// 어디에도 없으면 nil(.notInstalled).
    private func resolveCLIPath() -> String? {
        if let cliPath {
            return FileManager.default.isExecutableFile(atPath: cliPath) ? cliPath : nil
        }
        return Self.candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 외부 CLI를 동기 실행하고 stdout을 문자열로 반환한다. launch 실패(실행 파일 부재 등)는 throw.
    /// stderr는 무시한다(파싱은 stdout만 본다). 데몬 외부 프로세스라 5초 안에 응답하지 않으면 종료한다.
    static func run(executable: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `tailscale status --json` 출력에서 BackendState 문자열을 추출한다. 파싱 실패는 빈 문자열
    /// (호출부 default 분기가 .offline으로 환원). 신뢰 입력이 아니므로 관대하게 처리한다.
    static func backendState(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backend = object["BackendState"] as? String else {
            return ""
        }
        return backend
    }

    /// `tailscale ip -4` 출력에서 첫 100.x IPv4 주소를 추출한다. CGNAT 대역(100.64.0.0/10)을
    /// 느슨히 확인(100.으로 시작 + 점 3개)해 비정상 출력은 nil로 거른다. 공백/빈 줄은 무시한다.
    static func firstTailscaleIP(_ output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: ".")
            if line.hasPrefix("100."), parts.count == 4,
               parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                return line
            }
        }
        return nil
    }
}
