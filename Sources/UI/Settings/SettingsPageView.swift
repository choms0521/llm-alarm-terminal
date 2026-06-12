import SwiftUI

/// 설정 전체 페이지. 좌측 nav 사이드바 + 우측 콘텐츠 영역으로 구성된다.
///
/// 기존 NSWindow 팝업 방식(SettingsView + TabView)을 대체한다. 본 창의 HSplitView가
/// isShowingSettings == true일 때 이 뷰로 교체된다.
/// pairingModel은 AppSettingsState.pairingModel에서 읽으므로 별도 파라미터 불필요.
struct SettingsPageView: View {
    @ObservedObject var settingsState: AppSettingsState
    @ObservedObject var pushSettingsModel: PushSettingsModel

    var body: some View {
        HSplitView {
            settingsNav
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 220)

            settingsContent
                .frame(minWidth: 400)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 좌측 nav 사이드바

    private var settingsNav: some View {
        VStack(spacing: 0) {
            // 그룹 헤더
            HStack {
                Text("설정")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 6)

            // 섹션 목록
            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    navRow(section: section)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            Divider()
                .padding(.horizontal, 8)

            // 돌아가기 버튼
            backRow
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func navRow(section: SettingsSection) -> some View {
        let isSelected = settingsState.selectedSection == section
        return Button {
            settingsState.selectedSection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(section.rawValue)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected
                    ? Color.accentColor
                    : Color.clear
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-nav-\(section.id)")
    }

    private var backRow: some View {
        Button {
            settingsState.close()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20)
                Text("돌아가기")
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-back-button")
    }

    // MARK: - 우측 콘텐츠 영역

    @ViewBuilder
    private var settingsContent: some View {
        switch settingsState.selectedSection {
        case .pairing:
            PairingSettingsContent(model: settingsState.pairingModel)
        case .push:
            PushSettingsContent(model: pushSettingsModel)
        }
    }
}
