// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaKit
import TTZipCore
import TTZipPreviewKit
import XCTest

extension EbookBoundaryAndVFSRenderingTests {
    func testCancelledEPUBDetectionReleasesItsSession() async throws {
        let directory = try makeTempDir(prefix: "CancelledEPUBDetection")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try await createMultiLevelTocEpub(in: directory, named: "Cancelled.epub")
        let vfs = TTZipArchiveVfsProvider.shared
        let archiveId = TTZipArchiveVfsProvider.makeArchiveId(from: url.path)
        defer { EPUBArchiveUnpacker.releaseSession(for: url) }

        let parser = try XCTUnwrap(TTMediaBackgroundDetector.epubParser)
        let acquired = expectation(description: "The registered EPUB parser acquired the real VFS session")
        TTMediaBackgroundDetector.epubParser = { candidate in
            let book = await parser(candidate)
            if candidate == url, book != nil {
                XCTAssertEqual(vfs.sessionReferenceCount(archiveId: archiveId), 1)
                acquired.fulfill()
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return book
        }
        defer { TTMediaBackgroundDetector.epubParser = parser }

        let detector = TTMediaBackgroundDetector()
        let result = await Task { await detector.detectLatest(url: url) }.value
        await fulfillment(of: [acquired], timeout: 1)

        XCTAssertNil(result)
        XCTAssertEqual(vfs.sessionReferenceCount(archiveId: archiveId), 0)
        XCTAssertFalse(vfs.isSessionActive(archiveId: archiveId))
    }

    func testEPUBDetectionCopiesShareOneLeaseAlongsideAManualReader() async throws {
        let directory = try makeTempDir(prefix: "SharedEPUBDetection")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await createMultiLevelTocEpub(in: directory, named: "Shared.epub")
        let vfs = TTZipArchiveVfsProvider.shared
        let manual = try XCTUnwrap(EPUBArchiveUnpacker.unpackAndParseEPUB(at: url))
        let archiveId = try XCTUnwrap(vfs.parseVfsUri(manual.extractDir.absoluteString)?.archiveId)
        defer { vfs.closeSession(archiveId: archiveId) }

        var preview: EPUBBookModel? = try await detectEPUB(url)
        var copy = preview
        XCTAssertEqual(preview?.extractDir, manual.extractDir)
        XCTAssertEqual(vfs.sessionReferenceCount(archiveId: archiveId), 2)
        preview = nil
        withExtendedLifetime(copy) {
            XCTAssertEqual(vfs.sessionReferenceCount(archiveId: archiveId), 2)
        }
        copy = nil
        XCTAssertEqual(vfs.sessionReferenceCount(archiveId: archiveId), 1)
        let chapter = try await vfs.readEntryData(archiveId: archiveId, entryPath: "EPUB/text/ch1.xhtml")
        XCTAssertNotNil(chapter)
        EPUBArchiveUnpacker.releaseSession(for: url)
        XCTAssertFalse(vfs.isSessionActive(archiveId: archiveId))
    }

    func testStaleEPUBDetectionCannotReleaseReopenedSession() async throws {
        let directory = try makeTempDir(prefix: "StaleEPUBDetection")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await createMultiLevelTocEpub(in: directory, named: "Reopened.epub")
        let vfs = TTZipArchiveVfsProvider.shared
        var preview: EPUBBookModel? = try await detectEPUB(url)
        let archiveId = try XCTUnwrap(preview.flatMap { vfs.parseVfsUri($0.extractDir.absoluteString)?.archiveId })
        defer { vfs.closeSession(archiveId: archiveId) }

        withExtendedLifetime(preview) {
            vfs.closeSession(archiveId: archiveId)
            XCTAssertEqual(vfs.registerArchive(archivePath: url.path), archiveId)
        }
        preview = nil
        XCTAssertEqual(vfs.sessionReferenceCount(archiveId: archiveId), 1)
        XCTAssertTrue(vfs.isSessionActive(archiveId: archiveId))

        var replacement: EPUBBookModel? = try await detectEPUB(url)
        withExtendedLifetime(replacement) {
            XCTAssertEqual(vfs.releaseSession(archiveId: archiveId), 1)
        }
        replacement = nil
        XCTAssertFalse(vfs.isSessionActive(archiveId: archiveId))
    }

    func testNestedEPUBDetectionDeletesTheSpoolOnFinalRelease() async throws {
        let directory = try makeTempDir(prefix: "NestedEPUBDetection")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await createMultiLevelTocEpub(in: directory, named: "Nested.epub")
        let outer = directory.appendingPathComponent("Outer.zip")
        try await ArchiveWriter().createArchive(
            outputPath: outer.path,
            format: .zip,
            level: .fast,
            inputPaths: [source.path]
        )
        let vfs = TTZipArchiveVfsProvider.shared
        let outerId = vfs.registerArchive(archivePath: outer.path)
        defer { vfs.closeSession(archiveId: outerId) }
        let url = vfs.makeVfsURL(archiveId: outerId, entryPath: source.lastPathComponent)
        let parser = try XCTUnwrap(TTMediaBackgroundDetector.epubParser)
        var book = await parser(url)
        let archiveId = try XCTUnwrap(book.flatMap { vfs.parseVfsUri($0.extractDir.absoluteString)?.archiveId })
        defer { EPUBArchiveUnpacker.releaseSession(for: url) }
        let spool = try resolveNestedSpool(for: url, archiveId: archiveId)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: spool.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: spool.deletingLastPathComponent().path)[.posixPermissions] as? Int,
            0o700
        )
        withExtendedLifetime(book) {
            XCTAssertEqual(vfs.sessionReferenceCount(archiveId: archiveId), 1)
        }
        book = nil
        XCTAssertFalse(vfs.isSessionActive(archiveId: archiveId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path))
    }

    private func detectEPUB(_ url: URL) async throws -> EPUBBookModel {
        let result = await TTMediaBackgroundDetector().detectLatest(url: url)
        let book: EPUBBookModel?
        if case .epubBook(let detected) = result {
            book = detected
        } else {
            book = nil
        }
        return try XCTUnwrap(book, "Expected the registered EPUB parser to select the real fixture")
    }

    private func resolveNestedSpool(for url: URL, archiveId: String) throws -> URL {
        let fileManager = FileManager.default
        let tempRoot = ProcessInfo.processInfo.environment["TMPDIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.temporaryDirectory
        let root = tempRoot.appendingPathComponent("TTZipEphemeralEPUB", isDirectory: true)
        let directories = try fileManager.contentsOfDirectory(atPath: root.path)
        let name = "\(TTZipArchiveVfsProvider.makeArchiveId(from: url.absoluteString)).epub"
        let processPrefix = "session-\(ProcessInfo.processInfo.processIdentifier)-"
        return try XCTUnwrap(
            directories
                .filter { $0.hasPrefix(processPrefix) }
                .map { root.appendingPathComponent($0).appendingPathComponent(name) }
                .first { TTZipArchiveVfsProvider.makeArchiveId(from: $0.path) == archiveId }
        )
    }
}
