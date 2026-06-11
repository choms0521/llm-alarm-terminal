import AppKit
import Foundation
import os

/// libghostty surface 의 RAII 컨테이너.
///
/// ADR-I cmux 패턴 운영화:
/// - 모든 surface 는 등록 시점부터 release(id:) 까지 alive.
/// - hibernate / pause / suspend / occlusion-aware skip 코드 0줄.
/// - workspace 전환 등 SwiftUI view tree 재구성 시에도 registry 가 owner 이므로 surface 가 destroy 되지 않음.
///
/// release(id:) 가 마지막 strong reference 를 해제하면 NSView 의 deinit 이 호출되어
/// `ghostty_surface_free` 가 child PTY 까지 정리한다.
///
/// P3.5 Day 3: key 의 의미를 paneId → tabId 로 전환(REQ-2 멀티탭 컨테이너 도입).
/// 인자명을 generic `id` 로 일반화하여 호출자가 tabId 를 그대로 전달한다.
@MainActor
public final class SurfaceRegistry: ObservableObject {
    private var surfaces: [UUID: NSView] = [:]

    /// nonisolated init — 빈 dict 초기화는 actor-isolated 상태에 접근하지 않으므로 안전.
    public nonisolated init() {}

    private static let logger = Logger(subsystem: "com.choms0521.ClaudeAlarmTerminal", category: "R2-DIAG")

    /// 이미 등록된 surface 가 있으면 그대로 반환, 없으면 `factory` 로 생성하여 등록.
    public func acquire(id: UUID, factory: () -> NSView) -> NSView {
        if let existing = surfaces[id] {
            let ptr = Unmanaged.passUnretained(existing).toOpaque()
            Self.logger.info("[R2-DIAG] registry.acquire HIT id=\(id.uuidString.prefix(8), privacy: .public) viewPtr=\(String(describing: ptr), privacy: .public) totalActive=\(self.surfaces.count, privacy: .public)")
            return existing
        }
        let view = factory()
        surfaces[id] = view
        let ptr = Unmanaged.passUnretained(view).toOpaque()
        Self.logger.info("[R2-DIAG] registry.acquire MISS id=\(id.uuidString.prefix(8), privacy: .public) viewPtr=\(String(describing: ptr), privacy: .public) totalActive=\(self.surfaces.count, privacy: .public)")
        return view
    }

    /// surface 의 owner(tab 또는 pane) 종료 시 호출. dict 에서 strong reference 를
    /// 제거하여 NSView dealloc 을 유도.
    public func release(id: UUID) {
        let existed = surfaces[id] != nil
        surfaces.removeValue(forKey: id)
        Self.logger.info("[R2-DIAG] registry.release id=\(id.uuidString.prefix(8), privacy: .public) existed=\(existed, privacy: .public) totalActive=\(self.surfaces.count, privacy: .public)")
    }

    public func contains(id: UUID) -> Bool {
        surfaces[id] != nil
    }

    /// 활성 surface 수. DebugRenderStats 와 통합 테스트에서 사용.
    public var activeCount: Int { surfaces.count }

    /// ViewportPollingTimer / AgentTerminalHostView 가 polling tick 또는 우측 호스트
    /// mount 시 호출. 등록된 surface 만 반환하고 미등록 id 는 nil. factory 를 호출하지
    /// 않으므로 acquire 와 구분된다.
    public func acquireExisting(id: UUID) -> NSView? {
        surfaces[id]
    }
}
