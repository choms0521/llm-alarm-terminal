import XCTest
import Foundation
import AppKit

@MainActor
final class SurfaceLifecycleTests: XCTestCase {

    // MARK: - SurfaceRegistry — acquire / release / contains

    func test_acquire_release_invariants() {
        let registry = SurfaceRegistry()
        XCTAssertEqual(registry.activeCount, 0)

        let p1 = UUID()
        let v1 = registry.acquire(paneId: p1) { NSView() }
        XCTAssertEqual(registry.activeCount, 1)
        XCTAssertTrue(registry.contains(paneId: p1))

        // 동일 paneId 두 번째 acquire 는 factory 미호출, 기존 인스턴스 반환.
        var factoryCalls = 0
        let v1Again = registry.acquire(paneId: p1) {
            factoryCalls += 1
            return NSView()
        }
        XCTAssertTrue(v1 === v1Again, "동일 paneId acquire 는 같은 인스턴스 반환")
        XCTAssertEqual(factoryCalls, 0, "이미 등록된 paneId 의 factory 는 호출되지 않음")

        // release 후 dict 에서 제거됨.
        registry.release(paneId: p1)
        XCTAssertEqual(registry.activeCount, 0)
        XCTAssertFalse(registry.contains(paneId: p1))
    }

    func test_distinctPanes_isolatedSurfaces() {
        let registry = SurfaceRegistry()
        let p1 = UUID(); let p2 = UUID()
        let v1 = registry.acquire(paneId: p1) { NSView() }
        let v2 = registry.acquire(paneId: p2) { NSView() }
        XCTAssertFalse(v1 === v2, "다른 paneId 는 다른 surface 인스턴스")
        XCTAssertEqual(registry.activeCount, 2)
    }

    // MARK: - "workspace 전환" 시뮬레이션 — registry 가 owner 이므로 surface 보존

    func test_workspaceSwitch_doesNotDestroySurfaces() {
        let registry = SurfaceRegistry()
        let p1 = UUID(); let p2 = UUID()
        // workspace A 의 pane 등록.
        let viewA = registry.acquire(paneId: p1) { NSView() }
        XCTAssertEqual(registry.activeCount, 1)

        // workspace B 활성화 — 새 pane 등록 (A 의 view 는 release 호출 없음).
        let viewB = registry.acquire(paneId: p2) { NSView() }
        XCTAssertEqual(registry.activeCount, 2)

        // A 로 복귀: 동일 인스턴스 반환 (destroy 되지 않음).
        let viewARestored = registry.acquire(paneId: p1) { NSView() }
        XCTAssertTrue(viewARestored === viewA,
                      "비가시 workspace 의 surface 가 destroy 되지 않고 동일 인스턴스로 보존")
        _ = viewB  // suppress unused warning
    }

    // MARK: - 20 surface 동시 생성/해제 — bookkeeping invariant

    func test_20surfaces_createAndReleaseAll_returnsToZero() {
        let registry = SurfaceRegistry()
        var ids: [UUID] = []
        for _ in 0..<20 {
            let id = UUID()
            ids.append(id)
            _ = registry.acquire(paneId: id) { NSView() }
        }
        XCTAssertEqual(registry.activeCount, 20)

        for id in ids {
            registry.release(paneId: id)
        }
        XCTAssertEqual(registry.activeCount, 0,
                       "release 호출 후 activeCount 가 baseline (0) 으로 복원")
    }

    // MARK: - DebugRenderStats — env gating (off → nil init)

    func test_debugRenderStats_envOff_returnsNil() {
        unsetenv(DebugRenderStats.envKey)
        let registry = SurfaceRegistry()
        let stats = DebugRenderStats(registry: registry)
        XCTAssertNil(stats, "env 미설정 시 init? 는 nil (zero overhead)")
    }

    func test_debugRenderStats_envOn_returnsInstance() {
        setenv(DebugRenderStats.envKey, "1", 1)
        defer { unsetenv(DebugRenderStats.envKey) }
        let registry = SurfaceRegistry()
        let stats = DebugRenderStats(registry: registry)
        XCTAssertNotNil(stats, "env=1 시 init? 가 인스턴스 반환")

        // resident memory 측정 helper 도 비-zero 값 반환.
        let mem = DebugRenderStats.residentMemoryMB()
        XCTAssertGreaterThan(mem, 0, "task_info 가 양수 resident memory 반환")
    }
}
