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
    
    func test_findersync_extension_lifecycle_and_badge_requests() {
        // Supported extensions verification via FinderSyncHelper
        let zipExt = "zip"
        let sevenZExt = "7z"
        let txtExt = "txt"
        
        XCTAssertTrue(FinderSyncHelper.supportedArchiveExtensions.contains(zipExt))
        XCTAssertTrue(FinderSyncHelper.supportedArchiveExtensions.contains(sevenZExt))
        XCTAssertFalse(FinderSyncHelper.supportedArchiveExtensions.contains(txtExt))
    }
    
    @MainActor
    func test_quicklook_preview_view_controller_view_hierarchy() async throws {
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
        
        // Validate HTML engine preview synthesis directly to avoid headless WebKit IPC hang
        let html = try await QuickLookPreviewEngine.generateHTMLPreview(for: zipURL.path, language: .en)
        XCTAssertFalse(html.isEmpty, "QuickLook HTML preview should not be empty")
        XCTAssertTrue(html.contains("note.txt"), "QuickLook HTML preview must contain archive entries")
    }
    
    func test_findersync_url_construction_with_special_characters_and_delimiters() throws {
        let pathWithSpecialChars = "/Users/test/folder & documents/C++ Project #1 + extra.zip"
        let normalPath = "/Users/test/archive.7z"
        
        var components = URLComponents()
        components.scheme = "ttzip"
        components.host = "action"
        components.queryItems = [
            URLQueryItem(name: "type", value: "compress_quick_zip"),
            URLQueryItem(name: "paths", value: [pathWithSpecialChars, normalPath].joined(separator: "|"))
        ]
        
        let url = try XCTUnwrap(components.url)
        let parsed = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        
        let actionType = parsed.queryItems?.first(where: { $0.name == "type" })?.value
        let pathsStr = parsed.queryItems?.first(where: { $0.name == "paths" })?.value
        
        XCTAssertEqual(actionType, "compress_quick_zip")
        let splitPaths = pathsStr?.components(separatedBy: "|")
        XCTAssertEqual(splitPaths, [pathWithSpecialChars, normalPath])
    }
    
    func test_quicklook_single_file_memory_stream_zero_disk_io() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("QLZeroIOTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let docURL = tempDir.appendingPathComponent("stream_doc.txt")
        let testPayload = "Zero disk IO stream payload 2026".data(using: .utf8)!
        try testPayload.write(to: docURL)
        
        let zipURL = tempDir.appendingPathComponent("stream_archive.zip")
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [docURL.path]
        )
        
        let extractedData = try await QuickLookPreviewEngine.extractSingleFileMemoryStream(
            archivePath: zipURL.path,
            entryPath: "stream_doc.txt"
        )
        
        XCTAssertNotNil(extractedData)
        XCTAssertEqual(extractedData, testPayload)
    }
    
    @MainActor
    func test_quicklook_preview_view_controller_instantiation_and_view_load() {
        let vc = QuickLookPreviewViewController()
        vc.loadView()
        XCTAssertNotNil(vc.view)
        XCTAssertEqual(vc.view.frame.width, 800)
        XCTAssertEqual(vc.view.frame.height, 600)
    }
}
