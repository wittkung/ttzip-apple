// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class GUILocalizationTests: XCTestCase {
    
    @MainActor
    func testAppLocalizationStateDynamicSwitching() {
        let state = AppLocalizationState.shared
        
        // 1. Switch to English
        state.setLanguage(.en)
        XCTAssertEqual(state.currentLanguage, .en)
        XCTAssertEqual(TTZipLocalizationManager.shared.currentLanguage, .en)
        
        let extractEn = state.t(L10n.Extract.title)
        XCTAssertFalse(extractEn.isEmpty)
        XCTAssertEqual(extractEn, "Extract Archive")
        
        // 2. Switch to Chinese
        state.setLanguage(.zhHans)
        XCTAssertEqual(state.currentLanguage, .zhHans)
        XCTAssertEqual(TTZipLocalizationManager.shared.currentLanguage, .zhHans)
        
        let extractZh = state.t(L10n.Extract.title)
        XCTAssertFalse(extractZh.isEmpty)
        XCTAssertEqual(extractZh, "解压归档")
    }
    
    @MainActor
    func testAppKitMenuSynchronizer() {
        let synchronizer = AppKitMenuSynchronizer.shared
        let originalMenu = NSApplication.shared.mainMenu
        defer {
            NSApplication.shared.mainMenu = originalMenu
        }
        
        let mainMenu = NSMenu(title: "MainMenu")
        
        // 1. App Submenu
        let appMenuItem = NSMenuItem(title: "App Old", action: nil, keyEquivalent: "")
        let appSubmenu = NSMenu(title: "App Submenu")
        let aboutItem = NSMenuItem(title: "About Old", action: nil, keyEquivalent: "")
        aboutItem.tag = AppKitMenuSynchronizer.Tag.about
        let quitItem = NSMenuItem(title: "Quit Old", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appSubmenu.addItem(aboutItem)
        appSubmenu.addItem(quitItem)
        appMenuItem.submenu = appSubmenu
        mainMenu.addItem(appMenuItem)
        
        // 2. File Submenu
        let fileMenuItem = NSMenuItem(title: "File Old", action: nil, keyEquivalent: "")
        fileMenuItem.tag = AppKitMenuSynchronizer.Tag.fileMenu
        let fileSubmenu = NSMenu(title: "File Submenu")
        let newItem = NSMenuItem(title: "New Old", action: nil, keyEquivalent: "n")
        newItem.tag = AppKitMenuSynchronizer.Tag.newArchive
        let openItem = NSMenuItem(title: "Open Old", action: nil, keyEquivalent: "o")
        openItem.tag = AppKitMenuSynchronizer.Tag.openArchive
        fileSubmenu.addItem(newItem)
        fileSubmenu.addItem(openItem)
        fileMenuItem.submenu = fileSubmenu
        mainMenu.addItem(fileMenuItem)
        
        // 3. Edit Submenu
        let editMenuItem = NSMenuItem(title: "Edit Old", action: nil, keyEquivalent: "")
        editMenuItem.tag = AppKitMenuSynchronizer.Tag.editMenu
        mainMenu.addItem(editMenuItem)
        
        NSApplication.shared.mainMenu = mainMenu
        
        // Test Synchronizing to Simplified Chinese
        synchronizer.synchronize(language: .zhHans)
        XCTAssertEqual(fileMenuItem.title, "文件")
        XCTAssertEqual(editMenuItem.title, "编辑")
        XCTAssertEqual(newItem.title, "新建归档...")
        XCTAssertEqual(openItem.title, "打开归档...")
        XCTAssertEqual(aboutItem.title, "关于 TTZip")
        XCTAssertEqual(quitItem.title, "退出 TTZip")
        
        // Test Synchronizing to English
        synchronizer.synchronize(language: .en)
        XCTAssertEqual(fileMenuItem.title, "File")
        XCTAssertEqual(editMenuItem.title, "Edit")
        XCTAssertEqual(newItem.title, "New Archive...")
        XCTAssertEqual(openItem.title, "Open Archive...")
        XCTAssertEqual(aboutItem.title, "About TTZip")
        XCTAssertEqual(quitItem.title, "Quit TTZip")
    }
    
    func testLocaleCatalogCompleteness() {
        let manager = TTZipLocalizationManager.shared
        
        let testKeys: [any LocaleKeyProtocol] = [
            L10n.Common.ok,
            L10n.Common.cancel,
            L10n.Common.save,
            L10n.Common.done,
            L10n.Compress.title,
            L10n.Extract.title,
            L10n.Settings.general,
            L10n.Settings.language,
            L10n.Settings.byteUnits,
            L10n.Settings.licenseStatus
        ]
        
        for key in testKeys {
            let strEn = manager.string(for: key, language: .en)
            let strZh = manager.string(for: key, language: .zhHans)
            XCTAssertFalse(strEn.isEmpty, "Key \(key.rawKey) must have English translation")
            XCTAssertFalse(strZh.isEmpty, "Key \(key.rawKey) must have Simplified Chinese translation")
        }
    }
}
