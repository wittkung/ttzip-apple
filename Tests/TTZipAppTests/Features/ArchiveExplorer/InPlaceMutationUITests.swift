// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp
@testable import TTZipCore

@MainActor
final class InPlaceMutationUITests: XCTestCase {
    
    // MARK: - 1. Virtual Subpath URL Parsing Tests
    
    @MainActor
    func testVirtualURLParsing() {
        let plainPath = "/Users/test/Documents/archive.zip"
        let (plainArchive, plainSub) = MillerColumnItemRowView.parseVirtualURL(plainPath)
        XCTAssertEqual(plainArchive, plainPath)
        XCTAssertEqual(plainSub, "")
        
        let virtualPath = "file:///Users/test/Documents/archive.zip?subpath=folder/doc.txt"
        let (virtArchive, virtSub) = MillerColumnItemRowView.parseVirtualURL(virtualPath)
        XCTAssertEqual(virtArchive, "/Users/test/Documents/archive.zip")
        XCTAssertEqual(virtSub, "folder/doc.txt")
        
        let encodedVirtualPath = "file:///Users/test/Documents/my%20archive.zip?subpath=nested%20folder/file.pdf"
        let (encArchive, encSub) = MillerColumnItemRowView.parseVirtualURL(encodedVirtualPath)
        XCTAssertEqual(encArchive, "/Users/test/Documents/my archive.zip")
        XCTAssertEqual(encSub, "nested folder/file.pdf")
    }
    
    // MARK: - 2. InPlaceMutationCoordinator Cache Invalidation Tests
    
    @MainActor
    func testCoordinatorInvalidationAndNotificationBroadcast() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "InPlaceMutation")
        let fakeArchivePath = tempDir.appendingPathComponent("test_cache.zip").path
        let sampleData = Data("zip archive dummy header".utf8)
        try sampleData.write(to: URL(fileURLWithPath: fakeArchivePath))
        
        // Populate VFS LZ4 cache
        VFSLz4CachePool.shared.cacheEntry(archivePath: fakeArchivePath, entryPath: "item1.txt", data: Data("item1".utf8))
        XCTAssertNotNil(VFSLz4CachePool.shared.getCachedEntry(archivePath: fakeArchivePath, entryPath: "item1.txt"))
        
        let expectation = expectation(description: "Notification received")
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TTZipArchiveUnlockedRefresh"),
            object: nil,
            queue: .main
        ) { note in
            if let obj = note.object as? String, obj == fakeArchivePath {
                expectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        
        await InPlaceMutationCoordinator.shared.invalidateAndRefresh(archivePath: fakeArchivePath)
        
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertNil(VFSLz4CachePool.shared.getCachedEntry(archivePath: fakeArchivePath, entryPath: "item1.txt"))
    }
    
    // MARK: - 3. End-to-End In-Place Mutation Workflow
    
    @MainActor
    func testInPlaceAppendReplaceAndDeletePipeline() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "InPlaceMutation")
        let archiveURL = tempDir.appendingPathComponent("test_mutation.zip")
        let source1 = tempDir.appendingPathComponent("file1.txt")
        let source2 = tempDir.appendingPathComponent("file2.txt")
        let replacement = tempDir.appendingPathComponent("file1_new.txt")
        
        try Data("Original Content 1".utf8).write(to: source1)
        try Data("Original Content 2".utf8).write(to: source2)
        try Data("Replaced Content 1 New".utf8).write(to: replacement)
        
        // Create initial ZIP archive with source1 and source2
        let writer = ArchiveWriter()
        let request = ArchiveWriteRequest(
            outputPath: archiveURL.path,
            format: .zip,
            inputPaths: [source1.path, source2.path]
        )
        try await writer.createArchive(request)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        
        // 1. In-place replace entry "file1.txt" with replacement
        try await InPlaceMutationCoordinator.shared.replaceEntry(
            archivePath: archiveURL.path,
            entryPath: "file1.txt",
            sourceFilePath: replacement.path
        )
        
        let reader = ArchiveReader()
        let entriesAfterReplace = try await reader.listEntries(archivePath: archiveURL.path)
        XCTAssertEqual(entriesAfterReplace.count, 2)
        XCTAssertTrue(entriesAfterReplace.contains(where: { $0.path == "file1.txt" }))
        XCTAssertTrue(entriesAfterReplace.contains(where: { $0.path == "file2.txt" }))
        
        // 2. In-place append new file "file3.txt"
        let source3 = tempDir.appendingPathComponent("file3.txt")
        try Data("Appended Content 3".utf8).write(to: source3)
        try await InPlaceMutationCoordinator.shared.appendFiles(
            archivePath: archiveURL.path,
            sourceFilePaths: [source3.path]
        )
        
        let entriesAfterAppend = try await reader.listEntries(archivePath: archiveURL.path)
        XCTAssertEqual(entriesAfterAppend.count, 3)
        XCTAssertTrue(entriesAfterAppend.contains(where: { $0.path == "file3.txt" }))
        
        // 3. In-place delete entry "file2.txt"
        try await InPlaceMutationCoordinator.shared.deleteEntries(
            archivePath: archiveURL.path,
            entryPaths: ["file2.txt"]
        )
        
        let entriesAfterDelete = try await reader.listEntries(archivePath: archiveURL.path)
        XCTAssertEqual(entriesAfterDelete.count, 2)
        XCTAssertFalse(entriesAfterDelete.contains(where: { $0.path == "file2.txt" }))
        XCTAssertTrue(entriesAfterDelete.contains(where: { $0.path == "file1.txt" }))
        XCTAssertTrue(entriesAfterDelete.contains(where: { $0.path == "file3.txt" }))
    }

    @MainActor
    func testInPlaceMutationPasswordForwardingAndVaultSync() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "InPlaceMutation")
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        let replacement = tempDir.appendingPathComponent("replacement.txt")
        try "Original 1".write(to: file1, atomically: true, encoding: .utf8)
        try "Original 2".write(to: file2, atomically: true, encoding: .utf8)
        try "Replaced Content".write(to: replacement, atomically: true, encoding: .utf8)

        let archiveURL = tempDir.appendingPathComponent("test_pwd_mutation.zip")
        let writer = ArchiveWriter()
        let request = ArchiveWriteRequest(
            outputPath: archiveURL.path,
            format: .zip,
            level: .normal,
            inputPaths: [file1.path, file2.path]
        )
        try await writer.createArchive(request)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))

        // Ensure store is clean prior to mutation
        ArchivePasswordStore.shared.clearPassword(for: archiveURL.path)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archiveURL.path))

        // 1. Replace with password parameter -> verify store sync
        let secret1 = "vault_secret_999"
        try await InPlaceMutationCoordinator.shared.replaceEntry(
            archivePath: archiveURL.path,
            entryPath: "file1.txt",
            sourceFilePath: replacement.path,
            password: secret1
        )
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: archiveURL.path), secret1)

        // 2. Append files with updated password -> verify store update
        let secret2 = "vault_secret_updated"
        let appendFile = tempDir.appendingPathComponent("append.txt")
        try "Appended Content".write(to: appendFile, atomically: true, encoding: .utf8)
        try await InPlaceMutationCoordinator.shared.appendFiles(
            archivePath: archiveURL.path,
            sourceFilePaths: [appendFile.path],
            password: secret2
        )
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: archiveURL.path), secret2)

        // 3. Clean up credentials from store
        ArchivePasswordStore.shared.clearPassword(for: archiveURL.path)
    }
}
