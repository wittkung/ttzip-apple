// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipUI

/// Floating dropdown action and search results palette for the Universal Omnibar.
///
/// Encapsulates categorized results across applications, commands, directories, and files
/// within an ultra-thin glassmorphic panel adhering to the WSJ Editorial and Zen design specifications.
public struct UniversalOmniPaletteView: View {
    // MARK: - Dependencies

    public var engine: OmniSearchEngine
    @Binding public var selectedIndex: Int
    public var onCommit: (OmniSearchItem) -> Void
    public var onDismiss: () -> Void

    // MARK: - Internal State

    @State private var hoveredItemId: String?

    // MARK: - Constants

    private let paletteWidth: CGFloat = 580.0
    private let minPaletteHeight: CGFloat = 280.0
    private let maxPaletteHeight: CGFloat = 420.0
    private let rowHeight: CGFloat = 35.0
    private let footerHeight: CGFloat = 26.0

    // MARK: - Initialization

    public init(
        engine: OmniSearchEngine,
        selectedIndex: Binding<Int>,
        onCommit: @escaping (OmniSearchItem) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.engine = engine
        self._selectedIndex = selectedIndex
        self.onCommit = onCommit
        self.onDismiss = onDismiss
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            resultsScrollView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            paletteFooter
        }
        .frame(width: paletteWidth)
        .frame(minHeight: minPaletteHeight, maxHeight: maxPaletteHeight)
        .background(paletteBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(paletteBorder)
        .shadow(color: Color.black.opacity(0.3), radius: 24, x: 0, y: 12)
        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
        .zIndex(999)
    }

    // MARK: - Results List

    private var resultsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if engine.flatResults.isEmpty {
                        emptyStateView
                    } else {
                        categorySections
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                scrollToSelectedItem(index: newIndex, proxy: proxy)
            }
        }
    }

    // MARK: - Category Sections

    @ViewBuilder
    private var categorySections: some View {
        let displayCategories: [OmniSearchCategory] = [
            .applications,
            .commands,
            .directories,
            .files
        ]

        ForEach(displayCategories, id: \.self) { category in
            if let items = engine.categorizedResults[category], !items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    sectionHeader(for: category)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                        .padding(.bottom, 2)

                    ForEach(items) { item in
                        let isSelected = isItemSelected(item)
                        resultRow(for: item, isSelected: isSelected)
                            .id(item.id)
                    }
                }
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(for category: OmniSearchCategory) -> some View {
        HStack(spacing: 6) {
            Text(categoryHeaderBadge(for: category))
                .font(.system(size: 11))

            Text(categoryHeaderTitle(for: category))
                .font(.system(size: 10, weight: .bold, design: .serif))
                .tracking(1.0)
                .foregroundStyle(TTZipZenTheme.Surface.goldLeaf)

            Spacer()
        }
    }

    private func categoryHeaderBadge(for category: OmniSearchCategory) -> String {
        switch category {
        case .applications: return "🚀"
        case .commands:     return "⚡️"
        case .directories:  return "📁"
        case .files:        return "📄"
        }
    }

    private func categoryHeaderTitle(for category: OmniSearchCategory) -> String {
        let isEmptyQuery = engine.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch category {
        case .applications:
            return isEmptyQuery ? "常用应用 (Applications)" : "Applications"
        case .commands:
            return isEmptyQuery ? "快速指令 (Commands)" : "Commands"
        case .directories:
            return isEmptyQuery ? "快捷目录 (Directories)" : "Directories"
        case .files:
            return isEmptyQuery ? "最近文件 (Files)" : "Files"
        }
    }

    // MARK: - Row Item

    private func resultRow(for item: OmniSearchItem, isSelected: Bool) -> some View {
        Button {
            onCommit(item)
        } label: {
            HStack(spacing: 8) {
                // Left bamboo green active indicator capsule
                Capsule(style: .continuous)
                    .fill(isSelected ? TTZipTheme.bambooGreen : Color.clear)
                    .frame(width: 2.5, height: 18)
                    .padding(.leading, 1)

                // Item primary visual icon
                itemIconView(for: item)

                // Title and subtitle labels
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(item.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                        .lineLimit(1)

                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                // Trailing action badge / hint
                trailingBadge(for: item, isSelected: isSelected)
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .background(rowBackground(isSelected: isSelected, isHovered: hoveredItemId == item.id))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(rowSelectionBorder(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredItemId = item.id
                if let idx = engine.flatResults.firstIndex(where: { $0.id == item.id }) {
                    selectedIndex = idx
                }
            } else if hoveredItemId == item.id {
                hoveredItemId = nil
            }
        }
    }

    // MARK: - Item Icon

    @ViewBuilder
    private func itemIconView(for item: OmniSearchItem) -> some View {
        if let customIcon = item.customIcon {
            Image(nsImage: customIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else if let systemIcon = item.systemIcon {
            Image(systemName: systemIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(categoryIconColor(for: item.category))
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: item.category.systemIconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(categoryIconColor(for: item.category))
                .frame(width: 22, height: 22)
        }
    }

    private func categoryIconColor(for category: OmniSearchCategory) -> Color {
        switch category {
        case .applications:
            return Color.blue
        case .commands:
            return TTZipTheme.kintsugiGold
        case .directories:
            return TTZipTheme.bambooGreen
        case .files:
            return Color.secondary
        }
    }

    // MARK: - Trailing Badges

    @ViewBuilder
    private func trailingBadge(for item: OmniSearchItem, isSelected: Bool) -> some View {
        if let customHint = item.shortcutHint, !customHint.isEmpty {
            badgeView(title: customHint, isSelected: isSelected)
        } else {
            switch item.payload {
            case .application:
                badgeView(title: "⏎ 打开", isSelected: isSelected)
            case .directory:
                badgeView(title: "Tab 补全", isSelected: isSelected)
            case .file:
                badgeView(title: "⏎ 打开", isSelected: isSelected)
            case .command:
                badgeView(title: "⏎ 执行", isSelected: isSelected)
            }
        }
    }

    private func badgeView(title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : Color.secondary.opacity(0.8))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? TTZipTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(isSelected ? TTZipTheme.bambooGreen.opacity(0.28) : Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }

    // MARK: - Row Background & Border

    private func rowBackground(isSelected: Bool, isHovered: Bool) -> some View {
        Group {
            if isSelected {
                TTZipTheme.bambooGreen.opacity(0.14)
            } else if isHovered {
                Color.primary.opacity(0.04)
            } else {
                Color.clear
            }
        }
    }

    private func rowSelectionBorder(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(isSelected ? TTZipTheme.bambooGreen.opacity(0.3) : Color.clear, lineWidth: 0.5)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .padding(.top, 16)

            if engine.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("输入以搜索应用、目录、文件，或以 > 开头执行指令")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.secondary)
            } else {
                Text("未找到与 \"\(engine.query)\" 相关的匹配项")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Footer

    private var paletteFooter: some View {
        HStack(spacing: 8) {
            Spacer()

            Text("↑↓ 导航")
            Text("•")
            Text("⏎ 确认")
            Text("•")
            Text("Tab 补全")
            Text("•")
            Text("Esc 退出")

            Spacer()
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.secondary.opacity(0.85))
        .frame(height: footerHeight)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.75))
        .overlay(
            Rectangle()
                .fill(TTZipZenTheme.Surface.goldLeaf.opacity(0.18))
                .frame(height: 0.5),
            alignment: .top
        )
    }

    // MARK: - Panel Decorations

    private var paletteBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color(nsColor: .windowBackgroundColor).opacity(0.92)
        }
    }

    private var paletteBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(TTZipZenTheme.Surface.goldLeaf.opacity(0.2), lineWidth: 1.0)
    }

    // MARK: - Helpers

    private func isItemSelected(_ item: OmniSearchItem) -> Bool {
        guard engine.flatResults.indices.contains(selectedIndex) else { return false }
        return engine.flatResults[selectedIndex].id == item.id
    }

    private func scrollToSelectedItem(index: Int, proxy: ScrollViewProxy) {
        guard engine.flatResults.indices.contains(index) else { return }
        let targetId = engine.flatResults[index].id
        withAnimation(.easeInOut(duration: 0.12)) {
            proxy.scrollTo(targetId, anchor: .center)
        }
    }
}
