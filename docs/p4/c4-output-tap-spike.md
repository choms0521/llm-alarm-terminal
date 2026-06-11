# C4 출력 탭(output tap) 타당성 스파이크 — `.internal` 세션 byte-faithful 출력 스트리밍

> 본 문서는 연구 및 옵션 열거 전용 스파이크다. 어떤 구현도 수행하지 않으며, 어떤 옵션도 강제 선택하지 않는다.
> 목적은 `.internal` origin 세션의 출력 탭 문제를 풀 수 있는 선택지를 식별하고, P7 envelope freeze 직전의 결정 게이트에 입력으로 제공하는 것이다.

근거로 인용하는 파일과 라인은 모두 실제 관찰값이다. ghostty C 헤더는 macOS 슬라이스를 기준으로 인용한다:
`Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h`

---

## 배경

### C4 문제 요약

P4 데몬은 세션 터미널의 **byte-faithful 출력 스트리밍**을 필요로 한다. 즉 자식 프로세스가 PTY master로 내보내는 원시 바이트(ANSI 이스케이프 시퀀스, 제어 바이트, 부분 UTF-8 조각 포함)를 가감 없이 그대로 받아야 한다.

이 요구는 PTY를 누가 소유하느냐에 따라 갈린다.

- **`.external` origin**: PTY를 우리 코드(`PTYSpawner`)가 직접 spawn하여 master fd를 보유한다. 따라서 master fd를 직접 읽어 원시 바이트를 탭할 수 있다.
- **`.internal` origin**: libghostty가 surface 생성 시 PTY를 내부에서 소유한다. 외부로 노출되는 master fd가 없으며, 원시 출력 바이트를 노출하는 공개 C ABI 콜백도 없다.

결과적으로 P4 데몬의 byte-faithful 출력 스트리밍은 `.external`에서는 동작하지만 `.internal`에서는 동작하지 않는다. GUI 경로(`.internal`)가 실사용 주 경로이므로, 이 공백을 메우는 방법을 P7 envelope freeze 이전에 결정해야 한다.

### 근거 (file:line)

- **origin 구분과 PTY 소유권**: `Sources/Session/Session.swift:20-27`
  - `.external` 주석: "PTY spawned by `PTYSpawner` (Day 4 path). `ptyHandle` is non-nil."
  - `.internal` 주석: "PTY owned internally by libghostty (Day 5b GUI path). `ptyHandle` is nil because there is no externally-visible master fd to drive."
- **`.external` 세션은 ptyHandle 보유**: `Sources/Session/SessionManager.swift:125-134` — `create(...)`가 `PTYSpawner.spawn(...)`로 받은 `handle`을 `origin: .external`, `ptyHandle: handle`로 등록한다.
- **`.internal` 세션은 ptyHandle = nil**: `Sources/Session/SessionManager.swift:201-211` 및 `:216-237` — `createInternal(...)`가 `origin: .internal`, `ptyHandle: nil`로 등록한다.
- **`.external` master fd 탭 메커니즘**: `Sources/PTY/PTYReader.swift:25-50` — master fd를 `DispatchIO` stream 모드로 읽어 `onData`/`onEOF`를 발행한다. lowWater=1(`:34`), highWater=64KiB(`:35`). 원시 `Data` 청크를 그대로 전달한다(`:40-42`).
- **runtime config 콜백 셋업에 출력 바이트 콜백 부재 (load-bearing 사실)**: `Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h:1018-1027`
  - `ghostty_runtime_config_s` 구조체의 콜백 멤버는 정확히 다음뿐이다: `wakeup_cb`(`:1021`), `action_cb`(`:1022`), `read_clipboard_cb`(`:1023`), `confirm_read_clipboard_cb`(`:1024`), `write_clipboard_cb`(`:1025`), `close_surface_cb`(`:1026`).
  - **원시 출력(raw output) 바이트를 전달하는 콜백은 존재하지 않는다.** 즉 libghostty가 소유한 PTY가 토해내는 출력 바이트를 공개 ABI로 가로챌 진입점이 없다.

> 참고: 과제 계획서가 가리킨 라인 범위(ghostty.h:1018-1027)는 실제 헤더와 일치한다. `ghostty_runtime_config_s` 정의는 `:1018`에서 시작하여 `:1027`에서 닫힌다.

### 현재 우회 수단과 그 한계

GUI 경로는 출력을 직접 탭하지 못하는 대신, `ghostty_surface_read_text`로 화면 그리드 텍스트를 폴링한다.

- `Sources/UI/AgentView/GhosttyViewportProvider.swift:26-48` — viewport 영역에 대해 `ghostty_surface_read_text`(헤더 `:1159-1161`)를 호출하고 `defer`로 `ghostty_surface_free_text`(헤더 `:1162`)를 1:1로 짝지어 호출한 뒤, 결과를 `String(cString:)`로 변환해 반환한다(`:46-47`).

이 우회 수단은 P4 데몬 요구를 충족하지 못한다. 이유는 세 옵션의 단점 분석에서 상술하며, 핵심만 요약하면 다음과 같다.

- 그리드 스냅샷이므로 **ANSI/제어 바이트가 이미 소실**된 렌더 후 결과다.
- **폴링이지 스트리밍이 아니다** — 두 폴링 사이의 화면 갱신은 누락되거나 합쳐진다.
- 따라서 **바이트 정합(byte-faithful)을 보장할 수 없다**.

---

## 옵션 열거

각 옵션을 메커니즘, 근거 API/파일, 장점, 단점/한계, 예상 난이도 순으로 정리한다.

### 옵션 1 — libghostty upstream에 raw output 콜백 patch 제안

#### 메커니즘 설명

libghostty upstream을 수정하여 `ghostty_runtime_config_s` 구조체(또는 surface config)에 원시 출력 바이트 콜백(`output_cb` 류)을 추가한다. libghostty가 소유한 PTY에서 자식 프로세스의 출력 바이트를 읽어 터미널 파서로 넘기는 그 지점에서, 동일 바이트 버퍼를 호스트가 등록한 콜백으로도 fan-out하도록 한다. 호스트(우리 앱)는 이 콜백을 `.internal` 세션의 byte-faithful 스트림 소스로 사용한다.

#### 근거 API/파일

- `Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h:1018-1027` — 현 `ghostty_runtime_config_s`에 콜백을 추가할 자리. 현재 콜백은 wakeup/action/clipboard/close_surface 6종뿐이며, 출력 콜백을 추가하는 것이 이 옵션의 변경점이다.
- 기존 콜백 typedef 패턴은 `ghostty.h:1000-1016`에 있다(`ghostty_runtime_wakeup_cb`, `ghostty_runtime_action_cb` 등). 신규 `ghostty_runtime_output_cb` typedef도 동일 패턴(첫 인자 `void* userdata` + 데이터 포인터 + 길이)으로 추가하면 ABI 컨벤션에 들어맞는다.
- `Frameworks/GhosttyKit.xcframework/.../ghostty.h:1085-1086` — `ghostty_app_new(const ghostty_runtime_config_s*, ...)`가 런타임 config를 받는 진입점이므로, 콜백을 추가해도 app 생성 시 한 번 등록하는 기존 흐름과 정합한다.

#### 장점

- 단일 진정한 출처(single source of truth): libghostty가 파서로 넘기는 그 바이트를 그대로 받으므로 화면 렌더 결과와 100% 동일한 원시 스트림을 얻는다. ANSI/제어 바이트가 보존된다.
- 폴링이 아니라 push 스트림이라 latency가 낮고 누락이 없다.
- `.external`/`.internal` 두 경로를 동일한 byte-faithful 모델로 통일할 수 있어, P4 데몬 코드가 origin 분기 없이 단순해진다.
- 한 번 upstream에 머지되면 향후 xcframework 갱신마다 자동으로 따라온다(유지보수 부채 최소).

#### 단점/한계

- **외부 의존성에 대한 통제 불가**: upstream 머지는 우리 일정이 아니라 ghostty 메인테이너의 수용 여부와 리뷰 속도에 달려 있다. P7 envelope freeze 일정에 묶기엔 리스크가 크다.
- 머지 전까지는 fork를 들고 GhosttyKit.xcframework를 자체 빌드해야 한다. 이는 빌드 파이프라인과 코드서명/notarization 부담을 추가한다.
- libghostty 내부 구현(Zig)에 대한 이해가 필요하며, 출력 fan-out이 파서 성능/스레드 모델에 영향을 주지 않도록 설계해야 한다.
- ABI 추가(구조체 멤버 확장)는 호환성 정책상 신중한 검토가 필요하다.

#### 예상 난이도

높음. upstream 정책/일정 의존성과 Zig 코어 수정·자체 빌드 부담이 겹친다. 단, 성공 시 가장 깨끗한 해법이다.

### 옵션 2 — PTY interpose (`.external`처럼 spawn 경로 분기, master fd 자체 확보)

#### 메커니즘 설명

GUI 경로에서도 PTY를 libghostty에 맡기지 않고 우리가 직접 소유한다. `.external` 경로처럼 `PTYSpawner`로 자식 프로세스를 spawn하여 master fd를 우리가 보유하고, libghostty surface에는 그 PTY의 slave를 물리거나 화면 표시만 위임하는 구조다. 출력 바이트는 우리가 소유한 master fd에서 직접 탭한다.

#### 근거 API/파일

- `Sources/PTY/PTYReader.swift:25-50` — 우리가 master fd를 보유하기만 하면 이미 검증된 탭 경로를 그대로 재사용할 수 있다. `.external`이 이 방식으로 동작한다.
- `Sources/Session/SessionManager.swift:111-134` — `create(...)`의 `PTYSpawner.spawn(...)` → `origin: .external`, `ptyHandle: handle` 등록 흐름이 재사용 대상 템플릿이다.
- `Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h:467-480` — `ghostty_surface_config_s` 구조체 정의. 필드는 `working_directory`(`:473`), `command`(`:474`), `env_vars`(`:475`), `env_var_count`(`:476`), `initial_input`(`:477`), `wait_after_command`(`:478`), `context`(`:479`)다. **외부에서 소유한 master/slave fd를 surface에 주입할 필드(예: 기존 fd, tty 경로)가 존재하지 않는다.** libghostty는 `command`(`:474`)를 받아 자체적으로 PTY를 fork한다.
- `Frameworks/GhosttyKit.xcframework/.../ghostty.h:1127` — `ghostty_surface_text(...)`는 **입력(input) 바이트를 surface로 보내는** API다(키 입력/IME 텍스트 주입). surface로 **출력 바이트를 밀어 넣어 렌더링시키는** 대응 API는 헤더에 존재하지 않는다. 즉 "우리가 PTY를 소유하고 libghostty에는 화면만 그리게 한다"는 구상의 후반부(출력 → surface 렌더 주입)에 해당하는 공개 API가 없다.

#### 장점

- 이미 존재하고 검증된 `.external` 탭 경로(`PTYReader`)를 그대로 재사용한다. 출력 측 신규 코드가 최소화된다.
- upstream 의존이 없어 일정을 우리가 통제할 수 있다.
- byte-faithful 보장이 자연히 따라온다(master fd 원시 바이트를 직접 읽으므로).

#### 단점/한계

- **surface에 외부 PTY를 주입할 공개 API가 없다**: `ghostty_surface_config_s`(`:467-480`)에는 fd/tty 주입 필드가 없고 `command`(`:474`)만 받는다. libghostty가 PTY를 fork하는 주체이므로, 우리가 master를 소유하면서 동시에 libghostty가 같은 터미널을 렌더링하게 만들 정식 경로가 없다.
- **출력 → surface 렌더 주입 API 부재**: `ghostty_surface_text`(`:1127`)는 입력 전용이다. 우리가 master fd에서 읽은 출력 바이트를 libghostty surface에 그려 넣어 화면을 일치시킬 공개 API가 없다. 따라서 화면 표시와 데몬 스트림이 갈라질 위험이 있다.
- 회피책으로 우리가 자체 터미널 렌더러를 두거나 surface를 우회하면 libghostty를 GUI에서 쓰는 의미가 퇴색한다.
- ABI 가정에 의존한 비공개 동작(예: slave fd 환경변수/상속 트릭)을 쓰면 향후 libghostty 갱신에 깨지기 쉽다.

#### 예상 난이도

중간~높음. 탭 측 코드는 쉽지만, "PTY 자체 소유 + libghostty 화면 일치"를 공개 API만으로 성립시키는 경로가 현재 헤더에 없어 구조적 위험이 크다.

### 옵션 3 — `ghostty_surface_read_text` grid-diff 스트리밍

#### 메커니즘 설명

현재의 viewport 폴링(`GhosttyViewportProvider`)을 확장하여, 매 폴링 스냅샷을 직전 스냅샷과 diff하고 변경분만 스트림으로 emit한다. 즉 현 화면 그리드 텍스트를 주기적으로 읽어 줄/셀 단위 차이를 계산해 "갱신 이벤트"로 데몬에 흘려보낸다.

#### 근거 API/파일

- `Sources/UI/AgentView/GhosttyViewportProvider.swift:26-48` — 현재 폴링 구현. `ghostty_surface_read_text`(헤더 `:1159-1161`)로 viewport 텍스트를 읽고 `ghostty_surface_free_text`(헤더 `:1162`)와 1:1로 짝지어 해제한 뒤 `String`을 반환한다.
- `Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h:1159-1161` — `ghostty_surface_read_text(surface, selection, ghostty_text_s*)`. 그리드의 렌더된 텍스트 스냅샷을 돌려준다.
- 이 옵션은 신규 ABI나 upstream 변경 없이 현재 헤더의 공개 API만으로 성립한다.

#### 장점

- upstream/외부 의존이 전혀 없고, 이미 동작하는 코드(`GhosttyViewportProvider`)를 출발점으로 삼는다. 가장 빨리 무언가를 내보낼 수 있다.
- libghostty가 소유한 `.internal` 세션에도 즉시 적용 가능하다(현 GUI 경로가 이미 이 방식으로 텍스트를 읽는다).
- 사람이 읽을 화면 상태 요약 용도로는 충분히 유용하다(예: 데몬이 "현재 화면에 무엇이 보이는가"를 알려주는 용도).

#### 단점/한계

- **ANSI/제어 바이트 소실**: `read_text`는 렌더 후 그리드의 평문 텍스트다. 색상/커서이동/지우기 등 원시 제어 시퀀스가 이미 소비되어 사라진 결과이므로, byte-faithful 스트림을 재구성할 수 없다.
- **폴링 latency와 누락**: 스트리밍이 아니라 주기적 스냅샷이다. 폴링 간격 사이에 빠르게 지나간 출력(스크롤로 밀려난 줄, 순간적으로만 표시된 진행 표시 등)은 두 스냅샷 어디에도 남지 않아 영구 소실된다. diff를 떠도 "두 스냅샷의 차이"일 뿐 "그 사이 실제로 흘러간 바이트"가 아니다.
- **byte 정합 불가**: 위 두 한계의 귀결로, P4 데몬이 요구하는 byte-faithful 요건을 원리적으로 충족할 수 없다. 같은 화면이라도 그것을 만든 원시 바이트열은 유일하지 않다.
- 스크롤백 경계, viewport 밖 출력, 부분 UTF-8 조각 처리 등에서 diff 알고리즘이 복잡해지고 오탐/누락이 늘어난다.

#### 예상 난이도

낮음~중간(구현 난이도 기준). 단, 난이도가 낮은 만큼 **byte-faithful 요건 자체를 충족하지 못한다**는 점이 본질적 한계다. 요건을 "화면 상태 근사"로 완화하지 않는 한 P4 데몬의 정식 해법이 될 수 없다.

---

## 결정 게이트 — P7 envelope freeze 전 출력 탭 방식 결정

> 본 게이트는 P7 envelope freeze 직전에 `.internal` 출력 탭 방식을 확정하기 위한 단일 결정 지점이다.
> 다만 **본 스파이크는 결정을 강제하지 않는다.** 목적은 위 세 옵션을 열어 두고, 후속 결정 단계가 동일한 근거 위에서 선택하도록 입력을 제공하는 것이다.

### Trade-off 요약 표

| 항목 | 옵션 1 (upstream output_cb) | 옵션 2 (PTY interpose) | 옵션 3 (grid-diff 스트리밍) |
|---|---|---|---|
| byte-faithful 충족 | 가능 (파서 직전 바이트) | 가능 (master fd 직독) | **불가** (렌더 후 평문) |
| ANSI/제어 바이트 보존 | 보존 | 보존 | **소실** |
| 스트리밍 vs 폴링 | push 스트림 | push 스트림 | 폴링(diff) |
| upstream/외부 의존 | 큼 (메인테이너 수용 필요) | 없음 | 없음 |
| libghostty 화면 일치 | 자연히 일치 | **위험** (출력 주입 API 부재) | 일치 (현 surface 그대로) |
| 신규 ABI/공개 API 필요 | 필요 (구조체 멤버 추가) | 부분 필요/부재 | 불필요 |
| 예상 난이도 | 높음 | 중간~높음 | 낮음~중간 |
| 일정 통제력 | 낮음 | 높음 | 높음 |

### 권고 (잠정)

다음은 잠정 권고이며 P7 envelope freeze 게이트의 최종 결정을 구속하지 않는다.

- **장기 정답 후보**: 옵션 1. byte-faithful 요건을 가장 깨끗하게 충족하고 두 origin을 통일한다. 단 upstream 일정 의존이 해소되어야 한다.
- **단기 가교 후보**: 옵션 3. 요건을 "화면 상태 근사"로 한정한 임시 기능에만 한해, 옵션 1 머지 이전의 가시성 제공 용도로 검토한다. byte-faithful이 필요한 데몬 경로에는 사용하지 않는다.
- **조건부 후보**: 옵션 2. 헤더에 외부 fd 주입 및 출력 → surface 렌더 주입 공개 API가 추가되거나, 비공개 동작 의존 없이 화면 일치를 보장할 경로가 확인되면 재평가한다. 현 헤더(`:467-480`, `:1127`)만으로는 화면 일치 보장 경로가 없다.

### 미결 질문

1. ghostty upstream이 `ghostty_runtime_config_s`에 raw output 콜백 추가 제안을 수용할 의향이 있는가? 수용 시 예상 리드타임은 P7 일정과 양립하는가? (옵션 1 핵심 가정)
2. fork를 들고 GhosttyKit.xcframework를 자체 빌드·서명·notarization하는 비용이 P4/P7 빌드 파이프라인에서 감당 가능한가? (옵션 1 차선 경로)
3. libghostty surface에 외부 PTY fd를 주입하거나, master fd에서 읽은 출력 바이트를 surface 렌더로 밀어 넣을 비공개/우회 경로가 실재하는가? 있다면 갱신 안정성은? (옵션 2 핵심 가정)
4. P4 데몬 요건을 "byte-faithful 스트림"으로 엄격히 유지하는가, 아니면 일부 소비자(예: 사람이 읽는 요약)에 한해 "화면 상태 근사"로 완화 가능한가? 이 답이 옵션 3의 사용 가능 범위를 결정한다.
5. P7 envelope freeze가 동결하는 envelope 스키마는 byte 스트림과 그리드 스냅샷 중 어느 표현을 1급으로 삼아야 하는가? 두 표현을 모두 수용하도록 envelope를 설계해 결정을 유예할 여지가 있는가?

---

## 부록 — 인용 근거 모음 (file:line)

| 사실 | 근거 |
|---|---|
| `.internal`은 ptyHandle nil, master fd 외부 노출 없음 | `Sources/Session/Session.swift:20-27` |
| `.external`은 PTYSpawner spawn + ptyHandle 보유 | `Sources/Session/SessionManager.swift:125-134` |
| `.internal` 등록 경로 (ptyHandle nil) | `Sources/Session/SessionManager.swift:201-211`, `:216-237` |
| master fd 탭 (DispatchIO, lowWater=1, highWater=64KiB) | `Sources/PTY/PTYReader.swift:25-50` |
| runtime config 콜백에 출력 바이트 콜백 부재 | `ghostty.h:1018-1027` |
| 콜백 typedef 패턴 | `ghostty.h:1000-1016` |
| app 생성 시 runtime config 등록 진입점 | `ghostty.h:1085-1086` |
| surface config 구조체 (fd 주입 필드 없음, command만) | `ghostty.h:467-480` |
| `ghostty_surface_text`는 입력 전용 | `ghostty.h:1127` |
| `ghostty_surface_key` 입력 API | `ghostty.h:1123` |
| `ghostty_surface_read_text` 그리드 스냅샷 | `ghostty.h:1159-1161` |
| `ghostty_surface_free_text` 1:1 해제 | `ghostty.h:1162` |
| 현 viewport 폴링 구현 | `Sources/UI/AgentView/GhosttyViewportProvider.swift:26-48` |

ghostty 헤더 인용은 모두 macOS 슬라이스 기준이다:
`Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h`
