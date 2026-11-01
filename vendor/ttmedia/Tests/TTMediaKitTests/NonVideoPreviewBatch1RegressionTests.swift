// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import Darwin
import QuartzCore
@preconcurrency import PDFKit
import TTI18nCore
import TTI18nUI
@testable import TTMediaKit

final class NonVideoPreviewBatch1RegressionTests: XCTestCase {

    // MARK: - 1. Spreadsheet Save Policy & Office Container Protection

    @MainActor
    func testDerivedWorkbookSaveDoesNotOverwriteOriginalOfficeFileBytes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaSpreadsheetGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let originalXLSXBytes = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00, 0xDE, 0xAD, 0xBE, 0xEF])
        let xlsxURL = tempDir.appendingPathComponent("financials.xlsx")
        try originalXLSXBytes.write(to: xlsxURL, options: .atomic)

        let sheet = TTMediaSheetData(name: "Q1", totalRows: 2, totalColumns: 2, rows: [["Revenue", "Cost"], ["100", "40"]])
        let workbook = OfficeSpreadsheetWorkbook(
            fileName: "financials.xlsx",
            sheetNames: ["Q1"],
            activeSheet: sheet,
            fileURL: xlsxURL,
            rawData: originalXLSXBytes
        )

        let workbookView = SpreadsheetTablePreviewView(workbook: workbook)
        XCTAssertFalse(workbookView.canSaveInPlace)
        XCTAssertFalse(workbookView.saveFile())
        XCTAssertFalse(workbookView.saveFile(contentOverride: "Injected,CSV\n1,2\n"))
        XCTAssertEqual(try Data(contentsOf: xlsxURL), originalXLSXBytes)

        let odsBytes = Data([0x50, 0x4B, 0x03, 0x04, 0xAA, 0xBB, 0xCC, 0xDD])
        let odsURL = tempDir.appendingPathComponent("sheet.ods")
        try odsBytes.write(to: odsURL, options: .atomic)
        let directODSView = SpreadsheetTablePreviewView(
            initialContent: "A,B\n1,2\n",
            fileURL: odsURL,
            fileName: "sheet.ods"
        )
        XCTAssertFalse(directODSView.canSaveInPlace)
        XCTAssertFalse(directODSView.saveFile(contentOverride: "Modified,ODS\n"))
        XCTAssertEqual(try Data(contentsOf: odsURL), odsBytes)
    }

    @MainActor
    func testWorkbookDisguisedAsCSVIsRejectedAndAllowsOnlyGenuineCSVTSV() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaCSVGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let disguisedURL = tempDir.appendingPathComponent("disguised.csv")
        let originalContainerBytes = Data([0x50, 0x4B, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04])
        try originalContainerBytes.write(to: disguisedURL, options: .atomic)

        let sheet = TTMediaSheetData(name: "Sheet1", totalRows: 1, totalColumns: 2, rows: [["A", "B"]])
        let disguisedWorkbook = OfficeSpreadsheetWorkbook(
            fileName: "disguised.csv",
            sheetNames: ["Sheet1"],
            activeSheet: sheet,
            fileURL: disguisedURL
        )
        let disguisedView = SpreadsheetTablePreviewView(
            initialContent: "A,B\n",
            fileURL: disguisedURL,
            fileName: "disguised.csv",
            workbook: disguisedWorkbook
        )
        XCTAssertFalse(disguisedView.canSaveInPlace)
        XCTAssertFalse(disguisedView.saveFile(contentOverride: "Hacked,CSV\n"))
        XCTAssertEqual(try Data(contentsOf: disguisedURL), originalContainerBytes)

        let loaderBackedView = SpreadsheetTablePreviewView(
            initialContent: "A,B\n",
            fileURL: disguisedURL,
            fileName: "disguised.csv",
            sheetLoader: { _ in [["A", "B"]] }
        )
        XCTAssertFalse(loaderBackedView.canSaveInPlace)
        XCTAssertFalse(loaderBackedView.saveFile(contentOverride: "Hacked,Loader\n"))
        XCTAssertEqual(try Data(contentsOf: disguisedURL), originalContainerBytes)

        let csvURL = tempDir.appendingPathComponent("editable.csv")
        try "Col1,Col2\n1,2\n".write(to: csvURL, atomically: true, encoding: .utf8)
        let csvView = SpreadsheetTablePreviewView(
            initialContent: "Col1,Col2\n1,2\n",
            fileURL: csvURL,
            fileName: "editable.csv"
        )
        XCTAssertTrue(csvView.canSaveInPlace)
        XCTAssertTrue(csvView.saveFile(contentOverride: "Col1,Col2\n10,20\n"))
        XCTAssertEqual(try String(contentsOf: csvURL, encoding: .utf8), "Col1,Col2\n10,20\n")

        let tsvURL = tempDir.appendingPathComponent("editable.tsv")
        try "K\tV\nA\t1\n".write(to: tsvURL, atomically: true, encoding: .utf8)
        let tsvView = SpreadsheetTablePreviewView(
            initialContent: "K\tV\nA\t2\n",
            fileURL: tsvURL,
            fileName: "editable.tsv"
        )
        XCTAssertTrue(tsvView.canSaveInPlace)
        XCTAssertTrue(tsvView.saveFile())
        XCTAssertEqual(try String(contentsOf: tsvURL, encoding: .utf8), "K\tV\nA\t2\n")
    }

    // MARK: - 2. Unicode BOM Text Reading & Binary Sniffing on Real Temp Files

    func testUnicodeTextFilesReadAndSampleAcrossUTF16AndUTF32Endianness() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaUnicodeRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let expectedText = "TTMedia preview fixture\n中文 English 日本語 🚀\n0123456789\n"
        let encodings: [(name: String, bom: [UInt8], encoding: String.Encoding)] = [
            ("utf8bom.txt", [0xEF, 0xBB, 0xBF], .utf8),
            ("utf16le.txt", [0xFF, 0xFE], .utf16LittleEndian),
            ("utf16be.txt", [0xFE, 0xFF], .utf16BigEndian),
            ("utf32le.txt", [0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ("utf32be.txt", [0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
        ]

        for entry in encodings {
            let fileURL = tempDir.appendingPathComponent(entry.name)
            var payload = Data(entry.bom)
            let encodedBody = try XCTUnwrap(expectedText.data(using: entry.encoding))
            payload.append(encodedBody)
            try payload.write(to: fileURL, options: .atomic)

            XCTAssertFalse(PreviewContentReader.isBinaryPayload(payload), "\(entry.name) must not be flagged as binary")
            XCTAssertEqual(PreviewContentReader.readTextContent(from: fileURL), expectedText, "Full read failed for \(entry.name)")
            XCTAssertEqual(PreviewContentReader.readTextSample(from: fileURL), expectedText, "Sample read failed for \(entry.name)")

            let unalignedSample = PreviewContentReader.readTextSample(from: fileURL, maxBytes: 27)
            XCTAssertNotNil(unalignedSample, "Truncated sample read failed for \(entry.name)")
            XCTAssertTrue(expectedText.hasPrefix(unalignedSample ?? "invalid"), "Truncated sample prefix mismatch for \(entry.name)")

            let detectedSync = TTMediaDetector.detectType(url: fileURL)
            if case .text(let text) = detectedSync {
                XCTAssertEqual(text, expectedText)
            } else {
                XCTFail("Expected .text route for \(entry.name), got \(detectedSync)")
            }

            let detectedAsync = await TTMediaDetector.detectTypeAsync(url: fileURL)
            if case .text(let text) = detectedAsync {
                XCTAssertEqual(text, expectedText)
            } else {
                XCTFail("Expected async .text route for \(entry.name), got \(detectedAsync)")
            }
        }
    }

    func testGenuineBinaryFilesAndForgedBOMPayloadsAreRejected() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaBinaryReject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let binaryPayloads: [(name: String, bytes: [UInt8])] = [
            ("raw_nulls.txt", [0x00, 0x41, 0x42, 0x00, 0x43, 0x44]),
            ("utf8_bom_binary.txt", [0xEF, 0xBB, 0xBF, 0x00, 0x41, 0x00, 0x42]),
            ("utf16le_bom_nulls.txt", [0xFF, 0xFE, 0x41, 0x00, 0x00, 0x00, 0x42, 0x00]),
            ("utf16be_bom_nulls.txt", [0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41, 0x00, 0x00]),
            ("utf16le_unpaired_surrogate.txt", [0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00]),
            ("utf32le_bom_nulls.txt", [0xFF, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            ("utf32le_invalid_scalar.txt", [0xFF, 0xFE, 0x00, 0x00, 0x89, 0x50, 0x4E, 0x47]),
            ("utf32be_invalid_scalar.txt", [0x00, 0x00, 0xFE, 0xFF, 0x89, 0x50, 0x4E, 0x47]),
        ]

        for item in binaryPayloads {
            let url = tempDir.appendingPathComponent(item.name)
            let data = Data(item.bytes)
            try data.write(to: url, options: .atomic)

            XCTAssertTrue(PreviewContentReader.isBinaryPayload(data), "\(item.name) should be classified as binary")
            XCTAssertNil(PreviewContentReader.readTextContent(from: url), "\(item.name) full read should return nil")
            XCTAssertNil(PreviewContentReader.readTextSample(from: url), "\(item.name) sample read should return nil")
        }
    }

    // MARK: - 3. PDF Loading States, Equal-Length Identity, Cancellation & TTI18n

    @MainActor
    func testPDFCorruptFailureRetryAndLockedTransitions() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaPDFStates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pdfURL = tempDir.appendingPathComponent("sample.pdf")
        try Data("%PDF-1.4\n%corrupt\n".utf8).write(to: pdfURL, options: .atomic)

        let loader = PDFPreviewLoader()
        await loader.loadAsync(url: pdfURL, data: nil)
        if case .failed(let message) = loader.phase {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Corrupt PDF must enter .failed state, got \(loader.phase)")
        }
        XCTAssertNil(loader.document)

        let validPDFData = try makeSyntheticPDFData(pageCount: 1, label: "Recovered")
        try validPDFData.write(to: pdfURL, options: .atomic)
        await loader.retryAsync()
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.document?.pageCount, 1)

        let lockedURL = tempDir.appendingPathComponent("locked.pdf")
        let unlockedDoc = try XCTUnwrap(PDFDocument(data: validPDFData))
        let wroteLocked = unlockedDoc.write(
            to: lockedURL,
            withOptions: [
                PDFDocumentWriteOption.userPasswordOption: "secret123",
                PDFDocumentWriteOption.ownerPasswordOption: "owner123"
            ]
        )
        XCTAssertTrue(wroteLocked)

        await loader.loadAsync(url: lockedURL, data: nil)
        XCTAssertEqual(loader.phase, .locked)
        XCTAssertTrue(loader.document?.isLocked == true)

        XCTAssertFalse(loader.unlock(withPassword: "wrong"))
        XCTAssertEqual(loader.phase, .locked)
        XCTAssertNotNil(loader.unlockError)

        XCTAssertTrue(loader.unlock(withPassword: "secret123"))
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertNil(loader.unlockError)
        XCTAssertEqual(loader.document?.pageCount, 1)
    }

    @MainActor
    func testPDFEqualLengthDataRefreshesAndStaleRequestCannotOverwriteNewerInput() async throws {
        var mutableOnePage = try makeSyntheticPDFData(pageCount: 1, label: "DocA")
        var mutableTwoPages = try makeSyntheticPDFData(pageCount: 2, label: "DocB")
        let targetByteCount = max(mutableOnePage.count, mutableTwoPages.count) + 32
        padPDFData(&mutableOnePage, toByteCount: targetByteCount)
        padPDFData(&mutableTwoPages, toByteCount: targetByteCount)
        let dataOnePage = mutableOnePage
        let dataTwoPages = mutableTwoPages
        XCTAssertEqual(dataOnePage.count, dataTwoPages.count)

        let idA = PDFPreviewInputIdentity(url: nil, data: dataOnePage)
        let idB = PDFPreviewInputIdentity(url: nil, data: dataTwoPages)
        XCTAssertNotEqual(idA, idB, "Equal-length PDFs with different content must have distinct identities")

        let sharedURL = URL(fileURLWithPath: "/tmp/in_memory_source.pdf")
        XCTAssertNotEqual(
            PDFPreviewInputIdentity(url: sharedURL, data: dataOnePage),
            PDFPreviewInputIdentity(url: sharedURL, data: dataTwoPages)
        )

        let loader = PDFPreviewLoader()
        await loader.loadAsync(url: sharedURL, data: dataOnePage)
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.document?.pageCount, 1)

        await loader.loadAsync(url: sharedURL, data: dataTwoPages)
        XCTAssertEqual(loader.phase, .ready)
        XCTAssertEqual(loader.document?.pageCount, 2)

        let slowLoader = PDFPreviewLoader { _, data in
            guard let raw = data else { return nil }
            if raw == dataOnePage {
                try? await Task.sleep(for: .milliseconds(120))
            }
            return PDFDocument(data: raw)
        }

        slowLoader.startLoad(url: nil, data: dataOnePage)
        await slowLoader.loadAsync(url: nil, data: dataTwoPages)
        try await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(slowLoader.phase, .ready)
        XCTAssertEqual(slowLoader.document?.pageCount, 2, "Stale first load must not overwrite newer second load")
    }

    @MainActor
    func testPDFPreviewLocaleKeysUseSharedTTI18nState() {
        let state = LocalizationState.shared
        let original = state.currentLanguage
        defer { state.setLanguage(original) }

        for key in PDFPreviewLocaleKey.allCases {
            for lang in [AppLanguage.en, .zhHans, .zhHant] {
                let text = key.fallbackTranslation(for: lang)
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, key.rawKey)
            }
        }

        state.setLanguage(.zhHans)
        XCTAssertEqual(PDFPreviewLocalization.text(.loadFailedTitle), "无法加载 PDF 文档")
        XCTAssertEqual(PDFPreviewLocalization.pageTitle(3), "第 3 页")

        state.setLanguage(.en)
        XCTAssertEqual(PDFPreviewLocalization.text(.loadFailedTitle), "Unable to load PDF document")
        XCTAssertEqual(PDFPreviewLocalization.pageTitle(3), "Page 3")
    }

    func testTextReadEnforcesStreamingHardByteCeilingAtBoundarySizes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaTextBudgetBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let budget: Int64 = 1024
        let exactMinusOneURL = tempDir.appendingPathComponent("utf8_1023.txt")
        let exactURL = tempDir.appendingPathComponent("utf8_1024.txt")
        let overByOneURL = tempDir.appendingPathComponent("utf8_1025.txt")

        let text1023 = String(repeating: "A", count: 1023)
        let text1024 = String(repeating: "B", count: 1024)
        let text1025 = String(repeating: "C", count: 1025)
        try Data(text1023.utf8).write(to: exactMinusOneURL, options: .atomic)
        try Data(text1024.utf8).write(to: exactURL, options: .atomic)
        try Data(text1025.utf8).write(to: overByOneURL, options: .atomic)

        XCTAssertNil(PreviewContentReader.readTextContent(from: exactURL, maxBudget: 0))
        XCTAssertNil(PreviewContentReader.readTextContent(from: exactURL, maxBudget: -10))
        XCTAssertEqual(PreviewContentReader.readTextContent(from: exactMinusOneURL, maxBudget: budget), text1023)
        XCTAssertEqual(PreviewContentReader.readTextContent(from: exactURL, maxBudget: budget), text1024)
        XCTAssertNil(PreviewContentReader.readTextContent(from: overByOneURL, maxBudget: budget))

        // UTF-16LE BOM (2 bytes) + 511 code units (1022 bytes) == 1024 bytes exact budget
        let utf16ExactText = String(repeating: "中", count: 511)
        var utf16ExactData = Data([0xFF, 0xFE])
        utf16ExactData.append(try XCTUnwrap(utf16ExactText.data(using: .utf16LittleEndian)))
        XCTAssertEqual(utf16ExactData.count, Int(budget))
        let utf16ExactURL = tempDir.appendingPathComponent("utf16_exact.txt")
        try utf16ExactData.write(to: utf16ExactURL, options: .atomic)
        XCTAssertEqual(PreviewContentReader.readTextContent(from: utf16ExactURL, maxBudget: budget), utf16ExactText)
        XCTAssertNil(PreviewContentReader.readTextContent(from: utf16ExactURL, maxBudget: budget - 1))

        // UTF-32BE BOM (4 bytes) + 255 code units (1020 bytes) == 1024 bytes exact budget
        let utf32ExactText = String(repeating: "🚀", count: 255)
        var utf32ExactData = Data([0x00, 0x00, 0xFE, 0xFF])
        utf32ExactData.append(try XCTUnwrap(utf32ExactText.data(using: .utf32BigEndian)))
        XCTAssertEqual(utf32ExactData.count, Int(budget))
        let utf32ExactURL = tempDir.appendingPathComponent("utf32_exact.txt")
        try utf32ExactData.write(to: utf32ExactURL, options: .atomic)
        XCTAssertEqual(PreviewContentReader.readTextContent(from: utf32ExactURL, maxBudget: budget), utf32ExactText)
        XCTAssertNil(PreviewContentReader.readTextContent(from: utf32ExactURL, maxBudget: budget - 1))
    }

    func testTextReadHandlesFileGrowthDuringStreamingRead() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaTextMidReadGrowth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Case 1: File initially 512 bytes (passes stat <= 1024), grows to 2048 bytes mid-read -> must reject
        let growingOverflowURL = tempDir.appendingPathComponent("growing_overflow.txt")
        let initialText = String(repeating: "X", count: 512)
        try Data(initialText.utf8).write(to: growingOverflowURL, options: .atomic)

        var didAppendOverflow = false
        var observedChunkBytes: [Int] = []
        let overflowResult = PreviewContentReader.readTextContent(
            from: growingOverflowURL,
            maxBudget: 1024,
            chunkSize: 256
        ) { totalReadSoFar in
            observedChunkBytes.append(totalReadSoFar)
            if !didAppendOverflow {
                didAppendOverflow = true
                if let writer = try? FileHandle(forWritingTo: growingOverflowURL) {
                    _ = try? writer.seekToEnd()
                    try? writer.write(contentsOf: Data(String(repeating: "Y", count: 1536).utf8))
                    try? writer.close()
                }
            }
        }
        XCTAssertNil(overflowResult, "File growing past maxBudget during streaming read must be rejected")
        XCTAssertEqual(observedChunkBytes.last, 1024, "Reader must stop accumulating at hardBudget")

        // Case 2: UTF-16LE file with BOM initially 258 bytes, grows during read to 514 bytes (<= 1024 budget) -> succeeds
        let growingWithinBudgetURL = tempDir.appendingPathComponent("growing_utf16le_within.txt")
        let part1 = String(repeating: "文", count: 128)
        let part2 = String(repeating: "字", count: 128)
        var initialUTF16 = Data([0xFF, 0xFE])
        initialUTF16.append(try XCTUnwrap(part1.data(using: .utf16LittleEndian)))
        try initialUTF16.write(to: growingWithinBudgetURL, options: .atomic)

        let part2UTF16 = try XCTUnwrap(part2.data(using: .utf16LittleEndian))
        var didAppendUTF16 = false
        let withinResult = PreviewContentReader.readTextContent(
            from: growingWithinBudgetURL,
            maxBudget: 1024,
            chunkSize: 130
        ) { _ in
            if !didAppendUTF16 {
                didAppendUTF16 = true
                if let writer = try? FileHandle(forWritingTo: growingWithinBudgetURL) {
                    _ = try? writer.seekToEnd()
                    try? writer.write(contentsOf: part2UTF16)
                    try? writer.close()
                }
            }
        }
        XCTAssertEqual(withinResult, part1 + part2)
    }

    func testTextReadFailsWhenChunkReadOrOverflowProbeThrowsError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaTextReadErrors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("two_chunks.txt")
        let chunkOne = String(repeating: "A", count: 256)
        let chunkTwo = String(repeating: "B", count: 256)
        let fullText = chunkOne + chunkTwo
        try Data(fullText.utf8).write(to: fileURL, options: .atomic)

        // 1a. Injected EIO error on second chunk after first chunk succeeds -> must return nil (never partial chunkOne)
        var chunkCallCount = 0
        let midStreamInjectedErrorResult = PreviewContentReader.readTextContent(
            from: fileURL,
            maxBudget: 1024,
            chunkSize: 256,
            customChunkReader: { handle, count in
                chunkCallCount += 1
                if chunkCallCount == 1 {
                    return try handle.read(upToCount: count)
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
        )
        XCTAssertEqual(chunkCallCount, 2)
        XCTAssertNil(midStreamInjectedErrorResult, "Read error after first chunk must fail and never return partial text")

        // 1b. Real FileHandle closed after first chunk -> second read throws EBADF -> must return nil
        let midStreamClosedHandleResult = PreviewContentReader.readTextContent(
            from: fileURL,
            maxBudget: 1024,
            chunkSize: 256,
            customChunkReader: { handle, count in
                let data = try handle.read(upToCount: count)
                try? handle.close()
                return data
            }
        )
        XCTAssertNil(midStreamClosedHandleResult, "Descriptor read failure after first chunk must return nil")

        // 2a. Full budget reached (512 == hardBudget), 1-byte overflow probe throws injected EIO -> must return nil
        var probeCallObserved = false
        let probeInjectedErrorResult = PreviewContentReader.readTextContent(
            from: fileURL,
            maxBudget: 512,
            chunkSize: 256,
            customChunkReader: { handle, count in
                if count == 1 {
                    probeCallObserved = true
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                return try handle.read(upToCount: count)
            }
        )
        XCTAssertTrue(probeCallObserved, "Reaching hardBudget must trigger 1-byte overflow probe")
        XCTAssertNil(probeInjectedErrorResult, "Overflow probe read error must fail and never return full-budget text")

        // 2b. Full budget reached (512 == hardBudget), real FileHandle closed right before 1-byte overflow probe -> must return nil
        var bytesBeforeClose = 0
        let probeClosedHandleResult = PreviewContentReader.readTextContent(
            from: fileURL,
            maxBudget: 512,
            chunkSize: 256,
            customChunkReader: { handle, count in
                let data = try handle.read(upToCount: count)
                bytesBeforeClose += data?.count ?? 0
                if bytesBeforeClose == 512 {
                    try? handle.close()
                }
                return data
            }
        )
        XCTAssertNil(probeClosedHandleResult, "Overflow probe throwing EBADF on closed FileHandle must return nil")

        // 3. Normal EOF at exact 512-byte budget succeeds
        XCTAssertEqual(PreviewContentReader.readTextContent(from: fileURL, maxBudget: 512, chunkSize: 256), fullText)
    }

    func testTextReadAndSampleRejectNonRegularFilesWithoutBlockingOnFIFO() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaRegularFileGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Named pipe (FIFO) with no writer must not block open() and must be rejected by fstat(S_ISREG)
        let fifoURL = tempDir.appendingPathComponent("unconnected_pipe.txt")
        XCTAssertEqual(Darwin.mkfifo(fifoURL.path, 0o600), 0)

        let startFIFO = CACurrentMediaTime()
        XCTAssertNil(PreviewContentReader.readTextContent(from: fifoURL))
        XCTAssertNil(PreviewContentReader.readTextSample(from: fifoURL))
        let fifoElapsedMs = (CACurrentMediaTime() - startFIFO) * 1000.0
        XCTAssertLessThan(fifoElapsedMs, 100.0, "Opening and rejecting a writerless FIFO must be non-blocking")

        // 2. Symlink to FIFO must also be rejected without blocking
        let symlinkFIFOURL = tempDir.appendingPathComponent("symlink_to_fifo.txt")
        try FileManager.default.createSymbolicLink(at: symlinkFIFOURL, withDestinationURL: fifoURL)
        XCTAssertNil(PreviewContentReader.readTextContent(from: symlinkFIFOURL))
        XCTAssertNil(PreviewContentReader.readTextSample(from: symlinkFIFOURL))

        // 3. Directory and character device (/dev/null) must be rejected
        XCTAssertNil(PreviewContentReader.readTextContent(from: tempDir))
        XCTAssertNil(PreviewContentReader.readTextSample(from: tempDir))
        let devNullURL = URL(fileURLWithPath: "/dev/null")
        XCTAssertNil(PreviewContentReader.readTextContent(from: devNullURL))
        XCTAssertNil(PreviewContentReader.readTextSample(from: devNullURL))

        // 4. Symlink to a valid regular file must succeed for both full and sample reads
        let regularURL = tempDir.appendingPathComponent("regular.txt")
        let regularText = "Regular file content 常规文件测试"
        try Data(regularText.utf8).write(to: regularURL, options: .atomic)
        let symlinkRegularURL = tempDir.appendingPathComponent("symlink_to_regular.txt")
        try FileManager.default.createSymbolicLink(at: symlinkRegularURL, withDestinationURL: regularURL)
        XCTAssertEqual(PreviewContentReader.readTextContent(from: symlinkRegularURL), regularText)
        XCTAssertEqual(PreviewContentReader.readTextSample(from: symlinkRegularURL), regularText)
    }

    @MainActor
    func testSpreadsheetPreviewLocaleKeysUseSharedTTI18nState() {
        let state = LocalizationState.shared
        let original = state.currentLanguage
        defer { state.setLanguage(original) }

        for key in SpreadsheetPreviewLocaleKey.allCases {
            for lang in [AppLanguage.en, .zhHans, .zhHant] {
                let text = key.fallbackTranslation(for: lang)
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, key.rawKey)
            }
        }

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
        XCTAssertEqual(SpreadsheetPreviewMode.table.localizedTitle, "表格视图")
        XCTAssertEqual(SpreadsheetPreviewMode.source.localizedTitle, "原始源码")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.filterCellsPlaceholder), "筛选单元格...")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.headerRowOne), "表头：第 1 行")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.headerAlphabetical), "表头：A, B, C")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.toggleHeaderHelp), "切换首行作为表头")
        XCTAssertEqual(TTSpreadsheetDelimiter.comma.localizedDisplayName, "逗号 (,)")
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
        XCTAssertEqual(SpreadsheetPageSizeOption.hundred.localizedDisplayName, "100 行/页")
        XCTAssertEqual(SpreadsheetPageSizeOption.all.localizedDisplayName, "全部行（不分页）")
        XCTAssertEqual(SpreadsheetPreviewLocalization.pageSizeMenu("100 行/页"), "每页：100 行/页")
        XCTAssertEqual(SpreadsheetPreviewLocalization.pageIndicatorAccessibility(current: 2, total: 5), "第 2 页，共 5 页")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.emptyTableTitle), "无表格数据")

        state.setLanguage(.en)
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.readOnlyBadge), "Read-Only")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.previewCappedReadOnly), "Preview Capped (Read-Only)")
        XCTAssertEqual(SpreadsheetPreviewLocalization.text(.saveButton), "Save")
        XCTAssertEqual(SpreadsheetPreviewLocalization.saveFailed("Disk full"), "Failed to save: Disk full")
        XCTAssertEqual(SpreadsheetPreviewLocalization.sheetLoadFailed("Sheet2"), "Failed to load sheet: Sheet2")
        XCTAssertEqual(SpreadsheetPreviewMode.table.localizedTitle, "Grid Table")
        XCTAssertEqual(SpreadsheetPreviewMode.source.localizedTitle, "Raw Source")
        XCTAssertEqual(SpreadsheetPreviewLocalization.copySelectedCell("B4"), "Copy Selected Cell (B4)")
        XCTAssertEqual(SpreadsheetPreviewLocalization.filteredRowStatus(filtered: 5, total: 20), "Filtered: 5/20")
        XCTAssertEqual(SpreadsheetPreviewLocalization.rowCount(20), "20 rows")
        XCTAssertEqual(SpreadsheetPreviewLocalization.columnCount(8), "8 cols")
        XCTAssertEqual(SpreadsheetPreviewLocalization.cellCount(160), "160 cells")
        XCTAssertEqual(SpreadsheetPageSizeOption.hundred.localizedDisplayName, "100 rows")
        XCTAssertEqual(SpreadsheetPageSizeOption.all.localizedDisplayName, "All rows (No Pagination)")
    }

    @MainActor
    func testTextMarkdownAndContainerLocaleKeysUseSharedTTI18nState() {
        let state = LocalizationState.shared
        let original = state.currentLanguage
        defer { state.setLanguage(original) }

        for key in TextAndDocumentPreviewLocaleKey.allCases {
            for lang in [AppLanguage.en, .zhHans, .zhHant] {
                let text = key.fallbackTranslation(for: lang)
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, key.rawKey)
            }
        }

        state.setLanguage(.zhHans)
        XCTAssertTrue(CodeTextEditorContainerView.truncationBannerMessage.contains("2 MB"))
        XCTAssertEqual(CodeTextEditorContainerView.truncationBannerMessage, "为保证交互响应，预览已截断至 2 MB。已禁用编辑与原位保存以保护原始文件。")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.text(.plainTextLabel), "纯文本")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.fileSizeAndLines(sizeText: "12 KB", lineCount: 42), "12 KB • 42 行")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.text(.unsavedBadge), "未保存")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.text(.savedBadge), "已保存")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.text(.hideLineNumbersHelp), "隐藏行号")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.text(.showLineNumbersHelp), "显示行号")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.text(.copiedToClipboardHelp), "已复制到剪贴板")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.text(.copySourceCodeHelp), "复制源代码")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.text(.saveButton), "保存")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.saveWithShortcut("⌘S"), "保存 (⌘S)")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.saveChangesHelp("⌘S"), "保存更改到本地文件 (⌘S)")
        XCTAssertEqual(MarkdownRichPreviewView(initialMarkdown: "# Title").fileName, "Markdown 文档")
        XCTAssertEqual(MarkdownPreviewMode.rich.localizedTitle, "富文本预览")
        XCTAssertEqual(MarkdownPreviewMode.source.localizedTitle, "源代码")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.lineCount(10), "10 行")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.wordCount(88), "88 词")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.charCount(360), "360 字符")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.text(.copyCodeButton), "复制")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.text(.copiedCodeButton), "已复制")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.localizedUnsupportedMessage("Loading..."), "正在加载…")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.localizedUnsupportedMessage("Select a file from the explorer to preview"), "从文件列表中选择文件以预览")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.text(.toggleFullscreenOrDoubleClickHelp), "切换全屏预览（或双击画布）")

        state.setLanguage(.zhHant)
        XCTAssertTrue(CodeTextEditorContainerView.truncationBannerMessage.contains("2 MB"))
        XCTAssertEqual(MarkdownPreviewMode.rich.localizedTitle, "富文字預覽")
        XCTAssertEqual(MarkdownPreviewMode.source.localizedTitle, "原始碼")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.charCount(360), "360 字元")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.localizedUnsupportedMessage("Loading..."), "正在載入…")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.localizedUnsupportedMessage("Select a file from the explorer to preview"), "從檔案列表中選擇檔案以預覽")

        state.setLanguage(.en)
        XCTAssertEqual(CodeTextEditorContainerView.truncationBannerMessage, "Preview truncated to 2 MB for interactive responsiveness. Editing and in-place saving are disabled to protect the original file.")
        XCTAssertEqual(MarkdownPreviewMode.rich.localizedTitle, "Rich Preview")
        XCTAssertEqual(MarkdownPreviewMode.source.localizedTitle, "Source Code")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.fileSizeAndLines(sizeText: "12 KB", lineCount: 42), "12 KB • 42 lines")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.lineCount(10), "10 lines")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.wordCount(88), "88 words")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.charCount(360), "360 chars")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.localizedUnsupportedMessage("Loading..."), "Loading...")
        XCTAssertEqual(TextAndDocumentPreviewLocalization.localizedUnsupportedMessage("Select a file from the explorer to preview"), "Select a file from the explorer to preview")
    }

    // MARK: - Helpers

    private func makeSyntheticPDFData(pageCount: Int, label: String) throws -> Data {
        let pdf = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                let text = "\(label)-\(index + 1)" as NSString
                text.draw(at: NSPoint(x: 20, y: 90), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
                return true
            }
            let page = try XCTUnwrap(PDFPage(image: image))
            pdf.insert(page, at: index)
        }
        return try XCTUnwrap(pdf.dataRepresentation())
    }

    private func padPDFData(_ data: inout Data, toByteCount targetCount: Int) {
        guard data.count < targetCount else { return }
        let needed = targetCount - data.count
        var comment = Data("\n%".utf8)
        if needed > 3 {
            comment.append(Data(repeating: UInt8(ascii: "P"), count: needed - 3))
        }
        comment.append(UInt8(ascii: "\n"))
        data.append(comment.prefix(needed))
    }
}
