// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
import TTMediaKit
@testable import TTZipPreviewKit

@MainActor
final class ReaderProgressCheckpointTests: XCTestCase {
    func testUnchangedSidebarDisappearanceCannotOverwriteNewStandaloneProgressInRust() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = try ReaderPersistenceBridge(directory: directory).adapter
        let identity = "ttzip-vfs://stable-archive/books/book.epub"
        let old = position(block: 4, ratio: 0.2)
        let latest = position(block: 40, ratio: 0.8)
        try adapter.savePosition(identity, old)
        var sidebar = EPUBReaderProgressCheckpoint()
        var standalone = EPUBReaderProgressCheckpoint()
        sidebar.restore(identity: identity, anchor: try adapter.load(identity).position)
        standalone.restore(identity: identity, anchor: try adapter.load(identity).position)
        XCTAssertTrue(try standalone.saveIfChanged(identity: identity, anchor: latest, using: adapter.savePosition))
        XCTAssertFalse(try sidebar.saveIfChanged(identity: identity, anchor: old, using: adapter.savePosition))
        let reopened = try ReaderPersistenceBridge(directory: directory).adapter
        XCTAssertEqual(try reopened.load(identity).position, latest, "Closing an unchanged old reader must leave Rust's latest saved anchor intact")
        let newSidebarProgress = position(block: 5, ratio: 0.25)
        XCTAssertTrue(try sidebar.saveIfChanged(identity: identity, anchor: newSidebarProgress, using: adapter.savePosition))
        XCTAssertEqual(try reopened.load(identity).position, newSidebarProgress, "A real new reading operation remains writable")
    }

    func testFailedWriteKeepsCheckpointUnacknowledgedAndRetriesActualRustStorage() throws {
        enum StorageFailure: Error { case simulated }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = try ReaderPersistenceBridge(directory: directory).adapter
        let identity = "file:///books/book.epub"
        let old = position(block: 1, ratio: 0.1)
        let latest = position(block: 3, ratio: 0.3)
        try adapter.savePosition(identity, old)
        var checkpoint = EPUBReaderProgressCheckpoint()
        checkpoint.restore(identity: identity, anchor: old)
        XCTAssertThrowsError(try checkpoint.saveIfChanged(identity: identity, anchor: latest) { _, _ in
            throw StorageFailure.simulated
        })
        XCTAssertEqual(try adapter.load(identity).position, old)
        XCTAssertTrue(try checkpoint.saveIfChanged(identity: identity, anchor: latest, using: adapter.savePosition))
        XCTAssertEqual(try ReaderPersistenceBridge(directory: directory).adapter.load(identity).position, latest)
    }

    func testSameNumericalAnchorForAnotherBookIsNotSuppressed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = try ReaderPersistenceBridge(directory: directory).adapter
        let anchor = position(block: 0, ratio: 0)
        var checkpoint = EPUBReaderProgressCheckpoint()
        checkpoint.restore(identity: "book-a", anchor: anchor)
        XCTAssertTrue(try checkpoint.saveIfChanged(identity: "book-b", anchor: anchor, using: adapter.savePosition))
        XCTAssertTrue(try XCTUnwrap(adapter.hasStoredDocument)("book-b"))
        XCTAssertEqual(try adapter.load("book-b").position, anchor)
    }

    private func position(block: UInt32, ratio: Double) -> EPUBReaderAnchor {
        EPUBReaderAnchor(chapterIndex: 1, blockIndex: block, characterOffset: 7, chapterRatio: ratio)
    }
}
