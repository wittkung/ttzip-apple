// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit
import AppKit
import TTZipCore
import TTZipUI

/// Navigation control group providing Back, Forward, and Up directory actions
/// grouped into a cohesive 28pt capsule to eliminate per-button border fragmentation.
public struct NavigationControlGroupView: View {
    public var viewModel: AppViewState
    private var l10n = AppLocalizationState.shared

    @State private var hoveredButton: String? = nil

    public init(viewModel: AppViewState) {
        self.viewModel = viewModel
    }

    private var historyStack: WorkspaceHistoryStack? {
        viewModel.navigationState.activeTabSession?.historyStack
    }

    public var body: some View {
        HStack(spacing: 0) {
            // 1. Back Button (←)
            navButton(
                id: "back",
                icon: "arrow.backward",
                isEnabled: historyStack?.canGoBack == true,
                helpText: l10n.uiString(zh: "后退 (⌘[)", en: "Back (⌘[)"),
                accessibilityId: "NavBackButton"
            ) {
                viewModel.navigationState.goBack()
            }
            .contextMenu {
                let backList = historyStack?.backList ?? []
                ForEach(Array(backList.enumerated()), id: \.offset) { _, url in
                    Button(TTZipPathPresentationService.shared.displayName(for: url, language: l10n.currentLanguage)) {
                        viewModel.navigationState.navigateTo(url)
                    }
                }
            }

            segmentSeparator

            // 2. Forward Button (→)
            navButton(
                id: "forward",
                icon: "arrow.forward",
                isEnabled: historyStack?.canGoForward == true,
                helpText: l10n.uiString(zh: "前进 (⌘])", en: "Forward (⌘])"),
                accessibilityId: "NavForwardButton"
            ) {
                viewModel.navigationState.goForward()
            }
            .contextMenu {
                let forwardList = historyStack?.forwardList ?? []
                ForEach(Array(forwardList.enumerated()), id: \.offset) { _, url in
                    Button(TTZipPathPresentationService.shared.displayName(for: url, language: l10n.currentLanguage)) {
                        viewModel.navigationState.navigateTo(url)
                    }
                }
            }

            segmentSeparator

            // 3. Up to Parent Button (↑)
            navButton(
                id: "up",
                icon: "arrow.up",
                isEnabled: historyStack?.canGoUp == true,
                helpText: l10n.t(L10n.Explorer.parentDirectory) + " (⌘↑)",
                accessibilityId: "NavUpButton"
            ) {
                viewModel.navigationState.goUp()
            }
        }
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .background(keyboardShortcuts)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NavigationControlGroup")
    }

    private var segmentSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 0.5, height: 14)
    }

    private func navButton(
        id: String,
        icon: String,
        isEnabled: Bool,
        helpText: String,
        accessibilityId: String,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = (hoveredButton == id) && isEnabled
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.primary.opacity(isHovered ? 0.98 : 0.85) : Color.secondary.opacity(0.32))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                        .padding(1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            if hovering {
                hoveredButton = id
            } else if hoveredButton == id {
                hoveredButton = nil
            }
        }
        .ttButtonHelp(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier(accessibilityId)
    }

    private var keyboardShortcuts: some View {
        Group {
            Button("") { viewModel.navigationState.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .opacity(0)
            Button("") { viewModel.navigationState.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .opacity(0)
            Button("") { viewModel.navigationState.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .opacity(0)
        }
    }
}
