// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit

/// Dynamically updates AppKit system menu bar items using a three-tier topological engine
/// (Permanent Tags -> Standard Action Selectors -> Menu Tree Structural Slot Indices).
@MainActor
public final class AppKitMenuSynchronizer {
    public static let shared = AppKitMenuSynchronizer()
    
    public enum Tag {
        // Top-Level Menus
        public static let appMenu = 100
        public static let fileMenu = 110
        public static let editMenu = 120
        public static let viewMenu = 130
        public static let windowMenu = 140
        public static let helpMenu = 150
        
        // Application Submenu
        public static let about = 1001
        public static let preferences = 1002
        public static let checkForUpdates = 1003
        public static let services = 1004
        public static let hide = 1005
        public static let hideOthers = 1006
        public static let showAll = 1007
        public static let quit = 1008
        
        // File Submenu
        public static let newWindow = 1100
        public static let newArchive = 1101
        public static let openArchive = 1102
        public static let openRecent = 1103
        public static let closeWindow = 1104
        
        // Edit Submenu
        public static let undo = 1201
        public static let redo = 1202
        public static let cut = 1203
        public static let copy = 1204
        public static let paste = 1205
        public static let selectAll = 1206
        public static let delete = 1207
        
        // View Submenu
        public static let toggleFullScreen = 1301
        
        // Window Submenu
        public static let minimize = 1401
        public static let zoom = 1402
        public static let bringAllToFront = 1403
        
        // Help Submenu
        public static let help = 1501
    }
    
    private let selectorLocaleMap: [Selector: any LocaleKeyProtocol] = [
        #selector(NSApplication.orderFrontStandardAboutPanel(_:)): L10n.Menu.about,
        #selector(NSApplication.hide(_:)): L10n.Menu.hide,
        #selector(NSApplication.hideOtherApplications(_:)): L10n.Menu.hideOthers,
        #selector(NSApplication.unhideAllApplications(_:)): L10n.Menu.showAll,
        #selector(NSApplication.terminate(_:)): L10n.Menu.quit,
        #selector(NSWindow.performClose(_:)): L10n.Menu.closeWindow,
        #selector(NSWindow.performMiniaturize(_:)): L10n.Menu.minimize,
        #selector(NSWindow.performZoom(_:)): L10n.Menu.zoom,
        #selector(NSWindow.toggleFullScreen(_:)): L10n.Menu.toggleFullScreen,
        NSSelectorFromString("undo:"): L10n.Menu.undo,
        NSSelectorFromString("redo:"): L10n.Menu.redo,
        NSSelectorFromString("cut:"): L10n.Menu.cut,
        NSSelectorFromString("copy:"): L10n.Menu.copy,
        NSSelectorFromString("paste:"): L10n.Menu.paste,
        NSSelectorFromString("pasteAsPlainText:"): L10n.Menu.pasteAndMatchStyle,
        NSSelectorFromString("selectAll:"): L10n.Menu.selectAllMenu,
        NSSelectorFromString("delete:"): L10n.Menu.delete,
        NSSelectorFromString("arrangeInFront:"): L10n.Menu.bringAllToFront,
        NSSelectorFromString("checkForUpdates:"): L10n.Menu.checkForUpdates,
        NSSelectorFromString("showPreferencesWindow:"): L10n.Menu.preferences
    ]
    
    private let mainMenuTagLocaleMap: [Int: any LocaleKeyProtocol] = [
        Tag.fileMenu: L10n.Menu.fileMenu,
        Tag.editMenu: L10n.Menu.editMenu,
        Tag.viewMenu: L10n.Menu.viewMenu,
        Tag.windowMenu: L10n.Menu.windowMenu,
        Tag.helpMenu: L10n.Menu.helpMenu
    ]

    private let mainMenuSlotTagMap: [Int: Int] = [
        1: Tag.fileMenu,
        2: Tag.editMenu,
        3: Tag.viewMenu,
        4: Tag.windowMenu,
        5: Tag.helpMenu
    ]

    private let submenuTagLocaleMap: [Int: any LocaleKeyProtocol] = [
        Tag.about: L10n.Menu.about,
        Tag.preferences: L10n.Menu.preferences,
        Tag.checkForUpdates: L10n.Menu.checkForUpdates,
        Tag.services: L10n.Menu.services,
        Tag.hide: L10n.Menu.hide,
        Tag.hideOthers: L10n.Menu.hideOthers,
        Tag.showAll: L10n.Menu.showAll,
        Tag.quit: L10n.Menu.quit,
        Tag.newWindow: MultiWindowLocaleKey.newWindow,
        Tag.newArchive: MultiWindowLocaleKey.newArchiveMenu,
        Tag.openArchive: L10n.Menu.openArchive,
        Tag.openRecent: L10n.Menu.openRecent,
        Tag.closeWindow: L10n.Menu.closeWindow,
        Tag.undo: L10n.Menu.undo,
        Tag.redo: L10n.Menu.redo,
        Tag.cut: L10n.Menu.cut,
        Tag.copy: L10n.Menu.copy,
        Tag.paste: L10n.Menu.paste,
        Tag.selectAll: L10n.Menu.selectAllMenu,
        Tag.delete: L10n.Menu.delete,
        Tag.toggleFullScreen: L10n.Menu.toggleFullScreen,
        Tag.minimize: L10n.Menu.minimize,
        Tag.zoom: L10n.Menu.zoom,
        Tag.bringAllToFront: L10n.Menu.bringAllToFront
    ]

    private init() {}

    /// Synchronizes all main menu items with zero string title dependencies.
    public func synchronize(language: AppLanguage) {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }
        let manager = TTZipLocalizationManager.shared

        for (index, item) in mainMenu.items.enumerated() {
            if let key = mainMenuTagLocaleMap[item.tag] {
                item.title = manager.string(for: key, language: language)
            } else if let fallbackTag = mainMenuSlotTagMap[index],
                      let key = mainMenuTagLocaleMap[fallbackTag] {
                item.tag = fallbackTag
                item.title = manager.string(for: key, language: language)
            }
            if let submenu = item.submenu {
                synchronizeSubmenu(submenu, language: language)
            }
        }
    }

    private func synchronizeSubmenu(_ menu: NSMenu, language: AppLanguage) {
        let manager = TTZipLocalizationManager.shared

        for item in menu.items {
            if let key = resolveSubmenuItemLocaleKey(for: item) {
                item.title = manager.string(for: key, language: language)
            }
            if let sub = item.submenu {
                synchronizeSubmenu(sub, language: language)
            }
        }
    }

    private func resolveSubmenuItemLocaleKey(for item: NSMenuItem) -> (any LocaleKeyProtocol)? {
        if let tagKey = submenuTagLocaleMap[item.tag] {
            return tagKey
        }
        if let action = item.action, let selectorKey = selectorLocaleMap[action] {
            return selectorKey
        }
        guard !item.keyEquivalent.isEmpty else { return nil }
        return resolveShortcutLocaleKey(for: item)
    }

    private func resolveShortcutLocaleKey(for item: NSMenuItem) -> (any LocaleKeyProtocol)? {
        let mods = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
        switch (item.keyEquivalent.lowercased(), mods) {
        case ("n", .command): return MultiWindowLocaleKey.newWindow
        case ("n", [.command, .shift]): return MultiWindowLocaleKey.newArchiveMenu
        case (" ", [.command, .shift]): return L10n.Menu.globalSearch
        case ("k", .command): return L10n.Menu.omnibar
        case ("e", [.command, .option]): return L10n.Menu.quickExtractAll
        case ("s", [.command, .control]): return L10n.Menu.toggleSidebar
        case ("i", .command): return L10n.Menu.toggleInspector
        default: return nil
        }
    }
}
