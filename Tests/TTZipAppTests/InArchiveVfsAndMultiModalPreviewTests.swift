// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
@testable import TTZipPreviewKit
@testable import TTZipCore
@testable import TTZipApp

final class InArchiveVfsAndMultiModalPreviewTests: XCTestCase {
    
    // MARK: - TTZipArchiveVfsProvider Tests
    
    func testVfsUrlGenerationAndParsing() {
        let provider = TTZipArchiveVfsProvider.shared
        let archivePath = "/Users/test/archive.7z"
        let entryPath = "documents/subfolder/readme.txt"
        
        let vfsURL = provider.vfsURL(archivePath: archivePath, password: "secret", entryPath: entryPath)
        XCTAssertEqual(vfsURL.scheme, TTZipVfsSchemeHandler.scheme)
        
        guard let (archiveId, parsedPath) = provider.parseVfsUri(vfsURL.absoluteString) else {
            XCTFail("Failed to parse VFS URI")
            return
        }
        
        XCTAssertFalse(archiveId.isEmpty)
        XCTAssertEqual(parsedPath, "documents/subfolder/readme.txt")
    }
    
    func testPathNormalizationSecurity() {
        XCTAssertEqual(TTZipArchiveVfsProvider.normalizePath("a/b/../c/./d.txt"), "a/c/d.txt")
        XCTAssertEqual(TTZipArchiveVfsProvider.normalizePath("../../../etc/passwd"), "etc/passwd")
        XCTAssertEqual(TTZipArchiveVfsProvider.normalizePath("//var//log//app.log"), "var/log/app.log")
        XCTAssertEqual(TTZipArchiveVfsProvider.normalizePath("folder\\sub\\file.png"), "folder/sub/file.png")
    }
    
    func testMimeTypeResolution() {
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "index.html"), "text/html; charset=utf-8")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "style.css"), "text/css; charset=utf-8")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "app.js"), "application/javascript; charset=utf-8")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "photo.jpg"), "image/jpeg")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "graphic.svg"), "image/svg+xml")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "document.pdf"), "application/pdf")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "book.epub"), "application/epub+zip")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "clip.mp4"), "video/mp4")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "audio.mp3"), "audio/mpeg")
    }
    
    func testInMemoryCachingAndRetrieval() async throws {
        let provider = TTZipArchiveVfsProvider.shared
        let archivePath = "/tmp/test_cache_\(UUID().uuidString).zip"
        let archiveId = provider.registerArchive(archivePath: archivePath, password: nil)
        let sampleData = Data("Hello VFS In-Memory Streaming".utf8)
        
        provider.cacheEntryData(archiveId: archiveId, entryPath: "test.txt", data: sampleData)
        let vfsURL = provider.makeVfsURL(archiveId: archiveId, entryPath: "test.txt")
        
        let cached = provider.cachedData(for: vfsURL.absoluteString)
        XCTAssertEqual(cached, sampleData)
        
        let res = try await provider.loadResource(uri: vfsURL.absoluteString)
        XCTAssertNotNil(res)
        XCTAssertEqual(res?.data, sampleData)
        XCTAssertEqual(res?.mimeType, "text/plain; charset=utf-8")
        
        let rangeRes = try await provider.loadResourceRange(uri: vfsURL.absoluteString, byteRange: 0...4)
        XCTAssertNotNil(rangeRes)
        XCTAssertEqual(rangeRes?.fullSize, Int64(sampleData.count))
        XCTAssertEqual(rangeRes?.data, Data("Hello".utf8))
    }
    
    
    // MARK: - MediaPreviewFactory Extensions Tests
    
    func testOfficeExtensionsInFactory() {
        XCTAssertTrue(MediaPreviewFactory.spreadsheetExtensions.contains("xlsx"))
        XCTAssertTrue(MediaPreviewFactory.spreadsheetExtensions.contains("ods"))
        XCTAssertTrue(MediaPreviewFactory.spreadsheetExtensions.contains("csv"))
        XCTAssertTrue(MediaPreviewFactory.presentationExtensions.contains("pptx"))
        XCTAssertTrue(MediaPreviewFactory.presentationExtensions.contains("odp"))
        XCTAssertTrue(MediaPreviewFactory.docxExtensions.contains("docx"))
    }
    
    func testDetectTypeFromMemory() {
        let csvData = Data("Name,Score\nAlice,100\nBob,95".utf8)
        let type = MediaPreviewFactory.detectTypeFromMemory(data: csvData, suggestedName: "scores.csv")
        switch type {
        case .spreadsheetTable(let content, _):
            XCTAssertTrue(content.contains("Alice"))
        default:
            XCTFail("Expected spreadsheetTable for scores.csv")
        }
        
        let pdfBytes = Data("%PDF-1.4\n%header".utf8)
        let pdfType = MediaPreviewFactory.detectTypeFromMemory(data: pdfBytes, suggestedName: "document.pdf")
        switch pdfType {
        case .pdfData(let d, _):
            XCTAssertEqual(d, pdfBytes)
        default:
            XCTFail("Expected pdfData for document.pdf")
        }
    }
}
