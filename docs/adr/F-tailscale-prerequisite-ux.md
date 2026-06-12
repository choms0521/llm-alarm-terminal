# ADR-F: Tailscale prerequisite UX

상태: 동결(P6b Day 4)

마스터 계획의 ADR 목록에서 ADR-F는 작성 단계가 P6b/P8로 지정된다. P6b는 데스크톱 측 정책(데몬이 Tailscale 상태를 어떻게 진단·노출·폴백하는가)을 확정하고, 모바일 측 설치/로그인 안내 화면은 P8이 본 ADR을 참조해 적용한다. 본 문서는 P6b 상세 계획서(`docs/plans/p6b/p6b-detailed.html` §6) 본문을 이전한 것이며, Day 0 스파이크 실측(`.omc/research/p6b-tailscale-spike.md`)으로 확인된 함정을 반영했다.

## Decision (결정)

1. **Tailscale은 system service 의존, tsnet 미사용.** 데몬은 외부 `tailscale` CLI/데몬의 상태를 `tailscale status --json` / `tailscale ip -4`로 진단·소비만 하고, 임베디드 Tailscale(tsnet)은 도입하지 않는다.

2. **데스크톱은 진단 4분기를 한국어로 명시 노출한다.** `running(ip)` / `notInstalled` / `notLoggedIn` / `offline` 각각에 대해 설정 UI가 한국어 안내를 띄운다. silent 실패(조용한 loopback 폴백)는 금지한다.

3. **tailnet 미충족 시 loopback 폴백 + 노출.** Tailscale IP를 못 얻으면 데몬은 loopback으로 폴백하되 그 사유를 진단으로 노출한다. 데몬은 항상 기동하고(loopback 최소 보장), 원격 접속만 비활성된다.

4. **바인딩 전 `BackendState == "Running"`을 게이트한다.** Day 0 스파이크 실측 결과, `BackendState`가 `Stopped`여도 `tailscale ip -4`는 저장된 100.x 주소를 반환한다. 이 주소로 바인딩하면 utun 인터페이스가 내려가 있어 `NWListener`가 `.failed`가 아니라 `.waiting`에 무한 대기한다(테스트가 timeout 없이 영구 hang). 따라서 진단은 반드시 `status`를 먼저 보아 `Running`을 확인한 뒤에만 `ip -4`를 신뢰하고, listener 기동은 `.waiting`도 실패로 표면화하며 안전망 timeout을 둔다.

5. **모바일 prerequisite는 P8이 본 ADR 참조.** 모바일 앱은 페어링 전 Tailscale 앱 설치 + 동일 tailnet 로그인을 요구하는 안내 화면을 P8에서 제공한다. 데스크톱이 발급하는 `wsEndpoint`가 100.x 주소이므로(P6b), 모바일이 같은 tailnet에 없으면 도달 불가하다. 이 전제를 P8 UX가 안내한다.

## Drivers (결정 동인)

- 마스터 § 3 P6b "Tailscale은 system service 의존(tsnet 미사용). `tailscale status` 사전 진단 + 한국어 안내" — 명시적 요구.
- tsnet 임베디드는 데몬에 Tailscale 인증·키 관리를 끌어와 보안 표면·바이너리 크기·유지보수를 키운다. system service 위임이 경계를 단순하게 유지한다.
- silent 폴백은 "왜 모바일이 연결 안 되는가"를 사용자가 진단 불가능하게 만든다. 명시 노출이 지원 비용을 낮춘다.
- Day 0 스파이크가 `requiredLocalEndpoint`를 비-loopback IP로 바꾸면 그 인터페이스에만 바인딩되어 loopback 클라이언트가 도달 불가능함을 실측했다(인터페이스 격리 메커니즘이 utun 100.x에도 동일 적용). 옵션 A(Tailscale IP 직접 바인딩)가 1차 경계로 성립함이 확인됐다.

## Alternatives considered (검토한 대안)

| 대안 | 내용 | 기각 사유 |
|---|---|---|
| tsnet 임베디드 | 데몬이 Tailscale을 라이브러리로 내장해 자체 tailnet 노드가 됨 | 데몬에 Tailscale 인증/키/업데이트 책임 유입 — 보안 표면·바이너리·유지보수 증가. system service 위임 대비 이득 없음(사용자는 이미 Tailscale 앱 사용) |
| silent loopback 폴백 | Tailscale 미충족 시 조용히 loopback으로 떨어지고 안내 없음 | "왜 원격 연결이 안 되는가"를 사용자가 알 수 없음 — 지원 비용·혼란 증가. 명시 노출 원칙 위반 |
| `0.0.0.0` 무진단 노출 | Tailscale 무관하게 모든 인터페이스 노출(D-1 옵션 B) | tailnet 밖 공격 표면 확대(단층 방어). D-1에서 이미 기각 |
| `tailscale serve` 프록시(옵션 C) | 데몬은 loopback 유지, 외부 Tailscale이 tailnet→loopback 포워딩 | Day 0 스파이크가 옵션 A(직접 바인딩)의 인터페이스 격리를 실증해 폴백 불요. 프록시는 운영 복잡도만 추가 |

## Why chosen (선택 이유)

system service 의존 + 명시 진단 노출 + loopback 폴백의 조합이 (a) 데몬의 보안 경계를 단순하게 유지하고(tsnet 인증 책임 회피), (b) 사용자가 Tailscale 상태를 항상 알 수 있게 하며(silent 실패 제거), (c) Tailscale이 없어도 데몬은 loopback으로 최소 동작(점진적 저하)하는 세 목표를 동시에 만족한다. 모바일 측 안내를 P8로 미루는 것은 데스크톱이 먼저 `wsEndpoint`를 100.x로 발급하는 주체이므로(P6b), 그 전제를 데스크톱에서 확정하고 모바일이 소비하는 순서가 자연스럽기 때문이다. Day 0 스파이크가 옵션 A의 인터페이스 격리를 실측해, 프록시(옵션 C) 폴백 없이 직접 바인딩으로 1차 경계가 성립함을 확인했다.

## Consequences (결과)

- (+) 데몬이 Tailscale 인증/키를 다루지 않아 보안 표면이 작다.
- (+) 사용자가 설정 UI에서 Tailscale 상태를 한눈에 확인 — 원격 연결 실패 진단이 쉽다.
- (+) Tailscale 부재에도 데몬은 loopback으로 기동 — 데스크톱 단독 기능은 무영향.
- (-) 모바일 원격 접속은 양측이 같은 tailnet에 있어야만 성립 — P8이 이 전제를 안내해야 하는 부담(MVP 수용).
- (-) Tailscale IP 변동 시 데몬 재바인딩(재시작) 필요 — 진단 + 재시작 경로로 흡수(자동 재바인딩은 post-MVP).
- (-) IP 변동 시 기존 발급된 `wsEndpoint`도 stale하다. 페어링 payload는 발급 시점 IP를 고정 인코딩하므로(QR/6자리 코드 모두), 재바인딩 후에는 기존 디바이스가 옛 주소로 도달 불가하여 재페어링이 필요하다. 설정 UI가 현 바인딩 주소 변경을 노출해 사용자가 재페어링 시점을 판단한다(자동 endpoint 갱신은 post-MVP).
- (-) `BackendState` 게이트를 누락하면 Stopped 상태의 저장 IP로 바인딩해 listener가 `.waiting`에 무한 대기하는 함정이 있다(Day 0 실측). 진단은 반드시 status를 먼저 확인하고, listener 기동에 `.waiting` 표면화 + 안전망 timeout을 둔다.

## Follow-ups (후속)

- P8: 모바일 페어링 전 Tailscale 설치 + 동일 tailnet 로그인 안내 화면(본 ADR 참조).
- P8: 모바일이 데스크톱 발급 `wsEndpoint`(100.x)에 도달 가능한지 사전 점검 UX.
- post-MVP: Tailscale IP 변동 자동 감지 + 무중단 재바인딩(현재는 재시작 + 재페어링).
- P7: `wsEndpoint`가 tailnet 주소일 때의 envelope/페어링 payload 규약 동결(현재 loopback/100.x 양립).
