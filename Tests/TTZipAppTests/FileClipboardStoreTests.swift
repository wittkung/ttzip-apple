// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class FileClipboardStoreTests: XCTestCase {
    
    @MainActor
    func testFileClipboardStore() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "ClipboardStore")
        let tempDirPath = tempDirURL.path
        XCTAssertFalse(tempDirPath.isEmpty)
        
        let store = FileClipboardStore.shared
        let file1 = tempDirURL.appendingPathComponent("clip_1.txt")
        try "Clip 1".write(to: file1, atomically: true, encoding: .utf8)
        
        store.copy(urls: [file1])
        XCTAssertTrue(store.canPaste)
        XCTAssertFalse(store.isCutOperation)
        
        let pasteTargetDir = tempDirURL.appendingPathComponent("pasted_target")
        try FileManager.default.createDirectory(at: pasteTargetDir, withIntermediateDirectories: true)
        
        await store.paste(to: pasteTargetDir).value
        let pastedFile = pasteTargetDir.appendingPathComponent("clip_1.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pastedFile.path))
    }
}
