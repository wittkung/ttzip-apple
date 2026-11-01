// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit
import AppKit
import TTZipCore
import TTZipUI

/// Dedicated directory-scoped search control residing adjacent to the dual-mode address bar.
///
/// By default (when idle and `searchQuery.isEmpty`), renders as a compact 28x28pt search trigger button (`🔍`)
/// so the adjacent address bar gets maximum horizontal room for breadcrumbs.
/// When clicked or activated via `⌘F` (or while `searchQuery` is non-empty), smoothly expands into an
/// editable search capsule, compressing the address bar alongside it.
public struct ExplorerSearchCapsuleView: View {
    public var viewModel: AppViewState
    @Binding public var searchQuery: String
    public var isCompact: Bool
    public var isSearchIconOnly: Bool
    
    @State private var isHovered: Bool = false
    @State private var isExpanded: Bool = false
    @State private var capsuleWidth: CGFloat = 160.0
    @FocusState private var isFieldFocused: Bool
    
    private var l10n = AppLocalizationState.shared
    
    public init(
        viewModel: AppViewState,
        searchQuery: Binding<String>,
        isCompact: Bool = false,
        isSearchIconOnly: Bool = true
    ) {
        self.viewModel = viewModel
        self._searchQuery = searchQuery
        self.isCompact = isCompact
        self.isSearchIconOnly = isSearchIconOnly
    }
    
    /// Whether the search input capsule is currently expanded.
    public var isShowingExpandedCapsule: Bool {
        !isSearchIconOnly || isExpanded || isFieldFocused || !searchQuery.isEmpty
    }
    
    public var body: some View {
        Group {
            if isShowingExpandedCapsule {
                standardSearchCapsule
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            } else {
                compactSearchIconButton
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: isShowingExpandedCapsule)
        .onChange(of: viewModel.overlayState.findFocusRequestGeneration) { _, _ in
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                isExpanded = true
            }
            isFieldFocused = true
        }
    }
    
    // MARK: - Compact Search Icon Button (28x28pt)
    
    @ViewBuilder
    private var compactSearchIconButton: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                isExpanded = true
            }
            isFieldFocused = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(isHovered ? 0.14 : 0.08),
                            lineWidth: 0.5
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .ttButtonHelp(searchTooltipText)
        .accessibilityLabel(searchTooltipText)
        .accessibilityIdentifier("ExplorerSearchTriggerButton")
        .background(
            Button("") {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                    isExpanded = true
                }
                isFieldFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
        )
    }
    
    // MARK: - Expanded Search Capsule
    
    @ViewBuilder
    private var standardSearchCapsule: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(isFieldFocused ? TTZipTheme.bambooGreen : Color.secondary)
                .padding(.leading, 8)
            
            searchTextField
            trailingCollapseOrClearButton
        }
        .padding(.trailing, 6)
        .frame(
            minWidth: isCompact ? 96 : 156,
            idealWidth: isCompact ? 116 : 196,
            maxWidth: isCompact ? 132 : 232
        )
        .frame(height: 28.0)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { newWidth in
            if newWidth > 0 {
                capsuleWidth = newWidth
            }
        }
        .background(capsuleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(capsuleBorder)
        .contentShape(Rectangle())
        .onTapGesture {
            isFieldFocused = true
        }
        .onHover { isHovered = $0 }
        .ttButtonHelp(searchTooltipText)
        .onAppear {
            if isExpanded {
                isFieldFocused = true
            }
        }
        .onChange(of: isFieldFocused) { _, focused in
            if !focused && searchQuery.isEmpty {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                    isExpanded = false
                }
            }
        }
        .onChange(of: viewModel.overlayState.findFocusRequestGeneration) { _, _ in
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                isExpanded = true
            }
            isFieldFocused = true
        }
        .background(shortcutTriggerButton)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ExplorerSearchCapsule")
    }

    private var searchTextField: some View {
        TextField(dynamicPlaceholder, text: $searchQuery)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .focused($isFieldFocused)
            .frame(minWidth: 48, maxWidth: .infinity)
            .frame(height: 22)
            .accessibilityIdentifier("ExplorerSearchTextField")
            .accessibilityLabel(searchTooltipText)
            .onExitCommand {
                if !searchQuery.isEmpty {
                    searchQuery = ""
                } else {
                    isFieldFocused = false
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        isExpanded = false
                    }
                }
            }
    }

    private var trailingCollapseOrClearButton: some View {
        Button {
            if !searchQuery.isEmpty {
                searchQuery = ""
                isFieldFocused = true
            } else {
                isFieldFocused = false
                withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                    isExpanded = false
                }
            }
        } label: {
            Image(systemName: searchQuery.isEmpty ? "xmark" : "xmark.circle.fill")
                .font(.system(size: searchQuery.isEmpty ? 9.5 : 10.5, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.75))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ttButtonHelp(
            searchQuery.isEmpty
                ? l10n.uiString(zh: "收起搜索 (Esc)", en: "Collapse Search (Esc)")
                : l10n.uiString(zh: "清空搜索", en: "Clear Search")
        )
        .accessibilityIdentifier("ExplorerSearchClearButton")
    }

    private var capsuleBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(isFieldFocused ? 0.88 : (isHovered ? 0.65 : 0.45)))
            )
    }

    private var capsuleBorder: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(
                isFieldFocused
                    ? TTZipTheme.bambooGreen.opacity(0.7)
                    : (isHovered ? Color.primary.opacity(0.18) : Color.primary.opacity(0.10)),
                lineWidth: 0.5
            )
    }

    private var shortcutTriggerButton: some View {
        Button("") {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                isExpanded = true
            }
            isFieldFocused = true
        }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
    }

    private var isArchiveContext: Bool {
        if viewModel.explorerState.currentArchivePath != nil {
            return true
        }
        let nav = viewModel.navigationState
        guard AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(nav.currentDirectory) else { return false }
        return viewModel.explorerState.acceptedArchiveProjection(
            for: nav.activeSessionID,
            archivePath: nav.currentDirectory.path
        ) != nil
    }

    private var dynamicPlaceholder: String {
        if capsuleWidth < 148 || isCompact {
            if isArchiveContext {
                return l10n.uiString(zh: "搜索归档", en: "Search archive")
            }
            return l10n.t(L10n.Common.search)
        }
        if isArchiveContext {
            return l10n.uiString(zh: "搜索当前归档", en: "Search archive")
        }
        return l10n.uiString(zh: "搜索当前目录", en: "Search folder")
    }

    private var searchTooltipText: String {
        let currentName = TTZipPathPresentationService.shared.displayName(
            for: viewModel.effectiveDisplayDirectory,
            language: l10n.currentLanguage
        )
        let scopedDesc = l10n.format(L10n.Search.searchInFolder, currentName)
        let omnibarDesc = l10n.t(L10n.Menu.omnibar)
        return "\(scopedDesc) (⌘F) · \(omnibarDesc) (⌘K)"
    }
}
