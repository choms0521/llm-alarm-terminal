# P3.5 Day 0 Gate Report — R-1 회귀 검증

본 문서는 P3.5 진입 게이트(Day 0) walkthrough 결과를 기록한다. 6개 항목 전부 통과 시 P3.5 본 wave(Day 1~Day 8) 진입.

---

## 메타데이터

| 항목 | 값 |
| --- | --- |
| 게이트 회차 | 1차 시도 |
| walkthrough 일자 | 2026-05-15 |
| walkthrough 시작 시각 | 12:08 KST |
| walkthrough 종료 시각 | 12:45 KST |
| 검증 빌드 | commit 7865d97 + R-1 working tree (D-1 ~ D-5 + 클립보드 callback + 우클릭 context menu) |
| 결정자 sign-off | choms0521 |

---

## 항목별 결과

| # | 항목 | 검증 방식 | 기대 결과 | 결과 | 비고 |
| --- | --- | --- | --- | --- | --- |
| W-0-1 | Backspace → DEL 처리 | osascript 자동 + 로그 추적 | Backspace 후 문자 삭제 + `keyAction text-path codepoint=127 keycode=51` | **PASS** | osascript `a`+Backspace+`ok` → 파일 `ok\n` 확정 |
| W-0-2 | Enter/Tab/Arrow/Ctrl+D control byte | 로그 추적 | Enter `U+000D`, Tab `U+0009`, Arrow Up `U+F700` PUA→ESC seq, Ctrl+D `U+0004` mods=2 (CTRL) | **PASS** | 모든 special key가 keyAction을 거쳐 libghostty로 전달됨 확인 |
| W-0-3 | 한글 IME "안녕하세요" 완성형 | 장군님 시연 | 자모 분리 부재, 완성형 5 grapheme | **PASS** | 한글 IME 정상 동작 |
| W-0-4 | HSplitView sidebar 가시 | AX 구조 검증 | sidebar 노출 + workspace 목록 | **PASS** | `splitter group 1 → group 1 (sidebar) → outline (workspace list)` 노출, minWidth 200pt |
| W-0-5 | 첫 부팅 selected == agent-view | workspaces.json 검증 | `lastActiveWorkspaceId == agentView.id` | **PASS** | 자동 점검 통과 |
| W-0-6 | Cmd+V paste + 우클릭 copy/paste + drag-select | 장군님 시연 + 로그 추적 | 외부 → shell pane paste 동작, drag-select → 우클릭 복사 → 외부 paste 동작, MIME 분리(plain/html) | **PASS** | clipboard callback stub 토벌 + MIME→PasteboardType 매핑 후 PASS |

---

## 발견된 결함 + 처방 요약 (D-1 ~ D-7)

본 게이트 진행 중 노출된 R-1 surgical 결함과 처방을 모두 기록.

| 코드 | 결함 | 근원 | 처방 commit |
| --- | --- | --- | --- |
| D-1 | Backspace/Tab/Arrow/Enter가 PTY로 안 가거나 잘못된 byte 전달 | `GhosttyTerminalView.keyDown`이 `ghostty_surface_text`만 호출 | `ghostty_surface_key`로 교체 + `ghosttyCharacters` 헬퍼 + `keyUp` RELEASE 추가 |
| D-2 | 한글 IME 자모 분리 | `insertText`이 항상 `ghostty_surface_text` 직접 호출 → keyDown 외부 입력만 그대로, keyDown 내부에서는 accumulator 경유해야 함 | `keyTextAccumulator` 패턴으로 분기 |
| D-3 | sidebar 미가시 | `NavigationSplitView(.balanced)` 의도와 다르게 sidebar 숨김 | `HSplitView`로 교체 + minWidth 200pt 명시 |
| D-4 | 첫 부팅 시 agent-view 미선택 | bootstrap fallback이 normal workspace 우선 | bootstrap에서 agent-view 우선 선택 |
| D-5 | Cmd+V 미동작 | Edit 메뉴 + paste action 부재 | AppDelegate에 Edit 메뉴 신설 (복사/붙여넣기/모두 선택) + GhosttyTerminalView `@IBAction paste(_:)/copy(_:)/selectAll(_:)` |
| D-6 | clipboard callback이 stub | GhosttyApp의 `read_clipboard_cb` `return false`, `write_clipboard_cb` no-op | `NSPasteboard.general` 경유 정착 + `ghostty_surface_complete_clipboard_request` 호출 |
| D-7 | 복사 결과가 HTML 마크업으로 surfacing | `write_clipboard_cb`가 multi-MIME entry를 같은 `.string` 타입에 덮어쓰면서 마지막 entry(HTML) 잔존 | MIME `text/plain`→`.string`, `text/html`→`.html`, `text/rtf`→`.rtf` 분리 매핑 |
| 부가 | 우클릭 context menu 부재 | `menu(for:)` override 부재 | GhosttyTerminalView에 `menu(for:)` override 신설 (복사/붙여넣기/모두 선택/터미널 리셋) |

본 8건 모두 R-1 sub-wave로 토벌 완료.

---

## 종합 판정

- [x] **PASS** — 6개 항목 전부 통과. P3.5 본 wave(Day 1~Day 8) 진입 가능.
- [ ] FAIL — 1건 이상 실패.

### 실패 항목 (해당 없음)

없음.

---

## 결정자 sign-off

- 결정자 서명: choms0521
- sign-off 일자: 2026-05-15
- 판정: **PASS, P3.5 본 wave 진행 가능**

---

## 후속 작업

- [x] 게이트 통과 commit 1건 작성 (`feat(P3.5 Day 0): R-1 회귀 게이트 통과 + 클립보드 callback + 우클릭 context menu`)
- [ ] Day 1 진입 — REQ-3 `CLAUDE_CONFIG_DIR` 격리 폐지 작업 시작

---

## P3.5 본 wave 진입 시 인계 사항

1. **manual UX walkthrough 카탈로그 운영** — Day 1에서 격리 폐지 + 동시 claude tab walkthrough 항목 추가하여 카탈로그 정착. master plan v5 lessons learned에 박을 입력 자료.
2. **클립보드 OSC52 confirmation flow** — P4+ 보안 강화 시 `confirm_read_clipboard_cb` 정착 후보. 현재는 silently no-op.
3. **drag-select selection clipboard** — libghostty의 `supports_selection_clipboard`는 false 유지 중 (vendor는 true). X11-style middle-click paste가 필요하면 P4+에서 정착.
