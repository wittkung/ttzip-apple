// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipCore
import TTZipUI

public struct GlobalSearchPanelView: View {
    @ObservedObject public var controller: GlobalSearchPanelController
    private var l10n = AppLocalizationState.shared

    public init(controller: GlobalSearchPanelController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Omnibar search field with native AppKit IME-safe bridge
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)

                SearchInputField(
                    text: $controller.query,
                    placeholder: l10n.t(L10n.Search.placeholder),
                    onCommit: {
                        controller.activateSelectedItem()
                    },
                    onCancel: {
                        controller.dismissAndRestoreFocus()
                    },
                    onUpArrow: {
                        controller.selectPrevious()
                    },
                    onDownArrow: {
                        controller.selectNext()
                    }
                )

                if controller.isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }

                Text("⇧⌘Space")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    )
            }
            .padding(.horizontal, 16)
            .frame(height: GlobalSearchPanelController.fieldHeight)

            if !controller.results.isEmpty {
                Divider()
                    .background(TTZipTheme.hairlineBorder)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(controller.results.enumerated()), id: \.element.id) { index, item in
                                GlobalSearchResultRow(
                                    item: item,
                                    isSelected: index == controller.selectedIndex,
                                    onSelect: {
                                        controller.selectedIndex = index
                                        controller.activateSelectedItem()
                                    }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: controller.selectedIndex) { _, newIndex in
                        if newIndex >= 0, newIndex < controller.results.count {
                            proxy.scrollTo(controller.results[newIndex].id, anchor: .center)
                        }
                    }
                }

                Divider()
                    .background(TTZipTheme.hairlineBorder)

                // Bottom action hint footer
                footerBar
            } else if !controller.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !controller.isSearching {
                Divider()
                    .background(TTZipTheme.hairlineBorder)

                HStack {
                    Spacer()
                    Text(l10n.t(L10n.Search.noResults))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                    Spacer()
                }
            }
        }
        .frame(width: GlobalSearchPanelController.panelWidth)
        .background(Color.clear)
    }

    private var footerBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Text("↩")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(l10n.t(L10n.Search.actionOpen))
                    .font(.system(size: 11))
            }
            HStack(spacing: 4) {
                Text("⌘↩")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(l10n.t(L10n.Search.actionReveal))
                    .font(.system(size: 11))
            }
            HStack(spacing: 4) {
                Text("Space")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(l10n.t(L10n.Search.actionQuickLook))
                    .font(.system(size: 11))
            }
            Spacer()
            searchModeBadge
            HStack(spacing: 4) {
                Text("⎋")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(l10n.t(L10n.Search.actionDismiss))
                    .font(.system(size: 11))
            }
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .frame(height: 28)
    }

    private var searchModeBadge: some View {
        let modeText = controller.isSemanticSearchActive
            ? Self.tr(zhHans: "语义 + 词法搜索", zhHant: "語義 + 詞法搜尋", en: "Semantic + Lexical")
            : Self.tr(zhHans: "基础词法搜索", zhHant: "基礎詞法搜尋", en: "Basic Lexical Search")
        return Text(modeText)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(controller.isSemanticSearchActive ? TTZipTheme.bambooGreen : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
    }

    private static func tr(zhHans: String, zhHant: String, en: String) -> String {
        AppLocalizationState.shared.uiString(zh: zhHans, en: en, zhHant: zhHant)
    }
}

private struct GlobalSearchResultRow: View {
    let item: GlobalSearchResultItem
    let isSelected: Bool
    let onSelect: () -> Void
    /// Computed rather than stored: a `private` stored property would make the
    /// synthesized memberwise initializer `private`, which is only callable from
    /// inside this type on Swift toolchains before 6.2.
    private var l10n: AppLocalizationState { .shared }

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                let badge = badgeText
                if !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? TTZipTheme.bambooGreen.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        switch item.hitType {
        case .archiveFile:
            return "doc.zipper"
        case .archiveEntry:
            return item.isDirectory ? "folder.fill" : "doc.text.fill"
        case .recentArchive:
            return "clock.arrow.circlepath"
        case .quickAction:
            return "bolt.fill"
        }
    }

    private var iconColor: Color {
        switch item.hitType {
        case .archiveFile:
            return TTZipTheme.bambooGreen
        case .archiveEntry:
            return item.isDirectory ? Color.blue : Color.secondary
        case .recentArchive:
            return TTZipTheme.archiveAmber
        case .quickAction:
            return Color.yellow
        }
    }

    private var badgeText: String {
        if let matchBadge = item.matchBadge, !matchBadge.isEmpty {
            return matchBadge
        }
        switch item.hitType {
        case .archiveFile:
            return l10n.t(L10n.Search.badgeActiveArchive)
        case .archiveEntry:
            return item.isDirectory ? l10n.t(L10n.Search.badgeFolder) : l10n.t(L10n.Search.badgeFile)
        case .recentArchive:
            return l10n.t(L10n.Search.badgeRecent)
        case .quickAction:
            return l10n.t(L10n.Search.badgeAction)
        }
    }
}
