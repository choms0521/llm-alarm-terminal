# Workspace JSON Schema v1

P2 단계의 영속화 스키마 정의서. P2 상세 계획서 § 7 (`docs/plans/p2/p2-detailed.html`)의 코드 명세를 기준으로 동결된 결과를 기록한다.

## 저장 위치

```
~/Library/Application Support/ClaudeAlarmTerminal/workspaces.json
```

- 경로 산출: `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, ..., create: true).appendingPathComponent("ClaudeAlarmTerminal/workspaces.json")`
- App Sandbox OFF (master § P1 결정) 상태에서도 사용자별 정상 경로에 위치
- 동반 파일:
  - `workspaces.json.tmp` — atomic write 중 사용되는 임시 파일
  - `workspaces.json.bak` — 직전 정상 저장본 (3-파일 정책 M4)
  - `claude-config/<sessionId>/` — 세션별 격리 디렉터리 (Day 2 정책)

## Root 객체

```json
{
  "version": 1,
  "lastActiveWorkspaceId": "<uuid|null>",
  "workspaces": [ /* Workspace[] */ ]
}
```

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `version` | `Int` | 예 | 스키마 버전. P2 v1 에서 1. 필드 추가 시 유지, 제거/타입 변경/이름 변경 시 증가 |
| `lastActiveWorkspaceId` | `UUID?` | 아니오 | 다음 부팅 시 자동 선택할 워크스페이스 ID |
| `workspaces` | `Workspace[]` | 예 | 워크스페이스 배열. 첫 요소는 항상 `kind == "agentView"` (MED2 invariant guard) |

## Workspace 객체

```json
{
  "id": "<uuid>",
  "name": "내 작업",
  "cwd": "/Users/mscho/projA",
  "createdAt": "2026-05-13T09:00:00Z",
  "kind": "normal",
  "envSnapshot": { "PATH": "...", "SHELL": "...", "HOME": "...", "LANG": "..." },
  "panes": [ /* Pane[] (최대 2) */ ],
  "pushChannelHints": null,
  "fetchHintMetadata": null,
  "extraFields": null
}
```

| 필드 | 타입 | 필수 | P2 값 | 비고 |
|---|---|---|---|---|
| `id` | `UUID` | 예 | 자동 생성 | |
| `name` | `String` | 예 | 한국어 허용 | UTF-8 직렬화 (escape 없음) |
| `cwd` | `String` | 예 | `kind == agentView` 시 빈 문자열 | 새 pane spawn 의 기본 cwd |
| `createdAt` | `Date` | 예 | ISO8601 | |
| `kind` | `"agentView" \| "normal"` | 예 | | `agentView` 는 close 불가 |
| `envSnapshot` | `[String: String]` | 예 | workspace 생성 시점 capture | H6: 후속 pane spawn 의 base env |
| `panes` | `Pane[]` | 예 (배열) | 최대 2개 (top + bottom) | 비어 있을 수 있음 |
| `pushChannelHints` | `[String: String]?` | 아니오 | `null` | **P5 reserved** |
| `fetchHintMetadata` | `[String: AnyCodable]?` | 아니오 | `null` | **P10b reserved** |
| `extraFields` | `[String: AnyCodable]?` | 아니오 | `null` | **M6 forward-compat catch-all** |

## Pane 객체

```json
{
  "id": "<uuid>",
  "sessionId": null,
  "kind": "claude",
  "position": "top",
  "chatRoomId": null,
  "extraFields": null
}
```

| 필드 | 타입 | 필수 | P2 값 | 비고 |
|---|---|---|---|---|
| `id` | `UUID` | 예 | 자동 생성 | |
| `sessionId` | `UUID?` | 아니오 | 영속화는 하되 부팅 시 nil | UI 는 "세션 없음" 빈 상태로 표시 (자동 respawn 안 함) |
| `kind` | `"claude" \| "shell"` | 예 | | |
| `position` | `"top" \| "bottom"` | 예 | | 2-pane horizontal split |
| `chatRoomId` | `String?` | 아니오 | `null` | **P6a/P9 reserved** (master § P9 line 351 1:1 바인딩, H1 결정으로 pane level) |
| `extraFields` | `[String: AnyCodable]?` | 아니오 | `null` | **M6 forward-compat** |

## Reserved Fields 활용 단계 (add-only 마이그레이션)

| 필드 | Location | 활용 단계 | 예상 형식 |
|---|---|---|---|
| `pushChannelHints` | Workspace | P5 (Push Sender) | `{ "fcmDeviceId": "...", "apnsDeviceToken": "..." }` |
| `chatRoomId` | **Pane** (H1 결정) | P6a (Pairing), P9 (chat-room↔pane) | String UUID — ADR-A 에서 발급 주체 결정 |
| `fetchHintMetadata` | Workspace | P10b (Deep link + fetchHint) | `{ "lastSeqOnDevice": "...", "fetchEndpoint": "..." }` |
| `extraFields` | Workspace + Pane | P3~P12 | Unknown JSON 필드 보존용 catch-all |

P5 / P6a / P10b 가 reserved field 를 채워도 `version` 은 1 그대로 유지된다. 필드 제거나 타입 변경이 발생할 때만 `version` 을 증가시키고 migration 함수 체인을 추가한다.

## Atomic Write (3-파일 정책 M4)

| 파일 | 의미 |
|---|---|
| `workspaces.json` | 정상 상태본 |
| `workspaces.json.tmp` | 저장 진행 중 (rename 직전) |
| `workspaces.json.bak` | 직전 정상 저장본 |

### save() 순서

1. `JSONEncoder` 로 직렬화 (한국어 escape 없음, sortedKeys + prettyPrinted)
2. `.tmp` 에 `Data.write(to:options: .atomic)` (POSIX write + fsync)
3. 기존 `.bak` 가 있으면 제거, 그 후 현재 `.json → .bak` rename
4. `.tmp → .json` rename (POSIX `rename(2)` atomic)

어느 단계에서든 실패 시 `WorkspaceStoreError.writeFailed(path:underlyingDescription:)` 로 wrap 하여 throw — silently swallow 금지 (H2).

### load() 복구 로직

| 상태 | 동작 |
|---|---|
| `.tmp` 잔존 | warn 로그 + `.tmp` 제거 |
| `.json` 부재 + `.bak` 존재 | warn 로그 + `.bak → .json` 복사 후 디코딩 |
| `.json` / `.bak` 모두 부재 | 빈 `WorkspaceFile(agent-view 1개만)` 반환 (첫 부팅) |
| `.json` 존재 | 정상 디코딩 |

디코딩 후 agent-view invariant guard 적용 (MED2):
- agent-view 0개: `with(prepending: Workspace.makeAgentView())`
- agent-view 2개+: warn 로그 + `dedupAgentViews()` 로 첫 번째만 유지

## Forward-compat (M6)

- Workspace / Pane 양쪽 모두 `extraFields: [String: AnyCodable]?` 보유
- 디코딩 시 알려지지 않은 top-level 키 + 명시적 `extraFields` 객체 양쪽을 단일 dict 로 흡수
- 인코딩 시 `extraFields` 객체로 직렬화 (다음 round-trip 에서도 보존)
- 외부 도구가 추가한 키를 silently drop 하지 않는다

## 의존 외부 패키지

| 패키지 | 버전 | 용도 |
|---|---|---|
| [`Flight-School/AnyCodable`](https://github.com/Flight-School/AnyCodable) | `0.6.7+` | `extraFields` 와 `fetchHintMetadata` 의 type-erased Codable 값 |

P2 v2 decision A1 에 따라 외부 패키지를 채택. 인하우스 6줄 구현 대안은 거부됨 (forward-compat 정확성과 유지 비용 대비 6줄 절감의 가치가 낮음).

## 한국어 정책

- `name`, `envSnapshot` 의 값 등 모든 사용자 visible 문자열은 한국어 허용
- `JSONEncoder` 기본 동작은 `\uXXXX` escape 없이 UTF-8 그대로 직렬화 (Swift Foundation default)
- 한자(중국어 문자) 일절 금지 — `/Users/mscho/.claude/rules/plan-documents.md` 정책

## 참고

- 본 스키마의 코드 명세: `docs/plans/p2/p2-detailed.html` § 5.1, § 5.3, § 7
- 합의 이력: `docs/plans/p2/p2-history.md`
- 마스터 계획: `docs/plans/work-plan-v4.md` § P2
