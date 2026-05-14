# PTY env/cwd 격리 정책 (P2)

본 문서는 P2 단계 PTY 격리 invariant 5건의 코드 명세 + 검증 방법 + 위반 시 회복 절차를 기술한다. master § P2 수락 기준 A6 + M3 신규 invariant 5와 1:1 매핑된다.

## 5개 sub-invariant

### Invariant 1 — env snapshot (capture-at-creation, H6)

**명세:** `Workspace` 생성 시점에 `SessionSpawnEnv.captureUserEnv()` 로 `ProcessInfo.environment` 를 capture 하여 `Workspace.envSnapshot: [String: String]` 에 저장한다. 같은 workspace 의 모든 pane spawn 은 이 snapshot 을 base 로 사용한다.

**의미:** workspace 생성 후 사용자가 외부 셸에서 `export FOO=BAR` 를 추가하거나 `~/.zshrc` 를 편집해도, 그 workspace 의 후속 pane spawn 에는 영향이 없다.

**검증:** `MultiWorkspaceIsolationTests.test_invariant1_envSnapshot_immutableAfterCreation`
- workspace 생성 → `setenv("CHAT_TERMINAL_DAY6_INV1", ...)` → `workspace.envSnapshot` 에 신규 키 부재 확인.

**위반 시 회복:**
- `SessionSpawnEnv.captureUserEnv()` 가 reference 가 아닌 dict copy 를 반환하는지 점검 (`ProcessInfo.processInfo.environment` 는 Swift dictionary 이므로 value-type 복사가 자동 발생).
- `Workspace.envSnapshot` 이 `let` 인지 확인 (mutation 차단).

### Invariant 2 — cd 비전파 (POSIX child env)

**명세:** PTY 안에서 실행되는 child 의 `cd` / `export` 는 parent process(=앱) 에 영향을 주지 않는다. 같은 workspace 의 새 pane spawn 시 cwd 는 항상 `workspace.cwd` 가 적용된다 (직전 pane 의 cwd 를 상속받지 않음).

**의미:** POSIX `fork(2)` + `execve(2)` 가 child 만의 env / cwd 컨텍스트를 만들며, parent 의 cwd 와 env 는 변하지 않는다.

**검증:** `MultiWorkspaceIsolationTests.test_invariant2_cdNonPropagation_newPaneUsesWorkspaceCwd`
- workspace cwd = `/tmp/projA` 에서 pane1 spawn → `cd /tmp` → pane2 spawn → `pwd` 결과가 `/tmp/projA` 와 일치(`/tmp` 아님).

**위반 시 회복:**
- `SessionManager.create(workspace:paneId:kind:...)` 의 `cwd = workspace.cwd` 명시 확인.
- 직전 pane 의 cwd 를 추적하는 변수가 추가되지 않았는지 grep (`current.*cwd|lastPane.*cwd`).

### Invariant 3 — workspace 간 env 누설 차단

**명세:** workspace A 의 pane 에서 발생한 env / cwd 변경이 workspace B 의 새 pane spawn 에 누설되지 않는다.

**의미:** workspace 별 envSnapshot 은 독립 dict copy 이며, child process 의 env 변경은 sibling workspace 의 pane spawn 에 도달할 수 없다.

**검증:** `MultiWorkspaceIsolationTests.test_invariant3_envIsolation_betweenWorkspaces`
- wsA pane 에서 `export FOO_DAY6_INV3=wsA-only` 실행 → wsB pane 에서 `echo $FOO_DAY6_INV3` → 빈 출력.

**위반 시 회복:**
- 글로벌 mutable env 사전이 도입되지 않았는지 점검.
- `SessionSpawnEnv.buildSpawnEnv(...)` 가 `workspace.envSnapshot` 을 copy 로 사용하는지 확인 (Swift `var env = workspace.envSnapshot` 는 value copy).

### Invariant 4 — claude config dir 격리 (세션 단위)

**명세:** claude pane 마다 독립 `CLAUDE_CONFIG_DIR` path 가 부여된다. path 형식: `~/Library/Application Support/ClaudeAlarmTerminal/claude-config/<sessionId>/`.

**의미:** 여러 claude pane 이 같은 config / cache 를 공유하지 않으므로 reconnect 식별자와 history 가 충돌하지 않는다. 종료된 세션의 디렉터리는 P2 에서 보존(P4 reconnect 활용 예약), 7일 이상 stale 시 부팅 시 `cleanupStaleClaudeConfigDirs` 가 정리.

**검증:** `MultiWorkspaceIsolationTests.test_invariant4_claudeConfigDir_perSession_distinct`
- 두 sessionId 로 `SessionSpawnEnv.claudeConfigDir(forSession:)` 호출 → path 가 서로 다르며 각각 본 session UUID 포함.

**위반 시 회복:**
- `claudeConfigDir(forSession:)` 가 session-scoped UUID 를 path 에 포함하는지 확인.
- buildSpawnEnv 가 claude kind 일 때 CLAUDE_CONFIG_DIR override 를 잊지 않는지 확인.

### Invariant 5 — HISTFILE 격리 (pane 단위, M3 신규)

**명세:** 셸 pane 마다 독립 `HISTFILE` path 가 부여된다. path 형식: `~/Library/Caches/ClaudeAlarmTerminal/zsh_history/<workspaceId>/<paneId>/history`.

**의미:** 같은 workspace 의 두 셸 pane 이 명령 history 를 섞지 않는다. workspace 간에도 자연 분리된다.

**검증:** `MultiWorkspaceIsolationTests.test_invariant5_histFile_perPane_distinct_andUnderCachesDir`
- 두 paneId 로 `SessionSpawnEnv.zshHistoryDir(workspaceId:paneId:)` 호출 → path 가 서로 다르며 각각 본 pane UUID 포함.

**위반 시 회복:**
- `zshHistoryDir(workspaceId:paneId:)` 가 paneId 를 path 에 포함하는지 확인.
- buildSpawnEnv 가 shell kind 일 때 HISTFILE override 를 잊지 않는지 확인.

## H7 PtyTestHarness 운영

`Tests/SessionTests/PtyTestHarness.swift` — 통합 테스트의 공통 helper.

- `readUntilQuiet(fd:timeout:quietWindow:)`: non-blocking master fd 에서 byte 누적, quietWindow 동안 idle 이면 종료.
- `stripANSI(_:)`: zsh prompt 의 색상 / 커서 escape 시퀀스 제거.
- `writeCmd(_:_:)`: `command + "\n"` 을 fd 에 write.
- `minimalShellEnv(zdotdirParent:)`: 빈 ZDOTDIR 디렉터리를 만들어 사용자 `.zshrc` 의 invariant 오염을 차단.

## 위반 발견 시 escalation 절차

1. 첫 발견 시 본 정책 문서를 업데이트하여 새 violation path 를 docs 화.
2. 위반 sub-invariant 의 fix PR 에 `MultiWorkspaceIsolationTests` 의 새 케이스를 추가 (regression block).
3. 다음 phase(P5+) 의 reserved field 활용 코드에서 envSnapshot 을 직접 mutate 하는 경로가 발견되면 ADR amendment 가 필요하다.
