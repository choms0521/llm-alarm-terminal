import Foundation

/// TailscaleProbing 실 구현(§5.5a, D-1 옵션 A). Process로 `tailscale status --json` /
/// `tailscale ip -4`를 호출하고 출력을 파싱해 TailscaleState 4분기로 환원한다. protocol 뒤에
/// 격리돼 있어 단위 테스트는 fake로 4분기를 결정론적으로 검증한다(이 struct의 파싱 헬퍼는
/// static이라 Process 없이도 단위 검증 가능).
///
/// 실행 파일 부재·launch 실패는 .notInstalled. 실행은 됐으나 timeout·비정상 종료는
/// .offline(CLI는 존재하므로 "미설치"가 아니라 "응답 불가"다). BackendState로 로그인/오프라인을 가른다.
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
        // 1) status --json으로 BackendState 판정. launch 자체 실패만 미설치 —
        //    실행 후 timeout/비정상 종료는 "응답 불가"이므로 오프라인으로 환원한다.
        let statusJSON: String
        do {
            guard let output = try Self.run(executable: executable, args: ["status", "--json"]) else {
                return .offline
            }
            statusJSON = output
        } catch {
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
        // 2) Running이면 ip -4로 100.x 1줄 획득. 실패·timeout 시 offline로 보수적 폴백.
        guard let ipOut = (try? Self.run(executable: executable, args: ["ip", "-4"])) ?? nil,
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

    /// 외부 CLI를 동기 실행하고 stdout을 문자열로 반환한다. launch 실패(실행 파일 부재 등)만
    /// throw하고, timeout(기본 5초)·비정상 종료는 nil로 환원해 호출부가 "실행은 됐으나 응답
    /// 불가"로 다루게 한다. stderr는 무시한다(파싱은 stdout만 본다).
    ///
    /// timeout이 실제로 동작해야 하는 이유: 데몬 부트스트랩 opt-in 경로에서 호출되므로
    /// tailscaled/CLI가 무응답이면 앱 부팅이 함께 멈춘다 — 무기한 waitUntilExit 금지.
    static func run(executable: String, args: [String], timeout: TimeInterval = 5) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        // stdout은 별도 큐에서 끝까지 읽는다 — 파이프 버퍼가 가득 차 자식 프로세스가
        // 블록되는 교착을 막고, 본 스레드는 종료 신호만 기다린다.
        let output = OutputBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = stdout.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.data, encoding: .utf8) ?? ""
    }

    /// 백그라운드 읽기 큐와 본 스레드가 공유하는 stdout 수집 상자. readDone 신호 후에만
    /// 본 스레드가 읽으므로 동시 접근이 없다.
    private final class OutputBox: @unchecked Sendable {
        var data = Data()
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
