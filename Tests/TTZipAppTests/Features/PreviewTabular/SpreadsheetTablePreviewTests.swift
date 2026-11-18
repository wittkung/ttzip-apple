// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import TTZipUI
import TTMediaKit
@testable import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class SpreadsheetTablePreviewTests: XCTestCase {
    
    // MARK: - 1. RFC 4180 Parsing Compliance
    
    func testRFC4180BasicCSV() {
        let csv = """
        Name,Age,Role
        Alice,30,Developer
        Bob,25,Designer
        """
        let rows = TTZipSpreadsheetParser.parse(text: csv, delimiter: ",")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], ["Name", "Age", "Role"])
        XCTAssertEqual(rows[1], ["Alice", "30", "Developer"])
        XCTAssertEqual(rows[2], ["Bob", "25", "Designer"])
    }
    
    func testRFC4180QuotedFieldsWithDelimiters() {
        let csv = """
        "Apple, Inc.",150.25,"Cupertino, California"
        "Google, LLC",2800.50,"Mountain View, California"
        """
        let rows = TTZipSpreadsheetParser.parse(text: csv, delimiter: ",")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["Apple, Inc.", "150.25", "Cupertino, California"])
        XCTAssertEqual(rows[1], ["Google, LLC", "2800.50", "Mountain View, California"])
    }
    
    func testRFC4180EscapedQuotes() {
        let csv = #"""
        "He said ""Hello, World!""",42
        "She replied ""Yes, indeed""",99
        """#
        let rows = TTZipSpreadsheetParser.parse(text: csv, delimiter: ",")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0], "He said \"Hello, World!\"")
        XCTAssertEqual(rows[0][1], "42")
        XCTAssertEqual(rows[1][0], "She replied \"Yes, indeed\"")
        XCTAssertEqual(rows[1][1], "99")
    }
    
    func testRFC4180MultilineFieldsInQuotes() {
        let csv = "\"Line 1\nLine 2\nLine 3\",Col2\nRow2Col1,Row2Col2"
        let rows = TTZipSpreadsheetParser.parse(text: csv, delimiter: ",")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0], "Line 1\nLine 2\nLine 3")
        XCTAssertEqual(rows[0][1], "Col2")
        XCTAssertEqual(rows[1][0], "Row2Col1")
        XCTAssertEqual(rows[1][1], "Row2Col2")
    }
    
    func testRFC4180CRLFLineEndings() {
        let csv = "ID,Score\r\n101,95\r\n102,88\r\n"
        let rows = TTZipSpreadsheetParser.parse(text: csv, delimiter: ",")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], ["ID", "Score"])
        XCTAssertEqual(rows[1], ["101", "95"])
        XCTAssertEqual(rows[2], ["102", "88"])
    }
    
    func testRFC4180EmptyCells() {
        let csv = "a,,c\n,b,\n,,"
        let rows = TTZipSpreadsheetParser.parse(text: csv, delimiter: ",")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], ["a", "", "c"])
        XCTAssertEqual(rows[1], ["", "b", ""])
        XCTAssertEqual(rows[2], ["", "", ""])
    }
    
    // MARK: - 2. Delimiter Auto-Detection
    
    func testDelimiterAutoDetection() {
        let csv = "ColA,ColB,ColC\n1,2,3\n4,5,6"
        XCTAssertEqual(TTZipSpreadsheetParser.detectDelimiter(in: csv), .comma)
        
        let tsv = "ColA\tColB\tColC\n1\t2\t3\n4\t5\t6"
        XCTAssertEqual(TTZipSpreadsheetParser.detectDelimiter(in: tsv), .tab)
        
        let ssv = "ColA;ColB;ColC\n1;2;3\n4;5;6"
        XCTAssertEqual(TTZipSpreadsheetParser.detectDelimiter(in: ssv), .semicolon)
        
        let psv = "ColA|ColB|ColC\n1|2|3\n4|5|6"
        XCTAssertEqual(TTZipSpreadsheetParser.detectDelimiter(in: psv), .pipe)
    }
    
    // MARK: - 3. Column Letter Naming
    
    func testColumnLetterGeneration() {
        XCTAssertEqual(TTZipSpreadsheetParser.columnLetter(for: 0), "A")
        XCTAssertEqual(TTZipSpreadsheetParser.columnLetter(for: 25), "Z")
        XCTAssertEqual(TTZipSpreadsheetParser.columnLetter(for: 26), "AA")
        XCTAssertEqual(TTZipSpreadsheetParser.columnLetter(for: 27), "AB")
        XCTAssertEqual(TTZipSpreadsheetParser.columnLetter(for: 51), "AZ")
        XCTAssertEqual(TTZipSpreadsheetParser.columnLetter(for: 52), "BA")
        XCTAssertEqual(TTZipSpreadsheetParser.columnLetter(for: 701), "ZZ")
        XCTAssertEqual(TTZipSpreadsheetParser.columnLetter(for: 702), "AAA")
    }
    
    // MARK: - 4. Cell Coordinates & Reference
    
    func testSpreadsheetCellCoordinateReference() {
        let c1 = SpreadsheetCellCoordinate(row: 0, column: 0)
        XCTAssertEqual(c1.excelReference, "A1")
        
        let c2 = SpreadsheetCellCoordinate(row: 3, column: 1)
        XCTAssertEqual(c2.excelReference, "B4")
        
        let c3 = SpreadsheetCellCoordinate(row: 99, column: 26)
        XCTAssertEqual(c3.excelReference, "AA100")
    }
    
    // MARK: - 5. Export Utilities
    
    func testExportToMarkdownTable() {
        let rows = [
            ["ID", "Name", "Active"],
            ["1", "Alpha", "true"],
            ["2", "Beta", "false"]
        ]
        let mdWithHeader = TTZipSpreadsheetParser.exportToMarkdownTable(rows: rows, hasHeader: true)
        XCTAssertTrue(mdWithHeader.contains("| ID | Name | Active |"))
        XCTAssertTrue(mdWithHeader.contains("| --- | --- | --- |"))
        XCTAssertTrue(mdWithHeader.contains("| 1 | Alpha | true |"))
        
        let mdNoHeader = TTZipSpreadsheetParser.exportToMarkdownTable(rows: rows, hasHeader: false)
        XCTAssertTrue(mdNoHeader.contains("| A | B | C |"))
        XCTAssertTrue(mdNoHeader.contains("| ID | Name | Active |"))
    }
    
    func testExportToDelimitedRoundtrip() {
        let originalRows = [
            ["Title", "Notes"],
            ["Item 1", "Contains, comma"],
            ["Item 2", "Contains \"quote\" and \nnewline"]
        ]
        let csvExport = TTZipSpreadsheetParser.exportToDelimited(rows: originalRows, delimiter: ",")
        let parsed = TTZipSpreadsheetParser.parse(text: csvExport, delimiter: ",")
        XCTAssertEqual(parsed.count, originalRows.count)
        XCTAssertEqual(parsed[0], originalRows[0])
        XCTAssertEqual(parsed[1], originalRows[1])
        XCTAssertEqual(parsed[2], originalRows[2])
    }
    
    // MARK: - 6. MediaPreviewFactory Routing
    
    @MainActor
    func testSpreadsheetExtensionsClassificationInFactory() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "SpreadsheetTableTests")
        let extensions = ["csv", "tsv", "tab", "psv", "ssv"]
        for ext in extensions {
            let fileURL = tempDirURL.appendingPathComponent("sample.\(ext)")
            let content = "Col1,Col2,Col3\n10,20,30\n"
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            
            // 1. Synchronous
            let syncType = MediaPreviewFactory.detectType(url: fileURL)
            switch syncType {
            case .spreadsheetTable(let text, let url):
                XCTAssertEqual(url, fileURL)
                XCTAssertTrue(text.contains("Col1"))
            default:
                XCTFail("Extension .\(ext) should detect as .spreadsheetTable, got \(syncType)")
            }
            
            // 2. Asynchronous
            let asyncType = await MediaPreviewFactory.detectTypeAsync(url: fileURL)
            switch asyncType {
            case .spreadsheetTable(let text, let url):
                XCTAssertEqual(url, fileURL)
                XCTAssertTrue(text.contains("Col1"))
            default:
                XCTFail("Extension .\(ext) async should detect as .spreadsheetTable, got \(asyncType)")
            }
            
            // 3. Icon Name
            let icon = MediaPreviewFactory.iconName(for: "sample.\(ext)")
            XCTAssertEqual(icon, "tablecells.fill")
        }
        
        // 4. In-memory detection
        let memData = Data("A\tB\tC\n1\t2\t3".utf8)
        let memType = MediaPreviewFactory.detectTypeFromMemory(data: memData, suggestedName: "export.tsv")
        switch memType {
        case .spreadsheetTable(let text, _):
            XCTAssertTrue(text.contains("A\tB\tC"))
        default:
            XCTFail("In-memory TSV should detect as .spreadsheetTable, got \(memType)")
        }
    }
    
    // MARK: - 7. Large Spreadsheet Stress Test
    
    func testLargeSpreadsheetFastParsing() {
        var bigCSV = "ID,Name,Email,Score,Status\n"
        for i in 1...2000 {
            bigCSV += "\(i),User_\(i),user\(i)@example.com,\(i * 10),\"Active, Verified\"\n"
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let rows = TTZipSpreadsheetParser.parse(text: bigCSV, delimiter: ",")
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        XCTAssertEqual(rows.count, 2001)
        XCTAssertEqual(rows[1][0], "1")
        XCTAssertEqual(rows[1][4], "Active, Verified")
        XCTAssertLessThan(elapsed, 0.5, "Parsing 2000 rows must finish in under 500ms, actual: \(elapsed)s")
    }
    
    func testProductSpreadsheetGridFitsPreviewWidthsAndScrollsWideTables() async throws {
        let preview = MediaPreviewView(
            fileData: Data("Name,Value\nExample,42".utf8), fileName: "rows.csv",
            showsFloatingFullScreenButton: false
        )
        for width: CGFloat in [320, 400, 520, 860] {
            try await withSpreadsheetPreview(preview, width: width) { host in
                let grid = try await spreadsheetGrid(in: host) {
                    abs(($0.enclosingScrollView?.bounds.width ?? 0) - width) < 1
                }
                let scrollView = try XCTUnwrap(grid.enclosingScrollView)
                let viewport = scrollView.convert(scrollView.bounds, to: host)
                let firstColumn = try XCTUnwrap(grid.resolvedColumnWidths.first)
                let firstRow = grid.convert(grid.bounds, to: host)
                XCTAssertEqual(viewport.width, width, accuracy: 1, "Preview width \(width)")
                XCTAssertEqual(scrollView.documentVisibleRect.minX, 0, accuracy: 1)
                XCTAssertGreaterThanOrEqual(firstRow.minX, viewport.minX - 1)
                XCTAssertLessThanOrEqual(firstRow.minX + 44 + firstColumn, host.bounds.maxX)
            }
        }

        let longValue = String(repeating: "long value ", count: 24) + "last"
        let widePreview = MediaPreviewView(
            fileData: Data("\(longValue),2,3,4,5,6,7,8".utf8), fileName: "wide.csv",
            showsFloatingFullScreenButton: false
        )
        try await withSpreadsheetPreview(widePreview) { host in
            let grid = try await spreadsheetGrid(in: host) { $0.headers.count == 8 }
            let scrollView = try XCTUnwrap(grid.enclosingScrollView)
            let documentView = try XCTUnwrap(scrollView.documentView)
            XCTAssertEqual(grid.allRows.first?.first, longValue)
            XCTAssertLessThanOrEqual(try XCTUnwrap(grid.resolvedColumnWidths.first), 380)
            XCTAssertGreaterThan(documentView.bounds.width, scrollView.documentVisibleRect.width)
        }
    }

    func testProductSpreadsheetCSVAndTSVSelectNonLeadingAndMultilineCells() async throws {
        let rows = [["name", "value"], ["中文", "42"], ["two\nlines", "7"]]
        for (ext, separator) in [("csv", ","), ("tsv", "\t")] {
            let content = "name\(separator)value\n\"中文\"\(separator)42\n\"two\nlines\"\(separator)7\n"
            let preview = MediaPreviewView(
                fileData: Data(content.utf8), fileName: "sample.\(ext)",
                showsFloatingFullScreenButton: false
            )
            try await withSpreadsheetPreview(preview) { host in
                let grid = try await spreadsheetGrid(in: host) { $0.allRows == rows }
                XCTAssertEqual(grid.renderedRowNumbers, [1, 2, 3], ext)
                try XCTUnwrap(grid.simulateCellTap)(1, 1)
                _ = try await spreadsheetControls(in: host) { $0.selectedCellContent == "42" }
                let nonLeading = try await spreadsheetGrid(in: host) { $0.activeSelectedCell?.column == 1 }
                XCTAssertEqual(nonLeading.activeSelectedCell?.row, 1, ext)

                try XCTUnwrap(nonLeading.simulateCellTap)(2, 0)
                _ = try await spreadsheetControls(in: host) { $0.selectedCellContent == "two\nlines" }
                let multiline = try await spreadsheetGrid(in: host) { $0.activeSelectedCell?.row == 2 }
                XCTAssertEqual(multiline.activeSelectedCell?.column, 0, ext)
            }
        }
    }

    func testProductSpreadsheetDefaultPageAndFilterKeepOriginalRows() async throws {
        let rows = (1...105).map { "Item \($0),Value \($0)" }
        let csv = (["Name,Value"] + rows).joined(separator: "\n")
        let preview = MediaPreviewView(
            fileData: Data(csv.utf8), fileName: "paged.csv",
            showsFloatingFullScreenButton: false
        )
        try await withSpreadsheetPreview(preview, width: 860) { host in
            let first = try await spreadsheetGrid(in: host) { $0.renderedRowNumbers.count == 100 }
            XCTAssertEqual(first.renderedRowNumbers, Array(1...100))
            XCTAssertEqual(first.allRows.first, ["Name", "Value"])
            XCTAssertEqual(first.allRows.last, ["Item 99", "Value 99"])

            let filter = try XCTUnwrap(findSpreadsheetFilter(in: host))
            let window = try XCTUnwrap(host.window)
            XCTAssertTrue(window.makeFirstResponder(filter))
            let editor = try XCTUnwrap(filter.currentEditor() as? NSTextView)
            editor.insertText("Item 104", replacementRange: NSRange(location: 0, length: 0))
            let filtered = try await spreadsheetGrid(in: host) { $0.renderedRowNumbers == [105] }
            XCTAssertEqual(filtered.allRows, [["Item 104", "Value 104"]])
            try XCTUnwrap(filtered.simulateCellTap)(0, 1)
            _ = try await spreadsheetControls(in: host) { $0.selectedCellContent == "Value 104" }

            window.setContentSize(NSSize(width: 320, height: 400))
            let compact = try await spreadsheetGrid(in: host) {
                abs(($0.enclosingScrollView?.bounds.width ?? 0) - 320) < 1
            }
            XCTAssertEqual(compact.renderedRowNumbers, [105])
            XCTAssertEqual(compact.activeSelectedCell?.row, 0)
            XCTAssertEqual(compact.activeSelectedCell?.column, 1)
            let controls = try await spreadsheetControls(in: host)
            XCTAssertEqual(controls.selectedCellContent, "Value 104")
        }
    }

    func testProductSpreadsheetBlankCSVRendersWithoutGridRows() async throws {
        var resolvedContent: String?
        let preview = MediaPreviewView(
            fileData: Data("\n".utf8), fileName: "empty.csv", showsFloatingFullScreenButton: false,
            onPreviewTypeResolved: { type in
                if case .spreadsheetTable(let content, _) = type { resolvedContent = content }
            }
        )
        try await withSpreadsheetPreview(preview) { host in
            let controls = try await spreadsheetControls(in: host) { _ in resolvedContent != nil }
            XCTAssertEqual(resolvedContent, "\n")
            XCTAssertNil(findSpreadsheetGrid(in: host))
            XCTAssertNil(controls.selectedCellContent)
        }
    }

    func testProductSpreadsheetRouteRendersArchiveCSVAndOfficeWorkbookReadOnly() async throws {
        let directory = try makeTemporaryDirectory(prefix: "ProductSpreadsheetPreview")
        defer { try? FileManager.default.removeItem(at: directory) }
        let csvURL = directory.appendingPathComponent("cities.csv")
        let csv = Data("City,Country\nTokyo,Japan".utf8)
        try csv.write(to: csvURL)

        let csvPreview = MediaPreviewView(
            fileURL: csvURL,
            fileName: csvURL.lastPathComponent,
            showsFloatingFullScreenButton: false,
            resourceContext: .archiveEntry(
                archivePath: "/archives/cities.zip",
                entryPath: "cities.csv",
                stagedReadURL: csvURL,
                fileName: csvURL.lastPathComponent
            )
        )
        try await withSpreadsheetPreview(csvPreview) { host in
            let grid = try await spreadsheetGrid(in: host) { $0.allRows.count == 2 }
            XCTAssertEqual(grid.headers, ["A", "B"])
            XCTAssertEqual(grid.allRows, [["City", "Country"], ["Tokyo", "Japan"]])
            XCTAssertEqual(grid.renderedRowNumbers, [1, 2])
            XCTAssertEqual(grid.resolvedColumnWidths, [138, 138])
            try XCTUnwrap(grid.simulateCellTap)(1, 1)
            let cell = try await spreadsheetControls(in: host) { $0.selectedCellContent == "Japan" }
            let selection = try await spreadsheetGrid(in: host) { $0.activeSelectedCell?.column == 1 }
            XCTAssertEqual(selection.activeSelectedCell?.row, 1)
            XCTAssertFalse(cell.canSaveInPlace)
        }
        XCTAssertEqual(try Data(contentsOf: csvURL), csv)

        let workbookURL = try makeTwoSheetWorkbook(in: directory)
        let workbookBytes = try Data(contentsOf: workbookURL)
        let workbookPreview = MediaPreviewView(
            fileURL: workbookURL,
            fileName: workbookURL.lastPathComponent,
            showsFloatingFullScreenButton: false
        )
        try await withSpreadsheetPreview(workbookPreview) { host in
            let firstGrid = try await spreadsheetGrid(in: host) { $0.allRows == [["Tokyo"]] }
            try XCTUnwrap(firstGrid.simulateCellTap)(0, 0)
            let first = try await spreadsheetControls(in: host) {
                $0.selectedSheetName == "Cities" && $0.selectedCellContent == "Tokyo"
            }
            try XCTUnwrap(first.selectSheet)("Totals")
            let second = try await spreadsheetGrid(in: host) { $0.allRows == [["Grand total"]] }
            XCTAssertEqual(second.renderedRowNumbers, [1])
            XCTAssertNil(second.activeSelectedCell)
            try XCTUnwrap(second.simulateCellTap)(0, 0)
            let cell = try await spreadsheetControls(in: host) {
                $0.selectedSheetName == "Totals" && $0.selectedCellContent == "Grand total"
            }
            XCTAssertFalse(cell.canSaveInPlace)

            host.rootView = csvPreview
            let replacement = try await spreadsheetGrid(in: host) { $0.allRows == [["City", "Country"], ["Tokyo", "Japan"]] }
            XCTAssertNil(replacement.activeSelectedCell)
            let replacementControls = try await spreadsheetControls(in: host) { $0.selectedSheetName.isEmpty }
            XCTAssertNil(replacementControls.selectedCellContent)
            XCTAssertFalse(replacementControls.canSaveInPlace)
        }
        XCTAssertEqual(try Data(contentsOf: workbookURL), workbookBytes)
    }

    func testProductStagingPolicyDeniesWriteBackThroughExplicitDiskContext() async throws {
        let directory = try makeTemporaryDirectory(prefix: "ProductStagingPolicy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagingDirectory = directory.appendingPathComponent("ttzip_vfs_fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagedURL = stagingDirectory.appendingPathComponent("staged.csv")
        let ordinaryURL = directory.appendingPathComponent("ordinary.csv")
        let original = "City,Country\nTokyo,Japan"
        let edited = "City,Country\nOsaka,Japan"
        try Data(original.utf8).write(to: stagedURL)
        try Data(original.utf8).write(to: ordinaryURL)

        let stagedContext = TTPreviewResourceContext.diskFile(url: stagedURL, fileName: "original.csv")
        XCTAssertTrue(stagedContext.isEditableInPlace)
        let stagedPreview = MediaPreviewView(
            previewType: .spreadsheetTable(original, stagedURL),
            fileName: "original.csv",
            showsFloatingFullScreenButton: false,
            resourceContext: stagedContext
        )
        XCTAssertTrue(stagedPreview.effectiveIsFromArchive)
        XCTAssertFalse(stagedPreview.effectiveIsEditable)
        let protectedContext = stagedPreview.effectiveResourceContext
        XCTAssertEqual(protectedContext.origin, stagedContext.origin)
        XCTAssertEqual(protectedContext.displayFileName, "original.csv")
        XCTAssertFalse(try SpreadsheetSavePolicy.saveInPlace(
            content: edited, expectedBaseline: original, fileURL: stagedURL,
            fileName: "original.csv", resourceContext: protectedContext
        ))
        XCTAssertEqual(try Data(contentsOf: stagedURL), Data(original.utf8))
        try await withSpreadsheetPreview(stagedPreview) { host in
            _ = try await spreadsheetGrid(in: host) { $0.allRows.count == 2 }
            let controls = try await spreadsheetControls(in: host)
            XCTAssertFalse(controls.canSaveInPlace)
        }

        let ordinaryContext = TTPreviewResourceContext.diskFile(url: ordinaryURL)
        let ordinaryPreview = MediaPreviewView(
            fileURL: ordinaryURL,
            fileName: ordinaryURL.lastPathComponent,
            resourceContext: ordinaryContext
        )
        XCTAssertFalse(ordinaryPreview.effectiveIsFromArchive)
        XCTAssertTrue(ordinaryPreview.effectiveIsEditable)
        try await withSpreadsheetPreview(ordinaryPreview) { host in
            _ = try await spreadsheetGrid(in: host) { $0.allRows.count == 2 }
            let controls = try await spreadsheetControls(in: host)
            XCTAssertTrue(controls.canSaveInPlace)
        }
        XCTAssertTrue(try SpreadsheetSavePolicy.saveInPlace(
            content: edited, expectedBaseline: original, fileURL: ordinaryURL,
            fileName: ordinaryURL.lastPathComponent, resourceContext: ordinaryPreview.effectiveResourceContext
        ))
        XCTAssertEqual(try Data(contentsOf: ordinaryURL), Data(edited.utf8))
    }

    func testStagingClassificationRetainsRawAndStandardizedPathRules() {
        let root = "/tmp/PreviewStagingPolicyFixtures"
        let rawMarkers = [
            "TTZipLRUPreviewCache", "TTMediaEphemeralStorage", "TTZipPreviewCache",
            "TTZipArchiveMediaCache", ".ttzip-staging-fixture", "ttzip_vfs_fixture"
        ]
        for marker in rawMarkers {
            let rawURL = URL(fileURLWithPath: "\(root)/\(marker)/../report.csv")
            XCTAssertFalse(TTPreviewResourceContext.isManagedPreviewStagingURL(rawURL), marker)
            XCTAssertTrue(PreviewStagingPolicy.hasStagingURL(rawURL), marker)
        }

        let coreOnlyMarkers = ["ttzip_previews_fixture", "TTZip_QuickLook_fixture", "TTZip_Extract_fixture"]
        for marker in coreOnlyMarkers {
            let rawURL = URL(fileURLWithPath: "\(root)/\(marker)/../report.csv")
            XCTAssertFalse(PreviewStagingPolicy.hasStagingURL(rawURL), marker)
            let stagedURL = URL(fileURLWithPath: "\(root)/scratch/../\(marker)/report.csv")
            XCTAssertTrue(PreviewStagingPolicy.hasStagingURL(stagedURL), marker)
        }

        XCTAssertTrue(PreviewStagingPolicy.hasStagingURL(URL(string: "ttzip://archive/report.csv")))
        XCTAssertTrue(PreviewStagingPolicy.hasStagingURL(URL(string: "ttzip-vfs://archive/report.csv")))
        XCTAssertTrue(PreviewStagingPolicy.hasStagingURL(URL(string: "file:///tmp/archive.zip?subpath=report.csv")))
        XCTAssertFalse(PreviewStagingPolicy.hasStagingURL(URL(fileURLWithPath: "\(root)/report.csv")))
        XCTAssertFalse(PreviewStagingPolicy.hasStagingURL(URL(fileURLWithPath: "/var/folders/fixture/report.csv")))
    }

    func testStagingIngressRetainsArchiveIdentityAndContextFields() {
        let stagedURL = URL(fileURLWithPath: "/tmp/TTZipPreviewCache/../report.csv")
        let ordinaryURL = stagedURL.standardizedFileURL
        let diskContext = TTPreviewResourceContext.diskFile(url: ordinaryURL, fileName: "source.csv")
        let preview = MediaPreviewView(fileURL: stagedURL, fileName: "source.csv", resourceContext: diskContext)
        let item = ImmersiveMediaItem(url: stagedURL, name: "source.csv", resourceContext: diskContext)
        XCTAssertTrue(preview.effectiveIsFromArchive)
        XCTAssertTrue(item.isFromArchive)
        XCTAssertFalse(preview.effectiveIsEditable)
        XCTAssertFalse(item.isEditable)
        XCTAssertEqual(preview.effectiveResourceContext, diskContext.forcingReadOnly())
        XCTAssertEqual(item.resolvedResourceContext, diskContext.forcingReadOnly())

        let archiveContext = TTPreviewResourceContext.archiveEntry(
            archivePath: "/archives/source.zip", entryPath: "folder/source.csv",
            stagedReadURL: ordinaryURL, fileName: "source.csv"
        ).withDerivedRepresentation().withTruncatedPreview()
        let archivePreview = MediaPreviewView(fileURL: stagedURL, fileName: "source.csv", resourceContext: archiveContext)
        let archiveItem = ImmersiveMediaItem(url: stagedURL, name: "source.csv", resourceContext: archiveContext)
        XCTAssertEqual(archivePreview.effectiveResourceContext, archiveContext)
        XCTAssertEqual(archiveItem.resolvedResourceContext, archiveContext)
        XCTAssertEqual(archiveItem.resolvedResourceContext.archiveIdentity?.entryPath, "folder/source.csv")
        XCTAssertTrue(archiveItem.resolvedResourceContext.isPreviewTruncated)
        XCTAssertTrue(archiveItem.resolvedResourceContext.isDerivedRepresentation)
        XCTAssertFalse(archiveItem.resolvedResourceContext.isEditableInPlace)
    }

    func withSpreadsheetPreview<Content: View>(
        _ preview: Content,
        width: CGFloat = 320,
        exercise: (NSHostingView<Content>) async throws -> Void
    ) async throws {
        let bounds = NSRect(x: 0, y: 0, width: width, height: 400)
        let host = NSHostingView(rootView: preview)
        host.sizingOptions = []
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        try await exercise(host)
        XCTAssertFalse(window.isVisible)
    }

    @nonobjc func spreadsheetControls(
        in host: NSView,
        matching predicate: (TTZipSpreadsheetPreviewStateProbeNSView) -> Bool = { _ in true }
    ) async throws -> TTZipSpreadsheetPreviewStateProbeNSView {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let controls = findSpreadsheetControls(in: host), predicate(controls) {
                return controls
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(nil, "Expected TTZip spreadsheet controls to display the requested content")
    }

    private func findSpreadsheetControls(in view: NSView) -> TTZipSpreadsheetPreviewStateProbeNSView? {
        if let controls = view as? TTZipSpreadsheetPreviewStateProbeNSView {
            return controls
        }
        return view.subviews.lazy.compactMap { self.findSpreadsheetControls(in: $0) }.first
    }

    @nonobjc func spreadsheetGrid(
        in host: NSView,
        matching predicate: (TTZipSpreadsheetGridProbeNSView) -> Bool
    ) async throws -> TTZipSpreadsheetGridProbeNSView {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let grid = findSpreadsheetGrid(in: host), predicate(grid) {
                return grid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(nil, "Expected the mounted spreadsheet grid to display the requested cells")
    }

    @nonobjc func findSpreadsheetGrid(in view: NSView) -> TTZipSpreadsheetGridProbeNSView? {
        if let grid = view as? TTZipSpreadsheetGridProbeNSView {
            return grid
        }
        return view.subviews.lazy.compactMap { self.findSpreadsheetGrid(in: $0) }.first
    }

    @nonobjc func findSpreadsheetFilter(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.accessibilityPlaceholderValue() == SpreadsheetPreviewLocalization.text(.filterCellsPlaceholder) {
            return field
        }
        return view.subviews.lazy.compactMap { self.findSpreadsheetFilter(in: $0) }.first
    }

    private func makeTwoSheetWorkbook(in directory: URL) throws -> URL {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
            xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:spreadsheet>
            <table:table table:name="Cities">
              <table:table-row><table:table-cell><text:p>Tokyo</text:p></table:table-cell></table:table-row>
            </table:table>
            <table:table table:name="Totals">
              <table:table-row><table:table-cell><text:p>Grand total</text:p></table:table-cell></table:table-row>
            </table:table>
          </office:spreadsheet></office:body>
        </office:document-content>
        """
        try Data(content.utf8).write(to: directory.appendingPathComponent("content.xml"))
        let url = directory.appendingPathComponent("cities.ods")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", url.lastPathComponent, "content.xml"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return url
    }

    func testSpreadsheetPreviewLocaleKeysUseSharedTTI18nState() {
        let state = AppLocalizationState.shared
        let original = state.currentLanguage
        defer { state.setLanguage(original) }

        for key in SpreadsheetPreviewLocaleKey.allCases {
            for text in [
                key.fallbackTranslation(for: .en),
                key.fallbackTranslation(for: .zhHans),
                key.fallbackTranslation(for: .zhHant),
            ] {
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, key.rawKey)
            }
        }

        state.setLanguage(.en)
        state.setLanguage(.zhHans)
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.defaultDocumentTitle), "电子表格文档")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.defaultSheetTitle), "工作表")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.readOnlyBadge), "只读")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.previewCappedReadOnly), "预览已截断（只读）")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.saveButton), "保存")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.savedBadge), "已保存")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.unsavedBadge), "未保存")
        XCTAssertEqual(SpreadsheetPreviewLocalization.saveFailed("磁盘已满"), "保存失败：磁盘已满")
        XCTAssertEqual(SpreadsheetPreviewLocalization.sheetLoadFailed("Sheet2"), "加载工作表失败：Sheet2")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.filterCellsPlaceholder), "筛选单元格...")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.headerRowOne), "表头：第 1 行")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.headerAlphabetical), "表头：A, B, C")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.toggleHeaderHelp), "切换首行作为表头")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.copyButton), "复制")
        XCTAssertEqual(SpreadsheetPreviewLocalization.copySelectedCell("B4"), "复制选中单元格 (B4)")
        XCTAssertEqual(SpreadsheetPreviewLocalization.copiedCell("B4"), "已复制单元格 B4")
        XCTAssertEqual(SpreadsheetPreviewLocalization.copiedCellContent("B4"), "已复制单元格 B4 内容")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.copyTableAsCSV), "复制整表为 CSV (,)")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.inspectCellPrompt), "点击任意单元格以查看或复制完整内容")
        XCTAssertEqual(SpreadsheetPreviewLocalization.filteredRowStatus(filtered: 5, total: 20), "已筛选：5/20")
        XCTAssertEqual(SpreadsheetPreviewLocalization.rowCount(20), "20 行")
        XCTAssertEqual(SpreadsheetPreviewLocalization.columnCount(8), "8 列")
        XCTAssertEqual(SpreadsheetPreviewLocalization.cellCount(160), "160 单元格")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.jumpButton), "跳转")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.jumpToRowTitle), "跳转到行")
        XCTAssertEqual(SpreadsheetPreviewLocalization.jumpRowRange(maxRow: 20), "行号范围 (1–20)：")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.jumpGoButton), "前往")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.emptyTableTitle), "无表格数据")

        state.setLanguage(.en)
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.readOnlyBadge), "Read-Only")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.previewCappedReadOnly), "Preview Capped (Read-Only)")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.saveButton), "Save")
        XCTAssertEqual(SpreadsheetPreviewLocalization.saveFailed("Disk full"), "Failed to save: Disk full")
        XCTAssertEqual(SpreadsheetPreviewLocalization.sheetLoadFailed("Sheet2"), "Failed to load sheet: Sheet2")
        XCTAssertEqual(SpreadsheetPreviewLocalization.copySelectedCell("B4"), "Copy Selected Cell (B4)")
        XCTAssertEqual(SpreadsheetPreviewLocalization.filteredRowStatus(filtered: 5, total: 20), "Filtered: 5/20")
        XCTAssertEqual(SpreadsheetPreviewLocalization.rowCount(20), "20 rows")
        XCTAssertEqual(SpreadsheetPreviewLocalization.columnCount(8), "8 cols")
        XCTAssertEqual(SpreadsheetPreviewLocalization.cellCount(160), "160 cells")
    }

    func testSpreadsheetPresentationLabelsAndPaginationHelpFollowProductLanguage() {
        let state = AppLocalizationState.shared
        let original = state.currentLanguage
        defer { state.setLanguage(original) }

        state.setLanguage(.en)
        state.setLanguage(.zhHans)
        XCTAssertEqual(SpreadsheetPreviewMode.table.localizedTitle, "表格视图")
        XCTAssertEqual(SpreadsheetPreviewMode.source.localizedTitle, "原始源码")
        XCTAssertEqual(TTSpreadsheetDelimiter.comma.localizedDisplayName, "逗号 (,)")
        XCTAssertEqual(TTSpreadsheetDelimiter.tab.localizedDisplayName, "制表符 (\\t)")
        XCTAssertEqual(TTSpreadsheetDelimiter.semicolon.localizedDisplayName, "分号 (;)")
        XCTAssertEqual(TTSpreadsheetDelimiter.pipe.localizedDisplayName, "竖线 (|)")
        XCTAssertEqual(SpreadsheetPageSizeOption.hundred.localizedDisplayName, "100 行/页")
        XCTAssertEqual(SpreadsheetPageSizeOption.all.localizedDisplayName, "全部行（不分页）")
        XCTAssertEqual(SpreadsheetPreviewLocalization.pageSizeMenu("100 行/页"), "每页：100 行/页")
        XCTAssertEqual(SpreadsheetPreviewLocalization.pageIndicatorAccessibility(current: 2, total: 5), "第 2 页，共 5 页")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.firstPageHelp), "第一页")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.previousPageHelp), "上一页")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.nextPageHelp), "下一页")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.lastPageHelp), "最后一页")

        state.setLanguage(.zhHant)
        XCTAssertEqual(SpreadsheetPreviewMode.table.localizedTitle, "表格檢視")
        XCTAssertEqual(SpreadsheetPreviewMode.source.localizedTitle, "原始源碼")
        XCTAssertEqual(TTSpreadsheetDelimiter.comma.localizedDisplayName, "逗號 (,)")
        XCTAssertEqual(SpreadsheetPageSizeOption.hundred.localizedDisplayName, "100 列/頁")
        XCTAssertEqual(SpreadsheetPageSizeOption.all.localizedDisplayName, "全部列（不分頁）")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.firstPageHelp), "第一頁")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.previousPageHelp), "上一頁")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.nextPageHelp), "下一頁")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.lastPageHelp), "最後一頁")

        state.setLanguage(.en)
        XCTAssertEqual(SpreadsheetPreviewMode.allCases, [.table, .source])
        XCTAssertEqual(SpreadsheetPreviewMode.table.rawValue, "Grid Table")
        XCTAssertEqual(SpreadsheetPreviewMode.source.rawValue, "Raw Source")
        XCTAssertEqual(SpreadsheetPreviewMode.table.id, "Grid Table")
        XCTAssertEqual(SpreadsheetPreviewMode.source.id, "Raw Source")
        XCTAssertEqual(SpreadsheetPreviewMode.table.icon, "tablecells")
        XCTAssertEqual(SpreadsheetPreviewMode.source.icon, "curlybraces")
        XCTAssertEqual(SpreadsheetPreviewMode.table.localizedTitle, "Grid Table")
        XCTAssertEqual(SpreadsheetPreviewMode.source.localizedTitle, "Raw Source")
        XCTAssertEqual(TTSpreadsheetDelimiter.allCases, [.comma, .tab, .semicolon, .pipe])
        XCTAssertEqual(TTSpreadsheetDelimiter.comma.displayName, "Comma (,)")
        XCTAssertEqual(TTSpreadsheetDelimiter.tab.displayName, "Tab (\\t)")
        XCTAssertEqual(TTSpreadsheetDelimiter.semicolon.displayName, "Semicolon (;)")
        XCTAssertEqual(TTSpreadsheetDelimiter.pipe.displayName, "Pipe (|)")
        XCTAssertEqual(TTSpreadsheetDelimiter.comma.shortName, "CSV (,)")
        XCTAssertEqual(TTSpreadsheetDelimiter.tab.shortName, "TSV (⇥)")
        XCTAssertEqual(TTSpreadsheetDelimiter.semicolon.shortName, "SSV (;)")
        XCTAssertEqual(TTSpreadsheetDelimiter.pipe.shortName, "PSV (|)")
        XCTAssertEqual(SpreadsheetPageSizeOption.fifty.displayName, "50 rows")
        XCTAssertEqual(SpreadsheetPageSizeOption.hundred.displayName, "100 rows")
        XCTAssertEqual(SpreadsheetPageSizeOption.twoHundredFifty.displayName, "250 rows")
        XCTAssertEqual(SpreadsheetPageSizeOption.fiveHundred.displayName, "500 rows")
        XCTAssertEqual(SpreadsheetPageSizeOption.oneThousand.displayName, "1,000 rows")
        XCTAssertEqual(SpreadsheetPageSizeOption.all.displayName, "All rows (No Pagination)")
        XCTAssertEqual(SpreadsheetPageSizeOption.hundred.localizedDisplayName, "100 rows")
        XCTAssertEqual(SpreadsheetPageSizeOption.all.localizedDisplayName, "All rows (No Pagination)")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.firstPageHelp), "First Page")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.previousPageHelp), "Previous Page")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.nextPageHelp), "Next Page")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.lastPageHelp), "Last Page")
    }
}
