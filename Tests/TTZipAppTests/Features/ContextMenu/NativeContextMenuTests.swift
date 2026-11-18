// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import TTZipUI
@testable import TTZipCore
@testable import TTZipApp

final class NativeContextMenuTests: XCTestCase {
    
    @MainActor
    func testSinglePhysicalFileMenuStructure() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "ContextMenu")
        let prev = AppLocalizationState.shared.currentLanguage
        defer { AppLocalizationState.shared.setLanguage(prev) }
        AppLocalizationState.shared.setLanguage(.zhHans)
        let testFileURL = tempDirURL.appendingPathComponent("sample_document.txt")
        try "Test Plain Content".write(to: testFileURL, atomically: true, encoding: .utf8)
        
        let target = TTZipContextMenuTarget.singleItem(url: testFileURL, isDirectory: false, isArchive: false)
        let menu = TTZipContextMenuBuilder.shared.buildMenu(for: target)
        
        let titles = menu.items.map(\.title)
        
        // Assert Finder standard open and open with
        XCTAssertTrue(titles.contains("打开"))
        XCTAssertTrue(titles.contains("打开方式"))
        
        // Assert Open With submenu exists and contains App Store and Other
        let openWithItem = menu.items.first(where: { $0.title == "打开方式" })
        XCTAssertNotNil(openWithItem?.submenu)
        let openWithSubtitles = openWithItem?.submenu?.items.map(\.title) ?? []
        XCTAssertTrue(openWithSubtitles.contains("App Store..."))
        XCTAssertTrue(openWithSubtitles.contains("其它..."))
        
        // Assert TTZip compression actions
        XCTAssertTrue(titles.contains(where: { $0.contains("压缩为") }))
        
        // Assert Quick Look and Services
        XCTAssertTrue(titles.contains(where: { $0.contains("快速查看") }))
        XCTAssertTrue(titles.contains("服务"))
        
        // Assert menu plugin suppression
        XCTAssertFalse(menu.allowsContextMenuPlugIns)
        
        // Assert Rename, Duplicate, New Folder
        XCTAssertTrue(titles.contains("重命名"))
        XCTAssertTrue(titles.contains("创建副本"))
        XCTAssertTrue(titles.contains("新建文件夹"))
        
        // Assert Copy and Non-alternate Copy as Path
        let copyItem = menu.items.first(where: { $0.title.hasPrefix("拷贝") && $0.keyEquivalentModifierMask == [.command] })
        XCTAssertNotNil(copyItem)
        XCTAssertEqual(copyItem?.keyEquivalent, "c")
        XCTAssertEqual(copyItem?.keyEquivalentModifierMask, [.command])
        
        let copyPathItem = menu.items.first(where: { $0.keyEquivalentModifierMask == [.command, .option] })
        XCTAssertNotNil(copyPathItem)
        XCTAssertEqual(copyPathItem?.title, "拷贝“sample_document.txt”为路径名称")
        XCTAssertFalse(copyPathItem?.isAlternate ?? true)
        
        // Assert Reveal in Finder and Move to Trash
        XCTAssertTrue(titles.contains("在访达中显示"))
        XCTAssertTrue(titles.contains("移到废纸篓"))
    }
    
    @MainActor
    func testArchiveFileMenuSpecializedActions() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "ContextMenu")
        let prev = AppLocalizationState.shared.currentLanguage
        defer { AppLocalizationState.shared.setLanguage(prev) }
        AppLocalizationState.shared.setLanguage(.zhHans)
        
        let zipURL = tempDirURL.appendingPathComponent("bundle.zip")
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: zipURL)
        
        let target = TTZipContextMenuTarget.singleItem(url: zipURL, isDirectory: false, isArchive: true)
        let menu = TTZipContextMenuBuilder.shared.buildMenu(for: target)
        
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("解压到当前位置"))
        XCTAssertTrue(titles.contains("在检查器中浏览"))
    }
    
    @MainActor
    func testMultipleItemsMenuActions() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "ContextMenu")
        let prev = AppLocalizationState.shared.currentLanguage
        defer { AppLocalizationState.shared.setLanguage(prev) }
        AppLocalizationState.shared.setLanguage(.zhHans)
        
        let url1 = tempDirURL.appendingPathComponent("file1.txt")
        let url2 = tempDirURL.appendingPathComponent("file2.txt")
        try "1".write(to: url1, atomically: true, encoding: .utf8)
        try "2".write(to: url2, atomically: true, encoding: .utf8)
        
        let target = TTZipContextMenuTarget.multipleItems(urls: [url1, url2])
        let menu = TTZipContextMenuBuilder.shared.buildMenu(for: target)
        
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains(where: { $0.contains("新建归档 (2 个项目)") }))
        XCTAssertTrue(titles.contains(where: { $0.contains("拷贝 (2 个项目)") }))
        XCTAssertTrue(titles.contains(where: { $0.contains("移到废纸篓 (2 个项目)") }))

        // Verify that invoking default "Open (2 Items)" dispatches .openWithDefaultApp per URL
        // through the FileViewerService boundary (rather than treating firstURL as an application bundle).
        let mockViewer = MockFileViewerHarness()
        let state = AppViewState(fileViewer: mockViewer)
        BrowserWindowRegistry.shared.register(state)
        BrowserWindowRegistry.shared.activateWindow(id: state.windowID)
        AppIntentDispatcher.shared.bind(state: state)
        defer {
            AppIntentDispatcher.shared.unregister(windowID: state.windowID)
            state.prepareForWindowClose()
        }

        let openItem = try XCTUnwrap(menu.items.first(where: { $0.title.contains("打开") && !$0.title.contains("方式") }))
        let action = try XCTUnwrap(openItem.action)
        _ = openItem.target?.perform(action, with: openItem)
        XCTAssertEqual(
            mockViewer.openedURLs.map { $0.standardizedFileURL.path },
            [url1, url2].map { $0.standardizedFileURL.path },
            "Multi-selection default Open must route each selected file through FileViewerService"
        )
    }
    
    @MainActor
    func testVirtualArchiveEntryMenuActions() {
        let prev = AppLocalizationState.shared.currentLanguage
        defer { AppLocalizationState.shared.setLanguage(prev) }
        AppLocalizationState.shared.setLanguage(.zhHans)
        
        let target = TTZipContextMenuTarget.virtualArchiveEntry(archivePath: "/tmp/fake.zip", subpath: "docs/readme.txt", isDirectory: false)
        let menu = TTZipContextMenuBuilder.shared.buildMenu(for: target)
        
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("解压选中项"))
        XCTAssertTrue(titles.contains("替换为..."))
        XCTAssertTrue(titles.contains("删除"))
        XCTAssertTrue(titles.contains("拷贝路径"))
    }
    
    @MainActor
    func testColumnBackgroundMenuActions() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "ContextMenu")
        let prev = AppLocalizationState.shared.currentLanguage
        defer { AppLocalizationState.shared.setLanguage(prev) }
        AppLocalizationState.shared.setLanguage(.zhHans)
        
        let target = TTZipContextMenuTarget.columnBackground(directoryURL: tempDirURL)
        let menu = TTZipContextMenuBuilder.shared.buildMenu(for: target)
        
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("新建文件夹"))
        XCTAssertTrue(titles.contains("新建文件"))
    }
    
    @MainActor
    func testSingleItemMenuExtendedActionsAndPluginSuppression() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "ContextMenuExt")
        let prev = AppLocalizationState.shared.currentLanguage
        defer { AppLocalizationState.shared.setLanguage(prev) }
        
        let testFileURL = tempDirURL.appendingPathComponent("note.txt")
        try "Content".write(to: testFileURL, atomically: true, encoding: .utf8)
        let target = TTZipContextMenuTarget.singleItem(url: testFileURL, isDirectory: false, isArchive: false)
        
        // 1. Verify zhHans
        AppLocalizationState.shared.setLanguage(.zhHans)
        let zhMenu = TTZipContextMenuBuilder.shared.buildMenu(for: target)
        XCTAssertFalse(zhMenu.allowsContextMenuPlugIns)
        let zhTitles = zhMenu.items.map(\.title)
        XCTAssertTrue(zhTitles.contains("重命名"))
        XCTAssertTrue(zhTitles.contains("创建副本"))
        XCTAssertTrue(zhTitles.contains("新建文件夹"))
        
        let zhCopyPath = zhMenu.items.first(where: { $0.keyEquivalentModifierMask == [.command, .option] })
        XCTAssertNotNil(zhCopyPath)
        XCTAssertFalse(zhCopyPath?.isAlternate ?? true)
        
        // 2. Verify en
        AppLocalizationState.shared.setLanguage(.en)
        let enMenu = TTZipContextMenuBuilder.shared.buildMenu(for: target)
        XCTAssertFalse(enMenu.allowsContextMenuPlugIns)
        let enTitles = enMenu.items.map(\.title)
        XCTAssertTrue(enTitles.contains("Rename"))
        XCTAssertTrue(enTitles.contains("Duplicate"))
        XCTAssertTrue(enTitles.contains("New Folder"))
        
        let enCopyPath = enMenu.items.first(where: { $0.keyEquivalentModifierMask == [.command, .option] })
        XCTAssertNotNil(enCopyPath)
        XCTAssertFalse(enCopyPath?.isAlternate ?? true)
    }
}
