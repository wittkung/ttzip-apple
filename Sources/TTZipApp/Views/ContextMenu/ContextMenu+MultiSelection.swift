// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import TTZipCore
import TTZipUI

extension TTZipContextMenuBuilder {
    // MARK: - Multiple Items Menu Assembly
    
    internal func buildMultipleItemsMenu(menu: NSMenu, urls: [URL]) {
        guard let firstURL = urls.first else { return }
        let count = urls.count
        
        // 1. Open & Open With
        appendMultiOpenGroup(menu: menu, urls: urls, firstURL: firstURL, count: count)
        menu.addItem(NSMenuItem.separator())
        
        // 2. TTZip Compression Actions
        appendMultiCompressionGroup(menu: menu, urls: urls, count: count)
        menu.addItem(NSMenuItem.separator())
        
        // 3. Quick Look
        appendMultiQuickLookItem(menu: menu, firstURL: firstURL, count: count)
        
        // 4. Share Picker & Services
        appendMultiShareAndServicesGroup(menu: menu, urls: urls)
        menu.addItem(NSMenuItem.separator())
        
        // 5. Copy, Copy Path, Cut
        appendMultiClipboardGroup(menu: menu, urls: urls, count: count)
        menu.addItem(NSMenuItem.separator())
        
        // 6. Move to Trash
        appendMultiTrashGroup(menu: menu, urls: urls, count: count)
    }
    
    // MARK: - Multi-Selection Action Groups
    
    private func appendMultiOpenGroup(menu: NSMenu, urls: [URL], firstURL: URL, count: Int) {
        let l10n = AppLocalizationState.shared
        let openTitle = l10n.format(L10n.Menu.openItemsFormat, count)
        let openItem = makeActionItem(
            title: openTitle,
            image: NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        ) {
            for url in urls {
                AppIntentDispatcher.shared.dispatch(.openWithDefaultApp(url: url), from: .contextMenu)
            }
        }
        menu.addItem(openItem)
        
        let openWithTitle = l10n.t(L10n.Menu.openWith)
        let openWithItem = NSMenuItem(title: openWithTitle, action: nil, keyEquivalent: "")
        openWithItem.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        openWithItem.submenu = TTZipOpenWithMenuBuilder.shared.buildMenu(for: urls)
        menu.addItem(openWithItem)
    }
    
    private func appendMultiCompressionGroup(menu: NSMenu, urls: [URL], count: Int) {
        let l10n = AppLocalizationState.shared
        let newArchiveTitle = l10n.format(L10n.Menu.newArchiveItemsFormat, count)
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
        
        let zipTitle = l10n.format(L10n.Menu.compressZipItemsFormat, count)
        let zipItem = makeActionItem(
            title: zipTitle,
            image: NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        ) {
            AppIntentDispatcher.shared.dispatch(
                .createArchive(sourcePaths: urls.map(\.path), options: CompressIntentOptions(targetFormat: .zip)),
                from: .contextMenu
            )
        }
        menu.addItem(zipItem)
    }
    
    private func appendMultiQuickLookItem(menu: NSMenu, firstURL: URL, count: Int) {
        let l10n = AppLocalizationState.shared
        let quickLookTitle = l10n.format(L10n.Menu.quickLookItemsFormat, count)
        let quickLookItem = makeActionItem(
            title: quickLookTitle,
            image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil),
            keyEquivalent: " ",
            modifierMask: []
        ) {
            AppIntentDispatcher.shared.dispatch(.previewItem(url: firstURL), from: .contextMenu)
        }
        menu.addItem(quickLookItem)
    }
    
    private func appendMultiShareAndServicesGroup(menu: NSMenu, urls: [URL]) {
        let sharePicker = NSSharingServicePicker(items: urls)
        menu.addItem(sharePicker.standardShareMenuItem)
        
        let servicesItem = makeServicesMenuItem()
        menu.addItem(servicesItem)
    }
    
    private func appendMultiClipboardGroup(menu: NSMenu, urls: [URL], count: Int) {
        let l10n = AppLocalizationState.shared
        let copyTitle = l10n.format(L10n.Menu.copyItemsFormat, count)
        let copyItem = makeActionItem(
            title: copyTitle,
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil),
            keyEquivalent: "c",
            modifierMask: .command
        ) {
            FileClipboardStore.shared.copy(urls: urls)
        }
        menu.addItem(copyItem)
        
        let copyPathTitle = l10n.format(L10n.Menu.copyPathsFormat, count)
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
        
        let cutTitle = l10n.format(L10n.Menu.cutItemsFormat, count)
        let cutItem = makeActionItem(
            title: cutTitle,
            image: NSImage(systemSymbolName: "scissors", accessibilityDescription: nil),
            keyEquivalent: "x",
            modifierMask: .command
        ) {
            FileClipboardStore.shared.cut(urls: urls)
        }
        menu.addItem(cutItem)
    }
    
    private func appendMultiTrashGroup(menu: NSMenu, urls: [URL], count: Int) {
        let l10n = AppLocalizationState.shared
        let trashTitle = l10n.format(L10n.Menu.trashItemsFormat, count)
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
    }
}
