// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import AppKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

extension MainView {
    @ToolbarContentBuilder
    var mainToolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isLeftSidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isLeftSidebarVisible ? TTZipTheme.bambooGreen : .secondary)
                    .frame(height: 24)
            }
            .help(l10n.currentLanguage == .zhHans ? "切换常用目录边栏 (⌃⌘S)" : "Toggle Favorites Sidebar (⌃⌘S)")
            .keyboardShortcut("s", modifiers: [.control, .command])
        }
        
        ToolbarItemGroup(placement: .automatic) {
            Button { pickAndOpenArchive() } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 24)
            }
            .keyboardShortcut("o", modifiers: [.command])
            .help(l10n.t(L10n.Menu.openArchive) + " (⌘O)")
            .accessibilityLabel(l10n.t(L10n.Menu.openArchive))
            
            NewArchiveToolbarButton(
                title: l10n.currentLanguage == .zhHans ? "新建压缩" : "New Archive"
            ) {
                withAnimation {
                    viewModel.openCompressWorkspace()
                    viewModel.showCompressModal = true
                }
            }
            .keyboardShortcut("n", modifiers: [.command])
            .help(l10n.t(L10n.Menu.newArchiveMenu) + " (⌘N)")
            
            if viewModel.currentArchivePath != nil {
                if viewModel.activeTab == .home {
                    Button {
                        if let targetPath = viewModel.selectedDiskItem?.path ?? viewModel.currentArchivePath {
                            Task { await viewModel.quickExtractArchive(archivePath: targetPath) }
                        } else {
                            viewModel.statusMessage = l10n.t(L10n.Explorer.extractToPrompt)
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(height: 24)
                    }
                    .keyboardShortcut("e", modifiers: [.command])
                    .help(l10n.t(L10n.Extract.action) + " (⌘E)")
                    .accessibilityLabel(l10n.t(L10n.Extract.action))
                    
                    Button { viewModel.showExtractModal = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(height: 24)
                    }
                    .keyboardShortcut("e", modifiers: [.option, .command])
                    .help(l10n.t(L10n.Explorer.extractToPrompt) + " (⌥⌘E)")
                    .accessibilityLabel(l10n.t(L10n.Explorer.extractToPrompt))
                    
                    Button { withAnimation { viewModel.reset() } } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(height: 24)
                    }
                    .keyboardShortcut("w", modifiers: [.command])
                    .help(l10n.t(L10n.Common.close) + " (⌘W)")
                    .accessibilityLabel(l10n.t(L10n.Common.close))
                }
            }
            
            if viewModel.activePreviewFileURL != nil {
                Button {
                    NotificationCenter.default.post(name: NSNotification.Name("TTZipToggleMediaFocusNotification"), object: nil)
                } label: {
                    Image(
                        systemName: viewModel.navigationState.layoutMode == .mediaFocus
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 24)
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .help("Toggle Media Focus Mode (⌃⌘F)")
                .accessibilityLabel(viewModel.navigationState.layoutMode == .mediaFocus ? "Exit Focus" : "Focus Mode")
            }
            
            Menu {
                Button {
                    presentedSecondaryTool = .presets
                } label: {
                    Label(l10n.t(L10n.Sidebar.presets), systemImage: "slider.horizontal.3")
                }
                
                Button {
                    presentedSecondaryTool = .benchmark
                } label: {
                    Label(l10n.t(L10n.Sidebar.benchmark), systemImage: "speedometer")
                }
                
                Button {
                    presentedSecondaryTool = .vault
                } label: {
                    Label(l10n.t(L10n.Sidebar.vault), systemImage: "key.fill")
                }
                
                Divider()
                
                Button {
                    presentedSecondaryTool = .plugins
                } label: {
                    Label(l10n.currentLanguage == .zhHans ? "插件中心" : "Extensions", systemImage: "puzzlepiece.extension.fill")
                }
                
                ForEach(registry.sidebarItems, id: \.id) { contribution in
                    let targetPluginId = registry.installedPlugins.first(where: { $0.sidebarItem?.id == contribution.id })?.manifest.id ?? contribution.id
                    Button {
                        presentedSecondaryTool = .dynamicExtension(pluginId: targetPluginId, tabId: contribution.targetTabIdentifier)
                    } label: {
                        Label(contribution.title, systemImage: contribution.icon)
                    }
                }
                
                Divider()
                
                Button {
                    presentedSecondaryTool = .settings
                } label: {
                    Label(l10n.t(L10n.Sidebar.settings), systemImage: "gearshape.fill")
                }
                .keyboardShortcut(",", modifiers: [.command])
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 24)
            }
            .menuIndicator(.hidden)
            .help(l10n.currentLanguage == .zhHans ? "工具箱" : "Toolbox")
        }
        
        ToolbarItem(placement: .principal) {
            if viewModel.navigationState.layoutMode != .mediaFocus && viewModel.activeTab == .home {
                LiquidGlassOmnibar(
                    searchQuery: $searchQuery,
                    searchService: searchService,
                    viewModel: viewModel,
                    maxContainerWidth: 440
                )
                .frame(minWidth: 200, idealWidth: 360, maxWidth: 460)
            }
        }
        
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isRightSidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isRightSidebarVisible ? TTZipTheme.bambooGreen : .secondary)
                    .frame(height: 24)
            }
            .help(l10n.currentLanguage == .zhHans ? "切换检视器面板 (⌥⌘I)" : "Toggle Inspector Panel (⌥⌘I)")
            .keyboardShortcut("i", modifiers: [.option, .command])
        }
    }
    
    func openArchiveFromURL(_ url: URL) {
        let path = url.path
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            viewModel.openCompressWorkspace(paths: [path])
            viewModel.showCompressModal = true
        } else {
            viewModel.openArchiveAsFolder(url: url)
        }
    }
    
    func pickAndOpenArchive() {
        if let firstPath = SystemDialogHelper.pickFiles(prompt: l10n.t(L10n.Menu.openArchive), canChooseDirectories: false, allowsMultipleSelection: false).first {
            viewModel.openArchiveAsFolder(url: URL(fileURLWithPath: firstPath))
        }
    }
}

// MARK: - New Archive Toolbar Capsule Button

/// A lightweight translucent capsule button conforming to Zen minimalist design and macOS HIG.
/// It renders a bamboo green translucent capsule with delicate border and smooth hover/press transitions.
private struct NewArchiveToolbarButton: View {
    let title: String
    let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .bold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(TTZipTheme.bambooGreen)
            .padding(.horizontal, 9.5)
            .frame(height: 24)
        }
        .buttonStyle(NewArchiveCapsuleButtonStyle(isHovered: isHovered))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

/// A specialized ButtonStyle that manages the multi-state translucent fill and border.
private struct NewArchiveCapsuleButtonStyle: ButtonStyle {
    let isHovered: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        let fillOpacity: Double = configuration.isPressed ? 0.24 : (isHovered ? 0.14 : 0.08)
        let strokeOpacity: Double = isHovered ? 0.35 : 0.18
        
        configuration.label
            .background(
                Capsule()
                    .fill(TTZipTheme.bambooGreen.opacity(fillOpacity))
            )
            .overlay(
                Capsule()
                    .strokeBorder(TTZipTheme.bambooGreen.opacity(strokeOpacity), lineWidth: 0.8)
            )
            .contentShape(Capsule())
    }
}

