// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

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
    
    // MARK: - Office & Spreadsheet Tests
    
    func testSheetDataConversionToRows() {
        let cells = [
            UniFfiCell(row: 1, col: 1, coordinate: "A1", value: .text(value: "Product"), formula: nil),
            UniFfiCell(row: 1, col: 2, coordinate: "B1", value: .text(value: "Price"), formula: nil),
            UniFfiCell(row: 2, col: 1, coordinate: "A2", value: .text(value: "Apple"), formula: nil),
            UniFfiCell(row: 2, col: 2, coordinate: "B2", value: .number(value: 2.5), formula: nil),
            UniFfiCell(row: 3, col: 1, coordinate: "A3", value: .text(value: "Total"), formula: nil),
            UniFfiCell(row: 3, col: 2, coordinate: "B3", value: .formula(expression: "SUM(B2)", cachedValue: "2.5"), formula: "SUM(B2)")
        ]
        
        let row1 = UniFfiSheetRow(rowNumber: 1, cells: [cells[0], cells[1]])
        let row2 = UniFfiSheetRow(rowNumber: 2, cells: [cells[2], cells[3]])
        let row3 = UniFfiSheetRow(rowNumber: 3, cells: [cells[4], cells[5]])
        
        let sheetData = UniFfiSheetData(
            sheetName: "Sheet1",
            sheetIndex: 1,
            totalRows: 3,
            totalCols: 2,
            dimensionRef: "A1:B3",
            rows: [row1, row2, row3],
            sharedStringsCount: 3
        )
        
        let rows = TTZipSpreadsheetParser.convertSheetDataToRows(sheetData)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], ["Product", "Price"])
        XCTAssertEqual(rows[1], ["Apple", "2.5"])
        XCTAssertEqual(rows[2], ["Total", "2.5"])
    }
    
    func testCellValueFormatting() {
        XCTAssertEqual(TTZipSpreadsheetParser.formatCellValue(.empty), "")
        XCTAssertEqual(TTZipSpreadsheetParser.formatCellValue(.text(value: "Hello")), "Hello")
        XCTAssertEqual(TTZipSpreadsheetParser.formatCellValue(.number(value: 42.0)), "42")
        XCTAssertEqual(TTZipSpreadsheetParser.formatCellValue(.number(value: 3.14159)), "3.14159")
        XCTAssertEqual(TTZipSpreadsheetParser.formatCellValue(.boolean(value: true)), "TRUE")
        XCTAssertEqual(TTZipSpreadsheetParser.formatCellValue(.boolean(value: false)), "FALSE")
        XCTAssertEqual(TTZipSpreadsheetParser.formatCellValue(.formula(expression: "A1+B1", cachedValue: "10")), "10")
        XCTAssertEqual(TTZipSpreadsheetParser.formatCellValue(.formula(expression: "A1+B1", cachedValue: nil)), "=A1+B1")
        XCTAssertEqual(TTZipSpreadsheetParser.formatCellValue(.error(message: "DIV/0")), "#ERR: DIV/0")
    }
    
    // MARK: - Presentation Outline Tests
    
    func testPresentationOutlineModel() {
        let outline = UniFfiOfficeOutline(
            documentType: "Presentation",
            headings: [],
            sheets: [],
            slides: [
                "Title: TTZip Architecture\nOverview of pure Safe Rust microkernel",
                "Slide 2: Performance Metrics\nZero disk spill benchmarks"
            ],
            totalSections: 2,
            summaryPreview: "TTZip presentation summary"
        )
        
        let model = OfficePresentationModel(fileName: "Overview.pptx", outline: outline)
        XCTAssertEqual(model.fileName, "Overview.pptx")
        XCTAssertEqual(model.outline.slides.count, 2)
        XCTAssertEqual(model.outline.totalSections, 2)
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
