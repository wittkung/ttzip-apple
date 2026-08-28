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
@testable import TTZipApp
@testable import TTZipCore

final class FinderSyncIntentMappingTests: XCTestCase {
    
    private var mockHarness: MockFileURLHarness!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        mockHarness = try MockFileURLHarness()
    }
    
    override func tearDownWithError() throws {
        if let h = mockHarness {
            try? h.cleanup()
        }
        mockHarness = nil
        try super.tearDownWithError()
    }
    
    // MARK: - 1. URL Scheme Query Parsing & Path Decoding
    
    func testURLSchemeQueryParsingAndPathDecoding() throws {
        let path1 = mockHarness.createFile(named: "file with spaces.txt").path
        let path2 = mockHarness.createFile(named: "CJK_測試文檔.pdf").path
        
        let joinedPaths = [path1, path2].joined(separator: "|")
        let encodedPaths = joinedPaths.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let urlString = "ttzip://action?type=compress_quick_zip&paths=\(encodedPaths)"
        
        let url = try XCTUnwrap(URL(string: urlString))
        let envelope = try XCTUnwrap(AppIntentParser.parse(url: url))
        
        if case .createArchive(let paths, let options) = envelope.intent {
            XCTAssertEqual(paths, [path1, path2])
            XCTAssertEqual(options.targetFormat, .zip)
        } else {
            XCTFail("Parsed intent did not match .createArchive")
        }
    }
    
    // MARK: - 2. All 10 FinderSync Action Types Parsing Matrix
    
    func testAllFinderSyncActionTypesParsingMatrix() throws {
        let testArchive = mockHarness.createFile(named: "archive.7z").path
        let testFile = mockHarness.createFile(named: "document.txt").path
        
        let expectations: [(String, String, (AppIntent) -> Bool)] = [
            ("extract_here", testArchive, { if case .extractArchive(let p, let o) = $0 { return p == [testArchive] && !o.isSmartExtract } else { return false } }),
            ("extract_to_subfolder", testArchive, { if case .extractArchive(let p, let o) = $0 { return p == [testArchive] && o.isSmartExtract } else { return false } }),
            ("inspect_archive", testArchive, { if case .inspectArchive(let p) = $0 { return p == testArchive } else { return false } }),
            ("compute_hash", testArchive, { if case .verifyIntegrity(let p) = $0 { return p == testArchive } else { return false } }),
            ("autofill_password", testArchive, { if case .autofillVaultPassword(let p) = $0 { return p == testArchive } else { return false } }),
            ("compress_quick_zip", testFile, { if case .createArchive(let p, let o) = $0 { return p == [testFile] && o.targetFormat == .zip } else { return false } }),
            ("compress_quick_7z", testFile, { if case .createArchive(let p, let o) = $0 { return p == [testFile] && o.targetFormat == .sevenZip } else { return false } }),
            ("compress_separate", testFile, { if case .createArchive(let p, let o) = $0 { return p == [testFile] && o.separateArchives } else { return false } }),
            ("compress_and_delete_source", testFile, { if case .createArchive(let p, let o) = $0 { return p == [testFile] && o.deleteSourceAfterCompression } else { return false } }),
            ("compress_modal_advanced", testFile, { if case .createArchive(let p, _) = $0 { return p == [testFile] } else { return false } })
        ]
        
        for (actionType, path, validator) in expectations {
            let url = try XCTUnwrap(URL(string: "ttzip://action?type=\(actionType)&paths=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"))
            let envelope = try XCTUnwrap(AppIntentParser.parse(url: url), "Failed to parse action \(actionType)")
            XCTAssertTrue(validator(envelope.intent), "Action \(actionType) did not map to expected AppIntent payload")
        }
    }
    
    // MARK: - 3. Direct File URL Dropping / Opening
    
    func testDirectFileURLParsing() throws {
        let zipURL = mockHarness.createFile(named: "package.zip")
        let dirURL = mockHarness.createDirectory(named: "ProjectFolder")
        let imgURL = mockHarness.createFile(named: "photo.jpg")
        
        let zipEnvelope = try XCTUnwrap(AppIntentParser.parse(url: zipURL))
        if case .openArchive(let url, _) = zipEnvelope.intent {
            XCTAssertEqual(url.path, zipURL.path)
        } else {
            XCTFail("Zip URL must map to openArchive")
        }
        
        let dirEnvelope = try XCTUnwrap(AppIntentParser.parse(url: dirURL))
        if case .createArchive(let paths, _) = dirEnvelope.intent {
            XCTAssertEqual(paths, [dirURL.path])
        } else {
            XCTFail("Directory URL must map to createArchive")
        }
        
        let imgEnvelope = try XCTUnwrap(AppIntentParser.parse(url: imgURL))
        if case .previewItem(let url) = imgEnvelope.intent {
            XCTAssertEqual(url.path, imgURL.path)
        } else {
            XCTFail("Image URL must map to previewItem")
        }
    }
    
    // MARK: - 4. Darwin Notification Language Synchronization
    
    func testDarwinNotificationLanguageSynchronization() throws {
        let darwinHarness = MockDarwinNotificationHarness(
            notificationName: TTZipPreferencesStore.darwinNotificationName
        )
        
        darwinHarness.startObserving {}
        
        // Trigger preference change
        TTZipPreferencesStore.saveLanguage(.zhHans)
        
        // Assert Darwin notification broadcast
        XCTAssertTrue(darwinHarness.waitForNotification(timeout: 1.0), "Darwin notification must be delivered immediately")
        XCTAssertEqual(TTZipPreferencesStore.getSavedLanguage(), .zhHans)
        
        darwinHarness.stopObserving()
    }
}
