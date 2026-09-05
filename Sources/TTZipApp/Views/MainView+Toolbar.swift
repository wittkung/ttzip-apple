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
            if viewModel.currentArchivePath != nil {
                Button { pickAndOpenArchive() } label: { Label(l10n.t(L10n.Menu.openArchive), systemImage: "folder.badge.plus") }
                    .keyboardShortcut("o", modifiers: [.command])
                
                Button { withAnimation { viewModel.openCompressWorkspace() } } label: { Label(l10n.t(L10n.Menu.newArchiveMenu), systemImage: "archivebox.circle") }
                    .keyboardShortcut("n", modifiers: [.command])
                
                if viewModel.activeTab == .home {
                    Button {
                        if let targetPath = viewModel.selectedDiskItem?.path ?? viewModel.currentArchivePath {
                            Task { await viewModel.quickExtractArchive(archivePath: targetPath) }
                        } else {
                            viewModel.statusMessage = l10n.t(L10n.Explorer.extractToPrompt)
                        }
                    } label: { Label(l10n.t(L10n.Extract.action), systemImage: "arrow.down.circle.fill") }
                    .keyboardShortcut("e", modifiers: [.command])
                    
                    Button { viewModel.showExtractModal = true } label: { Label(l10n.t(L10n.Explorer.extractToPrompt), systemImage: "slider.horizontal.3") }
                    .keyboardShortcut("e", modifiers: [.option, .command])
                    
                    Button { withAnimation { viewModel.reset() } } label: { Label(l10n.t(L10n.Common.close), systemImage: "xmark.circle") }
                    .keyboardShortcut("w", modifiers: [.command])
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
        }
    }
    
    func openArchiveFromURL(_ url: URL) {
        let path = url.path
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            viewModel.openCompressWorkspace(paths: [path])
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
