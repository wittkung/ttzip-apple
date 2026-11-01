// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class ArchiveInspectorViewTests: XCTestCase {
    
    @MainActor
    func testArchiveInspectorViewModelInitialState() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "ArchiveInspector")
        _ = tempDir
        let vm = ArchiveInspectorViewModel()
        XCTAssertFalse(vm.state.isScanning)
        XCTAssertEqual(vm.state.filePath, "")
        XCTAssertNil(vm.state.detectedFormat)
    }
    
    @MainActor
    func testArchiveInspectorViewModelOnRealZipArchive() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "ArchiveInspector")
        await ArchiveDiagnosticsCache.shared.clear()
        defer {
            Task { await ArchiveDiagnosticsCache.shared.clear() }
        }
        let zipURL = tempDir.appendingPathComponent("sample.zip")
        let docURL = tempDir.appendingPathComponent("hello.txt")
        try "Hello TTZip Diagnostic Inspector".write(to: docURL, atomically: true, encoding: .utf8)
        
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [docURL.path]
        )
        
        let vm = ArchiveInspectorViewModel()
        let state = await vm.inspectArchiveAsync(atPath: zipURL.path)
        
        XCTAssertEqual(state.detectedFormat, .zip)
        XCTAssertEqual(state.fileName, "sample.zip")
        XCTAssertNotNil(state.standardSpec)
        XCTAssertEqual(state.standardSpec?.officialName, "PKWARE ZIP File Format Specification")
        XCTAssertEqual(state.complianceReport?.isCompliant, true)
        XCTAssertGreaterThan(state.scanDurationMs, 0.0)
        XCTAssertNil(state.errorMessage)
    }
    
    @MainActor
    func testArchiveDiagnosticsCacheHit() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "ArchiveInspector")
        await ArchiveDiagnosticsCache.shared.clear()
        defer {
            Task { await ArchiveDiagnosticsCache.shared.clear() }
        }
        let tarURL = tempDir.appendingPathComponent("sample.tar")
        let docURL = tempDir.appendingPathComponent("doc.txt")
        try "Diagnostic Caching Payload".write(to: docURL, atomically: true, encoding: .utf8)
        
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: tarURL.path,
            format: .tar,
            level: .fast,
            inputPaths: [docURL.path]
        )
        
        let vm1 = ArchiveInspectorViewModel()
        let state1 = await vm1.inspectArchiveAsync(atPath: tarURL.path)
        XCTAssertEqual(state1.detectedFormat, .tar)
        
        // Immediate second inspection with new ViewModel should be instant cache hit
        let vm2 = ArchiveInspectorViewModel()
        let state2 = await vm2.inspectArchiveAsync(atPath: tarURL.path)
        
        XCTAssertFalse(state2.isScanning)
        XCTAssertEqual(state2.detectedFormat, .tar)
        XCTAssertEqual(state2.standardSpec?.officialName, "POSIX.1-2001 / IEEE Std 1003.1 ustar/pax Format")
    }
}
