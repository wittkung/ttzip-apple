// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import Foundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class ArchiveInspectorViewTests: XCTestCase {
    
    private var tempDir: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ttzip_inspector_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ArchiveDiagnosticsCache.shared.clear()
    }
    
    override func tearDown() async throws {
        if let t = tempDir {
            try? FileManager.default.removeItem(at: t)
        }
        ArchiveDiagnosticsCache.shared.clear()
        try await super.tearDown()
    }
    
    @MainActor
    func testArchiveInspectorViewModelInitialState() {
        let vm = ArchiveInspectorViewModel()
        XCTAssertFalse(vm.state.isScanning)
        XCTAssertEqual(vm.state.filePath, "")
        XCTAssertNil(vm.state.detectedFormat)
    }
    
    @MainActor
    func testArchiveInspectorViewModelOnRealZipArchive() async throws {
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
        vm2.inspectArchive(atPath: tarURL.path)
        
        XCTAssertFalse(vm2.state.isScanning)
        XCTAssertEqual(vm2.state.detectedFormat, .tar)
        XCTAssertEqual(vm2.state.standardSpec?.officialName, "POSIX.1-2001 / IEEE Std 1003.1 ustar/pax Format")
    }
}
