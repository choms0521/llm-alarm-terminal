import XCTest
import Foundation

@MainActor
final class PaneSplitTests: XCTestCase {

    // MARK: - canSplit

    func test_canSplit_normalWorkspace_zeroPanes_true() throws {
        let manager = try freshManager()
        let ws = manager.addWorkspace(cwd: "/tmp/a", name: "a")
        // 새 workspace 는 기본 shell pane 1개 → canSplit == true
        XCTAssertTrue(manager.canSplit(workspaceId: ws.id))
    }

    func test_canSplit_normalWorkspace_twoPanes_false() throws {
        let manager = try freshManager()
        let ws = manager.addWorkspace(cwd: "/tmp/b", name: "b")
        manager.addPane(workspaceId: ws.id, kind: .claude)  // .right 으로 자동 할당
        // 두 pane 확보 후 canSplit == false (3rd block)
        XCTAssertFalse(manager.canSplit(workspaceId: ws.id))
    }

    func test_canSplit_agentView_false() throws {
        let manager = try freshManager()
        guard let agent = manager.workspaces.first(where: { $0.kind == .agentView }) else {
            XCTFail("agent-view 부재"); return
        }
        XCTAssertFalse(manager.canSplit(workspaceId: agent.id),
                       "agent-view 는 split 불가")
    }

    // MARK: - addPane

    func test_addPane_firstPane_assignedLeft() throws {
        let manager = try freshManager()
        // addWorkspace 가 자동 생성하는 기본 .left shell pane 을 제거해 빈 워크스페이스 상태 확보.
        let ws = manager.addWorkspace(cwd: "/tmp/empty", name: "empty")
        guard let defaultPaneId = ws.panes.first?.id else {
            XCTFail("기본 pane 부재"); return
        }
        manager.removePane(workspaceId: ws.id, paneId: defaultPaneId)

        manager.addPane(workspaceId: ws.id, kind: .shell)

        let updated = manager.workspaces.first(where: { $0.id == ws.id })
        XCTAssertEqual(updated?.panes.count, 1)
        XCTAssertEqual(updated?.panes.first?.position, .left,
                       "첫 pane 은 자동으로 .left 위치 할당")
    }

    func test_addPane_secondPane_assignedRight() throws {
        let manager = try freshManager()
        let ws = manager.addWorkspace(cwd: "/tmp/c", name: "c")  // 기본 .left shell pane 1개
        manager.addPane(workspaceId: ws.id, kind: .claude)

        let updated = manager.workspaces.first(where: { $0.id == ws.id })
        XCTAssertEqual(updated?.panes.count, 2)
        XCTAssertEqual(updated?.panes.first(where: { $0.position == .right })?.activeTab?.kind, .claude)
    }

    func test_addPane_thirdPane_rejected() throws {
        let manager = try freshManager()
        let ws = manager.addWorkspace(cwd: "/tmp/d", name: "d")
        manager.addPane(workspaceId: ws.id, kind: .claude)  // 2번째
        manager.addPane(workspaceId: ws.id, kind: .shell)   // 3번째 시도 (거부)

        let updated = manager.workspaces.first(where: { $0.id == ws.id })
        XCTAssertEqual(updated?.panes.count, 2, "3번째 pane 추가는 거부되어 갯수 변화 없음")
    }

    func test_addPane_onAgentView_rejected() throws {
        let manager = try freshManager()
        guard let agent = manager.workspaces.first(where: { $0.kind == .agentView }) else {
            XCTFail("agent-view 부재"); return
        }
        let beforeCount = agent.panes.count
        manager.addPane(workspaceId: agent.id, kind: .shell)
        let updated = manager.workspaces.first(where: { $0.id == agent.id })
        XCTAssertEqual(updated?.panes.count, beforeCount,
                       "agent-view 에는 pane 을 추가할 수 없음")
    }

    // MARK: - removePane

    func test_removePane_leftRemoval_promotesRightToLeft() throws {
        let manager = try freshManager()
        let ws = manager.addWorkspace(cwd: "/tmp/e", name: "e")
        manager.addPane(workspaceId: ws.id, kind: .claude)  // .right
        let updated1 = manager.workspaces.first(where: { $0.id == ws.id })!
        let leftId = updated1.panes.first(where: { $0.position == .left })!.id

        manager.removePane(workspaceId: ws.id, paneId: leftId)

        let updated2 = manager.workspaces.first(where: { $0.id == ws.id })!
        XCTAssertEqual(updated2.panes.count, 1)
        XCTAssertEqual(updated2.panes.first?.position, .left,
                       "남은 pane(.right) 이 .left 으로 승격")
        XCTAssertEqual(updated2.panes.first?.activeTab?.kind, .claude)
    }

    // MARK: - MED3 ADR-I grep invariant

    /// libghostty surface 자원 관리 cmux 패턴 invariant — Sources/UI/Pane/ 와 Sources/Session/
    /// 에 hibernate/pause/releaseSurface/surface.destroy/stopRendering/suspendRender/
    /// displayLayer = nil 등의 금지 패턴이 등장하지 않아야 한다.
    func test_grep_adrI_forbiddenPatterns_zeroMatches() throws {
        let project = try projectRoot()
        let scanDirs = ["Sources/UI/Pane", "Sources/Session"]
        let pattern = "(hibernate|pause|releaseSurface|occlusionState|surface\\.destroy|stopRendering|suspendRender|displayLayer.*nil)"
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])

        var hits: [String] = []
        for dir in scanDirs {
            let url = project.appendingPathComponent(dir)
            guard let it = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in it {
                guard file.pathExtension == "swift" else { continue }
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let nsr = NSRange(content.startIndex..., in: content)
                let matches = regex.matches(in: content, options: [], range: nsr)
                for m in matches {
                    if let r = Range(m.range, in: content) {
                        hits.append("\(file.lastPathComponent): \(content[r])")
                    }
                }
            }
        }
        XCTAssertTrue(hits.isEmpty,
                      "ADR-I cmux 패턴 위반 발견: \(hits.joined(separator: ", "))")
    }

    // MARK: - Helpers

    private func freshManager() throws -> WorkspaceManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneSplitTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))
        return WorkspaceManager(store: store)
    }

    private func projectRoot() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SessionTests dir → WorkspaceTests dir
            .deletingLastPathComponent()  // Tests dir
            .deletingLastPathComponent()  // project root
    }
}

