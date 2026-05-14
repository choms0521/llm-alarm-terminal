import XCTest
import Foundation

final class ErrorDialogTests: XCTestCase {

    // MARK: - Catalog coverage

    func test_allErrorCodes_haveKoreanMessage_andTitle() {
        for code in ErrorCode.allCases {
            let msg = KoreanErrorCatalog.message(for: code)
            XCTAssertFalse(msg.isEmpty, "\(code) 의 message 누락")
            XCTAssertNotEqual(msg, "오류가 발생했습니다.",
                              "\(code) 의 message 가 fallback 으로 떨어짐")

            let title = KoreanErrorCatalog.title(for: code)
            XCTAssertFalse(title.isEmpty, "\(code) 의 title 누락")
        }
    }

    // MARK: - MAX_SESSIONS_REACHED spec text

    func test_maxSessionsReached_messageMatches_specText() {
        let msg = KoreanErrorCatalog.message(for: .maxSessionsReached)
        XCTAssertEqual(
            msg,
            "최대 세션 개수에 도달했습니다 (N=20). 기존 세션을 종료하세요.",
            "v4 § P2 명시 문구와 정확히 일치"
        )
    }

    func test_managerError_maxSessionsReached_descriptionMatchesSpec() {
        let err = ManagerError.maxSessionsReached(currentMax: 20)
        XCTAssertEqual(
            String(describing: err),
            "최대 세션 개수에 도달했습니다 (N=20). 기존 세션을 종료하세요."
        )
    }

    func test_managerError_maxSessionsReached_mapsToErrorCode() {
        let err = ManagerError.maxSessionsReached(currentMax: 20)
        XCTAssertEqual(KoreanErrorCatalog.code(from: err), .maxSessionsReached)
    }

    // MARK: - Param substitution (cwd_inaccessible)

    func test_cwdInaccessible_paramSubstitution() {
        let msg = KoreanErrorCatalog.message(
            for: .cwdInaccessible,
            params: ["path": "/tmp/projA"]
        )
        XCTAssertTrue(msg.contains("/tmp/projA"))
        XCTAssertFalse(msg.contains("{path}"))
    }

    // MARK: - WorkspaceStoreError mapping

    func test_workspaceStoreError_writeFailed_mapsToAtomicWriteFailed() {
        let err = WorkspaceStoreError.writeFailed(path: "/x", underlyingDescription: "no space")
        XCTAssertEqual(KoreanErrorCatalog.code(from: err), .atomicWriteFailed)
    }

    // MARK: - 한국어 polyglyph 검증 (한국어 문자가 깨지지 않고 직접 저장됨)

    func test_messageContains_koreanCharacters_notEscaped() {
        let msg = KoreanErrorCatalog.message(for: .maxSessionsReached)
        XCTAssertTrue(msg.contains("최대"))
        XCTAssertTrue(msg.contains("세션"))
        XCTAssertFalse(msg.contains("\\u"),
                       "한국어가 \\u escape 형식이 아닌 직접 저장")
    }

    // MARK: - agent-view canClose 분기 (Cmd+W invariant)

    @MainActor
    func test_agentView_canCloseInvariant_blocksCloseShortcut() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErrorDialogTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))
        let manager = WorkspaceManager(store: store)

        guard let agent = manager.workspaces.first(where: { $0.kind == .agentView }) else {
            XCTFail("agent-view 부재"); return
        }
        // Cmd+W 핸들러 시뮬레이션: canClose 분기 점검.
        XCTAssertFalse(agent.canClose,
                       "agent-view 의 canClose 는 false — Cmd+W close 가 차단되어야 함")
    }
}
