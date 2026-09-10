// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class AppLocalizationTests: XCTestCase {
    
    // MARK: - 1. Inspector Localization Keys Verification
    
    /// Verifies that all localization keys under L10n.Inspector resolve to deterministic,
    /// non-empty translations across Simplified Chinese (Hans), Traditional Chinese (Hant),
    /// and English (EN) catalogs without falling back to raw keys.
    func testInspectorLocalizationKeysExistAndCorrect() {
        let manager = TTZipLocalizationManager.shared
        let inspectorKeys = L10n.Inspector.allCases
        
        XCTAssertFalse(inspectorKeys.isEmpty, "L10n.Inspector must define key cases")
        
        // 1. Simplified Chinese (zh-Hans)
        for key in inspectorKeys {
            let str = manager.string(for: key, language: .zhHans)
            XCTAssertFalse(str.isEmpty, "Key '\(key.rawKey)' must have non-empty zh-Hans translation")
            XCTAssertNotEqual(str, key.rawKey, "Key '\(key.rawKey)' must not fall back to raw key in zh-Hans")
        }
        XCTAssertEqual(manager.string(for: L10n.Inspector.title, language: .zhHans), "检视器")
        XCTAssertEqual(manager.string(for: L10n.Inspector.directoryCanvas, language: .zhHans), "目录画布")
        XCTAssertEqual(manager.string(for: L10n.Inspector.overviewFs, language: .zhHans), "概览与文件系统")
        XCTAssertEqual(manager.string(for: L10n.Inspector.emptyDirectory, language: .zhHans), "空目录")
        XCTAssertEqual(manager.string(for: L10n.Inspector.contentBreakdown, language: .zhHans), "内容结构分布")
        XCTAssertEqual(manager.string(for: L10n.Inspector.fileSystem, language: .zhHans), "文件系统")
        XCTAssertEqual(manager.string(for: L10n.Inspector.items, language: .zhHans), "项目数")
        XCTAssertEqual(manager.string(for: L10n.Inspector.modified, language: .zhHans), "修改时间")
        XCTAssertEqual(manager.string(for: L10n.Inspector.ownerGroup, language: .zhHans), "所有者 / 用户组")
        XCTAssertEqual(manager.string(for: L10n.Inspector.permissions, language: .zhHans), "POSIX 权限")
        XCTAssertEqual(manager.string(for: L10n.Inspector.size, language: .zhHans), "大小")
        
        // 2. Traditional Chinese (zh-Hant)
        for key in inspectorKeys {
            let str = manager.string(for: key, language: .zhHant)
            XCTAssertFalse(str.isEmpty, "Key '\(key.rawKey)' must have non-empty zh-Hant translation")
            XCTAssertNotEqual(str, key.rawKey, "Key '\(key.rawKey)' must not fall back to raw key in zh-Hant")
        }
        XCTAssertEqual(manager.string(for: L10n.Inspector.title, language: .zhHant), "檢視器")
        XCTAssertEqual(manager.string(for: L10n.Inspector.directoryCanvas, language: .zhHant), "目錄畫布")
        XCTAssertEqual(manager.string(for: L10n.Inspector.overviewFs, language: .zhHant), "概覽與檔案系統")
        XCTAssertEqual(manager.string(for: L10n.Inspector.emptyDirectory, language: .zhHant), "空目錄")
        XCTAssertEqual(manager.string(for: L10n.Inspector.contentBreakdown, language: .zhHant), "內容結構分佈")
        XCTAssertEqual(manager.string(for: L10n.Inspector.fileSystem, language: .zhHant), "檔案系統")
        XCTAssertEqual(manager.string(for: L10n.Inspector.items, language: .zhHant), "項目數")
        XCTAssertEqual(manager.string(for: L10n.Inspector.modified, language: .zhHant), "修改時間")
        XCTAssertEqual(manager.string(for: L10n.Inspector.ownerGroup, language: .zhHant), "擁有者 / 群組")
        XCTAssertEqual(manager.string(for: L10n.Inspector.permissions, language: .zhHant), "POSIX 權限")
        XCTAssertEqual(manager.string(for: L10n.Inspector.size, language: .zhHant), "大小")
        
        // 3. English (en)
        for key in inspectorKeys {
            let str = manager.string(for: key, language: .en)
            XCTAssertFalse(str.isEmpty, "Key '\(key.rawKey)' must have non-empty English translation")
            XCTAssertNotEqual(str, key.rawKey, "Key '\(key.rawKey)' must not fall back to raw key in English")
        }
        XCTAssertEqual(manager.string(for: L10n.Inspector.title, language: .en), "INSPECTOR")
        XCTAssertEqual(manager.string(for: L10n.Inspector.directoryCanvas, language: .en), "DIRECTORY CANVAS")
        XCTAssertEqual(manager.string(for: L10n.Inspector.overviewFs, language: .en), "OVERVIEW & FILE SYSTEM")
        XCTAssertEqual(manager.string(for: L10n.Inspector.emptyDirectory, language: .en), "Empty Directory")
        XCTAssertEqual(manager.string(for: L10n.Inspector.contentBreakdown, language: .en), "CONTENT BREAKDOWN")
        XCTAssertEqual(manager.string(for: L10n.Inspector.fileSystem, language: .en), "File System")
        XCTAssertEqual(manager.string(for: L10n.Inspector.items, language: .en), "Items")
        XCTAssertEqual(manager.string(for: L10n.Inspector.modified, language: .en), "Modified")
        XCTAssertEqual(manager.string(for: L10n.Inspector.ownerGroup, language: .en), "Owner / Group")
        XCTAssertEqual(manager.string(for: L10n.Inspector.permissions, language: .en), "POSIX Permissions")
        XCTAssertEqual(manager.string(for: L10n.Inspector.size, language: .en), "Size")
    }
    
    // MARK: - 2. System Directory Display Name Resolution
    
    /// Verifies that FileManager.default.displayName(atPath:) and DiskItemInfo.displayName
    /// resolve accurately against local user directories (Downloads, Documents, Desktop) in the
    /// active system locale, and safely fall back to raw entry name for virtual archive paths.
    func testSystemDirectoryDisplayNameResolution() {
        let fileManager = FileManager.default
        let testSearchDirectories: [FileManager.SearchPathDirectory] = [
            .downloadsDirectory,
            .documentDirectory,
            .desktopDirectory
        ]
        
        // 1. Verify standard local user directories
        for searchDir in testSearchDirectories {
            guard let url = fileManager.urls(for: searchDir, in: .userDomainMask).first,
                  fileManager.fileExists(atPath: url.path) else {
                continue
            }
            
            let systemExpectedName = fileManager.displayName(atPath: url.path)
            let item = DiskItemInfo(url: url)
            
            XCTAssertFalse(item.displayName.isEmpty, "Display name for \(url.path) must not be empty")
            XCTAssertEqual(item.displayName, systemExpectedName, "DiskItemInfo.displayName must match FileManager.displayName for \(url.path)")
            XCTAssertTrue(item.isDirectory, "Standard user directory should be identified as directory")
        }
        
        // 2. Verify virtual archive path (ttzip:// schema with subpath) safely falls back to name
        let virtualFileURL = URL(string: "ttzip://archive.zip?subpath=documents/report.pdf")!
        let virtualFileItem = DiskItemInfo(
            virtualName: "report.pdf",
            virtualURL: virtualFileURL,
            isDirectory: false,
            isArchive: false,
            sizeText: "10 KB",
            rawSizeBytes: 10240,
            kindText: "PDF Document"
        )
        XCTAssertEqual(virtualFileItem.displayName, "report.pdf", "Virtual file item displayName must safely fall back to raw name")
        
        // 3. Verify virtual directory path safely falls back to directory name
        let virtualDirURL = URL(string: "ttzip://project.tar.gz?subpath=src/components")!
        let virtualDirItem = DiskItemInfo(
            virtualName: "components",
            virtualURL: virtualDirURL,
            isDirectory: true,
            isArchive: false,
            sizeText: "0 B",
            rawSizeBytes: 0,
            kindText: "Folder"
        )
        XCTAssertEqual(virtualDirItem.displayName, "components", "Virtual directory displayName must safely fall back to raw name")
        
        // 4. Verify custom/unknown URI scheme safely falls back to name
        let customSchemeURL = URL(string: "ttzip://root_level_entry")!
        let customSchemeItem = DiskItemInfo(
            virtualName: "root_level_entry",
            virtualURL: customSchemeURL,
            isDirectory: false,
            isArchive: false,
            sizeText: "100 B",
            rawSizeBytes: 100,
            kindText: "Binary"
        )
        XCTAssertEqual(customSchemeItem.displayName, "root_level_entry", "Custom scheme URL must safely fall back to raw name")
    }
    
    // MARK: - 3. Compound Quantifier Formatting & Plural Boundaries
    
    /// Verifies units.files_and_directories compound quantifier formatting in Chinese and English,
    /// ensuring correct singular and plural boundaries in English and natural counter output in Chinese.
    @MainActor
    func testFilesAndDirectoriesQuantifierFormatting() {
        let state = AppLocalizationState.shared
        let originalLanguage = state.currentLanguage
        defer {
            state.setLanguage(originalLanguage)
        }
        
        // 1. Simplified Chinese (zh-Hans)
        state.setLanguage(.zhHans)
        XCTAssertEqual(
            state.formatFilesAndDirectories(files: 1, directories: 0),
            "1 个文件 · 0 个文件夹"
        )
        XCTAssertEqual(
            state.formatFilesAndDirectories(files: 0, directories: 1),
            "0 个文件 · 1 个文件夹"
        )
        XCTAssertEqual(
            state.formatFilesAndDirectories(files: 12, directories: 3),
            "12 个文件 · 3 个文件夹"
        )
        // Direct template formatting check
        let directHans = state.format(L10n.Units.filesAndDirectories, 1, 0)
        XCTAssertEqual(directHans, "1 个文件 · 0 个文件夹")
        
        // 2. Traditional Chinese (zh-Hant)
        state.setLanguage(.zhHant)
        XCTAssertEqual(
            state.formatFilesAndDirectories(files: 1, directories: 0),
            "1 個檔案 · 0 個資料夾"
        )
        XCTAssertEqual(
            state.formatFilesAndDirectories(files: 5, directories: 2),
            "5 個檔案 · 2 個資料夾"
        )
        let directHant = state.format(L10n.Units.filesAndDirectories, 1, 0)
        XCTAssertEqual(directHant, "1 個檔案 · 0 個資料夾")
        
        // 3. English (en) - Singular / Plural Boundary Assertions
        state.setLanguage(.en)
        
        // Case A: 1 File, 1 Directory (Singular / Singular)
        XCTAssertEqual(
            state.formatFilesAndDirectories(files: 1, directories: 1),
            "1 File · 1 Directory"
        )
        
        // Case B: 1 File, 0 Directories (Singular File, Plural Directory)
        XCTAssertEqual(
            state.formatFilesAndDirectories(files: 1, directories: 0),
            "1 File · 0 Directories"
        )
        
        // Case C: 0 Files, 1 Directory (Plural File, Singular Directory)
        XCTAssertEqual(
            state.formatFilesAndDirectories(files: 0, directories: 1),
            "0 Files · 1 Directory"
        )
        
        // Case D: Multiple Files, Multiple Directories (Plural / Plural)
        XCTAssertEqual(
            state.formatFilesAndDirectories(files: 5, directories: 3),
            "5 Files · 3 Directories"
        )
        
        // Case E: 0 Files, 0 Directories (Zero boundary behaves as Plural in English)
        XCTAssertEqual(
            state.formatFilesAndDirectories(files: 0, directories: 0),
            "0 Files · 0 Directories"
        )
        
        // Direct template check
        let directEn = state.format(L10n.Units.filesAndDirectories, 5, 2)
        XCTAssertEqual(directEn, "5 Files · 2 Directories")
    }
    
    // MARK: - 4. State Switching Responsiveness
    
    /// Verifies that switching currentLanguage on AppLocalizationState immediately updates
    /// both state and core localization engine without caching lag, with latency strictly under 50ms.
    @MainActor
    func testAppLocalizationStateSwitchingResponsiveness() {
        let state = AppLocalizationState.shared
        let originalLanguage = state.currentLanguage
        defer {
            state.setLanguage(originalLanguage)
            AppLocalizationState.onLanguageChanged = nil
        }
        
        final class LanguageBox: @unchecked Sendable {
            var language: AppLanguage?
        }
        let box = LanguageBox()
        AppLocalizationState.onLanguageChanged = { lang in
            box.language = lang
        }
        
        // Establish known baseline language (.en)
        state.setLanguage(.en)
        XCTAssertEqual(state.currentLanguage, .en)
        
        let clock = ContinuousClock()
        
        // 1. Switch to Simplified Chinese
        box.language = nil
        let hansDuration = clock.measure {
            state.setLanguage(.zhHans)
        }
        XCTAssertEqual(state.currentLanguage, .zhHans)
        XCTAssertEqual(TTZipLocalizationManager.shared.currentLanguage, .zhHans)
        XCTAssertEqual(state.t(L10n.Inspector.title), "检视器")
        XCTAssertEqual(state.t(L10n.Inspector.directoryCanvas), "目录画布")
        XCTAssertEqual(box.language, .zhHans)
        XCTAssertLessThan(hansDuration, .milliseconds(50), "zhHans switch latency must be < 50ms")
        
        // 2. Switch to Traditional Chinese
        box.language = nil
        let hantDuration = clock.measure {
            state.setLanguage(.zhHant)
        }
        XCTAssertEqual(state.currentLanguage, .zhHant)
        XCTAssertEqual(TTZipLocalizationManager.shared.currentLanguage, .zhHant)
        XCTAssertEqual(state.t(L10n.Inspector.title), "檢視器")
        XCTAssertEqual(state.t(L10n.Inspector.directoryCanvas), "目錄畫布")
        XCTAssertEqual(box.language, .zhHant)
        XCTAssertLessThan(hantDuration, .milliseconds(50), "zhHant switch latency must be < 50ms")
        
        // 3. Switch to English
        box.language = nil
        let enDuration = clock.measure {
            state.setLanguage(.en)
        }
        XCTAssertEqual(state.currentLanguage, .en)
        XCTAssertEqual(TTZipLocalizationManager.shared.currentLanguage, .en)
        XCTAssertEqual(state.t(L10n.Inspector.title), "INSPECTOR")
        XCTAssertEqual(state.t(L10n.Inspector.directoryCanvas), "DIRECTORY CANVAS")
        XCTAssertEqual(box.language, .en)
        XCTAssertLessThan(enDuration, .milliseconds(50), "English switch latency must be < 50ms")
        
        // 4. Repeated switches should not degrade performance
        for _ in 0..<10 {
            state.setLanguage(.zhHans)
            XCTAssertEqual(state.t(L10n.Inspector.title), "检视器")
            state.setLanguage(.en)
            XCTAssertEqual(state.t(L10n.Inspector.title), "INSPECTOR")
        }
    }
}
