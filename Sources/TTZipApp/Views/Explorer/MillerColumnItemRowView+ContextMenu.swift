// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore

public struct MillerColumnItemContextMenu: View {
    @ObservedObject private var l10n = AppLocalizationState.shared
    
    public let item: DiskItemInfo
    public let columnIndex: Int
    public let dirURL: URL
    public let multiSelectedPaths: Set<String>
    public let onSelectArchive: (String) -> Void
    public let onCompressPath: (String) -> Void
    public let onSelectItem: (DiskItemInfo, Int, Bool, Bool, URL?) -> Void
    public let onTriggerNewFolder: (URL) -> Void
    public let onTriggerNewFile: (URL) -> Void
    
    public init(
        item: DiskItemInfo,
        columnIndex: Int,
        dirURL: URL,
        multiSelectedPaths: Set<String>,
        onSelectArchive: @escaping (String) -> Void,
        onCompressPath: @escaping (String) -> Void,
        onSelectItem: @escaping (DiskItemInfo, Int, Bool, Bool, URL?) -> Void,
        onTriggerNewFolder: @escaping (URL) -> Void,
        onTriggerNewFile: @escaping (URL) -> Void
    ) {
        self.item = item
        self.columnIndex = columnIndex
        self.dirURL = dirURL
        self.multiSelectedPaths = multiSelectedPaths
        self.onSelectArchive = onSelectArchive
        self.onCompressPath = onCompressPath
        self.onSelectItem = onSelectItem
        self.onTriggerNewFolder = onTriggerNewFolder
        self.onTriggerNewFile = onTriggerNewFile
    }
    
    public var body: some View {
        Button {
            onSelectItem(item, columnIndex, false, false, dirURL)
        } label: {
            Text("\(item.name)")
        }
        .disabled(true)
        
        Divider()
        
        if multiSelectedPaths.count > 1 && multiSelectedPaths.contains(item.path) {
            Button {
                let targets = Array(multiSelectedPaths).map { URL(fileURLWithPath: $0) }
                FileClipboardStore.shared.copy(urls: targets)
            } label: {
                Label("\(l10n.t(L10n.Common.copy)) (\(multiSelectedPaths.count))", systemImage: "doc.on.doc")
            }
            
            Button {
                let targets = Array(multiSelectedPaths).map { URL(fileURLWithPath: $0) }
                FileClipboardStore.shared.cut(urls: targets)
            } label: {
                Label("\(l10n.t(L10n.Menu.cut)) (\(multiSelectedPaths.count))", systemImage: "scissors")
            }
            
            Divider()
            
            Button {
                AppIntentDispatcher.shared.dispatch(.createArchive(sourcePaths: Array(multiSelectedPaths), options: CompressIntentOptions()), from: .contextMenu)
            } label: {
                Label("\(l10n.t(L10n.Sidebar.newArchive)) (\(multiSelectedPaths.count))...", systemImage: "archivebox.fill")
            }
            
            Button {
                for path in multiSelectedPaths {
                    let u = URL(fileURLWithPath: path)
                    try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
                }
                NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
            } label: {
                Label("\(l10n.t(L10n.Common.delete)) (\(multiSelectedPaths.count))", systemImage: "trash")
            }
        } else if item.path.contains("?subpath=") {
            Button {
                onSelectItem(item, columnIndex, false, false, dirURL)
                let (archivePath, subpath) = MillerColumnItemRowView.parseVirtualURL(item.path)
                let destDir = (archivePath as NSString).deletingLastPathComponent
                Task {
                    let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                    try? await TTZipEngineFacade.shared.extractSingleEntry(archivePath: archivePath, entryPath: subpath, destinationDir: destDir, password: pwd)
                    NSWorkspace.shared.selectFile((destDir as NSString).appendingPathComponent(item.name), inFileViewerRootedAtPath: "")
                }
            } label: {
                Label(l10n.t(L10n.FinderSync.extractHereTitle), systemImage: "arrow.down.doc.fill")
            }
            
            Button {
                onSelectItem(item, columnIndex, false, false, dirURL)
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let destURL = panel.url {
                    let (archivePath, subpath) = MillerColumnItemRowView.parseVirtualURL(item.path)
                    Task {
                        let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                        try? await TTZipEngineFacade.shared.extractSingleEntry(archivePath: archivePath, entryPath: subpath, destinationDir: destURL.path, password: pwd)
                        NSWorkspace.shared.selectFile((destURL.path as NSString).appendingPathComponent(item.name), inFileViewerRootedAtPath: "")
                    }
                }
            } label: {
                Label(l10n.t(L10n.Explorer.extractToPrompt), systemImage: "folder.badge.plus")
            }
            
            Divider()
            
            if !item.isDirectory {
                Button {
                    onSelectItem(item, columnIndex, false, false, dirURL)
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Replace"
                    if panel.runModal() == .OK, let chosenURL = panel.url {
                        let (archivePath, subpath) = MillerColumnItemRowView.parseVirtualURL(item.path)
                        Task {
                            let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                            try? await InPlaceMutationCoordinator.shared.replaceEntry(
                                archivePath: archivePath,
                                entryPath: subpath,
                                sourceFilePath: chosenURL.path,
                                password: pwd
                            )
                        }
                    }
                } label: {
                    Label("Replace with...", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            
            Button(role: .destructive) {
                onSelectItem(item, columnIndex, false, false, dirURL)
                let (archivePath, subpath) = MillerColumnItemRowView.parseVirtualURL(item.path)
                Task {
                    let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                    try? await InPlaceMutationCoordinator.shared.deleteEntries(
                        archivePath: archivePath,
                        entryPaths: [subpath],
                        password: pwd
                    )
                }
            } label: {
                Label(l10n.t(L10n.Common.delete), systemImage: "trash")
            }
            
            Divider()
            
            Button {
                let (_, subpath) = MillerColumnItemRowView.parseVirtualURL(item.path)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(subpath, forType: .string)
            } label: {
                Label(l10n.t(L10n.Common.copy), systemImage: "doc.on.doc")
            }
        } else {
            Button {
                onSelectItem(item, columnIndex, false, false, dirURL)
                FileClipboardStore.shared.copy(urls: [URL(fileURLWithPath: item.path)])
            } label: {
                Label(l10n.t(L10n.Common.copy), systemImage: "doc.on.doc")
            }
            
            Button {
                onSelectItem(item, columnIndex, false, false, dirURL)
                FileClipboardStore.shared.cut(urls: [URL(fileURLWithPath: item.path)])
            } label: {
                Label(l10n.t(L10n.Menu.cut), systemImage: "scissors")
            }
            
            if item.isDirectory {
                Button {
                    onSelectItem(item, columnIndex, false, false, dirURL)
                    FileClipboardStore.shared.paste(to: URL(fileURLWithPath: item.path))
                } label: {
                    Label(l10n.t(L10n.Common.paste), systemImage: "doc.on.clipboard")
                }
                .disabled(!FileClipboardStore.shared.canPaste)
            }
            
            Divider()
            
            Button {
                onSelectItem(item, columnIndex, false, false, dirURL)
                let u = URL(fileURLWithPath: item.path)
                NSWorkspace.shared.open(u)
            } label: {
                Label(l10n.t(L10n.Common.openFiles), systemImage: "arrow.up.forward.app")
            }
            
            Button {
                onSelectItem(item, columnIndex, false, false, dirURL)
                AppIntentDispatcher.shared.dispatch(.previewItem(url: URL(fileURLWithPath: item.path)), from: .contextMenu)
            } label: {
                Label(l10n.t(L10n.Explorer.quickLook), systemImage: "eye")
            }
            
            Button {
                onSelectItem(item, columnIndex, false, false, dirURL)
                AppIntentDispatcher.shared.dispatch(.revealInFinder(url: URL(fileURLWithPath: item.path)), from: .contextMenu)
            } label: {
                Label(l10n.t(L10n.Common.revealInFinder), systemImage: "folder")
            }
            
            Button {
                onSelectItem(item, columnIndex, false, false, dirURL)
                onTriggerNewFolder(item.isDirectory ? URL(fileURLWithPath: item.path) : dirURL)
            } label: {
                Label(l10n.t(L10n.Explorer.newFolder), systemImage: "folder.badge.plus")
            }
            
            Button {
                onSelectItem(item, columnIndex, false, false, dirURL)
                onTriggerNewFile(item.isDirectory ? URL(fileURLWithPath: item.path) : dirURL)
            } label: {
                Label(l10n.t(L10n.Explorer.newFile), systemImage: "doc.badge.plus")
            }
            
            Divider()
            
            if item.isArchive {
                Button {
                    onSelectItem(item, columnIndex, false, false, dirURL)
                    AppIntentDispatcher.shared.dispatch(.openArchive(url: URL(fileURLWithPath: item.path), password: nil), from: .contextMenu)
                } label: {
                    Label(l10n.t(L10n.Sidebar.homeAndExtract), systemImage: "sidebar.right")
                }
                
                Button {
                    onSelectItem(item, columnIndex, false, false, dirURL)
                    AppIntentDispatcher.shared.dispatch(.extractArchive(archivePaths: [item.path], options: ExtractIntentOptions(isSmartExtract: false)), from: .contextMenu)
                } label: {
                    Label(l10n.t(L10n.FinderSync.extractHereTitle), systemImage: "arrow.down.circle.fill")
                }
                
                Button {
                    onSelectItem(item, columnIndex, false, false, dirURL)
                    AppIntentDispatcher.shared.dispatch(.inspectArchive(archivePath: item.path), from: .contextMenu)
                } label: {
                    Label(l10n.t(L10n.Diagnostics.title), systemImage: "doc.badge.gearshape")
                }
                
                Button {
                    onSelectItem(item, columnIndex, false, false, dirURL)
                    AppIntentDispatcher.shared.dispatch(.promptPassword(archivePath: item.path), from: .contextMenu)
                } label: {
                    Label(l10n.t(L10n.Extract.passwordPrompt), systemImage: "key.fill")
                }
            } else {
                Button {
                    onSelectItem(item, columnIndex, false, false, dirURL)
                    AppIntentDispatcher.shared.dispatch(.createArchive(sourcePaths: [item.path], options: CompressIntentOptions()), from: .contextMenu)
                } label: {
                    Label(l10n.t(L10n.Sidebar.newArchive), systemImage: "archivebox.fill")
                }
            }
            
            Divider()
            
            Button(role: .destructive) {
                onSelectItem(item, columnIndex, false, false, dirURL)
                let u = URL(fileURLWithPath: item.path)
                try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
                NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
            } label: {
                Label(l10n.t(L10n.Common.delete), systemImage: "trash")
            }
        }
    }
}
