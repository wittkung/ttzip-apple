// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class CompressionLevelDualModeSelectorTests: XCTestCase {
    
    func testFormatValidRangeDefinitions() {
        XCTAssertEqual(ArchiveCompressionFormat.zip.minCompressionLevel, 0)
        XCTAssertEqual(ArchiveCompressionFormat.zip.maxCompressionLevel, 12)
        
        XCTAssertEqual(ArchiveCompressionFormat.tarZst.maxCompressionLevel, 22)
        XCTAssertEqual(ArchiveCompressionFormat.sevenZip.maxCompressionLevel, 9)
        XCTAssertEqual(ArchiveCompressionFormat.tar.maxCompressionLevel, 0)
    }
    
    func testLevelClampingBehaviorAcrossFormats() {
        // ZIP: 0...12
        let highZipLevel = ArchiveCompressionLevel(levelInt: 15)
        let clampedZip = max(ArchiveCompressionFormat.zip.minCompressionLevel, min(ArchiveCompressionFormat.zip.maxCompressionLevel, highZipLevel.rawValue))
        XCTAssertEqual(clampedZip, 12)
        
        // ZSTD: 0...22
        let highZstdLevel = ArchiveCompressionLevel(levelInt: 22)
        let clampedZstd = max(ArchiveCompressionFormat.tarZst.minCompressionLevel, min(ArchiveCompressionFormat.tarZst.maxCompressionLevel, highZstdLevel.rawValue))
        XCTAssertEqual(clampedZstd, 22)
        
        // TAR: 0...0
        let clampedTar = max(ArchiveCompressionFormat.tar.minCompressionLevel, min(ArchiveCompressionFormat.tar.maxCompressionLevel, highZstdLevel.rawValue))
        XCTAssertEqual(clampedTar, 0)
    }
    
    func testDualModeViewInstantiation() {
        var level = ArchiveCompressionLevel.normal
        let binding = Binding<ArchiveCompressionLevel>(
            get: { level },
            set: { level = $0 }
        )
        
        let selector = CompressionLevelDualModeSelector(
            compressionLevel: binding,
            format: .zip
        )
        
        XCTAssertNotNil(selector)
    }
}
