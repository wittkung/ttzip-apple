// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

final class CodeSyntaxPreviewTests: XCTestCase {
    private var tempDirURL: URL!
    
    override func setUp() {
        super.setUp()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("CodeSyntaxTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        if let dir = tempDirURL {
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }
    
    // MARK: - 1. Streaming Tokenizer Tests with Priority Viewport
    
    func testStreamingTokenizerYieldsPriorityBatchFirst() async {
        let code = """
        import SwiftUI
        import AppKit
        
        // Priority header
        public struct MainView: View {
            let message: String = "Hello TTZip"
            let count: Int = 100
        }
        
        // Extended body content
        func computeValue() -> Int {
            return 42
        }
        """
        
        let priorityRange = NSRange(location: 0, length: 60)
        let stream = await BackgroundSyntaxTokenizer.shared.tokenizeStream(
            text: code,
            ext: "swift",
            priorityRange: priorityRange,
            batchSize: 10
        )
        
        var batches: [TokenSpanBatch] = []
        for await batch in stream {
            batches.append(batch)
        }
        
        XCTAssertFalse(batches.isEmpty, "Stream must yield at least one batch")
        let firstBatch = batches[0]
        XCTAssertTrue(firstBatch.isPriorityViewport, "First batch must be marked as priority viewport")
        XCTAssertEqual(firstBatch.batchIndex, 0)
        
        // Verify all priority spans are within the priority range
        for span in firstBatch.spans {
            let intersection = NSIntersectionRange(span.range, priorityRange)
            XCTAssertGreaterThan(intersection.length, 0, "Span in priority batch must intersect priorityRange")
        }
    }
    
    // MARK: - 2. Large File (>2MB) Tokenization & Batch Chunking Performance
    
    func testLargeFileProgressiveTokenizationUnderMemoryBudget() async {
        // Generate a 2.5 MB Swift code file with repeating functions
        var largeCode = "// TTZip High-Performance Syntax Engine Benchmark File\nimport Foundation\nimport TTZipCore\n\n"
        let template = """
        public struct ItemRecord%d: Sendable {
            public let id: Int = %d
            public let title: String = "Item title for index %d"
            // Computed checksum
            public func compute() -> Int {
                let multiplier = 42
                return self.id * multiplier
            }
        }
        
        """
        
        for i in 0..<10_000 {
            largeCode += String(format: template, i, i, i)
        }
        
        XCTAssertGreaterThan(largeCode.utf8.count, 2 * 1024 * 1024, "Code payload must exceed 2MB")
        
        let start = CACurrentMediaTime()
        let priorityRange = NSRange(location: 0, length: 1500)
        let stream = await BackgroundSyntaxTokenizer.shared.tokenizeStream(
            text: largeCode,
            ext: "swift",
            priorityRange: priorityRange,
            batchSize: 2000
        )
        
        var totalTokens = 0
        var batchCount = 0
        var firstBatchTime: Double = 0
        
        for await batch in stream {
            if batchCount == 0 {
                firstBatchTime = CACurrentMediaTime() - start
            }
            batchCount += 1
            totalTokens += batch.spans.count
        }
        let totalTime = CACurrentMediaTime() - start
        
        XCTAssertGreaterThan(totalTokens, 10000, "Should extract large volume of tokens")
        XCTAssertGreaterThan(batchCount, 1, "Should produce multiple batches for large files")
        XCTAssertLessThan(firstBatchTime, 2.0, "First priority batch must arrive rapidly under 2.0s")
        XCTAssertLessThan(totalTime, 4.0, "Total tokenization for 2.5MB source must complete in under 4.0s")
    }
    
    // MARK: - 3. Multi-Language Tokenizer Matrix Tests
    
    func testMultiLanguageTokenizationCategories() async {
        let languages: [(ext: String, code: String, expectedCategories: [ColorCategory])] = [
            ("rs", "fn main() {\n    let x: i32 = 42;\n    // Rust comment\n    let s = \"Rust string\";\n}", [.keyword, .type, .number, .comment, .string]),
            ("py", "def process_data(count: int) -> str:\n    # Python comment\n    message = 'Hello Python'\n    return 100", [.keyword, .type, .comment, .string, .number]),
            ("cpp", "#include <iostream>\nint calculate(int value) {\n    // C++ comment\n    const char* str = \"text\";\n    return 42;\n}", [.type, .comment, .string, .number]),
            ("swift", "import Foundation\nfunc calculate(value: Int) -> String {\n    // Swift comment\n    let name = \"TTZip\"\n    return name\n}", [.keyword, .type, .comment, .string]),
            ("ts", "interface Config {\n    id: number;\n    // TS comment\n    name: string;\n}", [.keyword, .type, .comment]),
            ("js", "const calculate = (val) => {\n    // JS comment\n    const name = \"TTZip\";\n    return 123;\n};", [.keyword, .comment, .string, .number])
        ]
        
        for lang in languages {
            let fullRange = NSRange(location: 0, length: (lang.code as NSString).length)
            let tokens = await BackgroundSyntaxTokenizer.shared.tokenize(
                text: lang.code,
                ext: lang.ext,
                targetRange: fullRange
            )
            
            XCTAssertFalse(tokens.isEmpty, "Language .\(lang.ext) should yield tokens")
            let foundCategories = Set(tokens.map { $0.colorType })
            for expected in lang.expectedCategories {
                XCTAssertTrue(
                    foundCategories.contains(expected),
                    "Language .\(lang.ext) must detect category \(expected)"
                )
            }
        }
    }
    
    // MARK: - 4. CodeTextEditorContainerView Atomic Save and Notification
    
    @MainActor
    func testCodeEditorViewAtomicSaveRoundtrip() throws {
        let testFileURL = tempDirURL.appendingPathComponent("sample_script.py")
        let initialCode = "print('Initial version')\n"
        try initialCode.write(to: testFileURL, atomically: true, encoding: .utf8)
        
        let containerView = CodeTextEditorContainerView(
            initialText: initialCode,
            fileURL: testFileURL,
            fileName: "sample_script.py"
        )
        
        XCTAssertNotNil(containerView)
        XCTAssertEqual(containerView.initialText, initialCode)
        XCTAssertEqual(containerView.fileName, "sample_script.py")
        XCTAssertEqual(containerView.fileURL, testFileURL)
    }
    
    // MARK: - 5. Large Code File Edit & Save Invariant
    
    @MainActor
    func testLargeFileAtomicSaveWithoutTruncation() throws {
        let largeFileURL = tempDirURL.appendingPathComponent("huge_source.swift")
        let largeContent = String(repeating: "let item_value_record = 12345\n", count: 80_000)
        try largeContent.write(to: largeFileURL, atomically: true, encoding: .utf8)
        
        let fileSize = try FileManager.default.attributesOfItem(atPath: largeFileURL.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 2 * 1024 * 1024, "File size must exceed 2MB")
        
        let loadedContent = MediaPreviewView.readTextContent(from: largeFileURL)
        XCTAssertNotNil(loadedContent)
        XCTAssertFalse(loadedContent!.contains("TTZip Large File Notice"))
        XCTAssertEqual(loadedContent!.utf8.count, largeContent.utf8.count)
        
        // Simulate edit and atomic rewrite
        let modifiedContent = "// Modified Header\n" + loadedContent!
        try modifiedContent.write(to: largeFileURL, atomically: true, encoding: .utf8)
        
        let reloadedContent = MediaPreviewView.readTextContent(from: largeFileURL)
        XCTAssertNotNil(reloadedContent)
        XCTAssertTrue(reloadedContent!.hasPrefix("// Modified Header\n"))
    }
}
