import SwiftUI

/// 페어링 화면. QR 코드와 6자리 코드, 만료 카운트다운, "새 코드 발급" 버튼, 등록된
/// 디바이스 목록을 표시한다. secret 평문은 표시하지 않으며 QR/코드 채널로만 운반된다.
struct PairingView: View {
    @ObservedObject var model: PairingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("디바이스 페어링")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("모바일 기기에서 아래 QR 코드를 스캔하거나 6자리 코드를 입력해 페어링하세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                codeSection

                Divider()

                deviceListSection

                if let message = model.errorMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await model.refreshDevices()
        }
        .onDisappear {
            model.stop()
        }
    }

    /// QR + 6자리 코드 + 카운트다운 + 발급 버튼.
    private var codeSection: some View {
        VStack(alignment: .center, spacing: 16) {
            if let qr = model.qrPayloadURL {
                QRImageView(content: qr)
            } else {
                placeholderBox
            }

            if let code = model.sixDigitCode {
                VStack(spacing: 6) {
                    Text("6자리 코드")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formattedCode(code))
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .tracking(4)
                    Text("\(model.secondsRemaining)초 후 만료")
                        .font(.caption)
                        .foregroundStyle(model.secondsRemaining <= 30 ? .orange : .secondary)
                }
            } else {
                Text("아직 발급된 코드가 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await model.issueNewCode() }
            } label: {
                Text(model.sixDigitCode == nil ? "코드 발급" : "새 코드 발급")
                    .frame(minWidth: 140)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }

    /// QR 미발급 상태의 자리 표시 상자.
    private var placeholderBox: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [6]))
            .foregroundStyle(.secondary)
            .frame(width: 220, height: 220)
            .overlay(
                Text("코드를 발급하면\nQR 코드가 표시됩니다.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            )
    }

    /// 등록된 디바이스 목록(read-only).
    private var deviceListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("등록된 디바이스")
                    .font(.headline)
                Spacer()
                Text("\(model.devices.count)대")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.devices.isEmpty {
                Text("등록된 디바이스가 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.devices, id: \.id) { device in
                    deviceRow(device)
                }
            }
        }
    }

    /// 디바이스 1행. tokenId는 식별자라 앞 8자만 노출하고 secret은 표시하지 않는다.
    private func deviceRow(_ device: Device) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.revoked ? "xmark.circle" : "iphone")
                .foregroundStyle(device.revoked ? .red : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body)
                Text("토큰 \(maskedTokenId(device.tokenId))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if device.revoked {
                Text("폐기됨")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    /// 6자리 코드를 "123 456" 형태로 가독성 있게 끊는다.
    private func formattedCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<mid]) \(code[mid...])"
    }

    /// tokenId 앞 8자만 노출(식별자 마스킹). secret이 아니라 안전하나 목록 가독성용.
    private func maskedTokenId(_ tokenId: String) -> String {
        String(tokenId.prefix(8))
    }
}
