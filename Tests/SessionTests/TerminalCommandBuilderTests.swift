import XCTest
// SessionTests target re-compiles Sources/Session into the test bundle's own
// module. 별도 @testable import 가 필요하지 않다 — 모든 internal/public 심볼이
// 같은 모듈 안에서 직접 접근 가능.
import Foundation

/// P5.5 Day 0 — `TerminalCommandBuilder` 공용 추출 회귀 방지.
///
/// 기존 `PaneTerminalView.buildCommand` 가 산출하던 command 문자열과
/// byte-identical 동작을 보장한다. claude/shell 두 kind, path quoting,
/// activeTab 부재 시 shell fallback 경로를 모두 검증한다.
final class TerminalCommandBuilderTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let fixedWsId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let fixedPaneId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeWorkspace(env: [String: String] = [:]) -> Workspace {
        Workspace(
            id: fixedWsId,
            name: "ws-cmd",
            cwd: "/tmp",
            createdAt: fixedDate,
            kind: .normal,
            envSnapshot: env
        )
    }

    private func makePane() -> Pane {
        Pane(id: fixedPaneId, position: .left)
    }

    // MARK: - claude kind

    /// claude tab 은 `<shell> -lic 'exec <claudePath>'` 형태를 산출한다.
    /// envSnapshot 의 SHELL 이 그대로 prefix 로 쓰인다.
    func test_build_claudeKind_usesLoginInteractiveShellExec() {
        let workspace = makeWorkspace(env: ["SHELL": "/bin/zsh"])
        let pane = makePane()
        let tab = Tab(kind: .claude, name: "Claude")

        let command = TerminalCommandBuilder.build(workspace: workspace, pane: pane, tab: tab)

        // resolveClaudeBinary 는 환경에 따라 절대 경로 또는 "claude" fallback 을 반환한다.
        // 어느 쪽이든 `/bin/zsh -lic 'exec ...'` prefix/suffix 는 고정이다.
        XCTAssertTrue(command.hasPrefix("/bin/zsh -lic 'exec "),
                      "claude command 는 login+interactive shell exec prefix 로 시작한다: \(command)")
        XCTAssertTrue(command.hasSuffix("'"),
                      "claude command 는 단일 인용부호로 닫힌다: \(command)")
    }

    /// SHELL 미지정 시 기본값 /bin/zsh 를 사용한다.
    func test_build_claudeKind_fallsBackToDefaultShell_whenShellEnvAbsent() {
        let workspace = makeWorkspace(env: [:])
        let tab = Tab(kind: .claude, name: "Claude")

        let command = TerminalCommandBuilder.build(workspace: workspace, pane: makePane(), tab: tab)

        XCTAssertTrue(command.hasPrefix("/bin/zsh -lic 'exec "),
                      "SHELL 부재 시 기본 /bin/zsh 사용: \(command)")
    }

    /// 사용자 지정 SHELL 이 prefix 에 반영된다.
    func test_build_claudeKind_respectsCustomShellFromEnvSnapshot() {
        let workspace = makeWorkspace(env: ["SHELL": "/usr/local/bin/fish"])
        let tab = Tab(kind: .claude, name: "Claude")

        let command = TerminalCommandBuilder.build(workspace: workspace, pane: makePane(), tab: tab)

        XCTAssertTrue(command.hasPrefix("/usr/local/bin/fish -lic 'exec "),
                      "envSnapshot 의 SHELL 이 prefix 로 사용된다: \(command)")
    }

    // MARK: - shell kind

    /// shell tab 은 `/usr/bin/env HISTFILE=<dir>/history <shell> -l` 형태를 산출한다.
    func test_build_shellKind_injectsHistFileEnvPrefix() {
        let workspace = makeWorkspace(env: ["SHELL": "/bin/zsh"])
        let pane = makePane()
        let tab = Tab(kind: .shell, name: "셸")

        let command = TerminalCommandBuilder.build(workspace: workspace, pane: pane, tab: tab)

        XCTAssertTrue(command.hasPrefix("/usr/bin/env HISTFILE="),
                      "shell command 는 HISTFILE env prefix 로 시작한다: \(command)")
        XCTAssertTrue(command.hasSuffix(" /bin/zsh -l"),
                      "shell command 는 `<shell> -l` 로 끝난다: \(command)")
        XCTAssertTrue(command.contains("/history "),
                      "HISTFILE 은 history 파일을 가리킨다: \(command)")
    }

    // MARK: - activeTab fallback byte-identical

    /// activeTab 부재 시 위임 스텁이 만드는 합성 shell tab 의 출력이,
    /// 명시적 shell tab 출력과 byte-identical 인지 검증한다.
    /// (PaneTerminalView.buildCommand 의 `pane.activeTab ?? Tab(kind: .shell, ...)`
    ///  fallback 이 .shell 경로와 동일 command 를 산출함을 보장.)
    func test_build_syntheticShellFallback_isByteIdenticalToExplicitShellTab() {
        let workspace = makeWorkspace(env: ["SHELL": "/bin/zsh"])
        let pane = makePane()

        // 위임 스텁이 만드는 합성 fallback tab.
        let syntheticFallback = Tab(kind: .shell, name: Tab.defaultName(for: .shell))
        // 명시적 active shell tab.
        let explicitShell = Tab(kind: .shell, name: "셸")

        let fallbackCommand = TerminalCommandBuilder.build(workspace: workspace, pane: pane, tab: syntheticFallback)
        let explicitCommand = TerminalCommandBuilder.build(workspace: workspace, pane: pane, tab: explicitShell)

        XCTAssertEqual(fallbackCommand, explicitCommand,
                       "activeTab 부재 합성 shell fallback 은 명시적 shell tab 과 byte-identical command 를 산출해야 한다")
    }

    /// 동일 workspace/pane 에 대해 build 는 deterministic 하다(HISTFILE path 가 id 로 결정).
    func test_build_shellKind_isDeterministicForSameWorkspaceAndPane() {
        let workspace = makeWorkspace(env: ["SHELL": "/bin/zsh"])
        let pane = makePane()
        let tab = Tab(kind: .shell, name: "셸")

        let first = TerminalCommandBuilder.build(workspace: workspace, pane: pane, tab: tab)
        let second = TerminalCommandBuilder.build(workspace: workspace, pane: pane, tab: tab)

        XCTAssertEqual(first, second, "동일 입력은 동일 command 를 산출한다")
    }

    // MARK: - shellQuote

    /// 공백/특수문자 없는 path 는 quote 하지 않는다.
    func test_shellQuote_leavesPlainPathUnquoted() {
        XCTAssertEqual(TerminalCommandBuilder.shellQuote("/usr/bin/claude"), "/usr/bin/claude")
    }

    /// 공백 포함 path 는 단일 인용부호로 감싼다.
    func test_shellQuote_wrapsPathWithSpace() {
        XCTAssertEqual(TerminalCommandBuilder.shellQuote("/Users/me/My Apps/claude"),
                       "'/Users/me/My Apps/claude'")
    }

    /// 탭 문자 포함 path 도 quote 한다.
    func test_shellQuote_wrapsPathWithTab() {
        XCTAssertEqual(TerminalCommandBuilder.shellQuote("/a\tb/claude"), "'/a\tb/claude'")
    }

    /// 단일 인용부호 포함 path 는 `'\''` escape 시퀀스로 치환한다.
    func test_shellQuote_escapesEmbeddedSingleQuote() {
        XCTAssertEqual(TerminalCommandBuilder.shellQuote("/it's/claude"),
                       "'/it'\\''s/claude'")
    }

    /// 공백 포함 path 가 single-quote 로 감싸진다. build 는 claude 명령 합성 시
    /// 이 shellQuote 를 사용하므로 quoting 규칙 자체를 직접 검증한다.
    func test_shellQuote_quotesPathWithSpace() {
        let quoted = TerminalCommandBuilder.shellQuote("/My Tools/claude")
        XCTAssertEqual(quoted, "'/My Tools/claude'")
    }
}
