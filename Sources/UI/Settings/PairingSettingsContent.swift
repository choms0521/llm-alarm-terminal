import SwiftUI

/// 설정 페이지 우측 — 디바이스 페어링 콘텐츠.
///
/// PairingModel API는 무수정이며, 이 뷰만 카드 기반 레이아웃으로 재구성한다.
/// secret 평문은 이 뷰 어디에도 표시하지 않는다.
struct PairingSettingsContent: View {
    let model: PairingModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                    .padding(.bottom, 20)

                if let model = model {
                    ReadyContent(model: model)
                } else {
                    preparingCallout
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 헤더

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("디바이스 페어링")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
            Text("모바일 디바이스를 QR 코드 또는 6자리 코드로 등록합니다.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 데몬 준비 중 callout

    private var preparingCallout: some View {
        calloutCard(
            color: Color.yellow.opacity(0.12),
            indicatorColor: Color.orange,
            title: "데몬을 준비하는 중입니다",
            description: "잠시 후 자동으로 페어링 화면으로 전환됩니다."
        )
    }

    // MARK: - 공통 callout 카드 헬퍼

    func calloutCard(
        color: Color,
        indicatorColor: Color,
        title: String,
        description: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(color)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 데몬 준비 완료 상태의 콘텐츠

private struct ReadyContent: View {
    @ObservedObject var model: PairingModel

    /// 삭제 확인 다이얼로그의 대상 디바이스. nil이면 다이얼로그를 닫는다.
    @State private var deviceToDelete: Device?

    /// 폐기 확인 다이얼로그의 대상 디바이스. nil이면 다이얼로그를 닫는다. 삭제와 별개의
    /// 파괴적 동작이라 별도 다이얼로그 상태로 관리한다.
    @State private var deviceToRevoke: Device?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 상태 callout — 데몬 실행 중
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text("데몬 실행 중 — 페어링 가능")
                        .font(.system(size: 13, weight: .semibold))
                    Text("QR 코드 또는 6자리 코드로 모바일 기기를 등록할 수 있습니다.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(Color.green.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Tailscale 진단 상태 카드 (원격 접속 전제 안내)
            TailscaleStatusCard(result: model.tailscaleResult) {
                Task { await model.refreshTailscale() }
            }

            // 페어링 코드 카드
            pairingCodeCard

            // 등록된 디바이스 카드
            deviceListCard

            // 안내 callout
            guideCallout
        }
        .task {
            await model.refreshDevices()
            // 설정 진입 시 Tailscale 진단 1회. 이후 갱신은 카드의 새로고침 버튼으로만.
            await model.refreshTailscale()
        }
        .onDisappear {
            model.stop()
        }
        .alert(
            "이 디바이스를 삭제할까요?",
            isPresented: Binding(
                get: { deviceToDelete != nil },
                set: { presented in if !presented { deviceToDelete = nil } }
            ),
            presenting: deviceToDelete
        ) { device in
            Button("삭제", role: .destructive) {
                Task {
                    await model.removeDevice(id: device.id)
                    deviceToDelete = nil
                }
            }
            Button("취소", role: .cancel) {
                deviceToDelete = nil
            }
        } message: { _ in
            Text("삭제하면 이 디바이스 항목과 토큰이 영구히 제거됩니다.")
        }
        .alert(
            "이 디바이스를 폐기할까요?",
            isPresented: Binding(
                get: { deviceToRevoke != nil },
                set: { presented in if !presented { deviceToRevoke = nil } }
            ),
            presenting: deviceToRevoke
        ) { device in
            Button("폐기", role: .destructive) {
                Task {
                    await model.revokeDevice(id: device.id)
                    deviceToRevoke = nil
                }
            }
            Button("취소", role: .cancel) {
                deviceToRevoke = nil
            }
        } message: { _ in
            Text("폐기하면 이 디바이스의 토큰이 즉시 무효화되고 연결이 끊깁니다. 항목은 폐기됨 상태로 남습니다.")
        }
    }

    // MARK: - 페어링 코드 카드

    private var pairingCodeCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("페어링 코드")
                    .font(.system(size: 13, weight: .semibold))

                HStack(alignment: .top, spacing: 24) {
                    // QR 코드 영역
                    VStack(spacing: 8) {
                        if let qr = model.qrPayloadURL {
                            QRImageView(content: qr)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            qrPlaceholder
                        }
                    }

                    // 코드 + 카운트다운 + 버튼
                    VStack(alignment: .leading, spacing: 12) {
                        if let code = model.sixDigitCode {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("6자리 코드")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(formattedCode(code))
                                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                                    .tracking(3)
                                countdownLabel
                            }
                        } else {
                            Text("아직 발급된 코드가 없습니다.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task { await model.issueNewCode() }
                        } label: {
                            Text(model.sixDigitCode == nil ? "코드 발급" : "새 코드 발급")
                                .frame(minWidth: 120)
                        }
                        .controlSize(.regular)
                        .keyboardShortcut(.defaultAction)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let message = model.errorMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var countdownLabel: some View {
        let isUrgent = model.secondsRemaining <= 30 && model.secondsRemaining > 0
        return HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 11))
            Text("\(model.secondsRemaining)초 후 만료")
                .font(.system(size: 12))
        }
        .foregroundStyle(isUrgent ? Color.orange : Color.secondary)
    }

    private var qrPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(Color.secondary.opacity(0.4))
            .frame(width: 160, height: 160)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("코드를 발급하면\nQR이 표시됩니다.")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            )
    }

    // MARK: - 등록된 디바이스 카드

    private var deviceListCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("등록된 디바이스")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(model.devices.count)대")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if model.devices.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone.slash")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Text("등록된 디바이스가 없습니다.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                            if index > 0 {
                                Divider()
                            }
                            deviceRow(device)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
        }
    }

    private func deviceRow(_ device: Device) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.revoked ? "xmark.circle.fill" : "iphone")
                .font(.system(size: 16))
                .foregroundStyle(device.revoked ? Color.red : Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 8) {
                    Text("토큰 \(maskedTokenId(device.tokenId))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("만료 \(formattedDate(device.expiresAt))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            lifecycleBadge(device)

            // 폐기 버튼 — 토큰 무효화 + 연결 끊기(항목은 폐기됨 상태로 존속). revoked 디바이스는
            // 이미 폐기됐으므로 버튼을 숨긴다.
            if !device.revoked {
                Button {
                    deviceToRevoke = device
                } label: {
                    Image(systemName: "nosign")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("이 디바이스의 토큰을 무효화하고 연결을 끊습니다.")
                .accessibilityLabel("디바이스 폐기")
            }

            // 삭제 버튼 — 항목과 토큰을 영구히 제거.
            Button {
                deviceToDelete = device
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("이 디바이스 항목을 영구히 삭제합니다.")
            .accessibilityLabel("디바이스 삭제")
        }
    }

    /// 디바이스 상태 뱃지. 폐기됨(빨강) > 만료됨(빨강) > 만료 임박(주황) 순으로 한 가지만 표시한다.
    /// 폐기/만료는 시간·상태가 독립이라 폐기됨을 최우선으로 보인다(폐기가 더 강한 종료 상태).
    @ViewBuilder
    private func lifecycleBadge(_ device: Device) -> some View {
        if device.revoked {
            statusBadge(text: "폐기됨", color: .red)
        } else if model.isExpired(device) {
            statusBadge(text: "만료됨", color: .red)
        } else if model.isExpiringSoon(device) {
            statusBadge(text: "\(model.daysRemaining(device))일 후 만료", color: .orange)
        }
    }

    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: - 안내 callout

    private var guideCallout: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.blue)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("이용 안내")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    guideItem("모바일 앱에서 카메라로 QR 코드를 스캔하세요.")
                    guideItem("카메라를 사용할 수 없으면 6자리 코드를 직접 입력하세요.")
                    guideItem("코드는 발급 후 5분이 지나면 자동으로 만료됩니다.")
                }
            }
        }
        .padding(14)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func guideItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 공통 카드 컨테이너

    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
    }

    // MARK: - 포맷 헬퍼

    private func formattedCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<mid]) \(code[mid...])"
    }

    private func maskedTokenId(_ tokenId: String) -> String {
        String(tokenId.prefix(8))
    }

    /// DateFormatter 생성은 비싸고 이 뷰는 1초 카운트다운으로 자주 re-render되므로
    /// static으로 캐시해 재사용한다. UI는 main thread 전용이라 공유가 안전하다.
    private static let expiryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "ko_KR")
        return formatter
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.expiryDateFormatter.string(from: date)
    }
}

// MARK: - Tailscale 진단 상태 카드

/// Tailscale 사전 진단 상태를 한국어 4분기로 표시하는 callout 카드(§5.5, ADR-F).
///
/// 연결됨(running)은 초록, 미설치/미로그인/오프라인은 주황으로 표시한다. 진단 전(result nil)이면
/// 회색 "확인 중" 표시다. 새로고침 버튼으로 수동 재진단을 트리거한다(설정 진입 시 1회 자동 진단 후).
/// 실 IP·secret은 표시하지 않고 koreanReason만 노출한다.
private struct TailscaleStatusCard: View {
    let result: TailscaleDiagnostics.Result?
    let onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text("원격 접속 (Tailscale)")
                    .font(.system(size: 13, weight: .semibold))
                Text(reasonText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Tailscale 상태를 다시 확인합니다.")
            .accessibilityLabel("Tailscale 상태 새로고침")
        }
        .padding(14)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 표시할 사유 텍스트. 진단 전이면 안내 문구, 진단 후면 상태별 한국어 사유.
    private var reasonText: String {
        result?.reason ?? "Tailscale 상태를 확인하는 중입니다."
    }

    /// 인디케이터 색. 연결됨만 초록, 나머지 3분기는 주황(점진적 저하 — 로컬 연결은 유지). 진단 전 회색.
    private var indicatorColor: Color {
        guard let state = result?.state else { return Color.secondary }
        if case .running = state { return .green }
        return .orange
    }

    /// 카드 배경 색. 인디케이터와 동일 색 계열의 옅은 톤.
    private var backgroundColor: Color {
        guard let state = result?.state else { return Color.secondary.opacity(0.08) }
        if case .running = state { return Color.green.opacity(0.10) }
        return Color.orange.opacity(0.10)
    }
}
