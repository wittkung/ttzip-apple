// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import CryptoKit
import SwiftUI
@testable import TTMediaKit

@MainActor
final class PreviewResourceContextAndSavePolicyTests: XCTestCase {

    // MARK: - 1. Disk vs Archive Origin & Save Target Resolution

    func testDiskFileContextGrantsInPlaceEditCapability() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTUserWorkspace_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let csvURL = tempDir.appendingPathComponent("budget.csv")
        try "item,amount\nbook,20\n".write(to: csvURL, atomically: true, encoding: .utf8)

        let context = TTPreviewResourceContext.diskFile(url: csvURL)
        XCTAssertFalse(context.isArchiveEntry)
        XCTAssertEqual(context.readableURL, csvURL.standardizedFileURL)
        XCTAssertEqual(context.originalDiskURL, csvURL.standardizedFileURL)
        XCTAssertEqual(context.originalResourceURL, csvURL.standardizedFileURL)
        XCTAssertTrue(context.isEditableInPlace)
        XCTAssertNil(context.readOnlyReason)
        XCTAssertEqual(context.writableSaveTargetURL, csvURL.standardizedFileURL)
        XCTAssertTrue(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: csvURL,
                fileName: "budget.csv",
                resourceContext: context
            )
        )
    }

    func testArchiveEntryContextRemainsStrictlyReadOnlyEvenWhenStagedFileIsWritableOnDisk() throws {
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipLRUPreviewCache/session_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let archiveURL = stagingDir.deletingLastPathComponent().appendingPathComponent("bundle.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18)).write(to: archiveURL)

        let stagedCSV = stagingDir.appendingPathComponent("report.csv")
        let originalCSV = "col1,col2\n1,2\n"
        try originalCSV.write(to: stagedCSV, atomically: true, encoding: .utf8)

        // Even though the OS marks the staged file writable (0600), archive context must block editing.
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: stagedCSV.path))

        let context = TTPreviewResourceContext.archiveEntry(
            archiveURL: archiveURL,
            entryPath: "docs/report.csv",
            stagedReadURL: stagedCSV,
            fileName: "report.csv"
        )
        XCTAssertTrue(context.isArchiveEntry)
        XCTAssertEqual(context.archiveContainerURL, archiveURL.standardizedFileURL)
        XCTAssertEqual(context.archiveEntryPath, "docs/report.csv")
        XCTAssertEqual(context.readableURL, stagedCSV.standardizedFileURL)
        XCTAssertNil(context.originalDiskURL)
        XCTAssertFalse(context.isEditableInPlace)
        XCTAssertEqual(context.readOnlyReason, .archiveEntry)
        XCTAssertNil(context.writableSaveTargetURL)
        XCTAssertNil(context.validateInPlaceSaveTarget(expectedFileURL: stagedCSV))

        XCTAssertFalse(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: stagedCSV,
                fileName: "report.csv",
                resourceContext: context
            )
        )
        let saved = try SpreadsheetSavePolicy.saveInPlace(
            content: "tampered,data\n9,9\n",
            fileURL: stagedCSV,
            fileName: "report.csv",
            resourceContext: context
        )
        XCTAssertFalse(saved)
        XCTAssertEqual(try String(contentsOf: stagedCSV, encoding: .utf8), originalCSV)
    }

    // MARK: - 2. Non-Staged /tmp & /var/folders User Files vs Managed Staging Directories

    func testUserFilesInTmpAndVarFoldersAreNotBlanketClassifiedAsArchiveReadOnly() throws {
        // 1. User file inside FileManager.default.temporaryDirectory (/var/folders/...)
        let varFoldersDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NormalUserFolder_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: varFoldersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: varFoldersDir) }

        let varFoldersCSV = varFoldersDir.appendingPathComponent("user_notes.csv")
        try "a,b\n1,2\n".write(to: varFoldersCSV, atomically: true, encoding: .utf8)

        XCTAssertFalse(TTPreviewResourceContext.isManagedPreviewStagingURL(varFoldersCSV))
        let varContext = TTPreviewResourceContext.diskFile(url: varFoldersCSV)
        XCTAssertTrue(varContext.isEditableInPlace)
        XCTAssertTrue(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: varFoldersCSV,
                fileName: "user_notes.csv",
                resourceContext: varContext
            )
        )
        let didSaveVar = try SpreadsheetSavePolicy.saveInPlace(
            content: "a,b\n3,4\n",
            fileURL: varFoldersCSV,
            fileName: "user_notes.csv",
            resourceContext: varContext
        )
        XCTAssertTrue(didSaveVar)
        XCTAssertEqual(try String(contentsOf: varFoldersCSV, encoding: .utf8), "a,b\n3,4\n")

        // 2. User file directly under /tmp
        let tmpFile = URL(fileURLWithPath: "/tmp/ttmedia_user_file_\(UUID().uuidString).csv")
        try "k,v\nx,y\n".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        XCTAssertFalse(TTPreviewResourceContext.isManagedPreviewStagingURL(tmpFile))
        let tmpContext = TTPreviewResourceContext.diskFile(url: tmpFile)
        XCTAssertTrue(tmpContext.isEditableInPlace)
        XCTAssertNotNil(tmpContext.writableSaveTargetURL)
    }

    func testManagedPreviewStagingMarkersAreBlockedEvenIfPassedAsDiskFile() throws {
        let managedMarkers = [
            "TTZipLRUPreviewCache",
            "TTMediaEphemeralStorage",
            "TTZipPreviewCache",
            "TTZipArchiveMediaCache",
            "ttzip_previews_12345",
            "TTZip_QuickLook_abc",
            "TTZip_Extract_xyz"
        ]
        for marker in managedMarkers {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(marker)/slot", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(
                    at: FileManager.default.temporaryDirectory.appendingPathComponent(marker)
                )
            }
            let fileURL = dir.appendingPathComponent("data.csv")
            try "h1,h2\n1,2\n".write(to: fileURL, atomically: true, encoding: .utf8)

            XCTAssertTrue(
                TTPreviewResourceContext.isManagedPreviewStagingURL(fileURL),
                "Expected marker \(marker) to be detected as managed staging URL"
            )
            let forgedDiskContext = TTPreviewResourceContext.diskFile(url: fileURL)
            XCTAssertFalse(forgedDiskContext.isEditableInPlace)
            XCTAssertEqual(forgedDiskContext.readOnlyReason, .managedStagingCachePath)
            XCTAssertNil(forgedDiskContext.writableSaveTargetURL)
            XCTAssertFalse(
                SpreadsheetSavePolicy.canSaveInPlace(
                    fileURL: fileURL,
                    fileName: "data.csv",
                    resourceContext: forgedDiskContext
                )
            )
        }
    }

    // MARK: - 3. Unknown Origin Fail-Closed & Truncated / Derived Read-Only Enforcement

    func testUnknownOriginAndFactoryDefaultNeverGrantOverwritePermission() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTUnknownOrigin_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("editable_on_disk.csv")
        let initial = "col1,col2\n10,20\n"
        try initial.write(to: fileURL, atomically: true, encoding: .utf8)

        // When explicitContext is nil, Factory resolves to .unknown (fail-closed read-only).
        let resolved = TTMediaPreviewFactory.resolveResourceContext(
            explicitContext: nil,
            type: .spreadsheetTable(initial, fileURL),
            fileName: "editable_on_disk.csv",
            fileURL: fileURL
        )
        XCTAssertEqual(resolved.origin, .unknown(readableURL: fileURL.standardizedFileURL))
        XCTAssertFalse(resolved.isEditableInPlace)
        XCTAssertEqual(resolved.readOnlyReason, .unknownOrigin)
        XCTAssertNil(resolved.writableSaveTargetURL)
        XCTAssertFalse(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: fileURL,
                fileName: "editable_on_disk.csv",
                resourceContext: resolved
            )
        )
        let saved = try SpreadsheetSavePolicy.saveInPlace(
            content: "mutated,0\n",
            fileURL: fileURL,
            fileName: "editable_on_disk.csv",
            resourceContext: resolved
        )
        XCTAssertFalse(saved)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), initial)
    }

    func testTruncatedAndDerivedContextsBlockSaveAtBothViewAndSaveEntryPoints() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTTruncatedDerived_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let csvURL = tempDir.appendingPathComponent("large.csv")
        let original = "id,val\n1,100\n"
        try original.write(to: csvURL, atomically: true, encoding: .utf8)

        let diskContext = TTPreviewResourceContext.diskFile(url: csvURL)
        let truncatedContext = diskContext.withTruncatedPreview(true)
        XCTAssertFalse(truncatedContext.isEditableInPlace)
        XCTAssertEqual(truncatedContext.readOnlyReason, .truncatedPreview)
        XCTAssertNil(truncatedContext.validateInPlaceSaveTarget(expectedFileURL: csvURL))
        XCTAssertFalse(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: csvURL,
                fileName: "large.csv",
                resourceContext: truncatedContext
            )
        )

        let derivedContext = diskContext.withDerivedRepresentation(true, description: "OfficeSpreadsheet")
        XCTAssertFalse(derivedContext.isEditableInPlace)
        XCTAssertEqual(derivedContext.readOnlyReason, .derivedContent)
        XCTAssertNil(derivedContext.validateInPlaceSaveTarget(expectedFileURL: csvURL))
        XCTAssertFalse(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: csvURL,
                fileName: "large.csv",
                resourceContext: derivedContext
            )
        )
    }

    // MARK: - 4. SHA-256 Integrity Across Archive, Staged, and Neighbor Disk Files

    func testArchivePreviewSaveAttemptPreservesArchiveStagedAndNeighborFileSHA256() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTSHA256Guard_\(UUID().uuidString)", isDirectory: true)
        let stagingDir = workspace.appendingPathComponent("TTZipLRUPreviewCache/slot1", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let archiveURL = workspace.appendingPathComponent("archive.zip")
        let neighborCSV = workspace.appendingPathComponent("data.csv")
        let stagedCSV = stagingDir.appendingPathComponent("data.csv")

        try Data("PK\u{03}\u{04}ARCHIVE_BYTES".utf8).write(to: archiveURL)
        try "neighbor,1\n".write(to: neighborCSV, atomically: true, encoding: .utf8)
        try "staged,2\n".write(to: stagedCSV, atomically: true, encoding: .utf8)

        let archiveHashBefore = try sha256Hex(of: archiveURL)
        let neighborHashBefore = try sha256Hex(of: neighborCSV)
        let stagedHashBefore = try sha256Hex(of: stagedCSV)

        let archiveContext = TTPreviewResourceContext.archiveEntry(
            archiveURL: archiveURL,
            entryPath: "nested/data.csv",
            stagedReadURL: stagedCSV,
            fileName: "data.csv"
        )

        let view = SpreadsheetTablePreviewView(
            initialContent: "staged,2\n",
            fileURL: stagedCSV,
            fileName: "data.csv",
            isReadOnly: !archiveContext.isEditableInPlace,
            resourceContext: archiveContext
        )
        XCTAssertFalse(view.canSaveInPlace)
        XCTAssertFalse(view.saveFile(contentOverride: "overwritten,999\n"))

        // Also verify target mismatch protection if someone passes neighborCSV to validateInPlaceSaveTarget
        XCTAssertNil(archiveContext.validateInPlaceSaveTarget(expectedFileURL: neighborCSV))

        XCTAssertEqual(try sha256Hex(of: archiveURL), archiveHashBefore)
        XCTAssertEqual(try sha256Hex(of: neighborCSV), neighborHashBefore)
        XCTAssertEqual(try sha256Hex(of: stagedCSV), stagedHashBefore)
    }

    // MARK: - 5. Lifecycle Transitions: Sidebar -> Fullscreen, Prev/Next Switching, Close/Reopen

    func testLifecycleHandoffPreservesPermissionsAcrossFullscreenPrevNextAndReopen() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTLifecycle_\(UUID().uuidString)", isDirectory: true)
        let stagingDir = tempDir.appendingPathComponent("TTZipLRUPreviewCache/entry", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskFileA = tempDir.appendingPathComponent("a.csv")
        let diskFileB = tempDir.appendingPathComponent("b.md")
        let stagedArchiveFile = stagingDir.appendingPathComponent("archived.csv")
        let archiveURL = tempDir.appendingPathComponent("pack.zip")

        try "a,1\n".write(to: diskFileA, atomically: true, encoding: .utf8)
        try "# Title\n".write(to: diskFileB, atomically: true, encoding: .utf8)
        try "arch,2\n".write(to: stagedArchiveFile, atomically: true, encoding: .utf8)
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: archiveURL)

        // 1. Sidebar -> Fullscreen notification serialization for archive entry
        let archiveCtx = TTPreviewResourceContext.archiveEntry(
            archiveURL: archiveURL,
            entryPath: "archived.csv",
            stagedReadURL: stagedArchiveFile
        )
        let userInfo = archiveCtx.toUserInfoDictionary(additional: ["url": stagedArchiveFile])
        let restoredArchiveCtx = try XCTUnwrap(TTPreviewResourceContext.fromUserInfoDictionary(userInfo))
        XCTAssertEqual(restoredArchiveCtx, archiveCtx)
        XCTAssertFalse(restoredArchiveCtx.isEditableInPlace)
        XCTAssertEqual(restoredArchiveCtx.readOnlyReason, .archiveEntry)

        // 2. Prev/Next switching from Archive Entry -> Disk File A -> Disk File B -> back to Archive Entry
        let diskCtxA = TTPreviewResourceContext.diskFile(url: diskFileA)
        let diskCtxB = TTPreviewResourceContext.diskFile(url: diskFileB)
        XCTAssertTrue(diskCtxA.isEditableInPlace)
        XCTAssertTrue(diskCtxB.isEditableInPlace)

        let reopenedArchiveCtx = TTPreviewResourceContext.archiveEntry(
            archiveURL: archiveURL,
            entryPath: "archived.csv",
            stagedReadURL: stagedArchiveFile
        )
        XCTAssertFalse(reopenedArchiveCtx.isEditableInPlace)
        XCTAssertNil(reopenedArchiveCtx.writableSaveTargetURL)
    }

    // MARK: - 6. Office Spreadsheet Sample Validity, Routing & Read-Only Workbook Rendering

    func testSampleXLSXAndSampleODSFixturesRouteToReadOnlyOfficeSpreadsheetWithParsedCells() throws {
        let fixturesDir = try locateDocumentsFixturesDirectory()
        let xlsxURL = fixturesDir.appendingPathComponent("sample.xlsx")
        let odsURL = fixturesDir.appendingPathComponent("sample.ods")

        XCTAssertTrue(FileManager.default.fileExists(atPath: xlsxURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: odsURL.path))

        // Capability Matrix declaration check
        XCTAssertEqual(TTMediaCapabilityMatrix.descriptor(for: "xlsx")?.isEditableSource, false)
        XCTAssertEqual(TTMediaCapabilityMatrix.descriptor(for: "ods")?.isEditableSource, false)
        XCTAssertEqual(TTMediaCapabilityMatrix.descriptor(for: "xls")?.isEditableSource, false)

        // 1. XLSX fixture: a Chinese-named sheet with two rows and two columns.
        let xlsxType = TTMediaDetector.detectType(url: xlsxURL)
        guard case .officeSpreadsheet(let xlsxWorkbook) = xlsxType else {
            return XCTFail("Expected .officeSpreadsheet for sample.xlsx, got \(xlsxType)")
        }
        XCTAssertEqual(xlsxWorkbook.sheetNames, ["中文"])
        XCTAssertEqual(xlsxWorkbook.activeSheet?.name, "中文")
        XCTAssertEqual(xlsxWorkbook.activeSheet?.rows, [["中文", "42"], ["1", "43"]])

        let xlsxContext = TTMediaPreviewFactory.resolveResourceContext(
            explicitContext: .diskFile(url: xlsxURL),
            type: xlsxType,
            fileName: "sample.xlsx",
            fileURL: xlsxURL
        )
        XCTAssertFalse(xlsxContext.isEditableInPlace)
        XCTAssertEqual(xlsxContext.readOnlyReason, .derivedContent)
        XCTAssertFalse(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: xlsxURL,
                fileName: "sample.xlsx",
                workbook: xlsxWorkbook,
                resourceContext: xlsxContext
            )
        )

        // 2. ODS fixture: a Chinese-named sheet with one Chinese cell.
        let odsType = TTMediaDetector.detectType(url: odsURL)
        guard case .officeSpreadsheet(let odsWorkbook) = odsType else {
            return XCTFail("Expected .officeSpreadsheet for sample.ods, got \(odsType)")
        }
        XCTAssertEqual(odsWorkbook.sheetNames, ["中文"])
        XCTAssertEqual(odsWorkbook.activeSheet?.name, "中文")
        XCTAssertEqual(odsWorkbook.activeSheet?.rows, [["中文"]])

        let odsView = SpreadsheetTablePreviewView(
            workbook: odsWorkbook,
            sheetLoader: { sheet in
                TTMediaOfficeSpreadsheetReader.loadSheetRows(workbook: odsWorkbook, sheetName: sheet)
            },
            resourceContext: .diskFile(url: odsURL).withDerivedRepresentation(true, description: "OfficeSpreadsheet")
        )
        XCTAssertTrue(odsView.isReadOnly)
        XCTAssertFalse(odsView.canSaveInPlace)
        XCTAssertEqual(odsView.initialWorkbook?.activeSheet?.rows, [["中文"]])
    }

    func testUnsupportedBinarySpreadsheetsReturnExplicitLimitationInsteadOfQuickLookIcon() throws {
        // OLE2 Compound Document header (D0 CF 11 E0 A1 B1 1A E1) for legacy .xls
        let ole2Bytes = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + Array(repeating: UInt8(0), count: 64))
        let xlsType = TTMediaDetector.detectTypeFromMemory(
            data: ole2Bytes,
            suggestedName: "legacy.xls"
        )
        guard case .unsupported(let xlsMessage) = xlsType else {
            return XCTFail("Expected .unsupported limitation message for .xls, got \(xlsType)")
        }
        XCTAssertTrue(xlsMessage.contains("XLS"))

        // Apple Numbers ZIP package without xl/workbook.xml or content.xml
        let fixturesDir = try locateDocumentsFixturesDirectory()
        let docxZipData = try Data(contentsOf: fixturesDir.appendingPathComponent("sample.docx"))
        let numbersType = TTMediaDetector.detectTypeFromMemory(
            data: docxZipData,
            suggestedName: "budget.numbers"
        )
        guard case .unsupported(let numbersMessage) = numbersType else {
            return XCTFail("Expected .unsupported limitation message for .numbers, got \(numbersType)")
        }
        XCTAssertTrue(numbersMessage.contains("NUMBERS"))
    }

    // MARK: - 7. ODS & XLSX Coordinate Faithfulness, Repeat Cursors, Budget Truncation & Malformed XML

    func testODSAndXLSXPreserveExactCoordinatesAfter100RepeatedRowsAndColumns() throws {
        let odsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:spreadsheet>
            <table:table table:name="RepeatedEmpty">
              <table:table-row table:number-rows-repeated="100"><table:table-cell/></table:table-row>
              <table:table-row>
                <table:table-cell table:number-columns-repeated="100"/>
                <table:table-cell office:value-type="string"><text:p>MARKER_100_100</text:p></table:table-cell>
                <table:table-cell table:number-columns-repeated="1024"/>
              </table:table-row>
              <table:table-row table:number-rows-repeated="1048475"><table:table-cell table:number-columns-repeated="1024"/></table:table-row>
            </table:table>
            <table:table table:name="RepeatedNonEmpty">
              <table:table-row table:number-rows-repeated="100">
                <table:table-cell office:value-type="string"><text:p>RFILL</text:p></table:table-cell>
              </table:table-row>
              <table:table-row>
                <table:table-cell table:number-columns-repeated="100" office:value-type="string"><text:p>CFILL</text:p></table:table-cell>
                <table:table-cell office:value-type="string"><text:p>AFTER_100_NON_EMPTY</text:p></table:table-cell>
              </table:table-row>
            </table:table>
          </office:spreadsheet></office:body>
        </office:document-content>
        """
        let odsArchive = makeStoredZipArchive(entries: [("content.xml", Data(odsXML.utf8))])
        guard let odsWorkbook = TTMediaOfficeSpreadsheetReader.loadWorkbook(data: odsArchive, fileName: "repeat100.ods"),
              let emptyRepeatSheet = odsWorkbook.activeSheet else {
            return XCTFail("Expected valid ODS workbook and active sheet")
        }
        XCTAssertEqual(odsWorkbook.sheetNames, ["RepeatedEmpty", "RepeatedNonEmpty"])
        XCTAssertFalse(emptyRepeatSheet.isTruncated)
        XCTAssertEqual(emptyRepeatSheet.rows.count, 101)
        XCTAssertEqual(emptyRepeatSheet.totalRows, 101)
        XCTAssertEqual(emptyRepeatSheet.totalColumns, 101)
        for r in 0..<100 { XCTAssertTrue(emptyRepeatSheet.rows[r].isEmpty) }
        XCTAssertEqual(emptyRepeatSheet.rows[100].count, 101)
        for c in 0..<100 { XCTAssertEqual(emptyRepeatSheet.rows[100][c], "") }
        XCTAssertEqual(emptyRepeatSheet.rows[100][100], "MARKER_100_100")

        guard let nonEmptyRepeatRows = TTMediaOfficeSpreadsheetReader.loadSheetRows(workbook: odsWorkbook, sheetName: "RepeatedNonEmpty") else {
            return XCTFail("Expected RepeatedNonEmpty sheet rows")
        }
        XCTAssertEqual(nonEmptyRepeatRows.count, 101)
        XCTAssertEqual(nonEmptyRepeatRows[0], ["RFILL"])
        XCTAssertEqual(nonEmptyRepeatRows[99], ["RFILL"])
        XCTAssertEqual(nonEmptyRepeatRows[100].count, 101)
        XCTAssertEqual(nonEmptyRepeatRows[100][0], "CFILL")
        XCTAssertEqual(nonEmptyRepeatRows[100][99], "CFILL")
        XCTAssertEqual(nonEmptyRepeatRows[100][100], "AFTER_100_NON_EMPTY")

        let xlsxArchive = makeMinimalXLSXArchive(
            sheetXML: """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <sheetData><row r="101"><c r="CW101" t="inlineStr"><is><t>XLSX_100_100</t></is></c></row></sheetData>
            </worksheet>
            """
        )
        guard let xlsxWorkbook = TTMediaOfficeSpreadsheetReader.loadWorkbook(data: xlsxArchive, fileName: "repeat100.xlsx"),
              let xlsxSheet = xlsxWorkbook.activeSheet else {
            return XCTFail("Expected valid XLSX workbook")
        }
        XCTAssertEqual(xlsxSheet.rows.count, 101)
        XCTAssertTrue(xlsxSheet.rows[0].isEmpty)
        XCTAssertTrue(xlsxSheet.rows[99].isEmpty)
        XCTAssertEqual(xlsxSheet.rows[100].count, 101)
        XCTAssertEqual(xlsxSheet.rows[100][100], "XLSX_100_100")
    }

    func testLeadingAndInteriorEmptyRowsPreserveOriginalRowCoordinates() throws {
        let odsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:spreadsheet><table:table table:name="EmptyRowsSheet">
            <table:table-row/>
            <table:table-row><table:table-cell/></table:table-row>
            <table:table-row><table:table-cell office:value-type="string"><text:p>ROW_2_COL_0</text:p></table:table-cell></table:table-row>
            <table:table-row table:number-rows-repeated="3"><table:table-cell/></table:table-row>
            <table:table-row>
              <table:table-cell/><table:table-cell office:value-type="string"><text:p>ROW_6_COL_1</text:p></table:table-cell>
            </table:table-row>
            <table:table-row table:number-rows-repeated="500"/>
          </table:table></office:spreadsheet></office:body>
        </office:document-content>
        """
        let odsData = makeStoredZipArchive(entries: [("content.xml", Data(odsXML.utf8))])
        guard let odsWB = TTMediaOfficeSpreadsheetReader.loadWorkbook(data: odsData, fileName: "empty_rows.ods"),
              let odsSheet = odsWB.activeSheet else {
            return XCTFail("Expected valid ODS workbook")
        }
        let expectedRows: [[String]] = [[], [], ["ROW_2_COL_0"], [], [], [], ["", "ROW_6_COL_1"]]
        XCTAssertEqual(odsSheet.rows, expectedRows)

        let xlsxData = makeMinimalXLSXArchive(
            sheetXML: """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <sheetData>
                <row r="1"/><row r="2"><c r="A2"/></row>
                <row r="3"><c r="A3" t="inlineStr"><is><t>ROW_2_COL_0</t></is></c></row>
                <row r="4"/><row r="7"><c r="B7" t="inlineStr"><is><t>ROW_6_COL_1</t></is></c></row><row r="8"/>
              </sheetData>
            </worksheet>
            """
        )
        guard let xlsxWB = TTMediaOfficeSpreadsheetReader.loadWorkbook(data: xlsxData, fileName: "empty_rows.xlsx"),
              let xlsxSheet = xlsxWB.activeSheet else {
            return XCTFail("Expected valid XLSX workbook")
        }
        XCTAssertEqual(xlsxSheet.rows, expectedRows)
    }

    func testBudgetTruncationDoesNotShiftCoordinatesAndMarksTruncation() throws {
        let colBudget = TTMediaOfficeSpreadsheetReader.maxSheetColumns // 512
        let rowBudget = TTMediaOfficeSpreadsheetReader.maxSheetRows    // 50,001
        let odsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:spreadsheet>
            <table:table table:name="ColBudgetSheet">
              <table:table-row>
                <table:table-cell table:number-columns-repeated="511"/>
                <table:table-cell office:value-type="string"><text:p>LAST_IN_BUDGET_511</text:p></table:table-cell>
                <table:table-cell office:value-type="string"><text:p>TRUNCATED_512</text:p></table:table-cell>
                <table:table-cell table:number-columns-repeated="88"/>
                <table:table-cell office:value-type="string"><text:p>TRUNCATED_601</text:p></table:table-cell>
              </table:table-row>
              <table:table-row>
                <table:table-cell table:number-columns-repeated="600"/>
                <table:table-cell office:value-type="string"><text:p>ONLY_OUT_OF_COL_BUDGET</text:p></table:table-cell>
              </table:table-row>
              <table:table-row>
                <table:table-cell office:value-type="string"><text:p>ROW_2_STAYS_AT_ROW_2</text:p></table:table-cell>
              </table:table-row>
            </table:table>
            <table:table table:name="RowBudgetSheet">
              <table:table-row><table:table-cell office:value-type="string"><text:p>FIRST_ROW_0</text:p></table:table-cell></table:table-row>
              <table:table-row table:number-rows-repeated="\(rowBudget + 10)"><table:table-cell/></table:table-row>
              <table:table-row><table:table-cell office:value-type="string"><text:p>BEYOND_ROW_BUDGET</text:p></table:table-cell></table:table-row>
            </table:table>
          </office:spreadsheet></office:body>
        </office:document-content>
        """
        let odsData = makeStoredZipArchive(entries: [("content.xml", Data(odsXML.utf8))])
        guard let odsWB = TTMediaOfficeSpreadsheetReader.loadWorkbook(data: odsData, fileName: "budget.ods"),
              let colSheet = odsWB.activeSheet else {
            return XCTFail("Expected valid ODS workbook")
        }
        XCTAssertTrue(colSheet.isTruncated)
        XCTAssertTrue(odsWB.isTruncated)
        XCTAssertEqual(colSheet.totalColumns, 602)
        XCTAssertEqual(colSheet.rows.count, 3)
        XCTAssertEqual(colSheet.rows[0].count, colBudget)
        XCTAssertEqual(colSheet.rows[0][colBudget - 1], "LAST_IN_BUDGET_511")
        XCTAssertFalse(colSheet.rows[0].contains("TRUNCATED_512"))
        XCTAssertFalse(colSheet.rows[0].contains("TRUNCATED_601"))
        XCTAssertEqual(colSheet.rows[1], [])
        XCTAssertEqual(colSheet.rows[2], ["ROW_2_STAYS_AT_ROW_2"])

        guard let rowBudgetRows = TTMediaOfficeSpreadsheetReader.loadSheetRows(workbook: odsWB, sheetName: "RowBudgetSheet") else {
            return XCTFail("Expected RowBudgetSheet")
        }
        XCTAssertEqual(rowBudgetRows.count, rowBudget)
        XCTAssertEqual(rowBudgetRows[0], ["FIRST_ROW_0"])
        XCTAssertFalse(rowBudgetRows.contains(["BEYOND_ROW_BUDGET"]))
    }

    func testMalformedXMLInODSAndXLSXFailsClosedInsteadOfReturningPartialWorkbook() throws {
        let truncatedODS = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:spreadsheet><table:table table:name="Sheet1">
            <table:table-row><table:table-cell><text:p>Partial</text:p></table:table-cell></table:table-row>
          </table:table>
        """
        let badODSZip = makeStoredZipArchive(entries: [("content.xml", Data(truncatedODS.utf8))])
        XCTAssertNil(TTMediaOfficeSpreadsheetReader.loadWorkbook(data: badODSZip, fileName: "broken.ods"))
        if case .officeSpreadsheet = TTMediaDetector.detectTypeFromMemory(data: badODSZip, suggestedName: "broken.ods") {
            XCTFail("Malformed ODS XML must not be routed as valid .officeSpreadsheet")
        }

        let badWorksheetXLSX = makeMinimalXLSXArchive(
            sheetXML: "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Partial</t></is></c></row>"
        )
        XCTAssertNil(TTMediaOfficeSpreadsheetReader.loadWorkbook(data: badWorksheetXLSX, fileName: "broken_sheet.xlsx"))
        if case .officeSpreadsheet = TTMediaDetector.detectTypeFromMemory(data: badWorksheetXLSX, suggestedName: "broken_sheet.xlsx") {
            XCTFail("Malformed XLSX worksheet XML must not be routed as valid .officeSpreadsheet")
        }

        let badSharedStringsXLSX = makeMinimalXLSXArchive(
            sheetXML: "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row></sheetData></worksheet>",
            sharedStringsXML: "<?xml version=\"1.0\"?><sst><si><t>Unclosed"
        )
        XCTAssertNil(TTMediaOfficeSpreadsheetReader.loadWorkbook(data: badSharedStringsXLSX, fileName: "broken_sst.xlsx"))

        let badWorkbookXMLZip = makeStoredZipArchive(entries: [
            ("xl/workbook.xml", Data("<workbook><sheets><sheet name=\"S1\"".utf8)),
            ("xl/worksheets/sheet1.xml", Data("<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>OK</t></is></c></row></sheetData></worksheet>".utf8))
        ])
        XCTAssertNil(TTMediaOfficeSpreadsheetReader.loadWorkbook(data: badWorkbookXMLZip, fileName: "broken_wb.xlsx"))
    }

    func testXLSMCapabilitySetConsumersDiskMemoryDetectorAndReadOnlySaveContract() throws {
        XCTAssertTrue(TTMediaCapabilityMatrix.binarySpreadsheetExtensions.contains("xlsm"))
        XCTAssertTrue(TTMediaCapabilityMatrix.spreadsheetExtensions.contains("xlsm"))
        XCTAssertEqual(TTMediaCapabilityMatrix.descriptor(for: "xlsm")?.capabilities, [.structuredData])
        XCTAssertEqual(TTMediaCapabilityMatrix.descriptor(for: "xlsm")?.capabilities, TTMediaCapabilityMatrix.descriptor(for: "xlsx")?.capabilities)
        XCTAssertTrue(TTPreviewHorizontalKeyPolicy.ownsHorizontalArrowKeys(fileName: "macro_book.xlsm"))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("xlsm_r5_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // Genuine macroEnabled.main+xml XLSM fixture (explicitly no xl/vbaProject.bin, no macro execution)
        let macroEnabledNoVBAData = makeStoredZipArchive(entries: [
            ("[Content_Types].xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/xl/workbook.xml" ContentType="application/vnd.ms-excel.sheet.macroEnabled.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
            """.utf8)),
            ("xl/workbook.xml", Data("<workbook><sheets><sheet name=\"MacroSheet\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>MacroEnabledNoVBA</t></is></c><c r=\"C1\"><f>1+2</f><v>3</v></c></row></sheetData></worksheet>".utf8))
        ])
        let xlsmURL = tempDir.appendingPathComponent("genuine_macro_enabled_no_vba.xlsm")
        try macroEnabledNoVBAData.write(to: xlsmURL)
        let renamedXLSXData = makeMinimalXLSXArchive(
            sheetXML: "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>RenamedXLSX</t></is></c></row></sheetData></worksheet>"
        )
        let renamedURL = tempDir.appendingPathComponent("renamed_control.xlsm")
        try renamedXLSXData.write(to: renamedURL)
        for (url, data, expectedRow) in [
            (xlsmURL, macroEnabledNoVBAData, ["MacroEnabledNoVBA", "", "3"]),
            (renamedURL, renamedXLSXData, ["RenamedXLSX"])
        ] {
            guard case .officeSpreadsheet(let diskWB) = TTMediaDetector.detectType(url: url) else {
                return XCTFail("Expected disk detector to route \(url.lastPathComponent) to .officeSpreadsheet")
            }
            guard case .officeSpreadsheet(let memWB) = TTMediaDetector.detectTypeFromMemory(
                data: data, suggestedName: url.lastPathComponent
            ) else {
                return XCTFail("Expected memory detector to route \(url.lastPathComponent) to .officeSpreadsheet")
            }
            XCTAssertEqual(diskWB.activeSheet?.rows, [expectedRow])
            XCTAssertEqual(memWB.activeSheet?.rows, [expectedRow])
            let preview = SpreadsheetTablePreviewView(workbook: diskWB)
            XCTAssertTrue(preview.isReadOnly)
            XCTAssertFalse(preview.canSaveInPlace)
            XCTAssertFalse(preview.saveFile(contentOverride: "mutated,1\n"))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testODSDateAndTimeValueFallbackPreservesDisplayTextPriorityAndPositiveControls() {
        let odsContent = """
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                                 xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
                                 xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:spreadsheet>
            <table:table table:name="TemporalAndRepeats">
              <table:table-row>
                <table:table-cell office:value-type="date" office:date-value="2026-10-25"/>
                <table:table-cell office:value-type="date" office:date-value="2026-10-25"><text:p>2026/10/25 (Display)</text:p></table:table-cell>
                <table:table-cell office:value-type="time" office:time-value="PT13H45M00S"/>
                <table:table-cell office:value-type="time" office:time-value="PT13H45M00S"><text:p>13:45</text:p></table:table-cell>
              </table:table-row>
              <table:table-row>
                <table:table-cell/>
                <table:table-cell table:number-columns-repeated="2" office:value-type="float" office:value="42.5"/>
                <table:table-cell office:value-type="float" office:value="99"><text:p>99.00 USD</text:p></table:table-cell>
              </table:table-row>
            </table:table>
          </office:spreadsheet></office:body>
        </office:document-content>
        """
        let archive = makeStoredZipArchive(entries: [
            ("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8)),
            ("content.xml", Data(odsContent.utf8))
        ])
        guard let wb = TTMediaOfficeSpreadsheetReader.loadWorkbook(data: archive, fileName: "dates_controls.ods"),
              let sheet = wb.activeSheet else {
            return XCTFail("Expected ODS workbook with date-value/time-value cells to parse")
        }
        XCTAssertEqual(sheet.rows, [
            ["2026-10-25", "2026/10/25 (Display)", "PT13H45M00S", "13:45"],
            ["", "42.5", "42.5", "99.00 USD"]
        ])
    }

    // MARK: - Helpers

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeMinimalXLSXArchive(sheetXML: String, sharedStringsXML: String? = nil) -> Data {
        let workbookXML = "<workbook><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
        let relsXML = "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"
        var entries: [(String, Data)] = [
            ("xl/workbook.xml", Data(workbookXML.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(relsXML.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheetXML.utf8))
        ]
        if let sst = sharedStringsXML { entries.append(("xl/sharedStrings.xml", Data(sst.utf8))) }
        return makeStoredZipArchive(entries: entries)
    }

    private func makeStoredZipArchive(entries: [(String, Data)]) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        for (name, payload) in entries {
            let nameData = Data(name.utf8)
            let localOffset = UInt32(archive.count)
            let size = UInt32(payload.count)
            for v: UInt32 in [0x0403_4B50] { appendUInt32LE(v, to: &archive) }
            for v: UInt16 in [20, 0, 0, 0, 0] { appendUInt16LE(v, to: &archive) }
            for v: UInt32 in [0, size, size] { appendUInt32LE(v, to: &archive) }
            for v: UInt16 in [UInt16(nameData.count), 0] { appendUInt16LE(v, to: &archive) }
            archive.append(nameData)
            archive.append(payload)

            appendUInt32LE(0x0201_4B50, to: &centralDirectory)
            for v: UInt16 in [20, 20, 0, 0, 0, 0] { appendUInt16LE(v, to: &centralDirectory) }
            for v: UInt32 in [0, size, size] { appendUInt32LE(v, to: &centralDirectory) }
            for v: UInt16 in [UInt16(nameData.count), 0, 0, 0, 0] { appendUInt16LE(v, to: &centralDirectory) }
            for v: UInt32 in [0, localOffset] { appendUInt32LE(v, to: &centralDirectory) }
            centralDirectory.append(nameData)
        }
        let cdOffset = UInt32(archive.count)
        let cdSize = UInt32(centralDirectory.count)
        archive.append(centralDirectory)
        appendUInt32LE(0x0605_4B50, to: &archive)
        for v: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] { appendUInt16LE(v, to: &archive) }
        for v: UInt32 in [cdSize, cdOffset] { appendUInt32LE(v, to: &archive) }
        appendUInt16LE(0, to: &archive)
        return archive
    }

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)
        ])
    }

    private func locateDocumentsFixturesDirectory() throws -> URL {
        let sourceDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/preview/documents", isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceDir.path) {
            return sourceDir
        }
        if let testSrcDir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] {
            let runfilesPath = URL(fileURLWithPath: testSrcDir)
                .appendingPathComponent("_main/infra/ttmedia/Tests/Fixtures/preview/documents", isDirectory: true)
            if FileManager.default.fileExists(atPath: runfilesPath.path) {
                return runfilesPath
            }
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Required preview documents fixture directory is missing"])
    }
}

