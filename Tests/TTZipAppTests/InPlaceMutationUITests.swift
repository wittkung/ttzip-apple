// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
@testable import TTZipApp
@testable import TTZipCore

final class InPlaceMutationUITests: XCTestCase {
    
    private var tempDir: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZip_InPlaceTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }
    
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
        var entries = try await reader.inspect(archivePath: archiveURL.path)
        XCTAssertTrue(entries.contains(where: { $0.name == "file1.txt" }))
        
        // 2. In-place delete entry "file2.txt"
        try await InPlaceMutationCoordinator.shared.deleteEntries(
            archivePath: archiveURL.path,
            entryPaths: ["file2.txt"]
        )
        
        entries = try await reader.inspect(archivePath: archiveURL.path)
        XCTAssertFalse(entries.contains(where: { $0.name == "file2.txt" }))
        XCTAssertTrue(entries.contains(where: { $0.name == "file1.txt" || $0.path.contains("file1.txt") }))
    }
    
    // MARK: - 4. Outline View Ancestor Chain & Tree Traversal Tests
    
    @MainActor
    func testOutlineViewAncestorChainResolution() {
        let child2 = ArchiveTreeNode(id: "c2", name: "file.txt", path: "root/sub/file.txt", uncompressedSize: 100, isDirectory: false, detectedEncoding: "UTF-8")
        let subDir = ArchiveTreeNode(id: "sub", name: "sub", path: "root/sub", uncompressedSize: 100, isDirectory: true, children: [child2])
        let rootDir = ArchiveTreeNode(id: "root", name: "root", path: "root", uncompressedSize: 100, isDirectory: true, children: [subDir])
        
        let chain = NativeArchiveOutlineView.findAncestorChain(for: "root/sub/file.txt", in: [rootDir])
        XCTAssertNotNil(chain)
        XCTAssertEqual(chain?.count, 3)
        XCTAssertEqual(chain?[0].name, "root")
        XCTAssertEqual(chain?[1].name, "sub")
        XCTAssertEqual(chain?[2].name, "file.txt")
    }
    
    // MARK: - 5. AppIntentDispatcher Mutation Intent Dispatch
    
    @MainActor
    func testAppIntentDispatcherAddAndDeleteDispatch() {
        let dispatcher = AppIntentDispatcher.shared
        let state = AppViewState()
        dispatcher.bind(state: state)
        
        let addResult = dispatcher.dispatch(
            .addFilesToArchive(archivePath: "/tmp/fake.zip", sourcePaths: ["/tmp/file.txt"], destinationSubfolder: nil),
            from: .dragAndDrop
        )
        XCTAssertEqual(addResult, IntentDispatchResult.success)
        
        let deleteResult = dispatcher.dispatch(
            .deleteArchiveEntries(archivePath: "/tmp/fake.zip", entryPaths: ["file.txt"]),
            from: .contextMenu
        )
        XCTAssertEqual(deleteResult, IntentDispatchResult.success)
    }
}
