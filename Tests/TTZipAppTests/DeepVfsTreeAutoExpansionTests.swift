// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

@MainActor
final class DeepVfsTreeAutoExpansionTests: XCTestCase {
    func testFindAncestorChainInDeepHierarchy() throws {
        let entries = [
            ArchiveEntry(path: "src/core/utils/math.swift", uncompressedSize: 500, isDirectory: false),
            ArchiveEntry(path: "src/core/facade.swift", uncompressedSize: 1200, isDirectory: false),
            ArchiveEntry(path: "README.md", uncompressedSize: 100, isDirectory: false)
        ]
        
        let tree = FastArchiveTreeBuilder.buildTree(from: entries)
        
        // Find root node
        let rootChain = NativeArchiveOutlineView.findAncestorChain(for: "README.md", in: tree)
        XCTAssertNotNil(rootChain)
        XCTAssertEqual(rootChain?.count, 1)
        XCTAssertEqual(rootChain?.first?.name, "README.md")
        
        // Find deep leaf node
        let deepChain = NativeArchiveOutlineView.findAncestorChain(for: "src/core/utils/math.swift", in: tree)
        XCTAssertNotNil(deepChain)
        XCTAssertEqual(deepChain?.count, 4)
        XCTAssertEqual(deepChain?[0].name, "src")
        XCTAssertEqual(deepChain?[1].name, "core")
        XCTAssertEqual(deepChain?[2].name, "utils")
        XCTAssertEqual(deepChain?[3].name, "math.swift")
        
        // Find non-existent node
        let missingChain = NativeArchiveOutlineView.findAncestorChain(for: "non/existent/path.txt", in: tree)
        XCTAssertNil(missingChain)
    }
}
