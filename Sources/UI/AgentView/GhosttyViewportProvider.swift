import AppKit
import Foundation
import GhosttyKit
import os

/// `AgentViewSurfaceProvider` 의 production 구현. SurfaceRegistry 에서
/// 등록된 `GhosttyTerminalView` 를 lookup 한 뒤 그 view 의 surface 핸들에 대해
/// `ghostty_surface_read_text` 와 `ghostty_surface_free_text` 를 1:1 패턴으로 호출한다.
///
/// CRITICAL: `ghostty_surface_read_text` 호출은 반드시 `defer` 로
/// `ghostty_surface_free_text` 와 1:1 짝지어진다 (ADR-E "나" 의 alloc/free 1:1 강제).
/// 본 파일이 verifier 4축 leak/RAII 축의 grep target 이다.
@MainActor
public final class GhosttyViewportProvider: AgentViewSurfaceProvider {
    private static let logger = Logger(
        subsystem: "com.choms0521.ClaudeAlarmTerminal",
        category: "AgentView.Provider"
    )

    private let surfaceRegistry: SurfaceRegistry

    public init(surfaceRegistry: SurfaceRegistry) {
        self.surfaceRegistry = surfaceRegistry
    }

    public func readViewportText(paneId: UUID) -> String? {
        guard let view = surfaceRegistry.acquireExisting(paneId: paneId) as? GhosttyTerminalView,
              let surface = view.surfaceHandle else { return nil }

        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0, y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0, y: 0
            ),
            rectangle: false
        )
        var text = ghostty_text_s()
        let ok = ghostty_surface_read_text(surface, sel, &text)
        defer { ghostty_surface_free_text(surface, &text) }
        guard ok, let cstr = text.text else { return nil }
        return String(cString: cstr)
    }
}
