// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import SwiftUI
import TTI18nCore
import TTI18nUI
import XCTest
@testable import TTMediaKit

@MainActor
final class SpreadsheetInspectorLayoutTests: XCTestCase {
    private static let sample37ByteCSV = "name,value\n\"中文\",42\n\"two\nlines\",7\n"

    func testResponsiveWidthsAndCaptureAfterScreenshots() async throws {
        let state = LocalizationState.shared
        let originalLang = state.currentLanguage
        defer { state.setLanguage(originalLang) }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("t1_after_sample-\(UUID().uuidString).csv")
        try Self.sample37ByteCSV.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let specs: [(tag: String, size: NSSize, appearance: NSAppearance.Name, lang: AppLanguage, expectedTier: SpreadsheetWidthTier)] = [
            ("after_320x220_zh_dark", NSSize(width: 320, height: 220), .darkAqua, .zhHans, .narrow),
            ("after_320x360_zh_dark", NSSize(width: 320, height: 360), .darkAqua, .zhHans, .narrow),
            ("after_320x360_zh_light", NSSize(width: 320, height: 360), .aqua, .zhHans, .narrow),
            ("after_320x360_en_dark", NSSize(width: 320, height: 360), .darkAqua, .en, .narrow),
            ("after_400x360_zh_dark", NSSize(width: 400, height: 360), .darkAqua, .zhHans, .regular),
            ("after_520x360_zh_dark", NSSize(width: 520, height: 360), .darkAqua, .zhHans, .medium),
            ("after_860x520_zh_dark", NSSize(width: 860, height: 520), .darkAqua, .zhHans, .wide),
        ]

        var diagnostics: [String] = []
        for spec in specs {
            state.setLanguage(spec.lang)
            let diag = try await verifyAndSnapshotSpec(
                tag: spec.tag,
                size: spec.size,
                appearance: spec.appearance,
                expectedTier: spec.expectedTier,
                fileURL: tempURL
            )
            diagnostics.append(diag)
        }

        if let outDir = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] {
            let reportURL = URL(fileURLWithPath: outDir).appendingPathComponent("t1_after_diagnostics.txt")
            try? diagnostics.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
        }
    }

    private func verifyAndSnapshotSpec(
        tag: String,
        size: NSSize,
        appearance: NSAppearance.Name,
        expectedTier: SpreadsheetWidthTier,
        fileURL: URL
    ) async throws -> String {
        let preview = SpreadsheetTablePreviewView(
            initialContent: Self.sample37ByteCSV,
            fileURL: fileURL,
            fileName: "sample.csv"
        )
        let hosting = try await mountPreview(preview, size: size, appearance: appearance)
        let probe = try XCTUnwrap(findContentProbe(in: hosting), "Missing content probe in \(tag)")
        let stateProbe = try XCTUnwrap(findStateProbe(in: hosting), "Missing state probe in \(tag)")

        stateProbe.setSelectedCoordinate?(SpreadsheetCellCoordinate(row: 2, column: 0))
        await pumpLayout(hosting, iterations: 6)

        let probeFrame = probe.convert(probe.bounds, to: hosting)
        let scrollFrames = findScrollViews(in: hosting).map { $0.convert($0.bounds, to: hosting) }
        let buttons = findButtons(in: hosting)
        let maxBtnHeight = buttons.map(\.frame.height).max() ?? 0

        XCTAssertEqual(stateProbe.widthTier, expectedTier, "Unexpected tier for \(tag)")
        XCTAssertGreaterThanOrEqual(probeFrame.minX, -0.5, "First column clipped on left in \(tag): \(probeFrame)")
        if let firstScroll = scrollFrames.first {
            XCTAssertEqual(firstScroll.minX, 0, accuracy: 1.0, "ScrollView minX must start at 0 in \(tag)")
            XCTAssertEqual(firstScroll.width, size.width, accuracy: 1.0, "ScrollView width must match viewport in \(tag)")
        }
        XCTAssertLessThanOrEqual(maxBtnHeight, 32.0, "Abnormally tall wrapped button in \(tag): \(maxBtnHeight)")
        for btn in buttons {
            let frameInRoot = btn.convert(btn.bounds, to: hosting)
            XCTAssertGreaterThanOrEqual(frameInRoot.minX, -1.0, "Button overflowed left in \(tag)")
            XCTAssertLessThanOrEqual(frameInRoot.maxX, size.width + 1.0, "Button overflowed right in \(tag)")
        }

        saveSnapshot(of: hosting, named: "t1_\(tag).png")
        return "\(tag): viewport=\(Int(size.width))x\(Int(size.height)) tier=\(stateProbe.widthTier.rawValue) " +
            "probeFrameInRoot=\(NSStringFromRect(probeFrame)) maxButtonHeight=\(Int(maxBtnHeight)) " +
            "scrollFrames=\(scrollFrames.map { NSStringFromRect($0) }.joined(separator: ";"))"
    }

    private static let sample37ByteTSV = "name\tvalue\n\"中文\"\t42\n\"two\nlines\"\t7\n"

    func testSample37ByteCSVAndTSVNonFirstColumnClickAndHeaderMapping() async throws {
        XCTAssertEqual(Self.sample37ByteCSV.utf8.count, 37)
        XCTAssertEqual(Self.sample37ByteTSV.utf8.count, 37)

        for (content, name) in [(Self.sample37ByteCSV, "sample.csv"), (Self.sample37ByteTSV, "sample.tsv")] {
            let preview = SpreadsheetTablePreviewView(initialContent: content, fileURL: nil, fileName: name)
            let hosting = try await mountPreview(preview, size: NSSize(width: 320, height: 360), appearance: .darkAqua)
            let probe = try XCTUnwrap(findContentProbe(in: hosting))
            let stateProbe = try XCTUnwrap(findStateProbe(in: hosting))

            XCTAssertEqual(probe.renderedRowCount, 3)
            XCTAssertEqual(probe.renderedColumnCount, 2)
            XCTAssertEqual(probe.headers, ["A", "B"])
            XCTAssertEqual(probe.renderedRowNumbers, [1, 2, 3])
            XCTAssertEqual(probe.allRows, [["name", "value"], ["中文", "42"], ["two\nlines", "7"]])
            XCTAssertEqual(probe.resolvedColumnWidths.count, 2)

            // Non-first-column click (Row index 1, Col index 1 -> B2 = "42")
            probe.simulateCellTap?(1, 1)
            await pumpLayout(hosting, iterations: 6)
            XCTAssertEqual(stateProbe.selectedCoordinate, SpreadsheetCellCoordinate(row: 1, column: 1))
            XCTAssertEqual(stateProbe.selectedCoordinate?.excelReference, "B2")
            XCTAssertEqual(stateProbe.selectedCellContent, "42")

            // Multiline cell click & copy (Row index 2, Col index 0 -> A3 = "two\nlines")
            probe.simulateCellTap?(2, 0)
            await pumpLayout(hosting, iterations: 6)
            XCTAssertEqual(stateProbe.selectedCoordinate, SpreadsheetCellCoordinate(row: 2, column: 0))
            XCTAssertEqual(stateProbe.selectedCoordinate?.excelReference, "A3")
            XCTAssertEqual(stateProbe.selectedCellContent, "two\nlines")

            NSPasteboard.general.clearContents()
            stateProbe.copySelectedCellAction?()
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "two\nlines")

            // Toggle first-row header mode: headers become ["name", "value"], visible rows are original rows [2, 3]
            stateProbe.toggleHeaderMode?()
            await pumpLayout(hosting, iterations: 8)
            let updatedProbe = try XCTUnwrap(findContentProbe(in: hosting))
            XCTAssertEqual(updatedProbe.headers, ["name", "value"])
            XCTAssertEqual(updatedProbe.renderedRowCount, 2)
            XCTAssertEqual(updatedProbe.renderedRowNumbers, [2, 3])
            XCTAssertEqual(updatedProbe.firstRowCells, ["中文", "42"])

            // Non-first-column click after header toggle (visible row 1, col 1 -> original B3 = "7")
            updatedProbe.simulateCellTap?(1, 1)
            await pumpLayout(hosting, iterations: 6)
            let updatedState = try XCTUnwrap(findStateProbe(in: hosting))
            XCTAssertEqual(updatedState.selectedCoordinate, SpreadsheetCellCoordinate(row: 2, column: 1))
            XCTAssertEqual(updatedState.selectedCoordinate?.excelReference, "B3")
            XCTAssertEqual(updatedState.selectedCellContent, "7")
        }
    }

    func testPaginationFilterAndJumpPreserveOriginalRowColumnMapping() async throws {
        var lines = ["id,label,score"]
        for i in 1...65 {
            lines.append("\(i),item_\(i),\(i * 10)")
        }
        let csv = lines.joined(separator: "\n") + "\n"
        let preview = SpreadsheetTablePreviewView(initialContent: csv, fileURL: nil, fileName: "paged.csv")
        let hosting = try await mountPreview(preview, size: NSSize(width: 520, height: 360), appearance: .darkAqua)
        let stateProbe = try XCTUnwrap(findStateProbe(in: hosting))

        stateProbe.toggleHeaderMode?()
        stateProbe.setPageSizeOption?(.fifty)
        stateProbe.setCurrentPageIndex?(1)
        await pumpLayout(hosting, iterations: 8)

        let page2Probe = try XCTUnwrap(findContentProbe(in: hosting))
        XCTAssertEqual(page2Probe.renderedRowCount, 15)
        XCTAssertEqual(page2Probe.renderedRowNumbers.first, 52)

        // Click visible row 1, column 2 (3rd column "score") on page 2 -> original row index 52 (excel C53 = "520")
        page2Probe.simulateCellTap?(1, 2)
        await pumpLayout(hosting, iterations: 6)
        let afterClickState = try XCTUnwrap(findStateProbe(in: hosting))
        XCTAssertEqual(afterClickState.selectedCoordinate, SpreadsheetCellCoordinate(row: 52, column: 2))
        XCTAssertEqual(afterClickState.selectedCoordinate?.excelReference, "C53")
        XCTAssertEqual(afterClickState.selectedCellContent, "520")

        // Filter by "item_60" and click column 1 ("label") -> original row index 60 (excel B61 = "item_60")
        afterClickState.setSearchQuery?("item_60")
        await pumpLayout(hosting, iterations: 8)
        let filteredProbe = try XCTUnwrap(findContentProbe(in: hosting))
        XCTAssertEqual(filteredProbe.renderedRowCount, 1)
        XCTAssertEqual(filteredProbe.renderedRowNumbers, [61])
        filteredProbe.simulateCellTap?(0, 1)
        await pumpLayout(hosting, iterations: 6)
        let filteredState = try XCTUnwrap(findStateProbe(in: hosting))
        XCTAssertEqual(filteredState.selectedCoordinate, SpreadsheetCellCoordinate(row: 60, column: 1))
        XCTAssertEqual(filteredState.selectedCoordinate?.excelReference, "B61")
        XCTAssertEqual(filteredState.selectedCellContent, "item_60")
    }

    func testMultiColumnLongFieldsEmptyTableTSVAndLocales() async throws {
        let longText = String(repeating: "LongSegment_中文_", count: 16)
        let wideHeader = (1...10).map { "col_\($0)" }.joined(separator: ",")
        let wideRow = ([longText] + (2...10).map { "val_\($0)" }).joined(separator: ",")
        let multiColCSV = "\(wideHeader)\n\(wideRow)\n"

        let multiPreview = SpreadsheetTablePreviewView(initialContent: multiColCSV, fileName: "wide.csv")
        let multiHost = try await mountPreview(multiPreview, size: NSSize(width: 320, height: 360), appearance: .darkAqua)
        let multiProbe = try XCTUnwrap(findContentProbe(in: multiHost))
        XCTAssertEqual(multiProbe.renderedColumnCount, 10)
        XCTAssertEqual(multiProbe.allRows.last?.first, longText)
        XCTAssertLessThanOrEqual(multiProbe.resolvedColumnWidths.first ?? 0, TTSpreadsheetView.maxAutoColumnWidth)
        XCTAssertGreaterThan(multiProbe.resolvedColumnWidths.reduce(0, +), 320)
        XCTAssertGreaterThanOrEqual(multiProbe.convert(multiProbe.bounds, to: multiHost).minX, -0.5)
        saveSnapshot(of: multiHost, named: "t1_after_320x360_multicolumn_dark.png")

        let tsvContent = "id\tcity\tpopulation\n1\tShanghai\t24870000\n2\tTokyo\t13960000\n"
        let tsvPreview = SpreadsheetTablePreviewView(initialContent: tsvContent, fileName: "cities.tsv")
        let tsvHost = try await mountPreview(tsvPreview, size: NSSize(width: 400, height: 320), appearance: .aqua)
        let tsvProbe = try XCTUnwrap(findContentProbe(in: tsvHost))
        XCTAssertEqual(tsvProbe.renderedColumnCount, 3)
        XCTAssertEqual(tsvProbe.renderedRowCount, 3)

        let emptyPreview = SpreadsheetTablePreviewView(initialContent: "", fileName: "empty.csv")
        let emptyHost = try await mountPreview(emptyPreview, size: NSSize(width: 320, height: 260), appearance: .darkAqua)
        XCTAssertNil(findContentProbe(in: emptyHost))

        let state = LocalizationState.shared
        let saved = state.currentLanguage
        defer { state.setLanguage(saved) }
        for lang in [AppLanguage.en, .zhHans, .zhHant] {
            state.setLanguage(lang)
            XCTAssertFalse(SpreadsheetPreviewLocalization.text(.tableSettingsMenu).isEmpty)
            XCTAssertFalse(SpreadsheetPreviewLocalization.text(.searchToggleHelp).isEmpty)
            XCTAssertTrue(SpreadsheetPreviewLocalization.cellDetailTitle("A3").contains("A3"))
        }
    }

    func testResizePreservesSearchSelectionModeWithoutReparse() async throws {
        let preview = SpreadsheetTablePreviewView(
            initialContent: Self.sample37ByteCSV,
            fileURL: nil,
            fileName: "sample.csv"
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: preview)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 360)
        window.contentView = hosting
        await pumpLayout(hosting, iterations: 15)

        let stateProbe = try XCTUnwrap(findStateProbe(in: hosting))
        let initialReparseCount = stateProbe.reparseCount
        XCTAssertEqual(initialReparseCount, 1)

        stateProbe.toggleHeaderMode?()
        stateProbe.setSearchQuery?("中文")
        stateProbe.setSelectedCoordinate?(SpreadsheetCellCoordinate(row: 1, column: 0))
        await pumpLayout(hosting, iterations: 8)

        for width in [CGFloat(400), 520, 860, 320] {
            let newSize = NSSize(width: width, height: 360)
            window.setContentSize(newSize)
            hosting.frame = NSRect(origin: .zero, size: newSize)
            await pumpLayout(hosting, iterations: 8)

            let currentProbe = try XCTUnwrap(findStateProbe(in: hosting))
            XCTAssertEqual(currentProbe.searchQuery, "中文", "Search query reset at width \(width)")
            XCTAssertEqual(currentProbe.selectedCoordinate, SpreadsheetCellCoordinate(row: 1, column: 0))
            XCTAssertTrue(currentProbe.useFirstRowAsHeader, "Header mode reset at width \(width)")
            XCTAssertEqual(currentProbe.mode, .table, "Preview mode reset at width \(width)")
            XCTAssertEqual(currentProbe.reparseCount, initialReparseCount, "Unexpected reparse on width change \(width)")
        }
    }

    func testDiskAndArchiveEntryPointsEnforceReadOnlyAndAuthorizedSaveReopen() async throws {
        let fm = FileManager.default
        let baseDir = fm.temporaryDirectory.appendingPathComponent("T1SaveGuard-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: baseDir) }

        let diskURL = baseDir.appendingPathComponent("editable.csv")
        try Self.sample37ByteCSV.write(to: diskURL, atomically: true, encoding: .utf8)
        let diskPreview = SpreadsheetTablePreviewView(initialContent: Self.sample37ByteCSV, fileURL: diskURL, fileName: "editable.csv")
        XCTAssertFalse(diskPreview.isReadOnly)
        XCTAssertTrue(diskPreview.canSaveInPlace)
        XCTAssertTrue(diskPreview.isEditorEditable)

        // Explicit F4 isReadOnly: true blocks both editing and saving even on a writable disk file
        let f4LockedPreview = SpreadsheetTablePreviewView(
            initialContent: Self.sample37ByteCSV,
            fileURL: diskURL,
            fileName: "editable.csv",
            isReadOnly: true
        )
        XCTAssertTrue(f4LockedPreview.isReadOnly)
        XCTAssertFalse(f4LockedPreview.canSaveInPlace)
        XCTAssertFalse(f4LockedPreview.isEditorEditable)
        XCTAssertFalse(f4LockedPreview.saveFile(contentOverride: "blocked,0\n"))

        // Explicit F4 TTPreviewResourceContext.archiveEntry blocks editing and saving even if staged on a writable URL
        let archiveContext = TTPreviewResourceContext.archiveEntry(
            archivePath: "/tmp/bundle.zip",
            entryPath: "tables/editable.csv",
            stagedReadURL: diskURL,
            fileName: "editable.csv"
        )
        let archiveContextPreview = SpreadsheetTablePreviewView(
            initialContent: Self.sample37ByteCSV,
            fileURL: diskURL,
            fileName: "editable.csv",
            resourceContext: archiveContext
        )
        XCTAssertTrue(archiveContextPreview.isReadOnly)
        XCTAssertFalse(archiveContextPreview.canSaveInPlace)
        XCTAssertFalse(archiveContextPreview.isEditorEditable)
        XCTAssertFalse(archiveContextPreview.saveFile(contentOverride: "blocked_archive_ctx,0\n"))

        let readOnlyURL = baseDir.appendingPathComponent("readonly.csv")
        try Self.sample37ByteCSV.write(to: readOnlyURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnlyURL.path)
        let readOnlyPreview = SpreadsheetTablePreviewView(initialContent: Self.sample37ByteCSV, fileURL: readOnlyURL, fileName: "readonly.csv")
        XCTAssertFalse(readOnlyPreview.canSaveInPlace)
        XCTAssertFalse(readOnlyPreview.isEditorEditable)
        XCTAssertFalse(readOnlyPreview.saveFile(contentOverride: "mutated,1\n"))

        let archiveCacheDir = baseDir.appendingPathComponent("TTZipLRUPreviewCache/entry_hash", isDirectory: true)
        try fm.createDirectory(at: archiveCacheDir, withIntermediateDirectories: true)
        let archiveStagedURL = archiveCacheDir.appendingPathComponent("sample.csv")
        try Self.sample37ByteCSV.write(to: archiveStagedURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveStagedURL.path)

        let archivePreview = SpreadsheetTablePreviewView(
            initialContent: Self.sample37ByteCSV,
            fileURL: archiveStagedURL,
            fileName: "sample.csv"
        )
        XCTAssertTrue(SpreadsheetTablePreviewView.isArchiveOrEphemeralStagingURL(archiveStagedURL))
        XCTAssertTrue(archivePreview.isReadOnly)
        XCTAssertFalse(archivePreview.canSaveInPlace, "Archive-staged temporary file must be strictly read-only")
        XCTAssertFalse(archivePreview.isEditorEditable)
        XCTAssertFalse(archivePreview.saveFile(contentOverride: "corrupted,999\n"))
        XCTAssertEqual(try String(contentsOf: archiveStagedURL, encoding: .utf8), Self.sample37ByteCSV)

        let archiveHost = try await mountPreview(archivePreview, size: NSSize(width: 400, height: 320), appearance: .darkAqua)
        let diskHost = try await mountPreview(diskPreview, size: NSSize(width: 400, height: 320), appearance: .darkAqua)
        let archiveStateProbe = try XCTUnwrap(findStateProbe(in: archiveHost))
        let diskStateProbe = try XCTUnwrap(findStateProbe(in: diskHost))
        XCTAssertFalse(archiveStateProbe.canSaveInPlace, "Read-only archive preview must omit Save button")
        XCTAssertTrue(diskStateProbe.canSaveInPlace, "Authorized disk preview must expose Save button")

        // Authorized disk save and reopen verification
        let updatedCSV = "name,value\n\"中文\",108\n\"two\nlines\",99\n"
        XCTAssertTrue(diskPreview.saveFile(contentOverride: updatedCSV))
        let reloadedDiskText = try String(contentsOf: diskURL, encoding: .utf8)
        XCTAssertEqual(reloadedDiskText, updatedCSV)

        let reopenedPreview = SpreadsheetTablePreviewView(initialContent: reloadedDiskText, fileURL: diskURL, fileName: "editable.csv")
        let reopenedHost = try await mountPreview(reopenedPreview, size: NSSize(width: 320, height: 360), appearance: .darkAqua)
        let reopenedProbe = try XCTUnwrap(findContentProbe(in: reopenedHost))
        XCTAssertEqual(reopenedProbe.allRows, [["name", "value"], ["中文", "108"], ["two\nlines", "99"]])

        let virtualURL = URL(string: "file:///tmp/archive.zip?subpath=tables/sample.csv")
        XCTAssertTrue(SpreadsheetTablePreviewView.isArchiveOrEphemeralStagingURL(virtualURL))
    }

    func testWorkbookFormatBadgeReflectsVerifiedWorkbookFormatAndPreservesDelimitedBadges() async throws {
        let singleRowSheet = TTMediaSheetData(name: "S1", totalRows: 1, totalColumns: 2, rows: [["A", "B"]])
        let xlsxWB = OfficeSpreadsheetWorkbook(fileName: "book.xlsx", sheetNames: ["S1"], activeSheet: singleRowSheet)
        let xlsmWB = OfficeSpreadsheetWorkbook(fileName: "macro.xlsm", sheetNames: ["S1"], activeSheet: singleRowSheet)
        let odsWB = OfficeSpreadsheetWorkbook(fileName: "calc.ods", sheetNames: ["S1"], activeSheet: singleRowSheet)

        let xlsxHost = try await mountPreview(SpreadsheetTablePreviewView(workbook: xlsxWB), size: NSSize(width: 480, height: 320), appearance: .darkAqua)
        let xlsmHost = try await mountPreview(SpreadsheetTablePreviewView(workbook: xlsmWB), size: NSSize(width: 480, height: 320), appearance: .darkAqua)
        let odsHost = try await mountPreview(SpreadsheetTablePreviewView(workbook: odsWB), size: NSSize(width: 480, height: 320), appearance: .darkAqua)
        let csvHost = try await mountPreview(SpreadsheetTablePreviewView(initialContent: "a,b\n1,2\n", fileName: "data.csv"), size: NSSize(width: 480, height: 320), appearance: .darkAqua)
        let tsvHost = try await mountPreview(SpreadsheetTablePreviewView(initialContent: "a\tb\n1\t2\n", fileName: "data.tsv"), size: NSSize(width: 480, height: 320), appearance: .darkAqua)

        XCTAssertEqual(try XCTUnwrap(findStateProbe(in: xlsxHost)).formatBadgeTitle, "XLSX")
        XCTAssertEqual(try XCTUnwrap(findStateProbe(in: xlsmHost)).formatBadgeTitle, "XLSM")
        XCTAssertEqual(try XCTUnwrap(findStateProbe(in: odsHost)).formatBadgeTitle, "ODS")
        XCTAssertEqual(try XCTUnwrap(findStateProbe(in: csvHost)).formatBadgeTitle, "CSV (,)")
        XCTAssertEqual(try XCTUnwrap(findStateProbe(in: tsvHost)).formatBadgeTitle, "TSV (⇥)")
    }

    func testWorkbookColumnTruncationAndRowBoundary50000Vs50001PreserveSheetTruncationTruth() async throws {
        // 1. Column > 512 truncation (totalColumns = 513, rows capped to 512 cols, only 1 row):
        // must remain truncated both at init AND after loadInitialWorkbookSheet two-stage snapshots complete.
        let wideRow = (1...512).map { "C\($0)" }
        let colTruncatedSheet = TTMediaSheetData(name: "Wide513", totalRows: 1, totalColumns: 513, rows: [wideRow])
        XCTAssertTrue(colTruncatedSheet.isTruncated)
        let colWB = OfficeSpreadsheetWorkbook(fileName: "wide.xlsx", sheetNames: ["Wide513"], activeSheet: colTruncatedSheet)
        let colPreview = SpreadsheetTablePreviewView(workbook: colWB)
        XCTAssertTrue(colPreview.isPreviewTruncated, "init(workbook:) must preserve activeSheet.isTruncated when columns > 512")
        let colHost = try await mountPreview(colPreview, size: NSSize(width: 600, height: 320), appearance: .darkAqua)
        await pumpLayout(colHost, iterations: 15)
        let colStateProbe = try XCTUnwrap(findStateProbe(in: colHost))
        XCTAssertTrue(colStateProbe.isPreviewTruncated, "loadInitialWorkbookSheet two-stage snapshot must not overwrite column truncation to false")

        // 2. Row exact boundary: 50,000 rows (isTruncated == false) vs 50,001 rows capped to 50,000 (isTruncated == true)
        let exact50kRows = Array(repeating: ["R"], count: 50_000)
        let exact50kSheet = TTMediaSheetData(name: "Exact50k", totalRows: 50_000, totalColumns: 1, rows: exact50kRows)
        XCTAssertFalse(exact50kSheet.isTruncated)
        let exact50kWB = OfficeSpreadsheetWorkbook(fileName: "exact50k.xlsx", sheetNames: ["Exact50k"], activeSheet: exact50kSheet)
        let exact50kPreview = SpreadsheetTablePreviewView(workbook: exact50kWB)
        XCTAssertFalse(exact50kPreview.isPreviewTruncated, "50,000 rows within budget must not be marked truncated")

        let over50kSheet = TTMediaSheetData(name: "Over50k", totalRows: 50_001, totalColumns: 1, rows: exact50kRows)
        XCTAssertTrue(over50kSheet.isTruncated)
        let over50kWB = OfficeSpreadsheetWorkbook(fileName: "over50k.xlsx", sheetNames: ["Over50k"], activeSheet: over50kSheet)
        let over50kPreview = SpreadsheetTablePreviewView(workbook: over50kWB)
        XCTAssertTrue(over50kPreview.isPreviewTruncated, "50,001 rows capped to 50,000 must preserve activeSheet.isTruncated == true")
        let over50kHost = try await mountPreview(over50kPreview, size: NSSize(width: 600, height: 320), appearance: .darkAqua)
        await pumpLayout(over50kHost, iterations: 20)
        XCTAssertTrue(try XCTUnwrap(findStateProbe(in: over50kHost)).isPreviewTruncated, "50,001 row sheet must stay truncated after async snapshot")
    }

    func testWorkbookSheetSwitchingNormalToTruncatedToNormalAndLateAsyncResultProtection() async throws {
        // 1. Independent contrast: legacy rows-only `sheetLoader` vs typed `sheetDataLoader`
        // Even if the underlying workbook has a column-truncated sheet of 1 row, a custom legacy
        // `sheetLoader` returning 1 row of different/complete columns must NOT secretly re-read the
        // workbook or borrow `readerSheet.totalRows/totalColumns` (even when source is unreadable/replaced).
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("R5LegacyContrast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workbookXML = """
        <workbook><sheets>
          <sheet name="NormalA" sheetId="1" r:id="rId1"/>
          <sheet name="TruncWide" sheetId="2" r:id="rId2"/>
          <sheet name="NormalB" sheetId="3" r:id="rId3"/>
        </sheets></workbook>
        """
        let relsXML = """
        <Relationships>
          <Relationship Id="rId1" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Target="worksheets/sheet2.xml"/>
          <Relationship Id="rId3" Target="worksheets/sheet3.xml"/>
        </Relationships>
        """
        let sheet1XML = "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>A_OK</t></is></c><c r=\"B1\"><v>1</v></c></row></sheetData></worksheet>"
        let sheet2XML = "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>WIDE_START</t></is></c><c r=\"SZ1\"><v>513</v></c></row></sheetData></worksheet>"
        let sheet3XML = "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>B_OK</t></is></c><c r=\"B1\"><v>2</v></c></row></sheetData></worksheet>"
        let zipData = makeStoredZipForMultiSheetTest(entries: [
            ("xl/workbook.xml", Data(workbookXML.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(relsXML.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet1XML.utf8)),
            ("xl/worksheets/sheet2.xml", Data(sheet2XML.utf8)),
            ("xl/worksheets/sheet3.xml", Data(sheet3XML.utf8))
        ])
        let sourceURL = tempDir.appendingPathComponent("multi_source.xlsx")
        try zipData.write(to: sourceURL)
        let diskBackedWB = try XCTUnwrap(TTMediaOfficeSpreadsheetReader.loadWorkbook(from: sourceURL))

        // Corrupt/replace the underlying disk file after initial workbook load so any hidden disk re-read fails or diverges
        try Data("unreadable_replaced_source".utf8).write(to: sourceURL, options: .atomic)
        let memoryBackedWB = try XCTUnwrap(TTMediaOfficeSpreadsheetReader.loadWorkbook(data: zipData, fileName: "multi.xlsx"))

        // Contrast A: Legacy `sheetLoader` returns 1 row x 3 cols for "TruncWide" (same row count = 1 as original 513-col sheet, different cols).
        // Must only compute extent from returned rows (1x3 -> isTruncated == false) and never borrow reader's 513-col metadata.
        let legacyLoadedFromMemory = await SpreadsheetBackgroundPipeline.loadAndComputeSelectedSheet(
            sheetName: "TruncWide",
            workbook: memoryBackedWB,
            sheetDataLoader: nil,
            sheetLoader: { _ in [["LEGACY_C1", "LEGACY_C2", "LEGACY_C3"]] },
            useFirstRowAsHeader: false,
            searchQuery: "",
            maxRows: SpreadsheetTablePreviewView.maxPreviewRows
        )
        let unwrappedLegacyMem = try XCTUnwrap(legacyLoadedFromMemory)
        XCTAssertEqual(unwrappedLegacyMem.result.parsedRows, [["LEGACY_C1", "LEGACY_C2", "LEGACY_C3"]])
        XCTAssertFalse(unwrappedLegacyMem.isTruncated, "Legacy rows-only loader must not borrow column truncation metadata from original workbook")

        let legacyLoadedWithReplacedDisk = await SpreadsheetBackgroundPipeline.loadAndComputeSelectedSheet(
            sheetName: "TruncWide",
            workbook: diskBackedWB,
            sheetDataLoader: nil,
            sheetLoader: { _ in [["DISK_REPLACED_OK", "C2"]] },
            useFirstRowAsHeader: false,
            searchQuery: "",
            maxRows: SpreadsheetTablePreviewView.maxPreviewRows
        )
        let unwrappedLegacyDisk = try XCTUnwrap(legacyLoadedWithReplacedDisk)
        XCTAssertEqual(unwrappedLegacyDisk.result.parsedRows, [["DISK_REPLACED_OK", "C2"]])
        XCTAssertFalse(unwrappedLegacyDisk.isTruncated)

        // Contrast B: Typed `sheetDataLoader` (and production factory path) delivers both rows and extent (`totalColumns = 513 -> isTruncated == true`).
        let barrier = DeterministicSheetLoadBarrier()
        let preview = SpreadsheetTablePreviewView(
            workbook: memoryBackedWB,
            sheetDataLoader: { sheetName in
                await barrier.load(
                    sheetName: sheetName,
                    fallback: { TTMediaOfficeSpreadsheetReader.loadSheet(workbook: memoryBackedWB, sheetName: sheetName) }
                )
            }
        )
        let host = try await mountPreview(preview, size: NSSize(width: 680, height: 360), appearance: .darkAqua)
        let stateProbe = try XCTUnwrap(findStateProbe(in: host))
        let contentProbe = try XCTUnwrap(findContentProbe(in: host))

        let initialReady = await waitUntil(host: host) {
            stateProbe.selectedSheetName == "NormalA" && contentProbe.allRows.first?.first == "A_OK"
        }
        XCTAssertTrue(initialReady)
        XCTAssertFalse(stateProbe.isPreviewTruncated)

        // NormalA -> TruncWide via production typed sheetDataLoader path
        stateProbe.selectSheetAction?("TruncWide")
        let truncReady = await waitUntil(host: host) {
            stateProbe.selectedSheetName == "TruncWide" && contentProbe.allRows.first?.first == "WIDE_START"
        }
        XCTAssertTrue(truncReady)
        XCTAssertTrue(stateProbe.isPreviewTruncated, "Typed sheetDataLoader must propagate TruncWide.isTruncated == true")

        // TruncWide -> NormalB via production typed sheetDataLoader path
        stateProbe.selectSheetAction?("NormalB")
        let normalBReady = await waitUntil(host: host) {
            stateProbe.selectedSheetName == "NormalB" && contentProbe.allRows.first?.first == "B_OK"
        }
        XCTAssertTrue(normalBReady)
        XCTAssertFalse(stateProbe.isPreviewTruncated, "Switching to NormalB must reset isPreviewTruncated to false")

        // 2. Deterministic barrier for late async result protection:
        // Request A ("TruncWide") enters loader -> capture Request A's identity & sheetLoadingTask handle via internal probe ->
        // Request B ("NormalA") completes & commits -> release Request A (loader still returns non-nil TruncWide data) ->
        // bounded wait for Request A's entire sheetLoadingTask to finish (post-pipeline & post-commit-guard) ->
        // assert final rows and truncation still belong to B ("NormalA").
        let generationBeforeA = stateProbe.sheetSelectionGeneration
        await barrier.armHold(for: "TruncWide")
        stateProbe.selectSheetAction?("TruncWide")
        let didEnterA = await barrier.waitForEntered(timeoutNanoseconds: 2_000_000_000)
        let didCaptureTaskA = await waitUntil(host: host) {
            stateProbe.sheetSelectionGeneration > generationBeforeA && stateProbe.sheetLoadingTask != nil
        }
        let generationA = stateProbe.sheetSelectionGeneration
        if let taskA = stateProbe.sheetLoadingTask {
            await barrier.observeTaskCompletion(generation: generationA, task: taskA)
        }
        if !didEnterA || !didCaptureTaskA {
            await barrier.releaseHold()
            _ = await barrier.waitForTaskCompleted(generation: generationA, timeoutNanoseconds: 1_000_000_000)
            XCTFail("Timed out waiting for Request A (TruncWide) to enter sheetDataLoader and expose sheetLoadingTask")
            return
        }

        // While Request A is held inside sheetDataLoader, issue Request B ("NormalA") and wait until B commits
        stateProbe.selectSheetAction?("NormalA")
        let didCommitB = await waitUntil(host: host) {
            stateProbe.selectedSheetName == "NormalA" && contentProbe.allRows.first?.first == "A_OK" && !stateProbe.isPreviewTruncated
        }
        await barrier.releaseHold()
        let didFinishTaskA = await barrier.waitForTaskCompleted(generation: generationA, timeoutNanoseconds: 2_000_000_000)
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(didCommitB, "Request B (NormalA) must commit before or upon release")
        XCTAssertTrue(didFinishTaskA, "Held Request A's entire sheetLoadingTask (including pipeline & commit guard) must finish after release")
        XCTAssertEqual(stateProbe.selectedSheetName, "NormalA")
        XCTAssertEqual(contentProbe.allRows.first?.first, "A_OK")
        XCTAssertFalse(stateProbe.isPreviewTruncated, "Late completion of held TruncWide must never overwrite NormalA")
    }

    // MARK: - Helpers

    private func waitUntil(
        host: NSView,
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        host.layoutSubtreeIfNeeded()
        return condition()
    }

    private func mountPreview(_ preview: SpreadsheetTablePreviewView, size: NSSize, appearance: NSAppearance.Name) async throws -> NSHostingView<some View> {
        let clippedRoot = ZStack(alignment: .topTrailing) {
            Color.clear
            preview.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: clippedRoot)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        await pumpLayout(hosting, iterations: 15)
        return hosting
    }

    private func pumpLayout(_ view: NSView, iterations: Int) async {
        for _ in 0..<iterations {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        view.layoutSubtreeIfNeeded()
    }

    private func saveSnapshot(of hosting: NSView, named fileName: String) {
        guard let outDir = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"],
              let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(fileName))
    }

    private func findContentProbe(in view: NSView) -> TTSpreadsheetContentProbeNSView? {
        if let p = view as? TTSpreadsheetContentProbeNSView { return p }
        for sub in view.subviews {
            if let found = findContentProbe(in: sub) { return found }
        }
        return nil
    }

    private func findStateProbe(in view: NSView) -> SpreadsheetPreviewStateProbeNSView? {
        if let p = view as? SpreadsheetPreviewStateProbeNSView { return p }
        for sub in view.subviews {
            if let found = findStateProbe(in: sub) { return found }
        }
        return nil
    }

    private func findScrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let sv = view as? NSScrollView { result.append(sv) }
        for sub in view.subviews {
            result.append(contentsOf: findScrollViews(in: sub))
        }
        return result
    }

    private func findButtons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        if let btn = view as? NSButton { result.append(btn) }
        for sub in view.subviews {
            result.append(contentsOf: findButtons(in: sub))
        }
        return result
    }

    private func makeStoredZipForMultiSheetTest(entries: [(String, Data)]) -> Data {
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
}

private actor DeterministicSheetLoadBarrier {
    private var heldSheetName: String?
    private var didEnterHeldSheet = false
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var completedTaskGenerations: Set<UInt64> = []

    func armHold(for sheetName: String) {
        heldSheetName = sheetName
        didEnterHeldSheet = false
        isReleased = false
    }

    func load(
        sheetName: String,
        fallback: @Sendable () -> TTMediaSheetData?
    ) async -> TTMediaSheetData? {
        let precomputed = fallback()
        guard sheetName == heldSheetName else {
            return precomputed
        }
        didEnterHeldSheet = true
        if !isReleased {
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        }
        return precomputed
    }

    func observeTaskCompletion(generation: UInt64, task: Task<Void, Never>) {
        Task {
            _ = await task.value
            self.recordTaskCompleted(generation: generation)
        }
    }

    private func recordTaskCompleted(generation: UInt64) {
        completedTaskGenerations.insert(generation)
    }

    func releaseHold() {
        isReleased = true
        heldSheetName = nil
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }

    func waitForEntered(timeoutNanoseconds: UInt64) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while !didEnterHeldSheet {
            if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    func waitForTaskCompleted(generation: UInt64, timeoutNanoseconds: UInt64) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while !completedTaskGenerations.contains(generation) {
            if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}
