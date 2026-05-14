import AppKit
import Foundation

/// libghostty surface 의 RAII 컨테이너.
///
/// ADR-I cmux 패턴 운영화:
/// - 모든 surface 는 등록 시점부터 release(paneId:) 까지 alive.
/// - hibernate / pause / suspend / occlusion-aware skip 코드 0줄.
/// - workspace 전환 등 SwiftUI view tree 재구성 시에도 registry 가 owner 이므로 surface 가 destroy 되지 않음.
///
/// release(paneId:) 가 마지막 strong reference 를 해제하면 NSView 의 deinit 이 호출되어
/// `ghostty_surface_free` 가 child PTY 까지 정리한다.
@MainActor
public final class SurfaceRegistry: ObservableObject {
    private var surfaces: [UUID: NSView] = [:]

    /// nonisolated init — 빈 dict 초기화는 actor-isolated 상태에 접근하지 않으므로 안전.
    public nonisolated init() {}

    /// 이미 등록된 surface 가 있으면 그대로 반환, 없으면 `factory` 로 생성하여 등록.
    public func acquire(paneId: UUID, factory: () -> NSView) -> NSView {
        if let existing = surfaces[paneId] {
            return existing
        }
        let view = factory()
        surfaces[paneId] = view
        return view
    }

    /// pane 종료 시 호출. dict 에서 strong reference 를 제거하여 NSView dealloc 을 유도.
    public func release(paneId: UUID) {
        surfaces.removeValue(forKey: paneId)
    }

    public func contains(paneId: UUID) -> Bool {
        surfaces[paneId] != nil
    }

    /// 활성 surface 수. DebugRenderStats 와 통합 테스트에서 사용.
    public var activeCount: Int { surfaces.count }

    /// ViewportPollingTimer 가 polling tick 마다 호출. 등록된 surface 만 반환하고
    /// 미등록 paneId 는 nil. factory 를 호출하지 않으므로 acquire 와 구분된다.
    public func acquireExisting(paneId: UUID) -> NSView? {
        surfaces[paneId]
    }
}
