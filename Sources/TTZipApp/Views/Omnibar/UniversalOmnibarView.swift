// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipUI

/// Workspace Header Universal Omnibar Capsule.
///
/// Features dual-mode interaction:
/// 1. Browsing Mode: segmented interactive breadcrumb navigation with quick-jump shortcuts.
/// 2. Search & Command Mode: full-text and prefix-aware search input with floating results palette.
public struct UniversalOmnibarView: View {
    // MARK: - Dependencies

    public var viewModel: AppViewState

    // MARK: - State

    @StateObject private var engine = OmniSearchEngine()
    @State private var isEditing: Bool = false
    @State private var inputText: String = ""
    @State private var selectedIndex: Int = 0
    @State private var isHoveringCapsule: Bool = false

    // MARK: - Constants

    private let capsuleHeight: CGFloat = 34.0
    private let paletteTopGap: CGFloat = 6.0
    private let minPaletteWidth: CGFloat = 460.0
    private let maxPaletteWidth: CGFloat = 640.0

    // MARK: - Initialization

    public init(viewModel: AppViewState) {
        self.viewModel = viewModel
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            capsuleContent
        }
        .frame(height: capsuleHeight)
        .background(capsuleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(capsuleBorder)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringCapsule = hovering
        }
        .overlay(alignment: .top) {
            if isEditing {
                UniversalOmniPaletteView(
                    engine: engine,
                    selectedIndex: $selectedIndex,
                    onCommit: { item in
                        commitSelectedItem(item)
                    },
                    onDismiss: {
                        cancelEditing()
                    }
                )
                .frame(minWidth: minPaletteWidth, maxWidth: maxPaletteWidth)
                .offset(y: capsuleHeight + paletteTopGap)
                .zIndex(1000)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                    removal: .opacity
                ))
            }
        }
        .background(keyboardShortcutTriggers)
        .onChange(of: viewModel.navigationState.isOmnibarFocused) { _, isFocused in
            if isFocused {
                beginEditing()
                viewModel.navigationState.isOmnibarFocused = false
            }
        }
        .onChange(of: viewModel.currentDirectory) { _, newDir in
            engine.currentDirectory = newDir
        }
        .onAppear {
            engine.currentDirectory = viewModel.currentDirectory
        }
    }

    // MARK: - Capsule Content

    @ViewBuilder
    private var capsuleContent: some View {
        if isEditing {
            editingInputBar
        } else {
            browsingBreadcrumbsBar
        }
    }

    // MARK: - Mode 1: Browsing Breadcrumbs

    private var browsingBreadcrumbsBar: some View {
        HStack(spacing: 6) {
            // Left folder icon indicator
            Image(systemName: "folder.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TTZipTheme.bambooGreen)
                .padding(.leading, 10)

            // Segmented breadcrumb trail
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let crumbs = buildBreadcrumbs()
                    ForEach(crumbs) { crumb in
                        breadcrumbSegment(for: crumb)

                        if !crumb.isCurrent {
                            Image(systemName: "chevron.forward")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.secondary.opacity(0.45))
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer(minLength: 8)

            // Right search shortcut badge
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TTZipTheme.bambooGreen)

                Text("⌘K")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
            .padding(.trailing, 10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            beginEditing()
        }
    }

    private func breadcrumbSegment(for crumb: BreadcrumbItem) -> some View {
        Button {
            viewModel.currentDirectory = crumb.url
        } label: {
            HStack(spacing: 3.5) {
                if let icon = crumb.iconName {
                    Image(systemName: icon)
                        .font(.system(size: 9.5))
                        .foregroundStyle(crumb.isCurrent ? Color.primary : Color.secondary)
                }

                Text(crumb.name)
                    .font(.system(size: 11.5, weight: crumb.isCurrent ? .semibold : .regular))
                    .foregroundStyle(crumb.isCurrent ? Color.primary : Color.secondary.opacity(0.9))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(crumb.isCurrent ? Color.primary.opacity(0.04) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mode 2: Search & Command Editing

    private var editingInputBar: some View {
        HStack(spacing: 8) {
            // Mode prefix indicator icon
            inputPrefixIcon
                .padding(.leading, 10)

            // High performance AppKit textfield wrapper with IME protection
            OmnibarTextField(
                text: $inputText,
                placeholder: "搜索应用、文件、路径或输入 > 执行指令 (⌘K)",
                isFocused: isEditing,
                onCommit: {
                    handleCommit()
                },
                onCancel: {
                    cancelEditing()
                },
                onTab: {
                    handleTabAutocomplete()
                },
                onMoveDown: {
                    handleMoveSelection(direction: 1)
                },
                onMoveUp: {
                    handleMoveSelection(direction: -1)
                },
                onTextChange: { newText in
                    engine.query = newText
                    selectedIndex = 0
                }
            )
            .frame(height: 24)

            // Trailing action / escape badge
            HStack(spacing: 4) {
                if !inputText.isEmpty {
                    Button {
                        inputText = ""
                        engine.query = ""
                        selectedIndex = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }

                Text("Esc")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
            .padding(.trailing, 10)
        }
    }

    @ViewBuilder
    private var inputPrefixIcon: some View {
        if engine.query.hasPrefix(">") {
            Image(systemName: "terminal.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TTZipTheme.kintsugiGold)
        } else if engine.query.contains("/") || engine.query.hasPrefix("~") {
            Image(systemName: "folder.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TTZipTheme.bambooGreen)
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TTZipTheme.bambooGreen)
        }
    }

    // MARK: - Actions & Navigation

    private func beginEditing() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isEditing = true
            inputText = ""
            engine.query = ""
            engine.currentDirectory = viewModel.currentDirectory
            selectedIndex = 0
        }
    }

    private func cancelEditing() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isEditing = false
            inputText = ""
            engine.query = ""
            selectedIndex = 0
        }
    }

    private func handleCommit() {
        if engine.flatResults.indices.contains(selectedIndex) {
            commitSelectedItem(engine.flatResults[selectedIndex])
        } else {
            // Direct path fallback
            let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let expanded = (trimmed as NSString).expandingTildeInPath
                let targetURL = URL(fileURLWithPath: expanded)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        viewModel.currentDirectory = targetURL
                    } else {
                        commitFile(url: targetURL)
                    }
                }
            }
            cancelEditing()
        }
    }

    private func commitSelectedItem(_ item: OmniSearchItem) {
        switch item.payload {
        case .application(let url):
            AppCatalogService.shared.launchApp(at: url)
        case .directory(let url):
            viewModel.currentDirectory = url
        case .file(let url):
            commitFile(url: url)
        case .command(_, let action):
            action()
        }
        cancelEditing()
    }

    private func commitFile(url: URL) {
        let ext = url.pathExtension.lowercased()
        let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst"]
        if archiveExtensions.contains(ext) {
            viewModel.openArchiveAsFolder(url: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func handleTabAutocomplete() -> Bool {
        guard engine.flatResults.indices.contains(selectedIndex) else { return false }
        let item = engine.flatResults[selectedIndex]

        if case .directory(let dirURL) = item.payload {
            let pathWithSlash = dirURL.path.hasSuffix("/") ? dirURL.path : dirURL.path + "/"
            inputText = pathWithSlash
            engine.query = pathWithSlash
            engine.currentDirectory = dirURL
            selectedIndex = 0
            return true
        }

        return false
    }

    private func handleMoveSelection(direction: Int) -> Bool {
        guard !engine.flatResults.isEmpty else { return false }
        let count = engine.flatResults.count
        selectedIndex = (selectedIndex + direction + count) % count
        return true
    }

    // MARK: - Breadcrumb Computation

    private func buildBreadcrumbs() -> [BreadcrumbItem] {
        var items: [BreadcrumbItem] = []
        let homeURL = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        let current = viewModel.currentDirectory.standardizedFileURL

        if current.path == "/" {
            items.append(BreadcrumbItem(
                id: "/",
                name: "Macintosh HD",
                iconName: "internaldrive",
                url: URL(fileURLWithPath: "/"),
                isCurrent: true
            ))
            return items
        }

        if current.path == homeURL.path {
            items.append(BreadcrumbItem(
                id: homeURL.path,
                name: "~",
                iconName: "house.fill",
                url: homeURL,
                isCurrent: true
            ))
            return items
        }

        if current.path.hasPrefix(homeURL.path) {
            items.append(BreadcrumbItem(
                id: homeURL.path,
                name: "~",
                iconName: "house.fill",
                url: homeURL,
                isCurrent: false
            ))
            let relativePath = String(current.path.dropFirst(homeURL.path.count))
            let segments = relativePath.split(separator: "/").map(String.init)
            var cumulative = homeURL
            for (idx, seg) in segments.enumerated() {
                cumulative.appendPathComponent(seg)
                let isLast = (idx == segments.count - 1)
                items.append(BreadcrumbItem(
                    id: cumulative.path,
                    name: seg,
                    iconName: nil,
                    url: cumulative,
                    isCurrent: isLast
                ))
            }
        } else {
            items.append(BreadcrumbItem(
                id: "/",
                name: "/",
                iconName: "internaldrive",
                url: URL(fileURLWithPath: "/"),
                isCurrent: false
            ))
            let segments = current.path.split(separator: "/").map(String.init)
            var cumulative = URL(fileURLWithPath: "/")
            for (idx, seg) in segments.enumerated() {
                cumulative.appendPathComponent(seg)
                let isLast = (idx == segments.count - 1)
                items.append(BreadcrumbItem(
                    id: cumulative.path,
                    name: seg,
                    iconName: nil,
                    url: cumulative,
                    isCurrent: isLast
                ))
            }
        }

        return items
    }

    // MARK: - Capsule Background & Borders

    private var capsuleBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color(nsColor: .controlBackgroundColor).opacity(isEditing ? 0.88 : (isHoveringCapsule ? 0.76 : 0.65))
        }
    }

    private var capsuleBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(
                isEditing
                    ? TTZipTheme.bambooGreen.opacity(0.4)
                    : (isHoveringCapsule ? Color.primary.opacity(0.18) : Color.primary.opacity(0.12)),
                lineWidth: isEditing ? 1.0 : 0.5
            )
    }

    // MARK: - Global Hotkeys

    private var keyboardShortcutTriggers: some View {
        Group {
            Button("") {
                if isEditing {
                    cancelEditing()
                } else {
                    beginEditing()
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0)

            Button("") {
                if isEditing {
                    cancelEditing()
                } else {
                    beginEditing()
                }
            }
            .keyboardShortcut("l", modifiers: .command)
            .opacity(0)
        }
    }
}

// MARK: - Breadcrumb Data Structure

private struct BreadcrumbItem: Identifiable, Hashable {
    let id: String
    let name: String
    let iconName: String?
    let url: URL
    let isCurrent: Bool
}
