import XCTest
import Foundation

/// MED4: 반복적 pane close/open 이 fd 누수를 유발하지 않음을 검증.
/// 실제 PTY spawn (`SessionManager.create(workspace:paneId:kind:rows:cols:)`) 으로 검증.
final class FdLeakTests: XCTestCase {

    func test_iterations_externalPty_doesNotLeakFds_idleAndActive() async throws {
        let manager = SessionManager(maxSessionsOverride: 5)
        let workspace = Workspace(
            id: UUID(),
            name: "leak",
            cwd: NSTemporaryDirectory(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .normal,
            envSnapshot: ProcessInfo.processInfo.environment
        )

        let baselineFds = currentProcessFdCount()
        XCTAssertGreaterThan(baselineFds, 0)

        // 20 회 반복 (MED4 의 100 회 기준을 빠른 unit test 사이즈로 축소).
        // 짝수 idx → idle close (spawn 직후 종료), 홀수 idx → active close (input 후 종료).
        let iterations = 20
        for i in 0..<iterations {
            let s = try await manager.create(
                workspace: workspace,
                paneId: UUID(),
                kind: .shell,
                rows: 24, cols: 80
            )
            if i % 2 == 1, let handle = s.ptyHandle {
                // active: 사용자 입력 시뮬레이션. write 가 EAGAIN 일 수 있어 best-effort.
                let bytes = Data("echo iter-\(i)\n".utf8)
                _ = try? PTYWriter.write(handle.masterFD, bytes)
            }
            try await manager.terminate(id: s.id)
            await manager.remove(id: s.id)
        }

        // 모든 session 이 registry 에서 제거됨.
        let count = await manager.count()
        XCTAssertEqual(count, 0, "iterations 후 session registry 비어 있어야 함")

        // fd 누수 검사: baseline 대비 증분이 작은 tolerance 안.
        let afterFds = currentProcessFdCount()
        let drift = afterFds - baselineFds
        XCTAssertLessThanOrEqual(
            drift, 5,
            "fd 누수 의심: baseline=\(baselineFds), after=\(afterFds), drift=\(drift)"
        )
    }

    /// `/dev/fd` 디렉터리는 현재 프로세스의 open fd 목록을 반환한다.
    /// 일부 fd 는 system / xctest 가 보유하므로 절대값보다는 baseline 대비 증분으로 검증한다.
    private func currentProcessFdCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }
}
