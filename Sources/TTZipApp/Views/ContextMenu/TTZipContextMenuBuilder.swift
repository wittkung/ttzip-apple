// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import TTZipCore
import TTZipUI

/// Assembles a 100% native macOS Finder-grade context menu (NSMenu) matching Apple Human Interface Guidelines.
@MainActor
public final class TTZipContextMenuBuilder {
    public static let shared = TTZipContextMenuBuilder()
    
    private init() {}
    
    /// Constructs a fully native NSMenu based on the supplied contextual target.
    public func buildMenu(for target: TTZipContextMenuTarget) -> NSMenu {
        let menu = NSMenu(title: "TTZipContextMenu")
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        
        switch target {
        case .singleItem(let url, let isDirectory, let isArchive):
            buildSingleItemMenu(menu: menu, url: url, isDirectory: isDirectory, isArchive: isArchive)
            
        case .multipleItems(let urls):
            buildMultipleItemsMenu(menu: menu, urls: urls)
            
        case .virtualArchiveEntry(let archivePath, let subpath, let isDirectory):
            buildVirtualArchiveEntryMenu(menu: menu, archivePath: archivePath, subpath: subpath, isDirectory: isDirectory)
            
        case .columnBackground(let directoryURL):
            buildColumnBackgroundMenu(menu: menu, directoryURL: directoryURL)
        }
        
        return menu
    }
    
    // MARK: - Helpers & Common Elements
    
    internal func makeActionItem(
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
    
    internal func makeServicesMenuItem() -> NSMenuItem {
        let servicesTitle = AppLocalizationState.shared.t(L10n.Menu.services)
        let servicesItem = NSMenuItem(title: servicesTitle, action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: servicesTitle)
        servicesItem.submenu = servicesMenu
        servicesItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        NSApplication.shared.servicesMenu = servicesMenu
        return servicesItem
    }
    
    // MARK: - Non-blocking Modal Sheet Dispatcher
    
    internal func presentOpenPanelSheet(
        with panel: NSOpenPanel,
        onConfirmed: @escaping @MainActor (URL) -> Void
    ) {
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                Task { @MainActor in
                    onConfirmed(url)
                }
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
