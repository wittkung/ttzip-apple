// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import TTZipCore
import TTZipUI

public extension L10n.Common {
    static var newFolder: L10n.Explorer { L10n.Explorer.newFolder }
}

extension TTZipContextMenuBuilder {
    // MARK: - Single Item Menu Assembly
    
    internal func buildSingleItemMenu(menu: NSMenu, url: URL, isDirectory: Bool, isArchive: Bool) {
        // 1. Open & Open With
        appendOpenGroup(menu: menu, url: url, isDirectory: isDirectory)
        menu.addItem(NSMenuItem.separator())
        
        // 2. Archive / Compression action matrix
        appendArchiveOrCompressGroup(menu: menu, url: url, isArchive: isArchive)
        menu.addItem(NSMenuItem.separator())
        
        // 3. Quick Look (Space)
        appendQuickLookItem(menu: menu, url: url)
        menu.addItem(NSMenuItem.separator())
        
        // 4. Rename, Duplicate, New Folder
        appendEditAndFileOpsGroup(menu: menu, url: url, isDirectory: isDirectory)
        menu.addItem(NSMenuItem.separator())
        
        // 5. Copy, Copy Path, Cut, Paste into Folder
        appendClipboardGroup(menu: menu, url: url, isDirectory: isDirectory)
        menu.addItem(NSMenuItem.separator())
        
        // 6. Share & Services
        appendShareAndServicesGroup(menu: menu, url: url)
        menu.addItem(NSMenuItem.separator())
        
        // 7. Reveal in Finder & Move to Trash
        appendRevealAndTrashGroup(menu: menu, url: url)
    }
    
    // MARK: - Action Groups
    
    private func appendOpenGroup(menu: NSMenu, url: URL, isDirectory: Bool) {
        let l10n = AppLocalizationState.shared
        let openTitle = l10n.t(L10n.Common.open)
        let openItem = makeActionItem(
            title: openTitle,
            image: NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        ) {
            AppIntentDispatcher.shared.dispatch(.openWithDefaultApp(url: url), from: .contextMenu)
        }
        menu.addItem(openItem)
        
        if !isDirectory {
            let openWithTitle = l10n.t(L10n.Menu.openWith)
            let openWithItem = NSMenuItem(title: openWithTitle, action: nil, keyEquivalent: "")
            openWithItem.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            openWithItem.submenu = TTZipOpenWithMenuBuilder.shared.buildMenu(for: [url])
            menu.addItem(openWithItem)
        }
    }
    
    private func appendArchiveOrCompressGroup(menu: NSMenu, url: URL, isArchive: Bool) {
        if isArchive {
            appendArchiveExtractActions(menu: menu, url: url)
        } else {
            appendCompressActions(menu: menu, url: url)
        }
    }
    
    private func appendArchiveExtractActions(menu: NSMenu, url: URL) {
        let l10n = AppLocalizationState.shared
        
        let extractHereTitle = l10n.t(L10n.Menu.extractHere)
        let extractHereItem = makeActionItem(
            title: extractHereTitle,
            image: NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
        ) {
            AppIntentDispatcher.shared.dispatch(
                .extractArchive(archivePaths: [url.path], options: ExtractIntentOptions(isSmartExtract: true)),
                from: .contextMenu
            )
        }
        menu.addItem(extractHereItem)
        
        let extractToTitle = l10n.t(L10n.Menu.extractTo)
        let extractToItem = makeActionItem(
            title: extractToTitle,
            image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        ) { [weak self] in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = l10n.t(L10n.Extract.action)
            self?.presentOpenPanelSheet(with: panel) { destURL in
                AppIntentDispatcher.shared.dispatch(
                    .extractArchive(archivePaths: [url.path], options: ExtractIntentOptions(destinationDirectory: destURL, isSmartExtract: true)),
                    from: .contextMenu
                )
            }
        }
        menu.addItem(extractToItem)
        
        let inspectTitle = l10n.t(L10n.Menu.inspectArchive)
        let inspectItem = makeActionItem(
            title: inspectTitle,
            image: NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: nil)
        ) {
            AppIntentDispatcher.shared.dispatch(.inspectArchive(archivePath: url.path), from: .contextMenu)
        }
        menu.addItem(inspectItem)
        
        let openInAppTitle = l10n.t(L10n.Menu.openInApp)
        let openInAppItem = makeActionItem(
            title: openInAppTitle,
            image: NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
        ) {
            AppIntentDispatcher.shared.dispatch(.openArchive(url: url, password: nil), from: .contextMenu)
        }
        menu.addItem(openInAppItem)
    }
    
    private func appendCompressActions(menu: NSMenu, url: URL) {
        let l10n = AppLocalizationState.shared
        
        let compressZipTitle = l10n.t(L10n.Menu.compressZip)
        let compressZipItem = makeActionItem(
            title: compressZipTitle,
            image: NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        ) {
            AppIntentDispatcher.shared.dispatch(
                .createArchive(sourcePaths: [url.path], options: CompressIntentOptions(targetFormat: .zip)),
                from: .contextMenu
            )
        }
        menu.addItem(compressZipItem)
        
        let compress7zTitle = l10n.t(L10n.Menu.compress7z)
        let compress7zItem = makeActionItem(
            title: compress7zTitle,
            image: NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil)
        ) {
            AppIntentDispatcher.shared.dispatch(
                .createArchive(sourcePaths: [url.path], options: CompressIntentOptions(targetFormat: .sevenZip)),
                from: .contextMenu
            )
        }
        menu.addItem(compress7zItem)
        
        let newArchiveTitle = l10n.t(L10n.Menu.newArchiveMenu)
        let newArchiveItem = makeActionItem(
            title: newArchiveTitle,
            image: NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        ) {
            AppIntentDispatcher.shared.dispatch(
                .createArchive(sourcePaths: [url.path], options: CompressIntentOptions()),
                from: .contextMenu
            )
        }
        menu.addItem(newArchiveItem)
    }
    
    private func appendQuickLookItem(menu: NSMenu, url: URL) {
        let l10n = AppLocalizationState.shared
        let quickLookTitle = l10n.format(L10n.Menu.quickLookItemFormat, url.lastPathComponent)
        let quickLookItem = makeActionItem(
            title: quickLookTitle,
            image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil),
            keyEquivalent: " ",
            modifierMask: []
        ) {
            AppIntentDispatcher.shared.dispatch(.previewItem(url: url), from: .contextMenu)
        }
        menu.addItem(quickLookItem)
    }
    
    private func appendEditAndFileOpsGroup(menu: NSMenu, url: URL, isDirectory: Bool) {
        let l10n = AppLocalizationState.shared
        
        let renameTitle = l10n.uiString(
            zh: "重命名",
            en: "Rename",
            zhHant: "重新命名",
            ja: "名称変更",
            ko: "이름 변경",
            de: "Umbenennen",
            fr: "Renommer",
            es: "Renombrar"
        )
        let renameItem = makeActionItem(
            title: renameTitle,
            image: NSImage(systemSymbolName: "pencil", accessibilityDescription: nil),
            keyEquivalent: "\r",
            modifierMask: []
        ) {
            NotificationCenter.default.post(
                name: NSNotification.Name("TTZipStartInlineRenameNotification"),
                object: url.path
            )
        }
        menu.addItem(renameItem)
        
        let duplicateTitle = l10n.uiString(
            zh: "创建副本",
            en: "Duplicate",
            zhHant: "製作替身",
            ja: "複製",
            ko: "복제",
            de: "Duplizieren",
            fr: "Dupliquer",
            es: "Duplicar"
        )
        let duplicateItem = makeActionItem(
            title: duplicateTitle,
            image: NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil),
            keyEquivalent: "d",
            modifierMask: .command
        ) { [weak self] in
            self?.duplicateFileOrDirectory(at: url)
        }
        menu.addItem(duplicateItem)
        
        let newFolderTitle = l10n.t(L10n.Common.newFolder)
        let newFolderItem = makeActionItem(
            title: newFolderTitle,
            image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil),
            keyEquivalent: "n",
            modifierMask: [.command, .shift]
        ) { [weak self] in
            self?.createNewFolder(at: url, isDirectory: isDirectory)
        }
        menu.addItem(newFolderItem)
    }
    
    private func appendClipboardGroup(menu: NSMenu, url: URL, isDirectory: Bool) {
        let l10n = AppLocalizationState.shared
        let itemName = url.lastPathComponent
        
        let copyTitle = l10n.format(L10n.Menu.copyItemFormat, itemName)
        let copyItem = makeActionItem(
            title: copyTitle,
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil),
            keyEquivalent: "c",
            modifierMask: .command
        ) {
            FileClipboardStore.shared.copy(urls: [url])
        }
        menu.addItem(copyItem)
        
        let copyPathTitle = l10n.format(L10n.Menu.copyPathFormat, itemName)
        let copyPathItem = makeActionItem(
            title: copyPathTitle,
            image: NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: nil),
            keyEquivalent: "c",
            modifierMask: [.command, .option]
        ) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        menu.addItem(copyPathItem)
        
        let cutTitle = l10n.t(L10n.Menu.cut)
        let cutItem = makeActionItem(
            title: cutTitle,
            image: NSImage(systemSymbolName: "scissors", accessibilityDescription: nil),
            keyEquivalent: "x",
            modifierMask: .command
        ) {
            FileClipboardStore.shared.cut(urls: [url])
        }
        menu.addItem(cutItem)
        
        if isDirectory {
            let pasteTitle = l10n.t(L10n.Menu.pasteIntoFolder)
            let pasteItem = makeActionItem(
                title: pasteTitle,
                image: NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil),
                keyEquivalent: "v",
                modifierMask: .command
            ) {
                FileClipboardStore.shared.paste(to: url)
            }
            pasteItem.isEnabled = FileClipboardStore.shared.canPaste
            menu.addItem(pasteItem)
        }
    }
    
    private func appendShareAndServicesGroup(menu: NSMenu, url: URL) {
        let sharePicker = NSSharingServicePicker(items: [url])
        menu.addItem(sharePicker.standardShareMenuItem)
        
        let servicesItem = makeServicesMenuItem()
        menu.addItem(servicesItem)
    }
    
    private func appendRevealAndTrashGroup(menu: NSMenu, url: URL) {
        let l10n = AppLocalizationState.shared
        let revealTitle = l10n.t(L10n.Common.revealInFinder)
        let revealItem = makeActionItem(
            title: revealTitle,
            image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        ) {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        }
        menu.addItem(revealItem)
        
        let trashTitle = l10n.t(L10n.Menu.moveToTrash)
        let trashItem = makeActionItem(
            title: trashTitle,
            image: NSImage(systemSymbolName: "trash", accessibilityDescription: nil),
            keyEquivalent: "\u{08}",
            modifierMask: .command
        ) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
        }
        menu.addItem(trashItem)
    }
    
    // MARK: - File Operation Helpers
    
    private func duplicateFileOrDirectory(at url: URL) {
        let parentDir = url.deletingLastPathComponent()
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let ext = isDir ? "" : url.pathExtension
        let baseName = isDir ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        
        var candidateURL = ext.isEmpty
            ? parentDir.appendingPathComponent("\(baseName) copy")
            : parentDir.appendingPathComponent("\(baseName) copy.\(ext)")
        
        var counter = 2
        while FileManager.default.fileExists(atPath: candidateURL.path) {
            candidateURL = ext.isEmpty
                ? parentDir.appendingPathComponent("\(baseName) copy \(counter)")
                : parentDir.appendingPathComponent("\(baseName) copy \(counter).\(ext)")
            counter += 1
        }
        
        do {
            try FileManager.default.copyItem(at: url, to: candidateURL)
            NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
        } catch {
            TTLogger.error("Failed to duplicate item at \(url.path): \(error)")
        }
    }
    
    private func createNewFolder(at url: URL, isDirectory: Bool) {
        let l10n = AppLocalizationState.shared
        let defaultFolderName = l10n.t(L10n.Common.newFolder)
        let targetDir = isDirectory ? url : url.deletingLastPathComponent()
        
        var targetURL = targetDir.appendingPathComponent(defaultFolderName)
        var counter = 2
        while FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = targetDir.appendingPathComponent("\(defaultFolderName) \(counter)")
            counter += 1
        }
        
        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
            NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
        } catch {
            TTLogger.error("Failed to create new folder at \(targetURL.path): \(error)")
        }
    }
}
