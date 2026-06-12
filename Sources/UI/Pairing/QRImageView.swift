import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// 문자열을 QR 코드 NSImage로 렌더하는 뷰. CIQRCodeGenerator 필터의 출력은 모듈당 1px라
/// 흐릿하므로, CIContext로 렌더하기 전에 정수 배율로 확대(nearest-neighbor)해 선명하게 만든다.
struct QRImageView: View {
    /// QR에 인코딩할 문자열(페어링 payload URL).
    let content: String
    /// 화면에 표시할 한 변의 점 크기.
    var side: CGFloat = 220

    var body: some View {
        Group {
            if let image = Self.makeQRImage(from: content, side: side) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: side, height: side)
                    .accessibilityLabel("페어링 QR 코드")
            } else {
                Text("QR 코드를 만들지 못했습니다.")
                    .foregroundStyle(.secondary)
                    .frame(width: side, height: side)
            }
        }
    }

    /// 문자열을 QR NSImage로 만든다. 실패 시 nil.
    static func makeQRImage(from content: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        // 고정 보정 수준 M(여유 복원력). 페어링 URL은 짧아 M으로 충분하다.
        filter.correctionLevel = "M"
        guard let baseImage = filter.outputImage else {
            return nil
        }
        // 모듈당 1px 출력을 표시 크기에 맞춰 정수 배율로 확대해 픽셀 경계를 또렷하게 한다.
        // floor로 정수 배율을 보장한다 — 실수 배율이면 모듈 경계가 다시 흐려진다.
        let scale = max(1, floor(side / baseImage.extent.width))
        let scaled = baseImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }
}
