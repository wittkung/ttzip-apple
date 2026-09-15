// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipUI
import TTZipPreviewKit

/// Dedicated Spotlight Search Capsule with interactive floating command and results palette.
///
/// Provides rapid search, application launching, directory jumping, and command palette triggers (⌘K).
public struct SpotlightSearchCapsuleView: View {
    // MARK: - Dependencies
    public var viewModel: AppViewState

    // MARK: - State
    @State private var engine = OmniSearchEngine()
    @State private var isEditing: Bool = false
    @State private var inputText: String = ""
    @State private var selectedIndex: Int = 0
    @State private var isHoveringCapsule: Bool = false

    private let capsuleHeight: CGFloat = 30.0
    private var l10n = AppLocalizationState.shared

    public init(viewModel: AppViewState) {
        self.viewModel = viewModel
    }

    private var isChinese: Bool {
        l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
    }

    public var body: some View {
        ZStack {
            if isEditing {
                editingInputBar
            } else {
                collapsedSearchBar
            }
        }
        .frame(height: capsuleHeight)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color(nsColor: .controlBackgroundColor).opacity(isEditing ? 0.88 : (isHoveringCapsule ? 0.65 : 0.5))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isEditing
                        ? TTZipTheme.bambooGreen.opacity(0.45)
                        : (isHoveringCapsule ? Color.white.opacity(0.2) : Color.white.opacity(0.1)),
                    lineWidth: isEditing ? 1.0 : 0.5
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHoveringCapsule = hovering
            }
        }
        .overlay(alignment: .top) {
            if isEditing {
                Color.black.opacity(0.001)
                    .frame(width: 4000, height: 4000)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        cancelEditing()
                    }
                    .zIndex(998)

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
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: 38)
                .zIndex(1000)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                    removal: .opacity
                ))
            }
        }
        .background(keyboardShortcutTriggers)
        .onChange(of: selectedIndex) { _, newIndex in
            engine.selectIndex(newIndex)
        }
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

    // MARK: - Collapsed Search Capsule

    private var collapsedSearchBar: some View {
        Button {
            beginEditing()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHoveringCapsule ? TTZipTheme.bambooGreen : Color.white.opacity(0.75))

                Text(isChinese ? "搜索或跳转..." : "Search or jump...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("⌘K")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isHoveringCapsule ? Color.white : Color.white.opacity(0.65))
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(Color.white.opacity(isHoveringCapsule ? 0.12 : 0.06))
                    )
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 140, idealWidth: 180, maxWidth: 220)
    }

    // MARK: - Active Search Input Bar

    private var editingInputBar: some View {
        HStack(spacing: 6) {
            inputPrefixIcon
                .padding(.leading, 8)

            OmnibarTextField(
                text: $inputText,
                placeholder: isChinese ? "搜索应用、文件、路径或输入 > 执行指令" : "Search files, apps, paths or type >",
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
            .frame(height: 22)

            HStack(spacing: 4) {
                if !inputText.isEmpty {
                    Button {
                        inputText = ""
                        engine.query = ""
                        selectedIndex = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }

                Text("Esc")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .padding(.trailing, 8)
        }
        .frame(minWidth: 280, maxWidth: .infinity)
    }

    @ViewBuilder
    private var inputPrefixIcon: some View {
        if engine.query.hasPrefix(">") {
            Image(systemName: "terminal.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(TTZipTheme.kintsugiGold)
        } else if engine.query.contains("/") || engine.query.hasPrefix("~") {
            Image(systemName: "folder.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(TTZipTheme.bambooGreen)
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(TTZipTheme.bambooGreen)
        }
    }

    // MARK: - Handlers

    private func beginEditing() {
        withAnimation(.easeInOut(duration: 0.12)) {
            isEditing = true
            inputText = ""
            engine.query = ""
            engine.currentDirectory = viewModel.currentDirectory
            selectedIndex = 0
            engine.selectIndex(0)
        }
    }

    private func cancelEditing() {
        withAnimation(.easeInOut(duration: 0.12)) {
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
        if MediaPreviewFactory.archiveExtensions.contains(ext) {
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

            Button("") {
                if isEditing {
                    cancelEditing()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
        }
    }
}
