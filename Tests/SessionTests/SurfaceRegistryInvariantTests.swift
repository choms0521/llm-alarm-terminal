import XCTest
import Foundation
import AppKit

/// P5.5 Day 2: `SurfaceRegistry` 불변식 + NSView 재부모화 메커니즘 단위 검증.
///
/// agent-view 우측 호스트(`AgentTerminalHostView`)는 `acquireExisting(id:)` 으로
/// 워크스페이스 탭에 이미 mount 된 기존 NSView 를 그대로 가져와 자신의 컨테이너에
/// 넣는다. 이때 같은 PTY/scrollback 을 공유하는 핵심 가정은 두 가지다.
///
///   (가정 1) `SurfaceRegistry` 가 동일 id 에 대해 항상 같은 NSView 인스턴스를 반환한다.
///   (가정 2) NSView 를 다른 superview 의 `addSubview` 로 넣으면 AppKit 이 이전
///            superview 에서 자동으로 제거(재부모화)하며 view 인스턴스는 보존된다.
///
/// 가정 1 은 (a)~(d) 불변식 테스트로, 가정 2 는 reparent 메커니즘 테스트로 실증한다.
/// `AgentTerminalHostView`(NSViewRepresentable) 자체는 GhosttyKit 의존 + 테스트 타겟
/// 제외라 여기서 직접 인스턴스화하지 않는다 — 재부모화의 라이브 scrollback 보존은
/// GUI walkthrough 게이트(docs/plans/p5.5/walkthrough.md)가 검증한다.
@MainActor
final class SurfaceRegistryInvariantTests: XCTestCase {

    // MARK: - 가정 1: SurfaceRegistry 동일 인스턴스 불변식

    /// (a) 동일 id 로 `acquire` 후 `acquireExisting` 이 같은 인스턴스를 반환한다.
    func test_acquireThenAcquireExisting_returnsSameInstance() {
        let registry = SurfaceRegistry()
        let id = UUID()
        let v1 = registry.acquire(id: id) { NSView() }
        let v2 = registry.acquireExisting(id: id)
        XCTAssertNotNil(v2)
        XCTAssertTrue(v1 === v2, "acquire 후 acquireExisting 은 동일 NSView 인스턴스를 반환")
    }

    /// (b) `acquireExisting` 을 두 번 호출해도 같은 인스턴스를 반환한다(우측 호스트
    ///     재생성 시 매번 같은 surface 를 mount 하는 기반).
    func test_acquireExisting_twice_returnsSameInstance() {
        let registry = SurfaceRegistry()
        let id = UUID()
        _ = registry.acquire(id: id) { NSView() }
        let first = registry.acquireExisting(id: id)
        let second = registry.acquireExisting(id: id)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "acquireExisting 2 회는 동일 인스턴스")
    }

    /// (c) 미등록 id 에 `acquireExisting` 은 nil 을 반환한다(lazy 미생성 탭 분기).
    func test_acquireExisting_unregisteredId_returnsNil() {
        let registry = SurfaceRegistry()
        XCTAssertNil(registry.acquireExisting(id: UUID()),
                     "등록되지 않은 id 는 nil — 우측 호스트가 lazy spawn 경로로 분기")
    }

    /// (d) `release` 후 `contains` 가 false 이고 `acquireExisting` 도 nil 이다
    ///     (세션 종료/closeTab/closeWorkspace 시 graceful EmptyState 전환 기반).
    func test_release_thenContainsFalse_andAcquireExistingNil() {
        let registry = SurfaceRegistry()
        let id = UUID()
        _ = registry.acquire(id: id) { NSView() }
        XCTAssertTrue(registry.contains(id: id))

        registry.release(id: id)
        XCTAssertFalse(registry.contains(id: id), "release 후 contains 는 false")
        XCTAssertNil(registry.acquireExisting(id: id), "release 후 acquireExisting 은 nil")
    }

    /// `acquireExisting` 은 factory 를 호출하지 않으므로 미등록 id 가 새로 등록되지
    /// 않는다(acquire 와의 구분 — 우측 호스트가 surface 를 우발적으로 생성하지 않음).
    func test_acquireExisting_doesNotRegister() {
        let registry = SurfaceRegistry()
        let id = UUID()
        _ = registry.acquireExisting(id: id)
        XCTAssertFalse(registry.contains(id: id), "acquireExisting 은 등록을 유발하지 않음")
        XCTAssertEqual(registry.activeCount, 0)
    }

    // MARK: - 가정 2: NSView 재부모화 메커니즘 (스파이크)

    /// 재부모화 스파이크: `acquireExisting` 으로 가져온 NSView 를 한 superview 에서
    /// 다른 superview 로 `addSubview` 하면 AppKit 이 이전 superview 에서 자동 제거하고
    /// view 인스턴스는 보존된다. 이것이 agent-view 우측 호스트가 워크스페이스 탭과
    /// 같은 NSView(=같은 surface=같은 PTY/scrollback)를 공유하는 메커니즘의 코드 레벨
    /// 실증이다. libghostty surface 는 NSView 에 1:1 결속(ADR-I)이므로 view 가 이동해도
    /// surface 는 그대로다.
    func test_reparent_addSubviewMovesViewBetweenContainers() {
        let registry = SurfaceRegistry()
        let id = UUID()
        // 워크스페이스 탭 컨테이너를 모사한 부모 A.
        let workspaceContainer = NSView()
        // agent-view 우측 호스트 컨테이너를 모사한 부모 B.
        let agentHostContainer = NSView()

        // (1) 워크스페이스 탭에 surface 가 mount 됨(부모 A 에 addSubview).
        let surface = registry.acquire(id: id) { NSView() }
        workspaceContainer.addSubview(surface)
        XCTAssertTrue(surface.superview === workspaceContainer)
        XCTAssertEqual(workspaceContainer.subviews.count, 1)
        XCTAssertEqual(agentHostContainer.subviews.count, 0)

        // (2) agent-view 진입: acquireExisting 으로 같은 인스턴스를 가져와 부모 B 에 mount.
        let mounted = registry.acquireExisting(id: id)
        XCTAssertTrue(mounted === surface, "재부모화 대상은 동일 인스턴스(신규 생성 아님)")
        agentHostContainer.addSubview(mounted!)

        // (3) AppKit 이 부모 A 에서 자동 제거하고 부모 B 로 이동(재부모화 자동 동작).
        XCTAssertTrue(surface.superview === agentHostContainer,
                      "addSubview 가 superview 를 agentHostContainer 로 재부모화")
        XCTAssertEqual(workspaceContainer.subviews.count, 0,
                       "이전 superview 에서 자동 제거됨")
        XCTAssertEqual(agentHostContainer.subviews.count, 1)

        // (4) 워크스페이스 탭 복귀: 다시 부모 A 로 재부모화 — 여전히 동일 인스턴스.
        let restored = registry.acquireExisting(id: id)
        XCTAssertTrue(restored === surface, "복귀 시에도 동일 인스턴스(surface/scrollback 보존)")
        workspaceContainer.addSubview(restored!)
        XCTAssertTrue(surface.superview === workspaceContainer,
                      "복귀 시 부모 A 로 재부모화")
        XCTAssertEqual(agentHostContainer.subviews.count, 0,
                       "agent-view 호스트에서 자동 제거됨")
    }

    /// 재부모화 전후로 registry 의 surface 인스턴스 동일성이 유지되어 두 번째
    /// GhosttyTerminalView 가 생성되지 않음을 보증(ADR-I 1 surface = 1 NSView).
    /// activeCount 가 재부모화로 증가하지 않는다(신규 surface 미생성).
    func test_reparent_doesNotCreateSecondSurface() {
        let registry = SurfaceRegistry()
        let id = UUID()
        let surface = registry.acquire(id: id) { NSView() }
        XCTAssertEqual(registry.activeCount, 1)

        let containerA = NSView()
        let containerB = NSView()
        containerA.addSubview(surface)
        // agent-view 호스트가 acquireExisting 으로 같은 surface 를 mount.
        let again = registry.acquireExisting(id: id)
        containerB.addSubview(again!)

        XCTAssertEqual(registry.activeCount, 1,
                       "재부모화는 신규 surface 를 생성하지 않음(activeCount 불변)")
        XCTAssertTrue(again === surface)
    }
}
