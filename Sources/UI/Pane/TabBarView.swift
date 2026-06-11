import SwiftUI

/// pane 상단의 탭바(REQ-2). 멀티탭 컨테이너의 탭 선택 / 추가 / 닫기 UI.
///
/// macOS 표준 탭 형태: 각 탭은 kind 아이콘 + 이름 + "×" close 버튼을 가지며,
/// 우측 끝에 "+" 추가 버튼이 있다. 활성 탭은 accent 배경으로 강조된다.
/// 상태 아이콘(idle/working/needsInput 등)은 Day 5 의 agent-view 트리에서 다루고,
/// 본 탭바는 kind 구분 아이콘만 표시한다.
struct TabBarView: View {
    let pane: Pane
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onAddTab: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(pane.tabs) { tab in
                    tabChip(tab)
                }
                addButton
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        .frame(height: 30)
        .background(.bar)
        .accessibilityIdentifier("tab-bar-\(pane.id.uuidString)")
    }

    @ViewBuilder
    private func tabChip(_ tab: Tab) -> some View {
        let isActive = (tab.id == pane.activeTabId)
        HStack(spacing: 5) {
            Image(systemName: tab.kind == .claude ? "sparkle" : "terminal")
                .font(.system(size: 10))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(tab.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
            Button(action: { onClose(tab.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("탭 닫기")
            .accessibilityIdentifier("tab-close-\(tab.id.uuidString)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(tab.id) }
        .accessibilityIdentifier("tab-chip-\(tab.id.uuidString)")
    }

    private var addButton: some View {
        Button(action: onAddTab) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("새 탭")
        .accessibilityIdentifier("tab-add-\(pane.id.uuidString)")
    }
}
