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
        ToolbarItemGroup(placement: .automatic) {
            Button { pickAndOpenArchive() } label: {
                Label(l10n.t(L10n.Menu.openArchive), systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("o", modifiers: [.command])
            .help(l10n.t(L10n.Menu.openArchive) + " (⌘O)")
            
            Button {
                withAnimation {
                    viewModel.openCompressWorkspace()
                    viewModel.showCompressModal = true
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text(l10n.currentLanguage == .zhHans ? "新建压缩" : "New Archive")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(TTZipTheme.bambooGreen)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
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
                    } label: { Label(l10n.t(L10n.Extract.action), systemImage: "arrow.down.circle.fill") }
                    .keyboardShortcut("e", modifiers: [.command])
                    .help(l10n.t(L10n.Extract.action) + " (⌘E)")
                    
                    Button { viewModel.showExtractModal = true } label: { Label(l10n.t(L10n.Explorer.extractToPrompt), systemImage: "slider.horizontal.3") }
                    .keyboardShortcut("e", modifiers: [.option, .command])
                    .help(l10n.t(L10n.Explorer.extractToPrompt) + " (⌥⌘E)")
                    
                    Button { withAnimation { viewModel.reset() } } label: { Label(l10n.t(L10n.Common.close), systemImage: "xmark.circle") }
                    .keyboardShortcut("w", modifiers: [.command])
                    .help(l10n.t(L10n.Common.close) + " (⌘W)")
                }
            }
            
            if viewModel.activePreviewFileURL != nil {
                Button {
                    NotificationCenter.default.post(name: NSNotification.Name("TTZipToggleMediaFocusNotification"), object: nil)
                } label: {
                    Label(
                        viewModel.navigationState.layoutMode == .mediaFocus ? "Exit Focus" : "Focus Mode",
                        systemImage: viewModel.navigationState.layoutMode == .mediaFocus ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                    )
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .help("Toggle Media Focus Mode (⌃⌘F)")
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
                    .font(.system(size: 13, weight: .medium))
            }
            .menuIndicator(.hidden)
            .help(l10n.currentLanguage == .zhHans ? "工具箱" : "Toolbox")
            
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isRightSidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isRightSidebarVisible ? TTZipTheme.bambooGreen : .secondary)
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
