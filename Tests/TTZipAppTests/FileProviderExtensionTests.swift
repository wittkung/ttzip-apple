// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import FileProvider
import UniformTypeIdentifiers
import XCTest
@testable import TTZipApp
@testable import TTZipFileProvider

final class FileProviderExtensionTests: XCTestCase {

    func testRootContainerItemProperties() {
        let rootItem = FileProviderItem.rootContainerItem(domainIdentifier: "sample_archive")

        XCTAssertEqual(rootItem.itemIdentifier, .rootContainer)
        XCTAssertEqual(rootItem.parentItemIdentifier, .rootContainer)
        XCTAssertEqual(rootItem.filename, "sample_archive")
        XCTAssertEqual(rootItem.contentType, .folder)
        XCTAssertTrue(rootItem.isDirectory)
        XCTAssertNil(rootItem.documentSize)
        XCTAssertEqual(rootItem.capabilities, [.allowsReading, .allowsContentEnumerating])
    }

    func testLeafFileItemProperties() {
        let fileItem = FileProviderItem(
            identifier: NSFileProviderItemIdentifier("docs/readme.txt"),
            parentIdentifier: NSFileProviderItemIdentifier("docs"),
            filename: "readme.txt",
            contentType: .plainText,
            documentSize: 1024,
            modificationDate: Date(timeIntervalSince1970: 1000),
            isDirectory: false
        )

        XCTAssertEqual(fileItem.itemIdentifier.rawValue, "docs/readme.txt")
        XCTAssertEqual(fileItem.parentItemIdentifier.rawValue, "docs")
        XCTAssertEqual(fileItem.filename, "readme.txt")
        XCTAssertEqual(fileItem.contentType, .plainText)
        XCTAssertFalse(fileItem.isDirectory)
        XCTAssertEqual(fileItem.documentSize?.int64Value, 1024)
        XCTAssertEqual(fileItem.capabilities, [.allowsReading])
    }

    func testEnumeratorBatchExecution() {
        let items = [
            FileProviderItem(
                identifier: NSFileProviderItemIdentifier("file1.dat"),
                parentIdentifier: .rootContainer,
                filename: "file1.dat",
                contentType: .data,
                documentSize: 50
            ),
            FileProviderItem(
                identifier: NSFileProviderItemIdentifier("dir1"),
                parentIdentifier: .rootContainer,
                filename: "dir1",
                contentType: .folder,
                isDirectory: true
            )
        ]

        let enumerator = FileProviderEnumerator(containerItemIdentifier: .rootContainer, items: items)

        final class MockObserver: NSObject, NSFileProviderEnumerationObserver {
            var receivedItems: [NSFileProviderItem] = []
            var finished = false

            func didEnumerate(_ items: [NSFileProviderItemProtocol]) {
                receivedItems.append(contentsOf: items)
            }

            func finishEnumerating(upTo page: NSFileProviderPage?) {
                finished = true
            }

            func finishEnumeratingWithError(_ error: Error) {}
        }

        let observer = MockObserver()
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage("initial".data(using: .utf8)!))

        XCTAssertTrue(observer.finished)
        XCTAssertEqual(observer.receivedItems.count, 2)
        XCTAssertEqual(observer.receivedItems.first?.filename, "file1.dat")
    }

    @MainActor
    func testMountCoordinatorNonExistentArchiveFails() async {
        let missingURL = URL(fileURLWithPath: "/tmp/non_existent_archive_\(UUID().uuidString).zip")
        let coordinator = ArchiveMountCoordinator.shared

        do {
            try await coordinator.mountArchive(at: missingURL)
            XCTFail("Expected mount to fail for missing file")
        } catch {
            let nsErr = error as NSError
            XCTAssertEqual(nsErr.domain, NSCocoaErrorDomain)
            XCTAssertEqual(nsErr.code, NSFileNoSuchFileError)
        }
    }

    func testVirtualIntermediateDirectoryItemProperties() {
        let segments = "nested/deep/directory".split(separator: "/").map(String.init)
        let filename = segments.last!
        let parentId = NSFileProviderItemIdentifier(segments.dropLast().joined(separator: "/"))

        let virtualDir = FileProviderItem(
            identifier: NSFileProviderItemIdentifier("nested/deep/directory"),
            parentIdentifier: parentId,
            filename: filename,
            contentType: .folder,
            isDirectory: true
        )

        XCTAssertEqual(virtualDir.itemIdentifier.rawValue, "nested/deep/directory")
        XCTAssertEqual(virtualDir.parentItemIdentifier.rawValue, "nested/deep")
        XCTAssertEqual(virtualDir.filename, "directory")
        XCTAssertEqual(virtualDir.contentType, .folder)
        XCTAssertTrue(virtualDir.isDirectory)
        XCTAssertEqual(virtualDir.capabilities, [.allowsReading, .allowsContentEnumerating])
    }
}
