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

@MainActor
final class AppViewStateArchiveOperationsTests: XCTestCase {
    
    private var tempDir: URL!
    private var mockFileViewer: MockFileViewerHarness!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AppViewStateOpsTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockFileViewer = MockFileViewerHarness()
    }
    
    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        mockFileViewer = nil
        try await super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func createSampleZipArchive(fileName: String = "sample.zip", contents: [String: String]) async throws -> URL {
        let zipURL = tempDir.appendingPathComponent(fileName)
        var inputPaths: [String] = []
        
        for (relName, text) in contents {
            let fileURL = tempDir.appendingPathComponent(relName)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            inputPaths.append(fileURL.path)
        }
        
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: inputPaths
        )
        return zipURL
    }
    
    private func createPasswordProtectedZipArchive(fileName: String = "locked.zip", password: String = "SecretKey123") async throws -> URL {
        let zipURL = tempDir.appendingPathComponent(fileName)
        let sampleFile = tempDir.appendingPathComponent("secret_notes.txt")
        try "Highly confidential report data".write(to: sampleFile, atomically: true, encoding: .utf8)
        
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [sampleFile.path],
            password: password
        )
        return zipURL
    }
    
    // MARK: - 1. Load Archive Tests
    
    func testLoadArchiveSuccessLifecycle() async throws {
        let zipURL = try await createSampleZipArchive(contents: [
            "readme.txt": "Welcome to TTZip",
            "docs/manual.pdf": "PDF Specification Guide"
        ])
        
        let sut = AppViewState(fileViewer: mockFileViewer)
        sut.activeTab = .compressWorkspace
        
        let success = await sut.loadArchive(path: zipURL.path)
        
        XCTAssertTrue(success, "loadArchive must return true for valid zip archive")
        XCTAssertEqual(sut.currentArchivePath, zipURL.path)
        XCTAssertEqual(sut.activeTab, .home, "loadArchive must navigate to Home/Archive Explorer tab")
        XCTAssertFalse(sut.isLoading)
        XCTAssertFalse(sut.showPasswordPrompt)
        XCTAssertGreaterThanOrEqual(sut.currentEntries.count, 2)
        XCTAssertTrue(sut.statusMessage.contains("Loaded") || sut.statusMessage.contains("entries"))
        XCTAssertTrue(sut.recentArchives.contains { $0.path == zipURL.path })
    }
    
    func testLoadArchivePasswordProtectedLifecycle() async throws {
        let lockedURL = try await createPasswordProtectedZipArchive()
        
        let sut = AppViewState(fileViewer: mockFileViewer)
        let success = await sut.loadArchive(path: lockedURL.path)
        
        // Listing zip entries succeeds
        XCTAssertTrue(success, "loadArchive lists entries from zip central directory")
        XCTAssertEqual(sut.currentArchivePath, lockedURL.path)
        XCTAssertEqual(sut.currentEntries.count, 1)
        XCTAssertTrue(sut.currentEntries.first?.isEncrypted == true)
        
        // Provide explicit password to unlock
        let unlocked = await sut.loadArchive(path: lockedURL.path, password: "SecretKey123")
        XCTAssertTrue(unlocked)
        XCTAssertEqual(sut.currentArchivePath, lockedURL.path)
        XCTAssertFalse(sut.showPasswordPrompt)
    }
    
    // MARK: - 2. Quick Extract Archive Tests
    
    func testQuickExtractArchiveLifecycle() async throws {
        let zipURL = try await createSampleZipArchive(contents: [
            "file_a.txt": "Content of File A",
            "file_b.txt": "Content of File B"
        ])
        
        let extractTargetDir = tempDir.appendingPathComponent("Extracted_Output")
        try FileManager.default.createDirectory(at: extractTargetDir, withIntermediateDirectories: true)
        
        let sut = AppViewState(fileViewer: mockFileViewer)
        await sut.quickExtractArchive(
            archivePath: zipURL.path,
            targetDir: extractTargetDir.path,
            isSmartExtract: false
        )
        
        XCTAssertTrue(sut.statusMessage.contains("Extraction complete"))
        XCTAssertEqual(mockFileViewer.revealedPaths.count, 1, "quickExtractArchive must call revealInFinder once")
        let expectedExtractDir = extractTargetDir.appendingPathComponent("sample").path
        XCTAssertEqual(mockFileViewer.revealedPaths.first, expectedExtractDir, "revealInFinder must target the extraction directory")
        
        let extractedFileA = extractTargetDir.appendingPathComponent("sample/file_a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedFileA.path) || FileManager.default.fileExists(atPath: extractTargetDir.appendingPathComponent("file_a.txt").path))
    }
    
    func testQuickExtractPasswordProtectedTriggersPrompt() async throws {
        let lockedURL = try await createPasswordProtectedZipArchive()
        let extractTargetDir = tempDir.appendingPathComponent("Extracted_Locked")
        try FileManager.default.createDirectory(at: extractTargetDir, withIntermediateDirectories: true)
        
        let sut = AppViewState(fileViewer: mockFileViewer)
        await sut.quickExtractArchive(
            archivePath: lockedURL.path,
            targetDir: extractTargetDir.path,
            password: nil,
            isSmartExtract: false
        )
        
        XCTAssertTrue(sut.showPasswordPrompt, "Password prompt must be shown when extracting encrypted archive without password")
        XCTAssertEqual(sut.pendingEncryptedPath, lockedURL.path)
        XCTAssertTrue(sut.statusMessage.lowercased().contains("password") || sut.statusMessage.lowercased().contains("encrypted"))
        XCTAssertTrue(mockFileViewer.revealedPaths.isEmpty, "revealInFinder must not be called when password prompt is triggered")
    }
    
    // MARK: - 3. Open Archive As Folder & Reset
    
    func testOpenArchiveAsFolderAndReset() async throws {
        let zipURL = try await createSampleZipArchive(contents: ["file.txt": "Hello"])
        
        let sut = AppViewState(fileViewer: mockFileViewer)
        sut.openArchiveAsFolder(url: zipURL)
        
        XCTAssertEqual(sut.selectedDiskItem?.path, zipURL.path)
        XCTAssertEqual(sut.activeTab, .home)
        XCTAssertTrue(sut.recentArchives.contains { $0.path == zipURL.path })
        
        sut.reset()
        XCTAssertNil(sut.currentArchivePath)
        XCTAssertNil(sut.activePassword)
        XCTAssertTrue(sut.currentEntries.isEmpty)
        XCTAssertEqual(sut.statusMessage, "Ready")
        XCTAssertFalse(sut.isLoading)
        XCTAssertEqual(sut.activeTab, .home)
    }
}
