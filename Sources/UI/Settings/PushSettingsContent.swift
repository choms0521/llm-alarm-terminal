import SwiftUI

/// 설정 페이지 우측 — 푸시 알림 콘텐츠.
///
/// PushSettingsModel API는 무수정이며, 기존 토글을 카드 스타일 레이아웃으로 재구성한다.
struct PushSettingsContent: View {
    @ObservedObject var model: PushSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                    .padding(.bottom, 20)

                settingsCard
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 헤더

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("푸시 알림")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
            Text("알람 이벤트 발생 시 모바일 기기로 전송되는 푸시 알림 동작을 설정합니다.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 설정 카드

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("연결 중일 때 푸시 건너뛰기")
                        .font(.system(size: 13, weight: .medium))
                    Text("앱이 활성화된 상태에서는 모바일 푸시를 전송하지 않습니다.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $model.skipWhenAttached)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(16)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}
