// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import AppKit
import TTZipCore

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
    
    private init() {}
    
    /// Synchronizes all main menu items with zero string title dependencies.
    public func synchronize(language: AppLanguage) {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }
        let manager = TTZipLocalizationManager.shared
        
        for (index, item) in mainMenu.items.enumerated() {
            // Tier 1: Tag Check
            switch item.tag {
            case Tag.fileMenu:
                item.title = manager.string(for: L10n.Menu.fileMenu, language: language)
            case Tag.editMenu:
                item.title = manager.string(for: L10n.Menu.editMenu, language: language)
            case Tag.viewMenu:
                item.title = manager.string(for: L10n.Menu.viewMenu, language: language)
            case Tag.windowMenu:
                item.title = manager.string(for: L10n.Menu.windowMenu, language: language)
            case Tag.helpMenu:
                item.title = manager.string(for: L10n.Menu.helpMenu, language: language)
            default:
                // Tier 3: Index Topological slot fallback
                switch index {
                case 1:
                    item.tag = Tag.fileMenu
                    item.title = manager.string(for: L10n.Menu.fileMenu, language: language)
                case 2:
                    item.tag = Tag.editMenu
                    item.title = manager.string(for: L10n.Menu.editMenu, language: language)
                case 3:
                    item.tag = Tag.viewMenu
                    item.title = manager.string(for: L10n.Menu.viewMenu, language: language)
                case 4:
                    item.tag = Tag.windowMenu
                    item.title = manager.string(for: L10n.Menu.windowMenu, language: language)
                case 5:
                    item.tag = Tag.helpMenu
                    item.title = manager.string(for: L10n.Menu.helpMenu, language: language)
                default:
                    break
                }
            }
            
            if let submenu = item.submenu {
                synchronizeSubmenu(submenu, language: language)
            }
        }
    }
    
    private func synchronizeSubmenu(_ menu: NSMenu, language: AppLanguage) {
        let manager = TTZipLocalizationManager.shared
        
        for item in menu.items {
            // Tier 1: Tag-based resolution
            switch item.tag {
            case Tag.about:
                item.title = manager.string(for: L10n.Menu.about, language: language)
            case Tag.preferences:
                item.title = manager.string(for: L10n.Menu.preferences, language: language)
            case Tag.checkForUpdates:
                item.title = manager.string(for: L10n.Menu.checkForUpdates, language: language)
            case Tag.services:
                item.title = manager.string(for: L10n.Menu.services, language: language)
            case Tag.hide:
                item.title = manager.string(for: L10n.Menu.hide, language: language)
            case Tag.hideOthers:
                item.title = manager.string(for: L10n.Menu.hideOthers, language: language)
            case Tag.showAll:
                item.title = manager.string(for: L10n.Menu.showAll, language: language)
            case Tag.quit:
                item.title = manager.string(for: L10n.Menu.quit, language: language)
            case Tag.newArchive:
                item.title = manager.string(for: L10n.Menu.newArchiveMenu, language: language)
            case Tag.openArchive:
                item.title = manager.string(for: L10n.Menu.openArchive, language: language)
            case Tag.openRecent:
                item.title = manager.string(for: L10n.Menu.openRecent, language: language)
            case Tag.closeWindow:
                item.title = manager.string(for: L10n.Menu.closeWindow, language: language)
            case Tag.undo:
                item.title = manager.string(for: L10n.Menu.undo, language: language)
            case Tag.redo:
                item.title = manager.string(for: L10n.Menu.redo, language: language)
            case Tag.cut:
                item.title = manager.string(for: L10n.Menu.cut, language: language)
            case Tag.copy:
                item.title = manager.string(for: L10n.Menu.copy, language: language)
            case Tag.paste:
                item.title = manager.string(for: L10n.Menu.paste, language: language)
            case Tag.selectAll:
                item.title = manager.string(for: L10n.Menu.selectAllMenu, language: language)
            case Tag.delete:
                item.title = manager.string(for: L10n.Menu.delete, language: language)
            case Tag.toggleFullScreen:
                item.title = manager.string(for: L10n.Menu.toggleFullScreen, language: language)
            case Tag.minimize:
                item.title = manager.string(for: L10n.Menu.minimize, language: language)
            case Tag.zoom:
                item.title = manager.string(for: L10n.Menu.zoom, language: language)
            case Tag.bringAllToFront:
                item.title = manager.string(for: L10n.Menu.bringAllToFront, language: language)
            default:
                // Tier 2: Action selector resolution
                if let action = item.action, let key = selectorLocaleMap[action] {
                    item.title = manager.string(for: key, language: language)
                }
            }
            
            if let sub = item.submenu {
                synchronizeSubmenu(sub, language: language)
            }
        }
    }
}
