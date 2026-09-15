// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import AppKit
import TTZipUI
@testable import TTZipCore
@testable import TTZipApp

final class NativeContextMenuTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let tempDirURL = tempDirURL {
            try? FileManager.default.removeItem(at: tempDirURL)
        }
        try super.tearDownWithError()
    }
    
    @MainActor
    func testSinglePhysicalFileMenuStructure() throws {
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
        
        // Assert Copy and Alternate Copy as Path
        let copyItem = menu.items.first(where: { $0.title.hasPrefix("拷贝") && !$0.isAlternate })
        XCTAssertNotNil(copyItem)
        XCTAssertEqual(copyItem?.keyEquivalent, "c")
        XCTAssertEqual(copyItem?.keyEquivalentModifierMask, [.command])
        
        let copyPathItem = menu.items.first(where: { $0.isAlternate })
        XCTAssertNotNil(copyPathItem)
        XCTAssertEqual(copyPathItem?.title, "拷贝“sample_document.txt”为路径名称")
        XCTAssertEqual(copyPathItem?.keyEquivalentModifierMask, [.command, .option])
        
        // Assert Reveal in Finder and Move to Trash
        XCTAssertTrue(titles.contains("在访达中显示"))
        XCTAssertTrue(titles.contains("移到废纸篓"))
    }
    
    @MainActor
    func testArchiveFileMenuSpecializedActions() throws {
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
    func testColumnBackgroundMenuActions() {
        let prev = AppLocalizationState.shared.currentLanguage
        defer { AppLocalizationState.shared.setLanguage(prev) }
        AppLocalizationState.shared.setLanguage(.zhHans)
        
        let target = TTZipContextMenuTarget.columnBackground(directoryURL: tempDirURL)
        let menu = TTZipContextMenuBuilder.shared.buildMenu(for: target)
        
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("新建文件夹"))
        XCTAssertTrue(titles.contains("新建文件"))
    }
}
