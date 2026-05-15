import XCTest
@testable import ClaudeAlarmTerminal

/// P3.5 REQ-3 — CLAUDE_CONFIG_DIR 격리 폐지 회귀 방지.
///
/// 이전 P2 invariant 4 ("claude 세션마다 독립 config 디렉터리") 는 사용자
/// ~/.claude/credentials 우회로 매번 재로그인을 강제했다. REQ-3 으로 격리가
/// 폐지됐고, buildSpawnEnv 가 claude case 에서 더 이상 CLAUDE_CONFIG_DIR 키를
/// 추가하지 않음을 본 테스트가 보장한다.
///
/// 향후 누군가 P2 invariant 를 무심코 복원하면 본 테스트가 실패한다.
final class SessionSpawnEnvSharedConfigTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeWorkspace(env: [String: String] = [:]) -> Workspace {
        Workspace(
            name: "ws-shared",
            cwd: "/tmp",
            createdAt: fixedDate,
            kind: .normal,
            envSnapshot: env
        )
    }

    /// case 1: claude buildSpawnEnv 가 CLAUDE_CONFIG_DIR 키를 추가하지 않는다.
    /// 빈 base env 로 호출해도 결과 dict 에 해당 키가 부재해야 한다.
    func test_claudeCase_doesNotInjectClaudeConfigDir_whenBaseEnvEmpty() throws {
        let env = try SessionSpawnEnv.buildSpawnEnv(
            workspace: makeWorkspace(),
            paneId: UUID(),
            sessionId: UUID(),
            kind: .claude
        )
        XCTAssertNil(env["CLAUDE_CONFIG_DIR"],
                     "REQ-3: claude pane 은 격리 디렉터리를 강제하지 않는다")
        XCTAssertNil(env["HISTFILE"], "claude case 는 HISTFILE 도 추가하지 않는다")
    }

    /// case 2: 사용자 env 에 CLAUDE_CONFIG_DIR 가 이미 있다면 그대로 propagate.
    /// (opt-in 격리 모드 사용자 — 자체 ~/.config 등으로 분리하는 경우)
    func test_claudeCase_propagatesUserClaudeConfigDir_whenPresentInBaseEnv() throws {
        let userPath = "/Users/mscho/.config/claude-custom"
        let env = try SessionSpawnEnv.buildSpawnEnv(
            workspace: makeWorkspace(env: ["CLAUDE_CONFIG_DIR": userPath, "PATH": "/usr/bin"]),
            paneId: UUID(),
            sessionId: UUID(),
            kind: .claude
        )
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], userPath,
                       "사용자 env 의 CLAUDE_CONFIG_DIR 는 base 로부터 그대로 propagate")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    /// case 3: shell case 는 여전히 HISTFILE override 만 적용, CLAUDE_CONFIG_DIR 부재.
    /// claude 격리 폐지가 shell HISTFILE 격리를 잘못 함께 폐지하지 않았음을 확인.
    func test_shellCase_stillAppliesHistFileOverride_andHasNoClaudeConfigDir() throws {
        let env = try SessionSpawnEnv.buildSpawnEnv(
            workspace: makeWorkspace(env: ["PATH": "/usr/bin"]),
            paneId: UUID(),
            sessionId: UUID(),
            kind: .shell
        )
        XCTAssertNil(env["CLAUDE_CONFIG_DIR"], "shell case 는 절대 CLAUDE_CONFIG_DIR 을 추가하지 않는다")
        XCTAssertNotNil(env["HISTFILE"], "HISTFILE 격리는 보존")
        XCTAssertTrue(env["HISTFILE"]!.hasSuffix("/history"))
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }
}
