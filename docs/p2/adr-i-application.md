# ADR-I 적용 (P2 libghostty surface 자원 관리)

본 문서는 master plan § 5 ADR-I (libghostty surface 자원 관리 정책) 의 P2 적용 내역을 기술한다.

## 정책 요약 — cmux 패턴 채택

> 모든 surface 는 등록 시점부터 명시적 release 까지 alive. hibernate / pause / suspend / occlusion-aware skip 코드 0줄. 비가시 surface 의 GPU idle 은 AppKit `displayLayer` 호출 부재로 자연 발생한다.

이 정책은 vendor cmux 의 `Sources/GhosttyTerminalView.swift` 에서 검증된 패턴이며, P2 는 본 형태를 그대로 모방한다.

## 코드 적용 위치

### `SurfaceRegistry` (`Sources/UI/Pane/SurfaceLifecycle.swift`)

- workspace / pane 의 lifetime owner. paneId → NSView 1:1 dict.
- `acquire(paneId:factory:)` 가 등록된 view 가 있으면 반환, 없으면 factory 호출 + 등록.
- `release(paneId:)` 가 마지막 strong reference 를 끊으면 NSView deinit 이 `ghostty_surface_free` 를 호출하여 child PTY 까지 정리.
- workspace 전환으로 SwiftUI tree 가 재구성되어도 registry 가 owner 이므로 surface 가 destroy 되지 않는다.

### `PaneTerminalView` (`Sources/UI/Pane/PaneTerminalView.swift`)

- NSViewRepresentable. `makeNSView` 는 registry.acquire 에 위임.
- 동일 pane.id 로 여러 번 만들어져도 registry 가 보존된 인스턴스를 반환.

### `WorkspaceCoordinator.closePane` / `closeWorkspace` (`Sources/Workspace/WorkspaceCoordinator.swift`)

- pane close → `sessionManager.terminate` + `surfaceRegistry.release(paneId:)`.
- workspace close → `terminateAll(inWorkspace:)` + 모든 pane 에 대해 `surfaceRegistry.release`.

## Telemetry — `CHAT_TERMINAL_DEBUG_SURFACE_STATS`

### 활성화 방법

```bash
CHAT_TERMINAL_DEBUG_SURFACE_STATS=1 open ClaudeAlarmTerminal.app
```

### 동작

- env 미설정 시 `DebugRenderStats(registry:)` 가 nil 을 반환 → Timer / FileHandle 모두 미생성, zero overhead.
- env 가 "1" 일 때:
  - `~/Library/Logs/ClaudeAlarmTerminal/surface-stats.log` 에 append mode 로 open.
  - 1Hz `DispatchSourceTimer` 가 tick 마다 다음을 1 line 으로 기록:
    - ISO8601 timestamp
    - resident memory (MB) — `task_info(MACH_TASK_BASIC_INFO)` 의 `resident_size`
    - active surface count — `SurfaceRegistry.activeCount`

### 사용 예 (surface-stats.log 형식)

```
2026-05-14T13:00:00Z mem=312MB surf=4
2026-05-14T13:00:01Z mem=318MB surf=5
...
```

## 메모리 추정 — Apple Silicon 16GB+ Mac 기준

| Surface 수 | 예상 resident memory |
|---|---|
| 1 | 80~120 MB |
| 5 | 180~250 MB |
| 10 | 280~380 MB |
| 20 | 400~600 MB |

본 추정은 master § 5 의 ADR-I 근거표를 그대로 인용한다 (Apple Silicon, 80x24 cells, SF Mono 13pt, GhosttyKit 0.x 기준).

## Revisit Trigger

다음 조건 중 하나라도 발생하면 ADR-I 를 재검토하고 보완 정책(LRU hibernate 등) 도입을 고려한다.

| Trigger | 조치 |
|---|---|
| 20 surface 시 측정 resident > 700 MB | Day 7 telemetry 일자를 +1d 연장 — Allocations 로 root cause 정탐 |
| pane close 후 leak count > 0 (`xcrun leaks`) | strong reference cycle 정탐 + closePane 흐름 grep |
| 비가시 workspace 의 surface 가 destroy 됨 | `SurfaceRegistry.acquire` 가 동일 paneId 에 새 인스턴스를 생성하는 경로 추적 |
| `CHAT_TERMINAL_DEBUG_SURFACE_STATS` off 상태에서 CPU 측정 > 1% | DebugRenderStats 가 env 점검을 건너뛰는 경로 grep |

## 검증

### MED3 grep invariant

```
grep -rE '(hibernate|pause|releaseSurface|occlusionState|surface\.destroy|stopRendering|suspendRender|displayLayer.*nil)' Sources/UI/Pane/ Sources/Session/
```

결과 0건 (`PaneSplitTests.test_grep_adrI_forbiddenPatterns_zeroMatches` 가 자동 검증).

### 통합 테스트

- `SurfaceLifecycleTests.test_acquire_release_invariants` — registry 의 lifecycle bookkeeping.
- `SurfaceLifecycleTests.test_workspaceSwitch_doesNotDestroySurfaces` — pane select 변경이 release 를 트리거하지 않음.
- `SurfaceLifecycleTests.test_debugRenderStats_envGating` — env 미설정 시 init? = nil.
