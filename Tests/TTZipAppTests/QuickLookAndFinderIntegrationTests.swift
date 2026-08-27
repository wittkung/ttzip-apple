// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
@testable import TTZipApp
@testable import TTZipCore
@testable import TTZipFinderSync
@testable import TTZipQuickLook

final class QuickLookAndFinderIntegrationTests: XCTestCase {
    
    func test_ephemeral_preview_cache_staging_and_cleanup() async throws {
        let manager = EphemeralPreviewCacheManager.shared
        let sampleData = Data("QuickLook Test Content 2026".utf8)
        let fileName = "sample_test_entry.txt"
        
        let stagedURL = try await manager.stageFile(data: sampleData, suggestedFileName: fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        
        let readData = try Data(contentsOf: stagedURL)
        XCTAssertEqual(readData, sampleData)
        
        await manager.cleanupAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }
    
    func test_archive_drag_item_provider_factory() {
        let itemProvider = ArchiveDragItemProviderFactory.createItemProvider(
            archivePath: "/tmp/fake_archive.zip",
            entryPath: "docs/spec.pdf",
            suggestedFileName: "spec.pdf"
        )
        
        XCTAssertNotNil(itemProvider)
        XCTAssertEqual(itemProvider.suggestedName, "spec.pdf")
    }
    
    func test_quicklook_format_identifier_mapping_all_16_formats() {
        for format in ArchiveCompressionFormat.allCases {
            let qlId = QuickLookFormatIdentifier.from(format: format)
            XCTAssertFalse(qlId.rawValue.isEmpty, "Format \(format) must map to non-empty QuickLook identifier")
        }
    }
    
    func test_findersync_context_menu_generation_for_archives() {
        let testURLs = [
            URL(fileURLWithPath: "/tmp/test.zip"),
            URL(fileURLWithPath: "/tmp/archive.7z")
        ]
        
        let menuItems = FinderSyncHelper.shared.getContextMenuItems(selectedURLs: testURLs)
        XCTAssertFalse(menuItems.isEmpty, "Context menu items should be generated for archive URLs")
        
        let actionIds = menuItems.map { $0.actionIdentifier }
        XCTAssertTrue(actionIds.contains("extract_here"))
        XCTAssertTrue(actionIds.contains("extract_to_subfolder"))
        XCTAssertTrue(actionIds.contains("inspect_archive"))
    }
    
    func test_findersync_action_request_ipc_json_roundtrip() throws {
        let original = FinderSyncActionRequest(
            action: .extractHere,
            sourcePaths: ["/Users/test/archive.zip"],
            destinationDirectory: "/Users/test/output"
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FinderSyncActionRequest.self, from: data)
        
        XCTAssertEqual(decoded.actionIdentifier, "extract_here")
        XCTAssertEqual(decoded.sourcePaths, ["/Users/test/archive.zip"])
        XCTAssertEqual(decoded.destinationDirectory, "/Users/test/output")
    }
    
    @MainActor
    func test_findersync_extension_lifecycle_and_badge_requests() {
        let sync = FinderSync()
        XCTAssertNotNil(sync)
        
        // Supported extensions get badge requested
        sync.requestBadgeIdentifier(for: URL(fileURLWithPath: "/tmp/package.zip"))
        sync.requestBadgeIdentifier(for: URL(fileURLWithPath: "/tmp/package.7z"))
        sync.requestBadgeIdentifier(for: URL(fileURLWithPath: "/tmp/plain.txt"))
    }
    
    @MainActor
    func test_quicklook_preview_view_controller_view_hierarchy() async throws {
        let vc = QuickLookPreviewViewController()
        vc.loadView()
        
        XCTAssertNotNil(vc.view)
        XCTAssertEqual(vc.view.frame.width, 800.0)
        XCTAssertEqual(vc.view.frame.height, 600.0)
        
        // Create a temporary zip archive
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("QLVCTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let dummyDoc = tempDir.appendingPathComponent("note.txt")
        try "Preview content".write(to: dummyDoc, atomically: true, encoding: .utf8)
        let zipURL = tempDir.appendingPathComponent("preview_test.zip")
        
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [dummyDoc.path]
        )
        
        let exp = expectation(description: "Preview prepared")
        vc.preparePreviewOfFile(at: zipURL) { error in
            XCTAssertNil(error)
            exp.fulfill()
        }
        
        await fulfillment(of: [exp], timeout: 5.0)
    }
}
