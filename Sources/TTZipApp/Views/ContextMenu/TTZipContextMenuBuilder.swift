// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import Foundation
import TTZipCore
import TTZipUI
import TTZipPluginKit

/// Assembles a 100% native macOS Finder-grade context menu (NSMenu) matching Apple Human Interface Guidelines.
@MainActor
public final class TTZipContextMenuBuilder {
    public static let shared = TTZipContextMenuBuilder()
    
    private init() {}
    
    /// Constructs a fully native NSMenu based on the supplied contextual target.
    public func buildMenu(for target: TTZipContextMenuTarget) -> NSMenu {
        let isZh = AppLocalizationState.shared.currentLanguage.bcp47.hasPrefix("zh")
        let menu = NSMenu(title: "TTZipContextMenu")
        menu.autoenablesItems = false
        
        switch target {
        case .singleItem(let url, let isDirectory, let isArchive):
            buildSingleItemMenu(menu: menu, url: url, isDirectory: isDirectory, isArchive: isArchive, isZh: isZh)
            
        case .multipleItems(let urls):
            buildMultipleItemsMenu(menu: menu, urls: urls, isZh: isZh)
            
        case .virtualArchiveEntry(let archivePath, let subpath, let isDirectory):
            buildVirtualArchiveEntryMenu(menu: menu, archivePath: archivePath, subpath: subpath, isDirectory: isDirectory, isZh: isZh)
            
        case .columnBackground(let directoryURL):
            buildColumnBackgroundMenu(menu: menu, directoryURL: directoryURL, isZh: isZh)
        }
        
        return menu
    }
    
    // MARK: - 1. Single Item Menu Assembly
    
    private func buildSingleItemMenu(menu: NSMenu, url: URL, isDirectory: Bool, isArchive: Bool, isZh: Bool) {
        let itemName = url.lastPathComponent
        
        // 1. Open & Open With
        let openTitle = isZh ? "打开" : "Open"
        let openItem = makeActionItem(
            title: openTitle,
            image: NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        ) {
            NSWorkspace.shared.open(url)
        }
        menu.addItem(openItem)
        
        if !isDirectory {
            let openWithTitle = isZh ? "打开方式" : "Open With"
            let openWithItem = NSMenuItem(title: openWithTitle, action: nil, keyEquivalent: "")
            openWithItem.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            openWithItem.submenu = TTZipOpenWithMenuBuilder.shared.buildMenu(for: [url])
            menu.addItem(openWithItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. TTZip Action Matrix
        if isArchive {
            let extractHereTitle = isZh ? "解压到当前位置" : "Extract Here"
            let extractHereItem = makeActionItem(
                title: extractHereTitle,
                image: NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            ) {
                AppIntentDispatcher.shared.dispatch(
                    .extractArchive(archivePaths: [url.path], options: ExtractIntentOptions(isSmartExtract: false)),
                    from: .contextMenu
                )
            }
            menu.addItem(extractHereItem)
            
            let extractToTitle = isZh ? "解压到..." : "Extract to..."
            let extractToItem = makeActionItem(
                title: extractToTitle,
                image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
            ) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = isZh ? "解压" : "Extract"
                if panel.runModal() == .OK, let destURL = panel.url {
                    AppIntentDispatcher.shared.dispatch(
                        .extractArchive(archivePaths: [url.path], options: ExtractIntentOptions(destinationDirectory: destURL, isSmartExtract: false)),
                        from: .contextMenu
                    )
                }
            }
            menu.addItem(extractToItem)
            
            let inspectTitle = isZh ? "在检查器中浏览" : "Inspect Archive"
            let inspectItem = makeActionItem(
                title: inspectTitle,
                image: NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: nil)
            ) {
                AppIntentDispatcher.shared.dispatch(.inspectArchive(archivePath: url.path), from: .contextMenu)
            }
            menu.addItem(inspectItem)
            
            let openInAppTitle = isZh ? "在 TTZip 中浏览" : "Open in TTZip"
            let openInAppItem = makeActionItem(
                title: openInAppTitle,
                image: NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
            ) {
                AppIntentDispatcher.shared.dispatch(.openArchive(url: url, password: nil), from: .contextMenu)
            }
            menu.addItem(openInAppItem)
        } else {
            let compressZipTitle = isZh ? "压缩为 Zip" : "Compress as Zip"
            let compressZipItem = makeActionItem(
                title: compressZipTitle,
                image: NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
            ) {
                AppIntentDispatcher.shared.dispatch(
                    .createArchive(sourcePaths: [url.path], options: CompressIntentOptions(targetFormat: .zip)),
                    from: .contextMenu
                )
            }
            menu.addItem(compressZipItem)
            
            let compress7zTitle = isZh ? "压缩为 7z" : "Compress as 7z"
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
            
            let newArchiveTitle = isZh ? "新建归档..." : "New Archive..."
            let newArchiveItem = makeActionItem(
                title: newArchiveTitle,
                image: NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
            ) {
                AppIntentDispatcher.shared.dispatch(
                    .createArchive(sourcePaths: [url.path], options: CompressIntentOptions()),
                    from: .contextMenu
                )
            }
            menu.addItem(newArchiveItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Quick Look (Space shortcut annotation)
        let quickLookTitle = isZh ? "快速查看“\(itemName)”" : "Quick Look “\(itemName)”"
        let quickLookItem = makeActionItem(
            title: quickLookTitle,
            image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil),
            keyEquivalent: " ",
            modifierMask: []
        ) {
            AppIntentDispatcher.shared.dispatch(.previewItem(url: url), from: .contextMenu)
        }
        menu.addItem(quickLookItem)
        
        // 4. Native Sharing Service Picker
        let sharePicker = NSSharingServicePicker(items: [url])
        let shareItem = sharePicker.standardShareMenuItem
        menu.addItem(shareItem)
        
        // 5. System Services Menu
        let servicesItem = makeServicesMenuItem(isZh: isZh)
        menu.addItem(servicesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 6. Copy & Option Alternate "Copy as Pathname"
        let copyTitle = isZh ? "拷贝“\(itemName)”" : "Copy “\(itemName)”"
        let copyItem = makeActionItem(
            title: copyTitle,
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil),
            keyEquivalent: "c",
            modifierMask: .command
        ) {
            FileClipboardStore.shared.copy(urls: [url])
        }
        menu.addItem(copyItem)
        
        let copyPathTitle = isZh ? "拷贝“\(itemName)”为路径名称" : "Copy “\(itemName)” as Pathname"
        let copyPathItem = makeActionItem(
            title: copyPathTitle,
            image: NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: nil),
            keyEquivalent: "c",
            modifierMask: [.command, .option]
        ) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        copyPathItem.isAlternate = true
        menu.addItem(copyPathItem)
        
        let cutTitle = isZh ? "剪切" : "Cut"
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
            let pasteTitle = isZh ? "粘贴到此文件夹" : "Paste into Folder"
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
        
        menu.addItem(NSMenuItem.separator())
        
        // 7. Reveal in Finder & Move to Trash
        let revealTitle = isZh ? "在访达中显示" : "Show in Finder"
        let revealItem = makeActionItem(
            title: revealTitle,
            image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        ) {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        }
        menu.addItem(revealItem)
        
        let trashTitle = isZh ? "移到废纸篓" : "Move to Trash"
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
        
        // 8. Plugin Actions Injection
        appendPluginActions(to: menu, url: url)
    }
    
    // MARK: - 2. Multiple Items Menu Assembly
    
    private func buildMultipleItemsMenu(menu: NSMenu, urls: [URL], isZh: Bool) {
        guard let firstURL = urls.first else { return }
        let count = urls.count
        
        // 1. Open & Open With
        let openTitle = isZh ? "打开 \(count) 个项目" : "Open \(count) Items"
        let openItem = makeActionItem(
            title: openTitle,
            image: NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        ) {
            let config = NSWorkspace.OpenConfiguration()
            config.promptsUserIfNeeded = true
            NSWorkspace.shared.open(urls, withApplicationAt: firstURL, configuration: config, completionHandler: nil)
        }
        menu.addItem(openItem)
        
        let openWithTitle = isZh ? "打开方式" : "Open With"
        let openWithItem = NSMenuItem(title: openWithTitle, action: nil, keyEquivalent: "")
        openWithItem.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        openWithItem.submenu = TTZipOpenWithMenuBuilder.shared.buildMenu(for: urls)
        menu.addItem(openWithItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. TTZip Compression Actions
        let newArchiveTitle = isZh ? "新建归档 (\(count) 个项目)..." : "New Archive (\(count) Items)..."
        let newArchiveItem = makeActionItem(
            title: newArchiveTitle,
            image: NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil)
        ) {
            AppIntentDispatcher.shared.dispatch(
                .createArchive(sourcePaths: urls.map(\.path), options: CompressIntentOptions()),
                from: .contextMenu
            )
        }
        menu.addItem(newArchiveItem)
        
        let zipTitle = isZh ? "压缩为 Zip (\(count) 个项目)" : "Compress as Zip (\(count) Items)"
        let zipItem = makeActionItem(
            title: zipTitle,
            image: NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        ) {
            AppIntentDispatcher.shared.dispatch(
                .createArchive(sourcePaths: urls.map(\.path), options: CompressIntentOptions(targetFormat: .zip)),
                from: .contextMenu
            )
        }
        menu.addItem(zipItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Quick Look
        let quickLookTitle = isZh ? "快速查看 \(count) 个项目" : "Quick Look \(count) Items"
        let quickLookItem = makeActionItem(
            title: quickLookTitle,
            image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil),
            keyEquivalent: " ",
            modifierMask: []
        ) {
            AppIntentDispatcher.shared.dispatch(.previewItem(url: firstURL), from: .contextMenu)
        }
        menu.addItem(quickLookItem)
        
        // 4. Share Picker
        let sharePicker = NSSharingServicePicker(items: urls)
        menu.addItem(sharePicker.standardShareMenuItem)
        
        // 5. System Services Menu
        let servicesItem = makeServicesMenuItem(isZh: isZh)
        menu.addItem(servicesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 6. Copy & Option Alternate
        let copyTitle = isZh ? "拷贝 (\(count) 个项目)" : "Copy (\(count) Items)"
        let copyItem = makeActionItem(
            title: copyTitle,
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil),
            keyEquivalent: "c",
            modifierMask: .command
        ) {
            FileClipboardStore.shared.copy(urls: urls)
        }
        menu.addItem(copyItem)
        
        let copyPathTitle = isZh ? "拷贝为路径名称 (\(count) 个项目)" : "Copy as Pathnames (\(count) Items)"
        let copyPathItem = makeActionItem(
            title: copyPathTitle,
            image: NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: nil),
            keyEquivalent: "c",
            modifierMask: [.command, .option]
        ) {
            let joinedPaths = urls.map(\.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(joinedPaths, forType: .string)
        }
        copyPathItem.isAlternate = true
        menu.addItem(copyPathItem)
        
        let cutTitle = isZh ? "剪切 (\(count) 个项目)" : "Cut (\(count) Items)"
        let cutItem = makeActionItem(
            title: cutTitle,
            image: NSImage(systemSymbolName: "scissors", accessibilityDescription: nil),
            keyEquivalent: "x",
            modifierMask: .command
        ) {
            FileClipboardStore.shared.cut(urls: urls)
        }
        menu.addItem(cutItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 7. Move to Trash
        let trashTitle = isZh ? "移到废纸篓 (\(count) 个项目)" : "Move to Trash (\(count) Items)"
        let trashItem = makeActionItem(
            title: trashTitle,
            image: NSImage(systemSymbolName: "trash", accessibilityDescription: nil),
            keyEquivalent: "\u{08}",
            modifierMask: .command
        ) {
            for u in urls {
                try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
            }
            NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
        }
        menu.addItem(trashItem)
        
        // 8. Plugins
        appendPluginActions(to: menu, url: firstURL)
    }
    
    // MARK: - 3. Virtual Archive Entry Menu Assembly
    
    private func buildVirtualArchiveEntryMenu(
        menu: NSMenu,
        archivePath: String,
        subpath: String,
        isDirectory: Bool,
        isZh: Bool
    ) {
        let entryName = (subpath as NSString).lastPathComponent
        
        // 1. Extract Selected Entry
        let extractTitle = isZh ? "解压选中项" : "Extract Selected Entry"
        let extractItem = makeActionItem(
            title: extractTitle,
            image: NSImage(systemSymbolName: "arrow.down.doc.fill", accessibilityDescription: nil)
        ) {
            let destDir = (archivePath as NSString).deletingLastPathComponent
            Task {
                let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                try? await TTZipEngineFacade.shared.extractSingleEntry(
                    archivePath: archivePath,
                    entryPath: subpath,
                    destinationDir: destDir,
                    password: pwd
                )
                let targetPath = (destDir as NSString).appendingPathComponent(entryName)
                NSWorkspace.shared.selectFile(targetPath, inFileViewerRootedAtPath: "")
            }
        }
        menu.addItem(extractItem)
        
        let extractToTitle = isZh ? "解压到..." : "Extract to..."
        let extractToItem = makeActionItem(
            title: extractToTitle,
            image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        ) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = isZh ? "解压" : "Extract"
            if panel.runModal() == .OK, let destURL = panel.url {
                Task {
                    let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                    try? await TTZipEngineFacade.shared.extractSingleEntry(
                        archivePath: archivePath,
                        entryPath: subpath,
                        destinationDir: destURL.path,
                        password: pwd
                    )
                    let targetPath = (destURL.path as NSString).appendingPathComponent(entryName)
                    NSWorkspace.shared.selectFile(targetPath, inFileViewerRootedAtPath: "")
                }
            }
        }
        menu.addItem(extractToItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. Replace Entry (files only)
        if !isDirectory {
            let replaceTitle = isZh ? "替换为..." : "Replace with..."
            let replaceItem = makeActionItem(
                title: replaceTitle,
                image: NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            ) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowsMultipleSelection = false
                panel.prompt = isZh ? "替换" : "Replace"
                if panel.runModal() == .OK, let chosenURL = panel.url {
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
            }
            menu.addItem(replaceItem)
        }
        
        // 3. Delete Entry
        let deleteTitle = isZh ? "删除" : "Delete Entry"
        let deleteItem = makeActionItem(
            title: deleteTitle,
            image: NSImage(systemSymbolName: "trash", accessibilityDescription: nil),
            keyEquivalent: "\u{08}",
            modifierMask: .command
        ) {
            Task {
                let pwd = ArchivePasswordStore.shared.getPassword(for: archivePath)
                try? await InPlaceMutationCoordinator.shared.deleteEntries(
                    archivePath: archivePath,
                    entryPaths: [subpath],
                    password: pwd
                )
            }
        }
        menu.addItem(deleteItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 4. Copy Subpath
        let copySubpathTitle = isZh ? "拷贝路径" : "Copy Subpath"
        let copySubpathItem = makeActionItem(
            title: copySubpathTitle,
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil),
            keyEquivalent: "c",
            modifierMask: .command
        ) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(subpath, forType: .string)
        }
        menu.addItem(copySubpathItem)
    }
    
    // MARK: - 4. Column Background Menu Assembly
    
    private func buildColumnBackgroundMenu(menu: NSMenu, directoryURL: URL, isZh: Bool) {
        let newFolderTitle = isZh ? "新建文件夹" : "New Folder"
        let newFolderItem = makeActionItem(
            title: newFolderTitle,
            image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil),
            keyEquivalent: "n",
            modifierMask: [.command, .shift]
        ) {
            Self.createNewFolder(in: directoryURL, isZh: isZh)
        }
        menu.addItem(newFolderItem)
        
        let newFileTitle = isZh ? "新建文件" : "New File"
        let newFileItem = makeActionItem(
            title: newFileTitle,
            image: NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil),
            keyEquivalent: "n",
            modifierMask: .command
        ) {
            Self.createNewFile(in: directoryURL, isZh: isZh)
        }
        menu.addItem(newFileItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let pasteTitle = isZh ? "粘贴" : "Paste"
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
        
        let revealTitle = isZh ? "在访达中显示" : "Show in Finder"
        let revealItem = makeActionItem(
            title: revealTitle,
            image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        ) {
            NSWorkspace.shared.selectFile(directoryURL.path, inFileViewerRootedAtPath: "")
        }
        menu.addItem(revealItem)
    }
    
    // MARK: - Helpers & Common Elements
    
    private func makeActionItem(
        title: String,
        image: NSImage? = nil,
        keyEquivalent: String = "",
        modifierMask: NSEvent.ModifierFlags = [],
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let trampoline = MenuItemActionTrampoline(action: action)
        let item = NSMenuItem(
            title: title,
            action: #selector(MenuItemActionTrampoline.performAction(_:)),
            keyEquivalent: keyEquivalent
        )
        item.target = trampoline
        item.representedObject = trampoline
        item.image = image
        item.keyEquivalentModifierMask = modifierMask
        return item
    }
    
    private func makeServicesMenuItem(isZh: Bool) -> NSMenuItem {
        let servicesTitle = isZh ? "服务" : "Services"
        let servicesItem = NSMenuItem(title: servicesTitle, action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: servicesTitle)
        servicesItem.submenu = servicesMenu
        servicesItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        NSApplication.shared.servicesMenu = servicesMenu
        return servicesItem
    }
    
    private func appendPluginActions(to menu: NSMenu, url: URL) {
        let pluginActions = TTZipPluginRegistry.shared.contextMenuActions
        guard !pluginActions.isEmpty else { return }
        
        menu.addItem(NSMenuItem.separator())
        for action in pluginActions {
            let item = makeActionItem(
                title: action.title,
                image: NSImage(systemSymbolName: action.icon, accessibilityDescription: nil)
            ) {
                action.action(url)
            }
            menu.addItem(item)
        }
    }
    
    private static func createNewFolder(in directoryURL: URL, isZh: Bool) {
        let baseName = isZh ? "未命名文件夹" : "untitled folder"
        var targetURL = directoryURL.appendingPathComponent(baseName)
        var counter = 2
        while FileManager.default.fileExists(atPath: targetURL.path) {
            let name = isZh ? "未命名文件夹 \(counter)" : "untitled folder \(counter)"
            targetURL = directoryURL.appendingPathComponent(name)
            counter += 1
        }
        try? FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
    }
    
    private static func createNewFile(in directoryURL: URL, isZh: Bool) {
        let baseName = isZh ? "未命名" : "untitled"
        var targetURL = directoryURL.appendingPathComponent("\(baseName).txt")
        var counter = 2
        while FileManager.default.fileExists(atPath: targetURL.path) {
            let name = isZh ? "\(baseName) \(counter).txt" : "\(baseName) \(counter).txt"
            targetURL = directoryURL.appendingPathComponent(name)
            counter += 1
        }
        FileManager.default.createFile(atPath: targetURL.path, contents: Data())
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
    }
}
