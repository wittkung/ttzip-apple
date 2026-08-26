// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
@testable import TTZipApp
import TTZipCore

final class FrontendArchitectureEvolutionTests: XCTestCase {
    
    // MARK: - 1. Observable Granularity & State Tests
    
    @MainActor
    func testAppSubStatesObservableGranularity() {
        let appState = AppViewState(fileViewer: NoOpFileViewer())
        XCTAssertEqual(appState.activeTab, .home)
        XCTAssertEqual(appState.isLoading, false)
        XCTAssertEqual(appState.progressValue, 0.0)
        
        appState.taskState.progressValue = 0.75
        XCTAssertEqual(appState.progressValue, 0.75)
        
        appState.navigationState.activeTab = .compressWorkspace
        XCTAssertEqual(appState.activeTab, .compressWorkspace)
    }
    
    @MainActor
    func testCompressFormSessionEncapsulation() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let f1 = tempDir.appendingPathComponent("test1.txt")
        let f2 = tempDir.appendingPathComponent("test2.txt")
        try? "test1".write(to: f1, atomically: true, encoding: .utf8)
        try? "test2".write(to: f2, atomically: true, encoding: .utf8)
        
        let session = CompressFormSession(initialInputPaths: [f1.path, f2.path])
        XCTAssertEqual(session.itemsList.count, 2)
        XCTAssertEqual(session.selectedFormat, .sevenZip)
        XCTAssertEqual(session.compressionLevel, .normal)
        XCTAssertEqual(session.isProcessing, false)
        
        session.customVolumeValueString = "500"
        session.customVolumeUnit = "MB"
        session.calculateCustomVolume()
        XCTAssertEqual(session.splitVolumeOption, 500 * 1024 * 1024)
    }
    
    // MARK: - 2. Non-Blocking I/O Scanner Tests
    
    func testDiskDirectoryScannerActorBatch() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        for i in 0..<10 {
            let file = tempDir.appendingPathComponent("file_\(i).txt")
            try? "content_\(i)".write(to: file, atomically: true, encoding: .utf8)
        }
        
        let items = await DiskDirectoryScannerActor.shared.scanDirectory(at: tempDir)
        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(items.first?.isDirectory, false)
    }
    
    // MARK: - 3. Syntax Highlighting & Tokenizer Tests
    
    func testPrecompiledSyntaxEngineAndTokenizer() async {
        let rules = PrecompiledSyntaxEngine.shared.rules(for: "swift")
        XCTAssertNotNil(rules)
        XCTAssertNotNil(rules?.keywordRegex)
        XCTAssertNotNil(rules?.stringRegex)
        
        let code = "import SwiftUI\nlet greeting = \"Hello\"\n// A comment\nlet count = 42"
        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        let tokens = await BackgroundSyntaxTokenizer.shared.tokenize(text: code, ext: "swift", targetRange: fullRange)
        
        XCTAssertFalse(tokens.isEmpty)
        let hasComment = tokens.contains { $0.colorType == .comment }
        let hasString = tokens.contains { $0.colorType == .string }
        let hasKeyword = tokens.contains { $0.colorType == .keyword }
        let hasNumber = tokens.contains { $0.colorType == .number }
        
        XCTAssertTrue(hasComment)
        XCTAssertTrue(hasString)
        XCTAssertTrue(hasKeyword)
        XCTAssertTrue(hasNumber)
    }
    
    // MARK: - 4. Thumbnail Service Tests
    
    func testImageIOThumbnailServiceLifecycle() async {
        let service = ImageIOThumbnailService(countLimit: 10, totalCostLimitMB: 4)
        await service.purgeCache()
        
        // Purging and non-existent files return nil cleanly
        let dummyURL = URL(fileURLWithPath: "/tmp/non_existent_image.png")
        let thumb = await service.getThumbnail(for: dummyURL)
        XCTAssertNil(thumb)
    }
}
