# P3.5 Manual UX Walkthrough Catalog

본 문서는 P3.5 진행 동안 사용자(결정자)가 직접 수행하는 시각/입력 동작 검증 체크리스트의 정착본이다. 자동 테스트로는 surfacing되지 않은 D-1~D-4 결함이 P3 시연에서 드러난 lessons learned에 직접 대응한다.

본 카탈로그는 Day 0(R-1 회귀 검증)부터 시작하여 Day 1(격리 폐지 + 동시 claude tab), Day 3(schema migration + cascade), Day 5(agent-view 재설계 통합 시연), Day 8(종합 acceptance)까지 5회 walkthrough 의무 기록을 누적한다.

> **참고**: 본 v0.1은 Day 0 항목(5건)만 정착. Day 1 종료 시 격리 폐지/디렉터리 노출/동시 claude tab 3건이 추가되어 총 8건으로 정착될 예정이다.

---

## 사전 준비

1. `swift build` 완료 (exit code 0)
2. 앱 실행 (`swift run` 또는 `.build/debug/ClaudeAlarmTerminal` 실행)
3. 첫 부팅 시 workspace 영속 파일이 비어 있다면 default normal workspace(MED5)가 생성됨

### 환경 변수

| 키 | 의미 | 기본값 |
| --- | --- | --- |
| `CHAT_TERMINAL_WORKSPACE_ROOT` | default normal workspace의 cwd | `$HOME` |
| `CHAT_TERMINAL_AGENT_VIEW_ENABLED` | agent-view 노출 여부 | `true` |

---

## Day 0 — R-1 회귀 검증 항목 (5건)

R-1 surgical 패치(D-1~D-4)가 사용자 시연 환경에서도 의도대로 동작하는지 확인한다. 1건이라도 실패하면 P3.5 본 wave 진입을 중단하고 R-1 재패치로 회귀한다.

### W-0-1. Backspace 키 → PTY 0x7F (DEL) byte 전달

D-1 (`ghostty_surface_text` → `ghostty_surface_key` 교체)이 special key 라우팅을 정상화했는지 확인.

**절차**

1. 앱 launch 후 default normal workspace의 shell pane을 선택
2. 터미널에서 다음 명령 입력:
   ```
   cat > /tmp/keytest
   ```
3. `a`, `b`, `c` 입력 후 **Backspace 1회** 입력
4. `Ctrl+D` (EOF)로 `cat` 종료
5. shell에서 결과 확인:
   ```
   hexdump -C /tmp/keytest
   ```

**기대 결과**

- hexdump 출력에 `7f` byte가 **정확히 1건** 포함
- 예: `00000000  61 62 63 7f 0a` (a, b, c, BS, LF)

**통과 판정**

- [ ] PASS: 0x7F byte 1건 확인
- [ ] FAIL: 0x7F 미포함 또는 다른 byte로 surfacing (예: `1b 5b 33 7e` ESC 시퀀스)

---

### W-0-2. Enter / Tab / Arrow Up 키 → PTY control byte 전달

D-1 패치의 special key 라우팅 통합 검증.

**절차**

1. 동일 shell pane에서 다음 명령으로 4개 키 입력을 캡처:
   ```
   cat > /tmp/keytest2
   ```
2. **Enter 1회** 입력 → 줄 바꿈
3. **Tab 1회** 입력
4. **Arrow Up 1회** 입력
5. `Ctrl+D`로 종료
6. `hexdump -C /tmp/keytest2`

**기대 결과**

- Enter: `0x0D` (CR) 또는 `0x0A` (LF) — terminal mode에 따라 다르나 한 줄 끝마다 1 byte
- Tab: `0x09` (HT) 정확히 1건
- Arrow Up: `0x1B 0x5B 0x41` 3-byte 시퀀스 (ESC `[` `A`)

**통과 판정**

- [ ] PASS: Tab 0x09 1건 + Arrow Up `1b 5b 41` 시퀀스 확인
- [ ] FAIL: Tab이 다른 byte로 surfacing되거나 Arrow Up이 누락/오변환

---

### W-0-3. 한글 IME 자모 결합 무결성

D-2 (`insertText` keyDown 컨텍스트 분기)가 한글 자모를 완성형 그래핌으로 PTY에 전달하는지 확인. P3 시연에서 "ㅇㄴㄹㅇㄴ" 자모 분리 형태로 surfacing된 결함의 회귀 검증.

**절차**

1. shell pane에서 `cat` 실행 (Utf8BoundaryTruncator를 거치지 않는 raw 입력 경로)
2. macOS 한글 입력기 활성화 (Cmd+Space)
3. **"안녕하세요"** 5자 입력 (자모 결합 시퀀스: ㅇ+ㅏ+ㄴ → 안, ㄴ+ㅕ+ㅇ → 녕, ㅎ+ㅏ → 하, ㅅ+ㅔ → 세, ㅇ+ㅛ → 요)
4. Enter 입력 후 echo line 관찰
5. 영문 IME로 복귀 (Cmd+Space)
6. `Ctrl+D`로 종료

**기대 결과**

- echo line에 "안녕하세요" 5 grapheme + 입력 line에 "안녕하세요" 1회 = 총 6 grapheme 분량의 완성형 한글
- 자모 분리 형태("ㅇㄴㄹㅇㄴ" 등) 부재
- preedit 영역(IME 조합 중 표시)이 confirm 직후 정상 grapheme으로 commit

**통과 판정**

- [ ] PASS: "안녕하세요" 완성형 표시
- [ ] FAIL: 자모 분리 형태 surfacing 또는 일부 글자 누락

---

### W-0-4. HSplitView 사이드바 가시성 (minWidth 200pt)

D-3 (NavigationSplitView → HSplitView 교체)이 sidebar를 결정적으로 노출하는지 확인.

**절차**

1. 앱 launch 직후 메인 윈도우 좌측 영역 관찰
2. sidebar 영역이 workspace 목록을 표시하고 있는지 시각 확인
3. (정량 검증) Accessibility Inspector 또는 다음 SwiftUI inspector 절차:
   - 메뉴 → View → Debug → "Show View Bounds" (DEBUG 빌드에서만)
   - 또는 윈도우 폭을 좌우로 드래그하며 sidebar 영역이 200pt 미만으로 줄어들지 않는지 확인

**기대 결과**

- 부팅 직후 sidebar 영역이 최소 200pt 폭으로 가시
- workspace 목록과 agent-view tab이 노출됨
- 우측 content 영역도 최소 480pt 폭 확보

**통과 판정**

- [ ] PASS: sidebar 200pt 이상 가시 + workspace 목록 노출
- [ ] FAIL: sidebar 완전 숨김(NavigationSplitView 회귀) 또는 minWidth 미준수

---

### W-0-5. 첫 부팅 시 selected workspace == agent-view

D-4 (`bootstrap()` selection fallback agent-view 우선)이 사용자 시연 환경에서도 첫 launch 시 agent-view를 선택하는지 확인.

**절차**

1. 앱 종료 (Cmd+Q)
2. workspace 영속 파일에서 `lastActiveWorkspaceId`를 무효화하기 위해:
   ```
   rm -f "$HOME/Library/Application Support/ClaudeAlarmTerminal/workspaces.json"
   ```
   (또는 본 walkthrough를 위한 임시 backup)
3. 앱 재실행
4. sidebar에서 어떤 tab이 선택되어 있는지 확인

**기대 결과**

- agent-view tab(상단 고정 첫 tab)이 자동 선택됨
- normal workspace 또는 임의 tab이 자동 선택되지 않음
- right pane에 agent-view 화면(P3.5 본 wave에서 재설계 예정) 또는 placeholder가 노출됨

**통과 판정**

- [ ] PASS: agent-view 자동 선택
- [ ] FAIL: 다른 workspace 자동 선택

---

### W-0-6. Cmd+V paste + 우클릭 context menu + drag-select copy

D-5/D-6/D-7 (Edit 메뉴 + paste action + clipboard callback + MIME 매핑) 통합 회귀 검증.

**절차**

1. shell pane에서 다음 입력:
   ```
   echo claude-alarm-test
   ```
   Enter
2. 출력된 `claude-alarm-test`를 마우스로 드래그하여 선택
3. **우클릭 → 복사** (또는 Cmd+C)
4. 다른 앱(메모장/TextEdit/Spotlight 등)에 Cmd+V
5. 역방향 시험: 다른 앱에서 임의 문자열(한국어/영어 혼합) Cmd+C → shell pane으로 와서 Cmd+V

**기대 결과**

- 우클릭 메뉴 노출: 복사 / 붙여넣기 / 모두 선택 / 터미널 리셋
- drag-select → 복사 → 외부 paste 시 **순수 텍스트** (HTML 마크업 부재)
- 외부 → shell pane paste 시 클립보드 내용 그대로 입력됨

**통과 판정**

- [ ] PASS: 양방향 클립보드 동작 + HTML 마크업 미surfacing
- [ ] FAIL: 한쪽 또는 양쪽 미동작 / HTML `<div>` 등 markup 잔존

---

## Day 0 종합 통과 판정

위 6개 항목 전부 통과해야 P3.5 본 wave(Day 1~Day 8) 진입 가능. 1건이라도 실패 시 별도 R-1 재패치 commit 후 Day 0 재실행 (재실행 최대 2회, 총 3회 시도까지).

판정 결과는 `docs/p3.5/day-0-gate-report.md`에 기록한다.

---

## Day 1 신규 항목 (Day 1 종료 시 정착 예정, v0.2)

본 섹션은 Day 1 종료 시 정착될 항목의 placeholder. Day 1 작업(`CLAUDE_CONFIG_DIR` 격리 폐지 + 동시 claude tab walkthrough)이 끝나면 다음 3건이 추가된다:

- W-1-1. claude 재로그인 부재 (격리 폐지 후 사용자 `~/.claude/credentials` 공유 검증)
- W-1-2. `~/.claude/` 디렉터리 사용자 본래 노출 (격리 가짜 디렉터리 미생성)
- W-1-3. 동시 두 claude tab 5분 idle (file lock 충돌 부재 검증, R6 후보)

---

## 카탈로그 운영 원칙

1. **walkthrough 종료마다 결과 기록 의무** — Day 0/1/3/5/8 마다 timestamp + 통과/실패 + 결정자 sign-off
2. **실패 항목은 재패치 후 재실행** — 실패 항목만 재시연하되, 동일 phase의 다른 통과 항목은 재실행 면제
3. **R-1 회귀 항목은 모든 후속 Day에서도 sanity check** — Day 5 통합 시연에서 R-1 항목 1회 재확인
4. **walkthrough 카탈로그 진화는 master plan v5에 lessons learned로 박힘** — manual UX walkthrough 의무화 조항이 P-2 lessons에 정착될 예정
