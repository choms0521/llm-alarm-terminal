import Foundation
import Darwin
import Darwin.Mach
import os.log

/// `CHAT_TERMINAL_DEBUG_SURFACE_STATS=1` 일 때만 활성화되는 telemetry 컴포넌트.
///
/// 1초마다 (resident memory, active surface count) 를
/// `~/Library/Logs/ClaudeAlarmTerminal/surface-stats.log` 에 append.
/// env 미설정 시 init? 가 nil 을 반환하여 zero overhead.
public final class DebugRenderStats {
    public static let envKey = "CHAT_TERMINAL_DEBUG_SURFACE_STATS"

    private let registry: SurfaceRegistry
    private let logger: os.Logger
    private let logFile: FileHandle?
    private var timer: DispatchSourceTimer?

    public init?(registry: SurfaceRegistry) {
        guard ProcessInfo.processInfo.environment[Self.envKey] == "1" else {
            return nil
        }
        self.registry = registry
        self.logger = os.Logger(
            subsystem: "com.choms0521.ClaudeAlarmTerminal",
            category: "DebugRenderStats"
        )
        self.logFile = Self.openLog()
        startTimer()
    }

    deinit {
        timer?.cancel()
        try? logFile?.close()
    }

    private static func openLog() -> FileHandle? {
        let logsRoot = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ClaudeAlarmTerminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        let path = logsRoot.appendingPathComponent("surface-stats.log").path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try? handle?.seekToEnd()
        return handle
    }

    private func startTimer() {
        let queue = DispatchQueue(label: "com.choms0521.ClaudeAlarmTerminal.DebugRenderStats")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        self.timer = t
    }

    private func tick() {
        let mem = Self.residentMemoryMB()
        // activeCount 는 @MainActor isolated 이므로 main 으로 hop.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let count = MainActor.assumeIsolated { self.registry.activeCount }
            let line = "\(Date().ISO8601Format()) mem=\(mem)MB surf=\(count)\n"
            try? self.logFile?.write(contentsOf: Data(line.utf8))
            self.logger.debug("mem=\(mem)MB surf=\(count, privacy: .public)")
        }
    }

    /// `task_info(MACH_TASK_BASIC_INFO)` 로 현재 프로세스의 resident memory(MB) 측정.
    public static func residentMemoryMB() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reb, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return info.resident_size / (1024 * 1024)
    }
}
