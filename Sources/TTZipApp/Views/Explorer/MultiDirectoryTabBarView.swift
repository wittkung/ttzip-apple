// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipUI
import TTZipCore

/// Native multi-directory tab bar for parallel workspace navigation.
///
/// Provides multi-folder tab management, folder icons, close triggers (⌘W),
/// new tab spawning (⌘T), and tab cycling (⌘⇧[ / ⌘⇧]).
public struct MultiDirectoryTabBarView: View {
    public var viewModel: AppViewState
    @State private var hoveredTabIndex: Int? = nil
    @State private var isHoveringNewTab: Bool = false
    private var l10n = AppLocalizationState.shared

    private let barHeight: CGFloat = 24.0

    public init(viewModel: AppViewState) {
        self.viewModel = viewModel
    }

    private var isChinese: Bool {
        l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Scrollable tab pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(viewModel.directoryTabs.enumerated()), id: \.element.id) { index, tab in
                        tabPill(for: tab, index: index)
                    }
                }
                .padding(.leading, 8)
                .padding(.vertical, 2)
            }

            // New Tab (+) Button
            Button {
                viewModel.openNewTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHoveringNewTab ? Color.white : Color.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isHoveringNewTab ? Color.white.opacity(0.08) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .help(isChinese ? "新建标签页 (⌘T)" : "New Tab (⌘T)")
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHoveringNewTab = hovering
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: barHeight)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.white.opacity(0.015)
            }
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.03))
                .frame(height: 0.5)
        }
        .background(keyboardShortcuts)
    }

    // MARK: - Single Tab Pill

    private func tabPill(for tab: DirectoryTabItem, index: Int) -> some View {
        let isActive = (index == viewModel.activeTabIndex)
        let isHovered = (hoveredTabIndex == index)

        return HStack(spacing: 5) {
            // Folder / Drive icon
            Image(systemName: iconName(for: tab.url))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isActive ? TTZipTheme.bambooGreen : Color.white.opacity(0.65))

            // Folder display title
            Text(tab.title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160)

            // Close (x) button
            if viewModel.directoryTabs.count > 1 {
                Button {
                    viewModel.closeTab(at: index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isActive ? Color.white.opacity(0.7) : Color.white.opacity(0.4))
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(isHovered ? Color.white.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .opacity((isActive || isHovered) ? 1.0 : 0.0)
                .help(isChinese ? "关闭标签页 (⌘W)" : "Close Tab (⌘W)")
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, viewModel.directoryTabs.count > 1 ? 4 : 7)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    isActive
                        ? Color.white.opacity(0.08)
                        : (isHovered ? Color.white.opacity(0.04) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    isActive ? Color.white.opacity(0.08) : Color.clear,
                    lineWidth: 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectTab(at: index)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                hoveredTabIndex = hovering ? index : nil
            }
        }
    }

    // MARK: - Helpers

    private func iconName(for url: URL) -> String {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        if url.standardizedFileURL.path == homeURL.path {
            return "house.fill"
        }
        if url.standardizedFileURL.path == "/" {
            return "internaldrive"
        }
        return "folder.fill"
    }

    // MARK: - Keyboard Shortcuts

    private var keyboardShortcuts: some View {
        Group {
            Button("") {
                viewModel.openNewTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .opacity(0)

            Button("") {
                if viewModel.directoryTabs.count > 1 {
                    viewModel.closeTab(at: viewModel.activeTabIndex)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .opacity(0)

            Button("") {
                viewModel.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .opacity(0)

            Button("") {
                viewModel.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .opacity(0)

            // Direct Tab Index Jump: ⌘1 .. ⌘8
            ForEach(0..<min(8, viewModel.directoryTabs.count), id: \.self) { idx in
                Button("") {
                    viewModel.selectTab(at: idx)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                .opacity(0)
            }
        }
    }
}
