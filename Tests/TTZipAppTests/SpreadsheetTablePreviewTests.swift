// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
@testable import TTZipCore
@testable import TTZipApp

final class SpreadsheetTablePreviewTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("SpreadsheetTableTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
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
    
    // MARK: - 8. SwiftUI View Instantiation
    
    @MainActor
    func testSpreadsheetTablePreviewViewInstantiation() {
        let csv = "City,Population,Country\nTokyo,37400068,Japan\nDelhi,30290936,India\nShanghai,27058480,China"
        let view = SpreadsheetTablePreviewView(initialContent: csv, fileURL: nil, fileName: "cities.csv")
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertNotNil(hosting)
    }
}
