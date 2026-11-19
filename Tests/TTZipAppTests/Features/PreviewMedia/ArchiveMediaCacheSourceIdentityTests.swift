// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import os
import XCTest
@testable import TTZipCore
@testable import TTZipPreviewKit

final class ArchiveMediaCacheSourceIdentityTests: XCTestCase {
    private enum SimulatedMediaError: Error, Equatable {
        case extractionFailed
    }

    private actor AsyncBarrier {
        private var entered = false
        private var released = false
        private var enterWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func markEnteredAndWaitForRelease() async {
            entered = true
            enterWaiter?.resume()
            enterWaiter = nil
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { continuation in
                enterWaiter = continuation
            }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private func createZipArchive(
        at destination: URL,
        entries: [(name: String, data: Data)],
        stagingRoot: URL
    ) async throws {
        let stageDir = stagingRoot.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        var inputPaths: [String] = []
        for entry in entries {
            let fileURL = stageDir.appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try entry.data.write(to: fileURL)
            inputPaths.append(fileURL.path)
        }
        let tempArchive = stagingRoot.appendingPathComponent("archive-\(UUID().uuidString).zip")
        try await ArchiveWriter().createArchive(
            outputPath: tempArchive.path,
            format: .zip,
            level: .fast,
            inputPaths: inputPaths
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempArchive)
        } else {
            try FileManager.default.moveItem(at: tempArchive, to: destination)
        }
    }

    private static func makeLargePayload(size: Int, markerByte: UInt8) -> Data {
        var data = Data(repeating: 0x11, count: size)
        let prefix = Data(repeating: markerByte, count: min(64, size))
        data.replaceSubrange(0..<prefix.count, with: prefix)
        return data
    }

    func testSourceFileIdentityTokenTracksOverwriteAndSymlinkReplacement() throws {
        let root = try makeTemporaryDirectory(prefix: "SourceIdentityToken")
        let missingPath = root.appendingPathComponent("does-not-exist.zip").path
        XCTAssertEqual(ArchiveMediaCachePool.sourceFileIdentityToken(at: missingPath), "absent")

        let fileA = root.appendingPathComponent("archive-a.zip")
        let fileB = root.appendingPathComponent("archive-b.zip")
        try Data("payload-alpha".utf8).write(to: fileA)
        try Data("payload-bravo".utf8).write(to: fileB)

        let tokenA1 = ArchiveMediaCachePool.sourceFileIdentityToken(at: fileA.path)
        XCTAssertNotEqual(tokenA1, "absent")
        let keyA1 = ArchiveMediaCachePool.computeCacheKey(
            archivePath: fileA.path,
            entryPath: "clip.mp4",
            uncompressedSize: 13,
            crc32: 0
        )

        // Overwrite in place with identical byte length and explicit mtime step.
        let handle = try FileHandle(forWritingTo: fileA)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("payload-omega".utf8))
        try handle.close()
        let bumpedDate = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: bumpedDate], ofItemAtPath: fileA.path)

        let tokenA2 = ArchiveMediaCachePool.sourceFileIdentityToken(at: fileA.path)
        let keyA2 = ArchiveMediaCachePool.computeCacheKey(
            archivePath: fileA.path,
            entryPath: "clip.mp4",
            uncompressedSize: 13,
            crc32: 0
        )
        XCTAssertNotEqual(tokenA2, tokenA1, "In-place overwrite must change source identity token")
        XCTAssertNotEqual(keyA2, keyA1, "In-place overwrite must change computed cache key")

        let symlink = root.appendingPathComponent("current.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fileA)
        let linkTokenA = ArchiveMediaCachePool.sourceFileIdentityToken(at: symlink.path)
        XCTAssertEqual(linkTokenA, tokenA2, "Symlink identity must follow through to the target file")

        try FileManager.default.removeItem(at: symlink)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fileB)
        let linkTokenB = ArchiveMediaCachePool.sourceFileIdentityToken(at: symlink.path)
        XCTAssertNotEqual(linkTokenB, linkTokenA, "Repointed symlink must produce a new identity token")

        try FileManager.default.removeItem(at: fileB)
        XCTAssertEqual(ArchiveMediaCachePool.sourceFileIdentityToken(at: symlink.path), "absent")
    }

    func testDiskCacheInvalidatesOnArchiveReplacementWhileProtectingActiveLease() async throws {
        let root = try makeTemporaryDirectory(prefix: "DiskCacheSourceIdentity")
        let pool = ArchiveMediaCachePool(
            maxItemCount: 1,
            customRootDirectory: root.appendingPathComponent("pool", isDirectory: true)
        )
        let archiveURL = root.appendingPathComponent("sample.zip")
        let payloadV1 = Data("media-payload-version-01".utf8)
        let payloadV2 = Data("media-payload-version-02".utf8)
        XCTAssertEqual(payloadV1.count, payloadV2.count)

        try await createZipArchive(at: archiveURL, entries: [("clip.mp4", payloadV1)], stagingRoot: root)
        let tokenV1 = ArchiveMediaCachePool.sourceFileIdentityToken(at: archiveURL.path)

        let extractCalls = OSAllocatedUnfairLock(initialState: 0)
        let countingExtraction = ArchiveMediaCachePool.Extraction(
            toDisk: { archivePath, entryPath, outputDirectory, password in
                extractCalls.withLock { $0 += 1 }
                _ = try await ArchiveRuntime.extractSingleEntry(
                    archivePath: archivePath,
                    entryPath: entryPath,
                    destinationDir: outputDirectory,
                    password: password,
                    handling: .policy(.replace)
                )
            },
            toMemory: { archivePath, entryPath, password in
                try await ArchiveRuntime.readEntry(
                    archivePath: archivePath,
                    entryPath: entryPath,
                    password: password
                )
            }
        )

        let leaseV1 = try await pool.acquireLeasedMedia(
            archivePath: archiveURL.path,
            entryPath: "clip.mp4",
            uncompressedSize: Int64(payloadV1.count),
            crc32: 0,
            extraction: countingExtraction
        )
        XCTAssertEqual(extractCalls.withLock { $0 }, 1)
        XCTAssertEqual(try Data(contentsOf: leaseV1.url), payloadV1)

        try await createZipArchive(at: archiveURL, entries: [("clip.mp4", payloadV2)], stagingRoot: root)
        let tokenV2 = ArchiveMediaCachePool.sourceFileIdentityToken(at: archiveURL.path)
        XCTAssertNotEqual(tokenV2, tokenV1)

        let leaseV2 = try await pool.acquireLeasedMedia(
            archivePath: archiveURL.path,
            entryPath: "clip.mp4",
            uncompressedSize: Int64(payloadV2.count),
            crc32: 0,
            extraction: countingExtraction
        )
        XCTAssertEqual(extractCalls.withLock { $0 }, 2, "Replacing archive must miss stale v1 cache entry")
        XCTAssertNotEqual(leaseV2.lease.key, leaseV1.lease.key)
        XCTAssertNotEqual(leaseV2.url, leaseV1.url)
        XCTAssertEqual(try Data(contentsOf: leaseV2.url), payloadV2, "New lease must return v2 bytes")
        XCTAssertEqual(try Data(contentsOf: leaseV1.url), payloadV1, "Active v1 lease must keep reading v1 safely")

        await pool.releaseLease(leaseV1.lease)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leaseV1.url.path),
            "Releasing stale v1 lease under maxItemCount=1 must reclaim v1 backing file"
        )
        XCTAssertEqual(try Data(contentsOf: leaseV2.url), payloadV2)
        await pool.releaseLease(leaseV2.lease)
    }

    func testVfsProviderInvalidatesMemoryAndDiskCacheOnArchiveReplacement() async throws {
        let root = try makeTemporaryDirectory(prefix: "VfsSourceIdentity")
        let pool = ArchiveMediaCachePool(customRootDirectory: root.appendingPathComponent("pool", isDirectory: true))
        let provider = TTZipArchiveVfsProvider(mediaCachePool: pool)
        let archiveURL = root.appendingPathComponent("bundle.zip")

        let largeSizeSame = Int(TTZipArchiveVfsProvider.maxInMemoryEntryBytes) + 64
        let largeSizeExpanded = Int(TTZipArchiveVfsProvider.maxInMemoryEntryBytes) + 256
        let smallV1 = Data("small-v1-alpha".utf8)
        let smallV2 = Data("small-v2-omega".utf8)
        let smallV3 = Data("small-v3-extended-payload-bytes".utf8)
        let largeV1 = Self.makeLargePayload(size: largeSizeSame, markerByte: 0x31)
        let largeV2 = Self.makeLargePayload(size: largeSizeSame, markerByte: 0x32)
        let largeV3 = Self.makeLargePayload(size: largeSizeExpanded, markerByte: 0x33)

        try await createZipArchive(
            at: archiveURL,
            entries: [("note.txt", smallV1), ("movie.mp4", largeV1)],
            stagingRoot: root
        )
        let archiveId = provider.registerArchive(archivePath: archiveURL.path)
        defer { provider.closeSession(archiveId: archiveId) }
        let noteURI = provider.makeVfsURL(archiveId: archiveId, entryPath: "note.txt").absoluteString
        let movieURI = provider.makeVfsURL(archiveId: archiveId, entryPath: "movie.mp4").absoluteString

        let rawSmallV1 = try await provider.loadResource(uri: noteURI)
        let loadedSmallV1 = try XCTUnwrap(rawSmallV1)
        XCTAssertEqual(loadedSmallV1.data, smallV1)
        XCTAssertEqual(provider.cachedData(for: noteURI), smallV1)
        let rawLargeV1 = try await provider.loadResourceRange(uri: movieURI, byteRange: 0...63)
        let rangeLargeV1 = try XCTUnwrap(rawLargeV1)
        XCTAssertEqual(rangeLargeV1.data, Data(repeating: 0x31, count: 64))
        XCTAssertEqual(rangeLargeV1.fullSize, Int64(largeV1.count))

        try await createZipArchive(
            at: archiveURL,
            entries: [("note.txt", smallV2), ("movie.mp4", largeV2)],
            stagingRoot: root
        )
        XCTAssertNil(provider.cachedData(for: noteURI), "Memory cache must invalidate after same-size replacement")
        let rawSmallV2 = try await provider.loadResource(uri: noteURI)
        let loadedSmallV2 = try XCTUnwrap(rawSmallV2)
        XCTAssertEqual(loadedSmallV2.data, smallV2)
        let rawLargeV2 = try await provider.loadResourceRange(uri: movieURI, byteRange: 0...63)
        let rangeLargeV2 = try XCTUnwrap(rawLargeV2)
        XCTAssertEqual(rangeLargeV2.data, Data(repeating: 0x32, count: 64))
        XCTAssertEqual(rangeLargeV2.fullSize, Int64(largeV2.count))

        try await createZipArchive(
            at: archiveURL,
            entries: [("note.txt", smallV3), ("movie.mp4", largeV3)],
            stagingRoot: root
        )
        let rawSmallV3 = try await provider.loadResourceRange(uri: noteURI, byteRange: 0...63)
        let rangeSmallV3 = try XCTUnwrap(rawSmallV3)
        XCTAssertEqual(rangeSmallV3.data, smallV3)
        XCTAssertEqual(rangeSmallV3.fullSize, Int64(smallV3.count))
        let rawLargeV3 = try await provider.loadResourceRange(uri: movieURI, byteRange: 0...63)
        let rangeLargeV3 = try XCTUnwrap(rawLargeV3)
        XCTAssertEqual(rangeLargeV3.data, Data(repeating: 0x33, count: 64))
        XCTAssertEqual(rangeLargeV3.fullSize, Int64(largeV3.count))
    }

    func testMidReadArchiveReplacementDoesNotPoisonVfsMemoryCache() async throws {
        let root = try makeTemporaryDirectory(prefix: "VfsMidReadReplace")
        let archiveURL = root.appendingPathComponent("live.zip")
        try Data("archive-v1-bytes".utf8).write(to: archiveURL)

        let provider = TTZipArchiveVfsProvider(
            mediaCachePool: ArchiveMediaCachePool(customRootDirectory: root.appendingPathComponent("pool", isDirectory: true))
        )
        let barrier = AsyncBarrier()
        let readAttempt = OSAllocatedUnfairLock(initialState: 0)
        await MainActor.run {
            provider.installReadAccess(.init(
                readEntry: { _, _, _ in
                    let attempt = readAttempt.withLock { count -> Int in
                        count += 1
                        return count
                    }
                    if attempt == 1 {
                        await barrier.markEnteredAndWaitForRelease()
                        return Data("stale-v1-content".utf8)
                    }
                    return Data("fresh-v2-content".utf8)
                },
                listEntrySizes: { _, _ in [] }
            ))
        }

        let archiveId = provider.registerArchive(archivePath: archiveURL.path)
        defer { provider.closeSession(archiveId: archiveId) }
        let uri = provider.makeVfsURL(archiveId: archiveId, entryPath: "doc.txt").absoluteString

        let inFlight = Task { try await provider.loadResource(uri: uri) }
        await barrier.waitUntilEntered()

        let replacement = root.appendingPathComponent("live-v2.zip")
        try Data("archive-v2-replacement-bytes".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(archiveURL, withItemAt: replacement)

        await barrier.release()
        let rawFirst = try await inFlight.value
        let firstResult = try XCTUnwrap(rawFirst)
        XCTAssertEqual(firstResult.data, Data("stale-v1-content".utf8))
        XCTAssertNil(provider.cachedData(for: uri), "Mid-read replacement must prevent v1 bytes from poisoning v2 cache")

        let rawSecond = try await provider.loadResource(uri: uri)
        let secondResult = try XCTUnwrap(rawSecond)
        XCTAssertEqual(secondResult.data, Data("fresh-v2-content".utf8))
        XCTAssertEqual(provider.cachedData(for: uri), Data("fresh-v2-content".utf8))
    }

    func testLoadResourceRangePropagatesLargeEntryExtractionErrorWithoutMemoryFallback() async throws {
        let root = try makeTemporaryDirectory(prefix: "VfsLargeExtractFailure")
        let pool = ArchiveMediaCachePool(customRootDirectory: root.appendingPathComponent("pool", isDirectory: true))
        let provider = TTZipArchiveVfsProvider(mediaCachePool: pool)
        let largeEntrySize = TTZipArchiveVfsProvider.maxInMemoryEntryBytes + 1
        let readEntryCalls = OSAllocatedUnfairLock(initialState: 0)

        await MainActor.run {
            provider.installReadAccess(.init(
                readEntry: { _, _, _ in
                    readEntryCalls.withLock { $0 += 1 }
                    return Data("unexpected-full-memory-fallback".utf8)
                },
                listEntrySizes: { _, _ in
                    [("video/large.mp4", UInt64(largeEntrySize))]
                }
            ))
            provider.installMediaCacheExtraction(.init(
                toDisk: { _, _, _, _ in
                    throw SimulatedMediaError.extractionFailed
                },
                toMemory: { _, _, _ in
                    throw SimulatedMediaError.extractionFailed
                }
            ))
        }

        let archivePath = "/fixture/large-error-\(UUID().uuidString).zip"
        let archiveId = provider.registerArchive(archivePath: archivePath)
        defer { provider.closeSession(archiveId: archiveId) }
        let uri = provider.makeVfsURL(archiveId: archiveId, entryPath: "video/large.mp4").absoluteString

        do {
            _ = try await provider.loadResourceRange(uri: uri, byteRange: 0...1023)
            XCTFail("Expected >8 MiB extraction failure to propagate without memory fallback")
        } catch let error as SimulatedMediaError {
            XCTAssertEqual(error, .extractionFailed)
        }

        XCTAssertEqual(readEntryCalls.withLock { $0 }, 0, "Full-memory loadResource fallback must not run for >8 MiB entry")
        let key = ArchiveMediaCachePool.computeCacheKey(
            archivePath: archivePath,
            entryPath: "video/large.mp4",
            uncompressedSize: largeEntrySize,
            crc32: 0
        )
        let activeLeases = await pool.activeLeaseCount(forKey: key)
        let cachedCount = await pool.cachedItemCount
        XCTAssertEqual(activeLeases, 0)
        XCTAssertEqual(cachedCount, 0)
    }

    func testLoadResourceRangePropagatesFileHandleOpenFailureAndReleasesLease() async throws {
        guard Darwin.geteuid() != 0 else {
            throw XCTSkip("Root user bypasses POSIX chmod 000 read restrictions")
        }

        let root = try makeTemporaryDirectory(prefix: "VfsFileHandleFailure")
        let pool = ArchiveMediaCachePool(customRootDirectory: root.appendingPathComponent("pool", isDirectory: true))
        let provider = TTZipArchiveVfsProvider(mediaCachePool: pool)
        let archivePath = "/fixture/filehandle-open-\(UUID().uuidString).zip"
        let entryPath = "media/unreadable.mp4"
        let declaredSize = TTZipArchiveVfsProvider.maxInMemoryEntryBytes + 1
        let readEntryCalls = OSAllocatedUnfairLock(initialState: 0)

        let cachedURL = try await pool.getOrExtractMedia(
            archivePath: archivePath,
            entryPath: entryPath,
            uncompressedSize: declaredSize,
            crc32: 0,
            extraction: .init(
                toDisk: { _, name, outputDir, _ in
                    let destination = URL(fileURLWithPath: outputDir)
                        .appendingPathComponent(ArchiveMediaCachePool.sanitizeFileName(name))
                    try Data(repeating: 0xAB, count: 256).write(to: destination)
                },
                toMemory: { _, _, _ in nil }
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedURL.path))

        XCTAssertEqual(Darwin.chmod(cachedURL.path, 0o000), 0)
        defer { _ = Darwin.chmod(cachedURL.path, 0o600) }

        await MainActor.run {
            provider.installReadAccess(.init(
                readEntry: { _, _, _ in
                    readEntryCalls.withLock { $0 += 1 }
                    return Data("unexpected-memory-fallback".utf8)
                },
                listEntrySizes: { _, _ in
                    [(entryPath, UInt64(declaredSize))]
                }
            ))
            provider.installMediaCacheExtraction(.init(
                toDisk: { _, _, _, _ in
                    XCTFail("Pre-populated media cache entry should hit existing cached file")
                },
                toMemory: { _, _, _ in nil }
            ))
        }

        let archiveId = provider.registerArchive(archivePath: archivePath)
        defer { provider.closeSession(archiveId: archiveId) }
        let uri = provider.makeVfsURL(archiveId: archiveId, entryPath: entryPath).absoluteString

        do {
            _ = try await provider.loadResourceRange(uri: uri, byteRange: 0...63)
            XCTFail("Expected FileHandle(forReadingFrom:) permission error to propagate")
        } catch {
            Self.assertFileHandlePermissionError(error)
        }

        XCTAssertEqual(readEntryCalls.withLock { $0 }, 0, "FileHandle open failure must not fall back to loadResource")
        let key = ArchiveMediaCachePool.computeCacheKey(
            archivePath: archivePath,
            entryPath: entryPath,
            uncompressedSize: declaredSize,
            crc32: 0
        )
        let activeLeases = await pool.activeLeaseCount(forKey: key)
        XCTAssertEqual(activeLeases, 0, "Failed FileHandle open must release ArchiveMediaCachePool lease")

        await pool.purgeAll()
        let deferredCount = await pool.pendingDeferredDeletionCount
        let cachedCount = await pool.cachedItemCount
        XCTAssertEqual(deferredCount, 0, "Zero leaked leases must allow immediate directory reclamation")
        XCTAssertEqual(cachedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedURL.path))
    }

    private static func assertFileHandlePermissionError(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let isCocoaPermissionError = nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError)
        let isDirectPosixEacces = nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EACCES)
        let isUnderlyingPosixEacces = underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(EACCES)
        XCTAssertTrue(
            (isCocoaPermissionError && isUnderlyingPosixEacces) || isDirectPosixEacces,
            "Expected FileHandle EACCES permission error, got \(nsError.domain)/\(nsError.code) underlying=\(String(describing: underlying))",
            file: file,
            line: line
        )
    }

    private static func replaceArchiveBytes(at archiveURL: URL, with contents: String, stagingRoot: URL) {
        let replacement = stagingRoot.appendingPathComponent("replace-\(UUID().uuidString).zip")
        try? Data(contents.utf8).write(to: replacement)
        _ = try? FileManager.default.replaceItemAt(archiveURL, withItemAt: replacement)
    }

    private func makeHookedProvider(
        root: URL,
        oneShotHook: OSAllocatedUnfairLock<(@Sendable (String) -> String)?>
    ) -> TTZipArchiveVfsProvider {
        let pool = ArchiveMediaCachePool(customRootDirectory: root.appendingPathComponent("pool", isDirectory: true))
        return TTZipArchiveVfsProvider(mediaCachePool: pool) { path in
            let armed = oneShotHook.withLock { hook -> (@Sendable (String) -> String)? in
                let current = hook
                hook = nil
                return current
            }
            if let armed {
                return armed(path)
            }
            return ArchiveMediaCachePool.sourceFileIdentityToken(at: path)
        }
    }

    private static func armAdvanceAndPopulateHook(
        in oneShotHook: OSAllocatedUnfairLock<(@Sendable (String) -> String)?>,
        archiveURL: URL,
        replacementBytes: String,
        stagingRoot: URL,
        provider: TTZipArchiveVfsProvider,
        archiveId: String,
        noteURI: String,
        noteData: Data
    ) {
        oneShotHook.withLock { hook in
            hook = { path in
                let staleIdentity = ArchiveMediaCachePool.sourceFileIdentityToken(at: path)
                Self.replaceArchiveBytes(at: archiveURL, with: replacementBytes, stagingRoot: stagingRoot)
                _ = provider.cachedData(for: noteURI)
                provider.cacheEntryData(archiveId: archiveId, entryPath: "note.txt", data: noteData)
                return staleIdentity
            }
        }
    }

    func testCacheEntryDataAfterSessionCloseDoesNotLeakStaleBytesIntoReplacedArchive() async throws {
        let root = try makeTemporaryDirectory(prefix: "VfsGhostEntry")
        let archiveURL = root.appendingPathComponent("ghost.zip")
        try Data("archive-v1".utf8).write(to: archiveURL)

        let oneShotHook = OSAllocatedUnfairLock<(@Sendable (String) -> String)?>(initialState: nil)
        let provider = makeHookedProvider(root: root, oneShotHook: oneShotHook)
        let readStage = OSAllocatedUnfairLock(initialState: 2)
        await MainActor.run {
            provider.installReadAccess(.init(
                readEntry: { _, _, _ in
                    let stage = readStage.withLock { $0 }
                    return Data("fresh-v\(stage)-bytes".utf8)
                },
                listEntrySizes: { _, _ in [] }
            ))
        }

        let archiveId1 = provider.registerArchive(archivePath: archiveURL.path)
        let noteURI = provider.makeVfsURL(archiveId: archiveId1, entryPath: "note.txt").absoluteString
        provider.closeSession(archiveId: archiveId1)
        provider.cacheEntryData(archiveId: archiveId1, entryPath: "note.txt", data: Data("stale-v1-ghost".utf8))

        Self.replaceArchiveBytes(at: archiveURL, with: "archive-v2-bytes", stagingRoot: root)
        let archiveId2 = provider.registerArchive(archivePath: archiveURL.path)
        defer { provider.closeSession(archiveId: archiveId2) }
        XCTAssertEqual(archiveId2, archiveId1)
        XCTAssertNil(provider.cachedData(for: noteURI), "Post-close cacheEntryData must not leak ghost v1 bytes into v2")
        let rawV2Loaded = try await provider.loadResource(uri: noteURI)
        let v2Loaded = try XCTUnwrap(rawV2Loaded)
        XCTAssertEqual(v2Loaded.data, Data("fresh-v2-bytes".utf8))

        let raceURI = provider.makeVfsURL(archiveId: archiveId2, entryPath: "race.txt").absoluteString
        oneShotHook.withLock { hook in
            hook = { path in
                let staleToken = ArchiveMediaCachePool.sourceFileIdentityToken(at: path)
                provider.closeSession(archiveId: archiveId2)
                return staleToken
            }
        }
        provider.cacheEntryData(archiveId: archiveId2, entryPath: "race.txt", data: Data("stale-v2-race-ghost".utf8))

        readStage.withLock { $0 = 3 }
        Self.replaceArchiveBytes(at: archiveURL, with: "archive-v3-extended-bytes", stagingRoot: root)
        let archiveId3 = provider.registerArchive(archivePath: archiveURL.path)
        XCTAssertEqual(archiveId3, archiveId2)
        XCTAssertNil(provider.cachedData(for: raceURI), "In-flight cacheEntryData racing closeSession must not leak ghost v2 bytes into v3")
        let rawV3Loaded = try await provider.loadResource(uri: raceURI)
        let v3Loaded = try XCTUnwrap(rawV3Loaded)
        XCTAssertEqual(v3Loaded.data, Data("fresh-v3-bytes".utf8))
    }

    func testDelayedV1WriterCannotRollBackV2SessionIdentityOrPoisonCache() async throws {
        let root = try makeTemporaryDirectory(prefix: "VfsMonotoneWriter")
        let archiveURL = root.appendingPathComponent("monotone.zip")
        try Data("archive-v1".utf8).write(to: archiveURL)

        let oneShotHook = OSAllocatedUnfairLock<(@Sendable (String) -> String)?>(initialState: nil)
        let provider = makeHookedProvider(root: root, oneShotHook: oneShotHook)
        let archiveId = provider.registerArchive(archivePath: archiveURL.path)
        defer { provider.closeSession(archiveId: archiveId) }
        let noteURI = provider.makeVfsURL(archiveId: archiveId, entryPath: "note.txt").absoluteString
        let clipURI = provider.makeVfsURL(archiveId: archiveId, entryPath: "clip.mp4").absoluteString

        let v1Note = Data("stale-v1-note".utf8)
        let v2Note = Data("fresh-v2-note-payload".utf8)
        let v3Note = Data("fresh-v3-note-payload-bytes".utf8)
        let v2Clip = Data(repeating: 0x22, count: 16)
        let v3Clip = Data(repeating: 0x33, count: 48)
        let readCalls = OSAllocatedUnfairLock(initialState: 0)
        let sizeCalls = OSAllocatedUnfairLock(initialState: 0)

        await MainActor.run {
            provider.installReadAccess(.init(
                readEntry: { _, entryPath, _ in
                    let call = readCalls.withLock { $0 += 1; return $0 }
                    if entryPath == "note.txt" && call == 1 {
                        Self.armAdvanceAndPopulateHook(
                            in: oneShotHook,
                            archiveURL: archiveURL,
                            replacementBytes: "archive-v2-bytes",
                            stagingRoot: root,
                            provider: provider,
                            archiveId: archiveId,
                            noteURI: noteURI,
                            noteData: v2Note
                        )
                        return v1Note
                    }
                    return entryPath == "clip.mp4" ? (sizeCalls.withLock { $0 } == 1 ? v2Clip : v3Clip) : v2Note
                },
                listEntrySizes: { _, _ in
                    let call = sizeCalls.withLock { $0 += 1; return $0 }
                    if call == 1 {
                        Self.armAdvanceAndPopulateHook(
                            in: oneShotHook,
                            archiveURL: archiveURL,
                            replacementBytes: "archive-v3-extended-bytes",
                            stagingRoot: root,
                            provider: provider,
                            archiveId: archiveId,
                            noteURI: noteURI,
                            noteData: v3Note
                        )
                        return [("clip.mp4", UInt64(v2Clip.count))]
                    }
                    return [("clip.mp4", UInt64(v3Clip.count))]
                }
            ))
        }

        let rawFirstNote = try await provider.loadResource(uri: noteURI)
        let firstNote = try XCTUnwrap(rawFirstNote)
        XCTAssertEqual(firstNote.data, v1Note)
        XCTAssertEqual(provider.cachedData(for: noteURI), v2Note, "Delayed v1 cache writer must not roll back I2 or evict v2 cache")
        let rawCachedNoteV2 = try await provider.loadResource(uri: noteURI)
        let cachedNoteV2 = try XCTUnwrap(rawCachedNoteV2)
        XCTAssertEqual(cachedNoteV2.data, v2Note)
        XCTAssertEqual(readCalls.withLock { $0 }, 1, "Intact v2 memory cache must satisfy reload without re-extracting")

        _ = try await provider.loadResourceRange(uri: clipURI, byteRange: 0...15)
        XCTAssertEqual(provider.cachedData(for: noteURI), v3Note, "Delayed v2 size writer must not roll back I3 or evict v3 cache")
        XCTAssertNil(provider.cachedData(for: clipURI), "Stale v2 clip bytes must not be cached under I3")

        let rawV3Range = try await provider.loadResourceRange(uri: clipURI, byteRange: 0...15)
        let v3Range = try XCTUnwrap(rawV3Range)
        XCTAssertEqual(sizeCalls.withLock { $0 }, 2, "Stale v2 entrySizes must not poison v3 entrySizes")
        XCTAssertEqual(v3Range.fullSize, Int64(v3Clip.count))
        XCTAssertEqual(v3Range.data, v3Clip.prefix(16))
    }

    func testDelayedReconciledSessionCannotRollBackV2SessionIdentity() throws {
        let root = try makeTemporaryDirectory(prefix: "VfsMonotoneReconcile")
        let archiveURL = root.appendingPathComponent("reconcile.zip")
        try Data("archive-v1".utf8).write(to: archiveURL)

        let oneShotHook = OSAllocatedUnfairLock<(@Sendable (String) -> String)?>(initialState: nil)
        let provider = makeHookedProvider(root: root, oneShotHook: oneShotHook)
        let archiveId = provider.registerArchive(archivePath: archiveURL.path)
        defer { provider.closeSession(archiveId: archiveId) }
        let noteURI = provider.makeVfsURL(archiveId: archiveId, entryPath: "note.txt").absoluteString
        let v2Note = Data("fresh-v2-reconciled".utf8)

        Self.armAdvanceAndPopulateHook(
            in: oneShotHook,
            archiveURL: archiveURL,
            replacementBytes: "archive-v2-bytes",
            stagingRoot: root,
            provider: provider,
            archiveId: archiveId,
            noteURI: noteURI,
            noteData: v2Note
        )

        let duringRace = provider.cachedData(for: noteURI)
        XCTAssertEqual(duringRace, v2Note, "Delayed reconciledSession must re-reconcile instead of rolling I2 back to I1")
        XCTAssertEqual(provider.cachedData(for: noteURI), v2Note, "v2 memory cache must stay intact after delayed reconciledSession")
    }

    func testAbaSourceIdentityTransitionBlocksStaleEpochZeroCacheWrite() async throws {
        let root = try makeTemporaryDirectory(prefix: "VfsAbaEpoch")
        let identity = OSAllocatedUnfairLock(initialState: "aba-I1")
        let pool = ArchiveMediaCachePool(customRootDirectory: root.appendingPathComponent("pool", isDirectory: true))
        let provider = TTZipArchiveVfsProvider(mediaCachePool: pool) { _ in identity.withLock { $0 } }

        let barrier = AsyncBarrier()
        let readAttempt = OSAllocatedUnfairLock(initialState: 0)
        await MainActor.run {
            provider.installReadAccess(.init(
                readEntry: { _, _, _ in
                    let attempt = readAttempt.withLock { count -> Int in
                        count += 1
                        return count
                    }
                    if attempt == 1 {
                        await barrier.markEnteredAndWaitForRelease()
                        return Data("stale-aba-v1".utf8)
                    }
                    return Data("fresh-aba-v3".utf8)
                },
                listEntrySizes: { _, _ in [] }
            ))
        }

        let archiveId = provider.registerArchive(archivePath: "/fixture/aba-\(UUID().uuidString).zip")
        defer { provider.closeSession(archiveId: archiveId) }
        let noteURI = provider.makeVfsURL(archiveId: archiveId, entryPath: "note.txt").absoluteString
        XCTAssertEqual(provider.sessionIdentityEpoch(archiveId: archiveId), 0)

        let inFlight = Task { try await provider.loadResource(uri: noteURI) }
        await barrier.waitUntilEntered()

        identity.withLock { $0 = "aba-I2" }
        XCTAssertNil(provider.cachedData(for: noteURI))
        XCTAssertEqual(provider.sessionIdentityEpoch(archiveId: archiveId), 1)

        identity.withLock { $0 = "aba-I1" }
        XCTAssertNil(provider.cachedData(for: noteURI))
        XCTAssertEqual(provider.sessionIdentityEpoch(archiveId: archiveId), 2)

        await barrier.release()
        let stale = try await inFlight.value
        XCTAssertEqual(stale?.data, Data("stale-aba-v1".utf8))
        XCTAssertNil(provider.cachedData(for: noteURI), "Epoch 0 writer must not poison cache after I1 -> I2 -> I1 ABA return at epoch 2")
        XCTAssertEqual(provider.sessionIdentityEpoch(archiveId: archiveId), 2)

        let fresh = try await provider.loadResource(uri: noteURI)
        XCTAssertEqual(fresh?.data, Data("fresh-aba-v3".utf8))
        XCTAssertEqual(provider.cachedData(for: noteURI), Data("fresh-aba-v3".utf8))
        XCTAssertEqual(provider.sessionIdentityEpoch(archiveId: archiveId), 2)
    }

    func testAcquireAndGetMediaComputeSourceIdentityOffActorExecutor() async throws {
        let root = try makeTemporaryDirectory(prefix: "PoolOffActorStat")
        let localPath = "/fixture/local-\(UUID().uuidString).zip"
        let slowPath = "/fixture/slow-\(UUID().uuidString).zip"
        let (enteredStream, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { enteredContinuation.finish() }
        var enteredIterator = enteredStream.makeAsyncIterator()
        let statCompleted = OSAllocatedUnfairLock(initialState: false)
        let allowStatExit = DispatchSemaphore(value: 0)
        let memoryExtraction = ArchiveMediaCachePool.Extraction(
            toDisk: { _, _, _, _ in },
            toMemory: { _, _, _ in Data("payload".utf8) }
        )

        let pool = ArchiveMediaCachePool(
            customRootDirectory: root.appendingPathComponent("pool", isDirectory: true)
        ) { path in
            guard path == slowPath else { return "local-token" }
            enteredContinuation.yield()
            _ = allowStatExit.wait(timeout: .now() + .seconds(5))
            statCompleted.withLock { $0 = true }
            return "remote-token"
        }

        func verifyOffActorStat(_ label: String, launchSlow: @escaping @Sendable () async throws -> Void) async throws {
            statCompleted.withLock { $0 = false }
            let localLease = try await pool.acquireLeasedMedia(
                archivePath: localPath,
                entryPath: "clip.mp4",
                uncompressedSize: 7,
                extraction: memoryExtraction
            )
            let slowTask = Task.detached { try await launchSlow() }
            _ = await enteredIterator.next()
            await pool.releaseLease(localLease.lease)
            await pool.purgeAll()
            XCTAssertFalse(statCompleted.withLock { $0 }, "\(label) must run stat() off the actor executor")
            allowStatExit.signal()
            try await slowTask.value
        }

        try await verifyOffActorStat("acquireLeasedMedia") {
            let leased = try await pool.acquireLeasedMedia(
                archivePath: slowPath,
                entryPath: "clip.mp4",
                uncompressedSize: 7,
                extraction: memoryExtraction
            )
            await pool.releaseLease(leased.lease)
        }
        try await verifyOffActorStat("getOrExtractMedia") {
            let url = try await pool.getOrExtractMedia(
                archivePath: slowPath,
                entryPath: "clip.mp4",
                uncompressedSize: 7,
                extraction: memoryExtraction
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
