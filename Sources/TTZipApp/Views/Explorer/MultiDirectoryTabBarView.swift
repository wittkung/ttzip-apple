// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

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
    @State private var hoveredTabID: UUID? = nil
    @State private var isHoveringNewTab: Bool = false
    private var l10n = AppLocalizationState.shared

    public init(viewModel: AppViewState) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(viewModel.navigationState.tabSessions) { session in
                        tabPill(for: session)
                            .id(session.id)
                    }

                    // New Tab (+) Button pinned directly after tabs
                    Button {
                        viewModel.navigationState.openNewTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isHoveringNewTab ? Color.primary : Color.secondary)
                            .frame(width: 20, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isHoveringNewTab ? Color.primary.opacity(0.08) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                    .help("\(l10n.t(L10n.Explorer.newTab)) (⌘T)")
                    .onHover { hovering in
                        withAnimation(.ttMicro) {
                            isHoveringNewTab = hovering
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }
            .onChange(of: viewModel.navigationState.activeSessionID) { _, activeId in
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(activeId, anchor: .center)
                }
            }
        }
        .frame(height: 28)
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
        .background(keyboardShortcuts)
    }

    // MARK: - Single Tab Pill

    private func tabPill(for session: WorkspaceTabSession) -> some View {
        let isActive = session.id == viewModel.navigationState.activeSessionID
        let isHovered = hoveredTabID == session.id
        let canClose = viewModel.navigationState.tabSessions.count > 1 || session.kind.isCompressWorkspace || session.kind.isStorageInspector

        return HStack(spacing: 5) {
            // Folder / Drive / Archive icon
            Image(systemName: session.iconName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isActive ? TTZipTheme.bambooGreen : Color.secondary)

            // Folder display title
            Group {
                if let titleKey = session.titleKey {
                    L10nText(titleKey)
                } else {
                    Text(session.displayTitle)
                }
            }
            .font(.system(size: 11, weight: isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 160)

            // Close (x) button
            if canClose {
                Button {
                    viewModel.navigationState.closeTab(id: session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isActive ? Color.primary.opacity(0.8) : Color.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(isHovered ? Color.primary.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .opacity((isActive || isHovered) ? 1.0 : 0.0)
                .help("\(l10n.t(L10n.Explorer.closeTab)) (⌘W)")
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, canClose ? 4 : 7)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    isActive
                        ? Color.primary.opacity(0.08)
                        : (isHovered ? Color.primary.opacity(0.04) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    isActive ? Color.primary.opacity(0.12) : Color.clear,
                    lineWidth: 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.navigationState.switchToTab(id: session.id)
        }
        .onHover { hovering in
            withAnimation(.ttMicro) {
                hoveredTabID = hovering ? session.id : nil
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    private var keyboardShortcuts: some View {
        Group {
            Button("") {
                viewModel.navigationState.openNewTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .opacity(0)

            Button("") {
                if let activeID = viewModel.navigationState.activeTabSession?.id,
                   viewModel.navigationState.tabSessions.count > 1 || viewModel.navigationState.isCompressWorkspaceActive || viewModel.navigationState.isStorageInspectorActive {
                    viewModel.navigationState.closeTab(id: activeID)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .opacity(0)

            Button("") {
                viewModel.navigationState.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .opacity(0)

            Button("") {
                viewModel.navigationState.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .opacity(0)

            // Direct Tab Index Jump: ⌘1 .. ⌘8
            ForEach(0..<min(8, viewModel.navigationState.tabSessions.count), id: \.self) { idx in
                Button("") {
                    let sessionID = viewModel.navigationState.tabSessions[idx].id
                    viewModel.navigationState.switchToTab(id: sessionID)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                .opacity(0)
            }
        }
    }
}
