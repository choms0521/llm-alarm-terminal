# ADR-A: chatRoomId 발급 주체 + sessionId lifetime

상태: 동결(P6a Day 4)

마스터 계획의 ADR 목록에서 ADR-A는 P7 freeze 전 동결이 필수로 지정된다. 본 문서는 P6a 상세 계획서(`docs/plans/p6a/p6a-detailed.html` §6) 본문을 이전한 것이며, 모바일 트랙(P9/P10a)이 이 결정에 의존한다.

## Decision (결정)

1. **chatRoomId 발급 주체 = 데스크톱.** 데스크톱이 pane을 생성하는 시점에 `chatRoomId`를 발급하고, 이를 single source of truth로 둔다. 모바일은 발급하지 않고 데스크톱이 push/WS로 전달한 `chatRoomId`를 수신해 라우팅에만 쓴다.

2. **데몬 재시작 시 모든 sessionId invalidate.** 데몬이 재시작하면 in-memory `SessionBindRegistry`는 비어 있어 옛 sessionId는 해석 불가다. 재시작 직후 데몬은 직전 살아 있던 세션들에 대해 `session.terminated`(orphaned 사유)를 발신하고, chatRoomId와 sessionId 바인딩을 폐기한다. chatRoomId 자체는 pane이 영속이면 보존된다(재바인딩은 새 세션 생성 시). pane 영속(workspace JSON persistence)은 P2 스키마가 보장하며, chatRoomId의 모바일 배선 책임은 P9에 있다.

## Drivers (결정 동인)

- 마스터 § P9 "채팅룸=데스크톱 pane 1:1 바인딩" — pane은 데스크톱 소유 자원이므로 그 식별자 발급도 데스크톱이 자연 소유한다.
- push `chatRoomId` 라우팅 정합 — 모바일이 발급하면 데스크톱이 모르는 ID가 push payload에 들어가 라우팅 불능. `PushEnvelope.chatRoomId`(현재 sessionId placeholder)의 실 source가 데스크톱이어야 일관.
- 마스터 § P10 dedupe key 후보(messageId vs sessionId+seq)와 정합 — chatRoomId가 데스크톱 발급이면 messageId도 데스크톱 단조 발급이 가능해 dedupe 설계가 단순.

## Alternatives considered (검토한 대안)

| 대안 | 내용 | 기각 사유 |
|---|---|---|
| 모바일 발급 | 모바일이 채팅룸 진입 시 chatRoomId 생성 후 데스크톱에 통보 | 데스크톱이 pane 소유자인데 ID를 모름 → push 라우팅 시 역매핑 테이블 필요, 두 발급원 충돌 가능. single source of truth 붕괴 |
| 합의 발급(양측 hash) | pane id + device id를 해시해 양측이 같은 chatRoomId 도출 | pane id 변경/재생성 시 충돌, 해시 충돌 표면, 디버깅 난해. 단순 데스크톱 발급 대비 이득 없음 |
| 재시작 시 sessionId 보존 | 데몬이 sessionId를 디스크 영속해 재시작 후 재바인딩 | PTY는 데몬 프로세스 자식이라 재시작 시 이미 죽음 — 보존된 sessionId가 가리킬 실 세션이 없어 거짓 생존. orphaned 신호가 정직 |

## Why chosen (선택 이유)

데스크톱 발급 + 재시작 전부 invalidate가 "pane 소유권 = 데스크톱"이라는 마스터 정보 구조와 일치하고, push 라우팅·dedupe·lifecycle 매트릭스(orphaned)를 모두 모순 없이 만족하는 유일한 조합이다. 데이터 손실 우려는 메시지가 모바일 SQLite에 영속(마스터 § P9)되므로 sessionId invalidation이 메시지를 지우지 않는다 — 세션 핸들만 끊고 채팅 이력은 보존된다.

## Consequences (결과)

- (+) push `chatRoomId`가 데스크톱 단조 발급이라 P10a dedupe 설계가 단순해진다.
- (+) 데몬 재시작이 "조용한 좀비 세션" 없이 orphaned로 정직하게 노출된다.
- (-) 모바일은 chatRoomId를 발급/예측 못 해 항상 데스크톱 통지에 의존 — 오프라인 선발급 UX 불가(MVP 범위 밖이라 수용).
- (-) `Pane.chatRoomId`를 데스크톱이 채우는 코드는 P9에서 배선(P6a는 placeholder 유지) — ADR만 동결, 구현 이연.

## Follow-ups (후속)

- P9: `Pane.chatRoomId` 실 발급 배선 + 모바일 수신 라우팅 (마스터 § P9).
- P9: **pane 영속 보장 책임** — 본 ADR은 "chatRoomId는 pane이 영속이면 보존"을 전제한다. pane 영속(`WorkspaceManager` 저장 스키마)이 chatRoomId 수명을 보장하는지 검증·배선은 P9이 책임진다(P6a는 ADR 전제만 동결, pane 저장 코드 미변경).
- P10a: ADR-C(dedupe key) 확정 시 본 결정 참조 — messageId 데스크톱 발급 전제.
- P7: envelope v1.0에 `session.terminated` orphaned 사유 코드 + `pairing.claim`/`pairing.response` 2종 kind 동결(§5.5 — P7 freeze 대상 편입).
