// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import TTZipCore
import TTZipUI

extension TTZipContextMenuBuilder {
    // MARK: - Virtual Archive Entry Menu Assembly
    
    internal func buildVirtualArchiveEntryMenu(
        menu: NSMenu,
        archivePath: String,
        subpath: String,
        isDirectory: Bool
    ) {
        let l10n = AppLocalizationState.shared
        appendVirtualEntryExtractionItems(menu: menu, archivePath: archivePath, subpath: subpath, l10n: l10n)
        menu.addItem(NSMenuItem.separator())
        appendVirtualEntryMutationItems(
            menu: menu,
            archivePath: archivePath,
            subpath: subpath,
            isDirectory: isDirectory,
            l10n: l10n
        )
        menu.addItem(NSMenuItem.separator())

        let copySubpathItem = makeActionItem(
            title: l10n.t(L10n.Menu.copySubpath),
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil),
            keyEquivalent: "c",
            modifierMask: .command
        ) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(subpath, forType: .string)
        }
        menu.addItem(copySubpathItem)
    }

    private func appendVirtualEntryExtractionItems(
        menu: NSMenu,
        archivePath: String,
        subpath: String,
        l10n: AppLocalizationState
    ) {
        let extractItem = makeActionItem(
            title: l10n.t(L10n.Extract.extractSelected),
            image: NSImage(systemSymbolName: "arrow.down.doc.fill", accessibilityDescription: nil)
        ) {
            let destDir = URL(fileURLWithPath: (archivePath as NSString).deletingLastPathComponent, isDirectory: true)
            Self.dispatchEntryExtraction(archivePath: archivePath, subpath: subpath, destination: destDir)
        }
        menu.addItem(extractItem)

        let extractToItem = makeActionItem(
            title: l10n.t(L10n.Menu.extractTo),
            image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        ) { [weak self] in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = l10n.t(L10n.Extract.action)
            self?.presentOpenPanelSheet(with: panel) { destURL in
                Self.dispatchEntryExtraction(archivePath: archivePath, subpath: subpath, destination: destURL)
            }
        }
        menu.addItem(extractToItem)
    }

    private func appendVirtualEntryMutationItems(
        menu: NSMenu,
        archivePath: String,
        subpath: String,
        isDirectory: Bool,
        l10n: AppLocalizationState
    ) {
        if !isDirectory {
            let replaceItem = makeActionItem(
                title: l10n.t(L10n.Menu.replaceWith),
                image: NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            ) { [weak self] in
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowsMultipleSelection = false
                panel.prompt = l10n.t(L10n.Menu.replace)
                self?.presentOpenPanelSheet(with: panel) { chosenURL in
                    Task {
                        let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                        try? await Self.replaceVirtualEntryHandler?(
                            archivePath,
                            subpath,
                            chosenURL.path,
                            pwd
                        )
                    }
                }
            }
            menu.addItem(replaceItem)
        }

        let deleteItem = makeActionItem(
            title: l10n.t(L10n.Menu.delete),
            image: NSImage(systemSymbolName: "trash", accessibilityDescription: nil),
            keyEquivalent: "\u{08}",
            modifierMask: .command
        ) {
            Task {
                let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                try? await Self.deleteVirtualEntriesHandler?(
                    archivePath,
                    [subpath],
                    pwd
                )
            }
        }
        menu.addItem(deleteItem)
    }
    
    // MARK: - Column Background Menu Assembly
    
    internal func buildColumnBackgroundMenu(menu: NSMenu, directoryURL: URL) {
        let l10n = AppLocalizationState.shared
        let newFolderTitle = l10n.t(L10n.Explorer.newFolder)
        let newFolderItem = makeActionItem(
            title: newFolderTitle,
            image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil),
            keyEquivalent: "n",
            modifierMask: [.command, .shift]
        ) {
            Self.createNewFolder(in: directoryURL)
        }
        menu.addItem(newFolderItem)
        
        let newFileTitle = l10n.t(L10n.Menu.newFile)
        let newFileItem = makeActionItem(
            title: newFileTitle,
            image: NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil),
            keyEquivalent: "n",
            modifierMask: .command
        ) {
            Self.createNewFile(in: directoryURL)
        }
        menu.addItem(newFileItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let pasteTitle = l10n.t(L10n.Common.paste)
        let pasteItem = makeActionItem(
            title: pasteTitle,
            image: NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil),
            keyEquivalent: "v",
            modifierMask: .command
        ) {
            FileClipboardStore.shared.paste(to: directoryURL)
        }
        pasteItem.isEnabled = FileClipboardStore.shared.canPaste
        menu.addItem(pasteItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let revealTitle = l10n.t(L10n.Common.revealInFinder)
        let revealItem = makeActionItem(
            title: revealTitle,
            image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        ) {
            NSWorkspace.shared.selectFile(directoryURL.path, inFileViewerRootedAtPath: "")
        }
        menu.addItem(revealItem)
    }
    
    // MARK: - Archive Entry Extraction

    /// Hands a single-entry extraction to AppViewState via the intent dispatcher, which applies the
    /// user's collision preference, progress reporting and error surfacing.
    internal static func dispatchEntryExtraction(archivePath: String, subpath: String, destination: URL) {
        let options = ExtractIntentOptions(
            destinationDirectory: destination,
            isSmartExtract: false,
            targetEntrySubpaths: [subpath]
        )
        AppIntentRouter.dispatch(
            .extractArchive(archivePaths: [archivePath], options: options),
            from: .contextMenu
        )
    }
    
    // MARK: - Filesystem Creation Helpers
    
    internal static func createNewFolder(in directoryURL: URL) {
        let l10n = AppLocalizationState.shared
        let baseName = l10n.t(L10n.Explorer.untitledFolder)
        var targetURL = directoryURL.appendingPathComponent(baseName)
        var counter = 2
        while FileManager.default.fileExists(atPath: targetURL.path) {
            let name = l10n.format(L10n.Explorer.untitledFolderFormat, counter)
            targetURL = directoryURL.appendingPathComponent(name)
            counter += 1
        }
        try? FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
    }
    
    internal static func createNewFile(in directoryURL: URL) {
        let l10n = AppLocalizationState.shared
        let baseName = l10n.t(L10n.Explorer.untitledFile)
        var targetURL = directoryURL.appendingPathComponent("\(baseName).txt")
        var counter = 2
        while FileManager.default.fileExists(atPath: targetURL.path) {
            let name = l10n.format(L10n.Explorer.untitledFileFormat, baseName, counter)
            targetURL = directoryURL.appendingPathComponent(name)
            counter += 1
        }
        FileManager.default.createFile(atPath: targetURL.path, contents: Data())
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
    }
}
