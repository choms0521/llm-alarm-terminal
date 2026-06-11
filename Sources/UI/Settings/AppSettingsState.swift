import Foundation
import Combine

/// 설정 페이지 표시 상태를 앱 전역에서 공유하는 ObservableObject.
///
/// AppDelegate에서 생성하여 RootView에 주입한다. isShowingSettings가 true이면
/// RootView가 HSplitView 대신 SettingsPageView를 표시한다.
/// pairingModel은 데몬 부트스트랩 완료 후 AppDelegate가 채운다. @Published이므로
/// RootView가 자동으로 갱신된다(NSHostingView rootView 재설정 불필요).
@MainActor
public final class AppSettingsState: ObservableObject {
    @Published public var isShowingSettings: Bool = false
    @Published public var selectedSection: SettingsSection = .pairing
    /// 데몬 부트스트랩 후 채워지는 페어링 모델. nil이면 "데몬 준비 중" 안내를 표시한다.
    @Published public var pairingModel: PairingModel?

    public init() {}

    /// 설정 페이지를 열고 지정 섹션을 선택한다. 기본 선택은 디바이스 페어링.
    public func open(section: SettingsSection = .pairing) {
        self.selectedSection = section
        self.isShowingSettings = true
    }

    /// 설정 페이지를 닫고 메인 화면으로 복귀한다.
    public func close() {
        self.isShowingSettings = false
    }
}

/// 설정 페이지의 섹션 항목.
public enum SettingsSection: String, CaseIterable, Identifiable {
    case pairing = "디바이스 페어링"
    case push = "푸시 알림"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .pairing: return "qrcode"
        case .push: return "bell.badge"
        }
    }
}
