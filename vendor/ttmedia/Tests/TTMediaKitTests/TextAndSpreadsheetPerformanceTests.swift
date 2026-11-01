// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import SwiftUI
import QuartzCore
@testable import TTMediaKit

final class TextAndSpreadsheetPerformanceTests: XCTestCase {

    // MARK: - 1. Bounded RFC 4180 Delimiter Detection with Quoted Multiline Cells

    func testBoundedDelimiterDetectionHandlesQuotedMultilineCellsWithoutScanningFullDocument() {
        var headerAndSample = "\"Metric, Alpha\nSecond Line \"\"Quoted\"\", Still Header\"\t\"Value, Beta\r\nLine 2\"\t\"Notes, Gamma\"\r\n"
        for i in 1...40 {
            headerAndSample += "\"Item \(i), Group A\nSubline \(i)\"\t\(i * 10)\t\"Note, \(i); ok | yes\"\r\n"
        }

        // Append an 8 MB tail full of unquoted commas after the first 41 logical records.
        // An unbounded line-splitting scan would both allocate tens of megabytes and get skewed by the tail.
        let decoyLine = "decoy1,decoy2,decoy3,decoy4,decoy5,decoy6,decoy7,decoy8,decoy9,decoy10\n"
        let tail = String(repeating: decoyLine, count: 120_000)
        let payload = headerAndSample + tail
        XCTAssertGreaterThan(payload.utf8.count, 8 * 1024 * 1024)

        let start = CACurrentMediaTime()
        let detected = TTSpreadsheetParser.detectDelimiter(in: payload)
        let elapsedMs = (CACurrentMediaTime() - start) * 1000.0

        XCTAssertEqual(detected, .tab, "Must ignore commas and newlines inside quotes and detect tab delimiter")
        XCTAssertLessThan(elapsedMs, 15.0, "Bounded delimiter scan must not split or scan the entire 8 MB string")
    }

    // MARK: - 2. Cooperative Mid-Flight Cancellation (< 25 ms)

    func testSpreadsheetParseExitsPromptlyWhenCancelledMidFlight() async throws {
        let rowTemplate = "1001,\"Customer Name, Inc.\",customer@example.com,98765.43,\"Active, Verified\"\n"
        let largeCSV = String(repeating: rowTemplate, count: 160_000)
        XCTAssertGreaterThan(largeCSV.utf8.count, 10 * 1024 * 1024)

        let started = expectation(description: "Parser task started")
        let parseTask = Task.detached(priority: .userInitiated) { () -> [[String]] in
            started.fulfill()
            return TTSpreadsheetParser.parse(text: largeCSV, delimiter: ",")
        }

        await fulfillment(of: [started], timeout: 1.0)
        try await Task.sleep(for: .milliseconds(2))

        let cancelStart = CACurrentMediaTime()
        parseTask.cancel()
        let rows = await parseTask.value
        let cancelElapsedMs = (CACurrentMediaTime() - cancelStart) * 1000.0

        XCTAssertTrue(rows.isEmpty, "Cancelled parse must return empty rows immediately")
        XCTAssertLessThan(cancelElapsedMs, 25.0, "TTSpreadsheetParser.parse cancellation took \(cancelElapsedMs) ms (> 25 ms)")
    }

    func testSyntaxTokenizerStreamExitsPromptlyWhenCancelledMidFlight() async throws {
        let block = """
        public struct SyntaxRecordItem {
            public let identifier: Int = 12345
            public let label: String = " highlight token payload "
            // Comment line inside large source file
            public func computeTotal() -> Int { return identifier * 42 }
        }

        """
        let largeSource = String(repeating: block, count: 50_000)
        XCTAssertGreaterThan(largeSource.utf8.count, 10 * 1024 * 1024)

        let firstBatchReceived = expectation(description: "Received priority batch")
        let consumerTask = Task.detached(priority: .userInitiated) { () -> Int in
            let stream = await BackgroundSyntaxTokenizer.shared.tokenizeStream(
                text: largeSource,
                ext: "swift",
                priorityRange: NSRange(location: 0, length: 2048),
                batchSize: 500
            )
            var count = 0
            for await batch in stream {
                count += batch.spans.count
                if count == batch.spans.count {
                    firstBatchReceived.fulfill()
                }
            }
            return count
        }

        await fulfillment(of: [firstBatchReceived], timeout: 1.0)

        let cancelStart = CACurrentMediaTime()
        consumerTask.cancel()
        _ = await consumerTask.value
        let cancelElapsedMs = (CACurrentMediaTime() - cancelStart) * 1000.0

        XCTAssertLessThan(cancelElapsedMs, 25.0, "BackgroundSyntaxTokenizer.tokenizeStream cancellation took \(cancelElapsedMs) ms (> 25 ms)")
    }

    // MARK: - 3. First-Screen Priority Viewport Batch Yielded Before Full Tokenization

    private final class ControllableSyntaxBackend: SyntaxTokenizingBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedMaxLengths: [Int] = []
        private let priorityPassGate = DispatchSemaphore(value: 0)
        private let priorityPassEnteredGate = DispatchSemaphore(value: 0)
        private let fullPassGate = DispatchSemaphore(value: 0)
        private let fullPassEnteredGate = DispatchSemaphore(value: 0)
        private let fullPassExitGate = DispatchSemaphore(value: 0)
        private let isPriorityPassGated: Bool
        private let isFullPassGated: Bool
        private var priorityPassCancelled: Bool = false
        private var fullPassCancelled: Bool = false
        private var fullPassFinished: Bool = false

        init(gatePriorityPass: Bool = false, gateFullPass: Bool = false) {
            self.isPriorityPassGated = gatePriorityPass
            self.isFullPassGated = gateFullPass
        }

        func tokenize(text: String, fileExtension: String, maxLength: Int) -> [TokenSpan] {
            lock.lock()
            recordedMaxLengths.append(maxLength)
            let isFullPass = maxLength > 16_384
            let shouldGatePriority = !isFullPass && isPriorityPassGated
            let shouldGateFull = isFullPass && isFullPassGated
            lock.unlock()

            if !isFullPass {
                priorityPassEnteredGate.signal()
                if shouldGatePriority {
                    _ = priorityPassGate.wait(timeout: .now() + 5.0)
                    if Task.isCancelled {
                        lock.lock()
                        priorityPassCancelled = true
                        lock.unlock()
                        return []
                    }
                }
            } else {
                fullPassEnteredGate.signal()
                if shouldGateFull {
                    _ = fullPassGate.wait(timeout: .now() + 5.0)
                    if Task.isCancelled {
                        lock.lock()
                        fullPassCancelled = true
                        lock.unlock()
                        fullPassExitGate.signal()
                        return []
                    }
                }
            }

            lock.lock()
            if isFullPass {
                fullPassFinished = true
            }
            lock.unlock()

            if isFullPass {
                fullPassExitGate.signal()
            }

            return [
                TokenSpan(range: NSRange(location: 0, length: 6), colorType: .keyword),
                TokenSpan(range: NSRange(location: min(max(64, maxLength - 10), text.utf16.count - 4), length: 4), colorType: .type)
            ]
        }

        func awaitPriorityPassEntered(timeoutSeconds: Double = 2.0) -> Bool {
            let res = priorityPassEnteredGate.wait(timeout: .now() + timeoutSeconds)
            return res == .success
        }

        func unblockPriorityPass() {
            priorityPassGate.signal()
        }

        func awaitFullPassEntered(timeoutSeconds: Double = 2.0) -> Bool {
            let res = fullPassEnteredGate.wait(timeout: .now() + timeoutSeconds)
            return res == .success
        }

        func unblockFullPass() {
            fullPassGate.signal()
        }

        func awaitFullPassExit(timeoutSeconds: Double = 2.0) -> Bool {
            let res = fullPassExitGate.wait(timeout: .now() + timeoutSeconds)
            return res == .success
        }

        func snapshotMaxLengths() -> [Int] {
            lock.lock()
            defer { lock.unlock() }
            return recordedMaxLengths
        }

        func isFullPassComplete() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return fullPassFinished
        }

        func wasFullPassCancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return fullPassCancelled
        }

        func wasPriorityPassCancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return priorityPassCancelled
        }
    }

    func testTokenizeStreamYieldsPriorityViewportBeforeFullDocumentLexing() async {
        let backend = ControllableSyntaxBackend(gatePriorityPass: false, gateFullPass: true)
        let tokenizer = BackgroundSyntaxTokenizer(backend: backend)
        let largeText = String(repeating: "import Foundation\nstruct Demo {}\n", count: 40_000)
        let priorityRange = NSRange(location: 0, length: 512)

        let stream = await tokenizer.tokenizeStream(
            text: largeText,
            ext: "swift",
            priorityRange: priorityRange,
            batchSize: 100
        )

        var sawPriorityBatch = false
        var fullPassCompletedBeforePriorityBatch = true
        var receivedBatches: [TokenSpanBatch] = []

        for await batch in stream {
            receivedBatches.append(batch)
            if batch.batchIndex == 0 {
                sawPriorityBatch = batch.isPriorityViewport
                fullPassCompletedBeforePriorityBatch = backend.isFullPassComplete()
                backend.unblockFullPass()
            }
        }

        XCTAssertTrue(sawPriorityBatch, "First yielded batch must be marked isPriorityViewport")
        XCTAssertFalse(fullPassCompletedBeforePriorityBatch, "Priority batch must be yielded before full-document tokenization completes")
        XCTAssertGreaterThan(receivedBatches.count, 1, "Remaining batches must be yielded after unblocking full pass")
        XCTAssertTrue(backend.awaitFullPassExit(), "Full pass must complete and signal exit")
        XCTAssertTrue(backend.isFullPassComplete(), "Full pass must be marked complete")
        let lengths = backend.snapshotMaxLengths()
        XCTAssertEqual(lengths.first, 16_384, "Priority pass must only lex the bounded prefix (16,384 UTF-16 units)")
        XCTAssertEqual(lengths.last, min(largeText.utf16.count, BackgroundSyntaxTokenizer.maxSyntaxHighlightUTF16Length))
    }

    func testTokenizeStreamNaturalPipelinedSchedulePreservesBatchOrderingAndPrefixBound() async {
        let backend = ControllableSyntaxBackend(gatePriorityPass: false, gateFullPass: false)
        let tokenizer = BackgroundSyntaxTokenizer(backend: backend)
        let largeText = String(repeating: "import Foundation\nstruct Demo {}\n", count: 40_000)
        let priorityRange = NSRange(location: 0, length: 512)

        let stream = await tokenizer.tokenizeStream(
            text: largeText,
            ext: "swift",
            priorityRange: priorityRange,
            batchSize: 100
        )

        var firstBatchSeen = false
        var firstBatchIsPriority = false
        var subsequentBatchesAreNonPriority = true
        var totalBatches = 0

        for await batch in stream {
            totalBatches += 1
            if !firstBatchSeen {
                firstBatchSeen = true
                firstBatchIsPriority = batch.isPriorityViewport && batch.batchIndex == 0
            } else {
                if batch.isPriorityViewport || batch.batchIndex == 0 {
                    subsequentBatchesAreNonPriority = false
                }
            }
        }

        XCTAssertTrue(firstBatchSeen, "Stream must yield at least one batch")
        XCTAssertTrue(firstBatchIsPriority, "Batch 0 must be marked isPriorityViewport")
        XCTAssertTrue(subsequentBatchesAreNonPriority, "Subsequent batches must not be marked isPriorityViewport")
        XCTAssertGreaterThan(totalBatches, 1, "Must yield priority batch plus remaining batches")
        let lengths = backend.snapshotMaxLengths()
        XCTAssertEqual(lengths.count, 2, "Must execute bounded priority pass followed by full document pass")
        XCTAssertEqual(lengths.first, 16_384, "First pass must be bounded to 16,384 UTF-16 code units")
        XCTAssertEqual(lengths.last, min(largeText.utf16.count, BackgroundSyntaxTokenizer.maxSyntaxHighlightUTF16Length))
    }

    func testTokenizeStreamCancellationBeforeFullPassBypassesFullLexing() async {
        let backend = ControllableSyntaxBackend(gatePriorityPass: true, gateFullPass: false)
        let tokenizer = BackgroundSyntaxTokenizer(backend: backend)
        let largeText = String(repeating: "import Foundation\nstruct Demo {}\n", count: 40_000)
        let priorityRange = NSRange(location: 0, length: 512)

        let consumerTask = Task.detached(priority: .userInitiated) { () -> Void in
            let stream = await tokenizer.tokenizeStream(
                text: largeText,
                ext: "swift",
                priorityRange: priorityRange,
                batchSize: 100
            )
            for await _ in stream {
                break
            }
        }

        // Synchronize on priority pass entered event
        XCTAssertTrue(backend.awaitPriorityPassEntered(), "Priority pass must be entered")

        // Cancel the consumer task while producer is still in priority pass
        consumerTask.cancel()

        // Unblock priority pass so worker reaches pre-full-pass cancellation check
        backend.unblockPriorityPass()

        await consumerTask.value

        // Assert lifecycle: full-document pass was never invoked
        let lengths = backend.snapshotMaxLengths()
        XCTAssertEqual(lengths.count, 1, "Full document pass must be bypassed completely when cancelled before full pass begins")
        XCTAssertEqual(lengths.first, 16_384, "Only the bounded priority pass should have run")
        XCTAssertFalse(backend.isFullPassComplete(), "Full document pass must never complete")
    }

    func testTokenizeStreamCancellationDuringInFlightFullPassAbortsPromptly() async {
        let backend = ControllableSyntaxBackend(gatePriorityPass: false, gateFullPass: true)
        let tokenizer = BackgroundSyntaxTokenizer(backend: backend)
        let largeText = String(repeating: "import Foundation\nstruct Demo {}\n", count: 40_000)
        let priorityRange = NSRange(location: 0, length: 512)

        let firstBatchSeen = expectation(description: "First batch received by consumer")
        let consumerTask = Task.detached(priority: .userInitiated) { () -> Void in
            let stream = await tokenizer.tokenizeStream(
                text: largeText,
                ext: "swift",
                priorityRange: priorityRange,
                batchSize: 100
            )
            for await batch in stream {
                if batch.batchIndex == 0 {
                    firstBatchSeen.fulfill()
                    // Keep stream active so worker can proceed to full-document pass
                }
            }
        }

        await fulfillment(of: [firstBatchSeen], timeout: 2.0)

        // Synchronize on full pass entered event (guarantees full pass is actively in-flight)
        XCTAssertTrue(backend.awaitFullPassEntered(), "Worker must have entered full-document pass")

        // Cancel consumer task and unblock gate to test in-flight cooperative abort
        consumerTask.cancel()

        backend.unblockFullPass()

        await consumerTask.value

        // Assert lifecycle: full pass was in-flight, aborted on cancellation, and never completed
        XCTAssertTrue(backend.awaitFullPassExit(), "In-flight full pass must exit promptly upon cancellation")
        XCTAssertTrue(backend.wasFullPassCancelled(), "Full pass must observe Task.isCancelled and abort")
        XCTAssertFalse(backend.isFullPassComplete(), "Full document pass must not complete when cancelled in-flight")
        XCTAssertEqual(backend.snapshotMaxLengths().count, 2, "Both priority pass and full pass were entered")
    }

    // MARK: - 4. Large Text (> 2 MB) & Truncated Spreadsheet Save Protection

    @MainActor
    func testLargeTextPreviewTruncatesSafelyAndBlocksInPlaceSave() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaLargeTextGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Place multi-byte UTF-8 characters across the 2 MB boundary to verify safe scalar truncation.
        let prefixChunk = String(repeating: "let value = 1234567890 // 中文🚀\n", count: 65_000)
        XCTAssertGreaterThan(prefixChunk.utf8.count, CodeSyntaxPreviewView.maxInteractiveTextUTF8Bytes)

        let fileURL = tempDir.appendingPathComponent("huge_file.swift")
        try prefixChunk.write(to: fileURL, atomically: true, encoding: .utf8)
        let originalDiskBytes = try Data(contentsOf: fileURL)

        let preview = CodeSyntaxPreviewView(
            content: prefixChunk,
            fileURL: fileURL,
            fileName: "huge_file.swift"
        )

        XCTAssertTrue(preview.isTruncatedForPreview, "Files > 2 MB must be marked as truncated for preview")
        XCTAssertLessThanOrEqual(preview.previewDisplayText.utf8.count, CodeSyntaxPreviewView.maxInteractiveTextUTF8Bytes)
        XCTAssertFalse(preview.canSaveInPlace, "Truncated text preview must block in-place saving")
        XCTAssertFalse(preview.isEditorEditable, "Truncated text preview must force read-only mode")
        XCTAssertFalse(preview.saveFile(), "saveFile() must return false when truncated")
        XCTAssertFalse(preview.saveFile(contentOverride: "// Overwritten\n"), "saveFile(contentOverride:) must be blocked when truncated")
        XCTAssertEqual(try Data(contentsOf: fileURL), originalDiskBytes, "Original file on disk must remain untouched")

        let nsEditor = CodeHighlightingEditorNSView(
            text: .constant(prefixChunk),
            fileName: "huge_file.swift",
            isEditable: true
        )
        XCTAssertTrue(nsEditor.isTruncatedForPreview)
        XCTAssertFalse(nsEditor.effectiveIsEditable)
    }

    @MainActor
    func testTruncatedSpreadsheetSurfacesTruncationAndBlocksInPlaceSave() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaLargeCSVGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rowLimit = SpreadsheetTablePreviewView.maxPreviewRows
        let overBudgetCSV = String(repeating: "1,2\n", count: rowLimit + 10)
        let csvURL = tempDir.appendingPathComponent("large_dataset.csv")
        try overBudgetCSV.write(to: csvURL, atomically: true, encoding: .utf8)
        let originalCSVBytes = try Data(contentsOf: csvURL)

        let prefixParsed = TTSpreadsheetParser.parsePrefix(
            text: overBudgetCSV,
            delimiter: ",",
            maxRows: rowLimit
        )
        XCTAssertEqual(prefixParsed.rows.count, rowLimit)
        XCTAssertTrue(prefixParsed.isTruncated)

        let tableView = SpreadsheetTablePreviewView(
            initialContent: overBudgetCSV,
            fileURL: csvURL,
            fileName: "large_dataset.csv"
        )
        XCTAssertTrue(tableView.isPreviewTruncated, "Spreadsheet exceeding 50,000 rows must flag isPreviewTruncated")
        XCTAssertFalse(tableView.canSaveInPlace, "Truncated spreadsheet must disallow in-place save")
        XCTAssertFalse(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: csvURL,
                fileName: "large_dataset.csv",
                isPreviewTruncated: true
            )
        )
        XCTAssertFalse(tableView.saveFile())
        XCTAssertFalse(tableView.saveFile(contentOverride: "corrupted,data\n"))
        XCTAssertEqual(try Data(contentsOf: csvURL), originalCSVBytes, "Original CSV file on disk must never be overwritten by truncated preview")
    }

    // MARK: - 5. Cross-Chunk Boundary State Preservation (Block Comments, Strings, Line Comments)

    func testCrossChunkMultilineBlockCommentAndStringEquivalenceWithSinglePass() async {
        let codeUnit = "public func computeValue(_ input: Int) -> Int { let result = input + 42; return result }\n"
        // ~15,800 UTF-16 units before the 16,384 priority prefix boundary
        let beforePriorityBoundary = String(repeating: codeUnit, count: 178)
        let straddlingBlockComment = """
        /* Multiline block comment straddling 16,384 priority boundary
        \(String(repeating: "let x = 42; return \"fake\" // inside block comment\n", count: 40))
        struct ShouldStayComment { let bogus = 999 }
        */
        """
        // Advance toward ~146,000 UTF-16 units (just before the 16,384 + 131,072 chunk boundary)
        let middleSection = String(repeating: codeUnit, count: 1440)
        let straddlingStringAndBlockAt128K = """
        let straddlingString = "start of string before 128KB boundary \\"escaped\\" \(String(repeating: "func foo() { return 123 } \\\"quote\\\" ", count: 90)) end of string"
        /* Block comment straddling second chunk boundary
        \(String(repeating: "class FakeType { var number = 777 }\n", count: 60))
        */
        """
        let tailSection = String(repeating: codeUnit, count: 100)
        let fullDocument = beforePriorityBoundary + straddlingBlockComment + middleSection + straddlingStringAndBlockAt128K + tailSection

        await assertStreamingMatchesSinglePassLexer(
            text: fullDocument,
            ext: "swift",
            priorityRange: NSRange(location: 0, length: 4096)
        )
    }

    func testCrossChunkLineCommentAndEscapedStringStraddlingBoundariesEquivalence() async {
        let codeUnit = "let alpha: Int = 100\n"
        // Position right before 16,384 UTF-16 units
        let prefix = String(repeating: codeUnit, count: 775)
        // A >2,500-char line comment without newline until the end, forcing advanceNewlineAligned to split inside it
        let longLineComment = "// " + String(repeating: "class Bar { let z = 100; return \"not_a_string\" } ", count: 55) + "\n"
        // A >3,000-char string literal with escaped quotes straddling the next boundary
        let preStringPad = String(repeating: codeUnit, count: 760)
        let longStringLiteral = "let message = \"" + String(repeating: "func foo() { return 123 } \\\"escaped\\\" ", count: 85) + "\"\n"
        // Pad out to straddle the 128 KB streamChunkUTF16Length boundary with another long string
        let midPad = String(repeating: codeUnit, count: 5200)
        let boundaryString128K = "let payload = \"" + String(repeating: "struct Widget { let count = 456 } \\\"inner\\\" ", count: 80) + "\"\n"
        let fullDocument = prefix + longLineComment + preStringPad + longStringLiteral + midPad + boundaryString128K + prefix

        await assertStreamingMatchesSinglePassLexer(
            text: fullDocument,
            ext: "swift",
            priorityRange: NSRange(location: 0, length: 2048)
        )
    }

    private func assertStreamingMatchesSinglePassLexer(
        text: String,
        ext: String,
        priorityRange: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let totalUTF16 = text.utf16.count
        let expectedSpans = BackgroundSyntaxTokenizer.defaultLexer(text: text, ext: ext, maxLength: 0)

        var streamedSpans: [TokenSpan] = []
        let stream = await BackgroundSyntaxTokenizer.shared.tokenizeStream(
            text: text,
            ext: ext,
            priorityRange: priorityRange,
            batchSize: 512
        )
        for await batch in stream {
            streamedSpans.append(contentsOf: batch.spans)
        }

        var expectedCategories = [ColorCategory?](repeating: nil, count: totalUTF16)
        for span in expectedSpans {
            let end = min(totalUTF16, span.range.location + span.range.length)
            for idx in max(0, span.range.location)..<end {
                expectedCategories[idx] = span.colorType
            }
        }

        var actualCategories = [ColorCategory?](repeating: nil, count: totalUTF16)
        for span in streamedSpans {
            let end = min(totalUTF16, span.range.location + span.range.length)
            for idx in max(0, span.range.location)..<end {
                actualCategories[idx] = span.colorType
            }
        }

        if expectedCategories != actualCategories {
            let firstMismatch = zip(expectedCategories.indices, zip(expectedCategories, actualCategories))
                .first { $0.1.0 != $0.1.1 }
            if let (offset, (exp, act)) = firstMismatch {
                XCTFail(
                    "TokenCategory mismatch at UTF-16 offset \(offset): expected \(String(describing: exp)), got \(String(describing: act))",
                    file: file,
                    line: line
                )
            }
        }
    }

    // MARK: - 6. Bounded First-Screen Mount (64 KB) + Scroll, Search, Copy & Truncation Banner

    @MainActor
    func testLargeTextBoundedFirstScreenMountScrollSearchCopyAndTruncationBanner() throws {
        let line64B = "public let itemValue: Int = 1234567890 // padded 64B line item!\n"
        XCTAssertEqual(line64B.utf8.count, 64)

        // ~512 KB before the search needle, plus ~3 MB after -> ~3.5 MB total (> 2 MB truncation budget)
        let beforeNeedle = String(repeating: line64B, count: 8_000)
        let needleLine = "public let marker = \"NEEDLE_AT_500KB_MARKER\" // searchable target\n"
        let afterNeedle = String(repeating: line64B, count: 48_000)
        let hugeDocument = beforeNeedle + needleLine + afterNeedle
        XCTAssertGreaterThan(hugeDocument.utf8.count, 3 * 1024 * 1024)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )

        let mountStart = CACurrentMediaTime()
        let container = CodeTextEditorContainerView(
            initialText: hugeDocument,
            fileURL: nil,
            fileName: "large_module.swift"
        )
        let hostingView = NSHostingView(rootView: container)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        let mountElapsedMs = (CACurrentMediaTime() - mountStart) * 1000.0

        let maybeTextView = findLargeTextEditorTextView(in: hostingView)
        let textView = try XCTUnwrap(maybeTextView, "Must mount LargeTextEditorTextView inside hosting hierarchy")

        // 1. Bounded first-screen mount (64 KB) & main-thread budget (< 50 ms)
        XCTAssertEqual(textView.mountedUTF8ByteCount, CodeHighlightingEditorNSView.initialMountUTF8Bytes)
        XCTAssertTrue(textView.isPartiallyMountedForViewport)
        XCTAssertLessThan(mountElapsedMs, 50.0, "Bounded 64 KB first-screen mount took \(mountElapsedMs) ms")

        // 2. Scroll-driven chunk expansion (+128 KB -> 192 KB)
        let didLoadChunk = textView.loadNextPreviewChunk()
        XCTAssertTrue(didLoadChunk)
        XCTAssertEqual(
            textView.mountedUTF8ByteCount,
            CodeHighlightingEditorNSView.initialMountUTF8Bytes + CodeHighlightingEditorNSView.chunkStepUTF8Bytes
        )

        // 3. Search across unmounted chunks (~512 KB offset)
        XCTAssertFalse(textView.string.contains("NEEDLE_AT_500KB_MARKER"), "Needle at 512 KB must not be mounted before search")
        let matchRange = try XCTUnwrap(textView.searchInPreview("NEEDLE_AT_500KB_MARKER"))
        XCTAssertGreaterThanOrEqual(textView.mountedUTF8ByteCount, 512 * 1024)
        XCTAssertEqual(textView.selectedRange(), matchRange)
        XCTAssertEqual((textView.string as NSString).substring(with: matchRange), "NEEDLE_AT_500KB_MARKER")

        // 4. Copy verification (both selection copy in NSTextView and full 2 MB preview copy in container)
        textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "NEEDLE_AT_500KB_MARKER")

        let customBoard = NSPasteboard.withUniqueName()
        let copiedFullPreview = container.copyPreviewToPasteboard(customBoard)
        XCTAssertEqual(copiedFullPreview.utf8.count, CodeTextEditorContainerView.maxInteractiveTextUTF8Bytes)
        XCTAssertEqual(customBoard.string(forType: .string), container.previewDisplayText)

        // 5. Truncation prompt & write-safety verification
        XCTAssertTrue(container.isTruncatedForPreview)
        XCTAssertFalse(container.canSaveInPlace)
        XCTAssertFalse(container.saveFile())
        XCTAssertTrue(CodeTextEditorContainerView.truncationBannerMessage.contains("2 MB"))
    }

    @MainActor
    private func findLargeTextEditorTextView(in root: NSView) -> LargeTextEditorTextView? {
        if let match = root as? LargeTextEditorTextView {
            return match
        }
        for subview in root.subviews {
            if let found = findLargeTextEditorTextView(in: subview) {
                return found
            }
        }
        return nil
    }
}
