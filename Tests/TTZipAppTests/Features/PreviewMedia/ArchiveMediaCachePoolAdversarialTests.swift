// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import AppKit
import CryptoKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

/// Adversarial stress testing and security validation suite for ArchiveMediaCachePool & MediaPreviewFactory.
/// Challenges concurrency deduplication, LRU quota exhaustion, Zip-Slip sandbox containment, and POSIX permissions.
final class ArchiveMediaCachePoolAdversarialTests: XCTestCase {
    private actor ExtractionCount {
        private(set) var diskCalls = 0

        func recordDiskCall() { diskCalls += 1 }
    }

    func testMediaExtractionSharesDiskResultForConcurrentRequestsAndHits() async throws {
        let root = try makeTemporaryDirectory(prefix: "DiskMediaExtraction")
        let pool = ArchiveMediaCachePool(customRootDirectory: root.appendingPathComponent("pool"))
        let payload = Data("disk payload".utf8)
        let calls = ExtractionCount()
        let extraction = ArchiveMediaCachePool.Extraction(
            toDisk: { archivePath, entryPath, outputDirectory, password in
                await calls.recordDiskCall()
                XCTAssertEqual(archivePath, "/fixture/archive.zip")
                XCTAssertEqual(entryPath, "nested/clip.mp4")
                XCTAssertEqual(password, "fixture-password")
                let folder = URL(fileURLWithPath: outputDirectory).appendingPathComponent("nested")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try payload.write(to: folder.appendingPathComponent("clip.mp4"))
            },
            toMemory: { _, _, _ in
                XCTFail("A valid disk result does not require a memory read")
                return nil
            }
        )

        @Sendable func extract() async throws -> URL {
            try await pool.getOrExtractMedia(
                archivePath: "/fixture/archive.zip",
                entryPath: "nested/clip.mp4",
                uncompressedSize: Int64(payload.count),
                crc32: 123,
                password: "fixture-password",
                extraction: extraction
            )
        }

        async let first = extract()
        async let second = extract()
        let (firstURL, secondURL) = try await (first, second)
        let cached = try await extract()
        let count = await calls.diskCalls
        XCTAssertEqual(count, 1)
        XCTAssertEqual(firstURL, secondURL)
        XCTAssertEqual(firstURL, cached)
        XCTAssertEqual(firstURL.lastPathComponent, "clip.mp4")
        XCTAssertEqual(try Data(contentsOf: firstURL), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: firstURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testMediaExtractionFallsBackWhenDiskOutputIsASymlink() async throws {
        let root = try makeTemporaryDirectory(prefix: "MemoryMediaExtraction")
        let pool = ArchiveMediaCachePool(customRootDirectory: root.appendingPathComponent("pool"))
        let outside = root.appendingPathComponent("outside")
        let outsideBytes = Data("unrelated file".utf8)
        try outsideBytes.write(to: outside)
        let payload = Data("memory payload".utf8)
        let extraction = ArchiveMediaCachePool.Extraction(
            toDisk: { _, entryPath, outputDirectory, _ in
                let link = URL(fileURLWithPath: outputDirectory).appendingPathComponent(entryPath)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            },
            toMemory: { archivePath, entryPath, password in
                XCTAssertEqual(archivePath, "/fixture/archive.zip")
                XCTAssertEqual(entryPath, "clip.mp4")
                XCTAssertEqual(password, "fixture-password")
                return payload
            }
        )

        let url = try await pool.getOrExtractMedia(
            archivePath: "/fixture/archive.zip",
            entryPath: "clip.mp4",
            uncompressedSize: Int64(payload.count),
            password: "fixture-password",
            extraction: extraction
        )
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }
    
    // MARK: - Challenge 1: 100-Way High-Concurrency Stampede on Same Entry
    
    func testHighConcurrencyStampedeOnSameEntry() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "CachePool")
        let poolDir = tempDirURL.appendingPathComponent("StampedePool", isDirectory: true)
        let pool = ArchiveMediaCachePool(
            maxQuotaBytes: 50 * 1024 * 1024,
            maxItemCount: 10,
            customRootDirectory: poolDir
        )
        
        let testPayload = Data("adversarial high concurrency media content 4K stream".utf8)
        let concurrentCalls = 100
        
        // Use an unchecked sendable collector to aggregate results
        final class ResultCollector: @unchecked Sendable {
            private var urls: [URL] = []
            private let lock = NSLock()
            
            func add(_ url: URL) {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            
            var allURLs: [URL] {
                lock.lock()
                defer { lock.unlock() }
                return urls
            }
        }
        
        let collector = ResultCollector()
        
        await withTaskGroup(of: URL?.self) { group in
            for _ in 0..<concurrentCalls {
                group.addTask {
                    do {
                        let url = try await pool.stageData(testPayload, fileName: "stampede_track.flac")
                        return url
                    } catch {
                        return nil
                    }
                }
            }
            
            for await result in group {
                if let url = result {
                    collector.add(url)
                }
            }
        }
        
        let allResults = collector.allURLs
        XCTAssertEqual(allResults.count, concurrentCalls, "All 100 concurrent tasks must complete successfully")
        
        guard let firstURL = allResults.first else {
            XCTFail("No results collected")
            return
        }
        
        // Every task must resolve to the identical valid file on disk
        for url in allResults {
            XCTAssertEqual(url.path, firstURL.path, "All tasks must share the deduplicated staged cache path")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Target cached file must exist on disk")
        }
        
        // Total cached item count must be exactly 1
        let finalItemCount = await pool.cachedItemCount
        let finalSizeBytes = await pool.totalCacheSizeBytes
        XCTAssertEqual(finalItemCount, 1, "Cache pool must contain exactly 1 entry for deduplicated resource")
        XCTAssertEqual(finalSizeBytes, Int64(testPayload.count))
    }
    
    // MARK: - Challenge 2: Multi-Threaded Concurrent Extraction of Distinct Items
    
    func testMultiThreadedConcurrentExtractionOfDistinctItems() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "CachePool")
        let poolDir = tempDirURL.appendingPathComponent("DistinctPool", isDirectory: true)
        let pool = ArchiveMediaCachePool(
            maxQuotaBytes: 100 * 1024 * 1024,
            maxItemCount: 100,
            customRootDirectory: poolDir
        )
        
        let itemCount = 50
        
        await withTaskGroup(of: (Int, URL?).self) { group in
            for i in 0..<itemCount {
                group.addTask {
                    let data = Data("payload for media item \(i) with unique content".utf8)
                    let name = "item_\(i).mp4"
                    let url = try? await pool.stageData(data, fileName: name)
                    return (i, url)
                }
            }
            
            for await (idx, url) in group {
                XCTAssertNotNil(url, "Item \(idx) extraction must succeed")
                if let u = url {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: u.path))
                    XCTAssertTrue(u.pathExtension == "mp4")
                }
            }
        }
        
        let distinctCount = await pool.cachedItemCount
        XCTAssertEqual(distinctCount, itemCount)
    }
    
    // MARK: - Challenge 3: Extreme LRU Quota Thrashing & Zero Orphan Leaks
    
    func testExtremeLRUQuotaThrashingAndZeroOrphanLeaks() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "CachePool")
        let poolDir = tempDirURL.appendingPathComponent("LRUThrashingPool", isDirectory: true)
        // Set strict budget: 2000 bytes maximum, max 4 items
        let maxQuota: Int64 = 2000
        let maxItems = 4
        let pool = ArchiveMediaCachePool(
            maxQuotaBytes: maxQuota,
            maxItemCount: maxItems,
            customRootDirectory: poolDir
        )
        
        // Concurrently insert 40 items of 400 bytes each
        let totalInserts = 40
        let itemSize = 400
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<totalInserts {
                group.addTask {
                    let chunk = Data(repeating: UInt8(i % 250 + 1), count: itemSize)
                    _ = try? await pool.stageData(chunk, fileName: "thrash_\(i).mkv")
                }
            }
        }
        
        // Assert strict invariants after storm of insertions
        let thrashCount = await pool.cachedItemCount
        let thrashSize = await pool.totalCacheSizeBytes
        XCTAssertLessThanOrEqual(thrashCount, maxItems, "Item count must strictly stay within quota (\(maxItems))")
        XCTAssertLessThanOrEqual(thrashSize, maxQuota, "Cache size must strictly stay within byte budget (\(maxQuota))")
        
        // Verify on-disk directories: all subdirectories must strictly equal active cache entries
        let subdirs = (try? FileManager.default.contentsOfDirectory(
            at: poolDir.appendingPathComponent("staged", isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        
        XCTAssertLessThanOrEqual(
            subdirs.count,
            maxItems,
            "On-disk subdirectory count (\(subdirs.count)) must not exceed max item count (\(maxItems))"
        )
        
        for dir in subdirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            XCTAssertFalse(files.isEmpty, "Existing subdirectories must contain valid media files")
        }
    }
    
    // MARK: - Challenge 4: Adversarial Zip-Slip & Path Traversal Matrix
    
    func testAdversarialZipSlipAndPathTraversalMatrix() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "CachePool")
        let poolDir = tempDirURL.appendingPathComponent("SecuritySandboxPool", isDirectory: true)
        let pool = ArchiveMediaCachePool(customRootDirectory: poolDir)
        let normalizedRoot = poolDir.standardizedFileURL.path
        
        let maliciousVectors: [(input: String, expectedExt: String)] = [
            ("../../../../../../../../../../etc/shadow.mp4", "mp4"),
            ("..\\..\\..\\windows\\system32\\calc.flac", "flac"),
            ("/private/etc/passwd.mkv", "mkv"),
            ("a/b/../../../../outside.webm", "webm"),
            ("....//....//....//escape.wav", "wav"),
            ("CON.mp4", "mp4"),
            ("NUL.wav", "wav"),
            ("AUX.flac", "flac"),
            ("COM1.avi", "avi"),
            ("LPT1.mp3", "mp3"),
            ("test\0hidden.m4a", "m4a"),
            ("movie:zone.identifier.mov", "mov"),
            ("   .mp4", "mp4"),
            ("///root///escape.ogg", "ogg"),
            ("normal_song.flac", "flac")
        ]
        
        let dummyData = Data("safe secure payload".utf8)
        
        for (vector, expectedExt) in maliciousVectors {
            let sanitized = ArchiveMediaCachePool.sanitizeFileName(vector)
            
            // 1. Sanitization checks
            XCTAssertFalse(sanitized.contains("/"), "Sanitized name must not contain forward slashes: \(sanitized)")
            XCTAssertFalse(sanitized.contains("\\"), "Sanitized name must not contain backslashes: \(sanitized)")
            XCTAssertFalse(sanitized.contains("\0"), "Sanitized name must not contain null bytes: \(sanitized)")
            XCTAssertFalse(sanitized.contains(":"), "Sanitized name must not contain colons: \(sanitized)")
            XCTAssertEqual((sanitized as NSString).pathExtension.lowercased(), expectedExt, "Sanitized name must preserve media extension")
            
            // 2. Concrete staging containment
            let stagedURL = try await pool.stageData(dummyData, fileName: vector)
            let standardPath = stagedURL.standardizedFileURL.path
            
            XCTAssertTrue(
                standardPath.hasPrefix(normalizedRoot),
                "Staged file '\(standardPath)' MUST be strictly contained inside sandbox root '\(normalizedRoot)' for input '\(vector)'"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: standardPath), "File must be created at safe location")
        }
    }
    
    // MARK: - Challenge 5: POSIX Permission Hardening Verification
    
    func testPOSIXPermissionHardening() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "CachePool")
        let poolDir = tempDirURL.appendingPathComponent("PermissionsPool", isDirectory: true)
        let pool = ArchiveMediaCachePool(customRootDirectory: poolDir)
        
        let testData = Data("strictly confidential media buffer".utf8)
        let stagedURL = try await pool.stageData(testData, fileName: "secure_audio.opus")
        
        // 1. File permissions: 0o600 (read/write owner only)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: stagedURL.path)
        let filePosix = (fileAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(filePosix, 0o600, "Media cache file permissions must be strictly 0o600 (rw-------)")
        
        // 2. Directory permissions: 0o700 (read/write/exec owner only)
        let parentDir = stagedURL.deletingLastPathComponent().path
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: parentDir)
        let dirPosix = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(dirPosix, 0o700, "Media cache directory permissions must be strictly 0o700 (rwx------)")
    }
    
    // MARK: - Challenge 6: Lifecycle Cleanup & Old Session Eviction
    
    func testLifecycleCleanupAndOldSessionEviction() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "CachePool")
        let poolDir = tempDirURL.appendingPathComponent("LifecyclePool", isDirectory: true)
        let pool = ArchiveMediaCachePool(customRootDirectory: poolDir)
        
        // 1. Create a fresh item
        let freshURL = try await pool.stageData(Data("fresh session data".utf8), fileName: "fresh.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path))
        let count1 = await pool.cachedItemCount
        XCTAssertEqual(count1, 1)
        
        // 2. Simulate an expired session folder from 48 hours ago
        let oldSessionDir = poolDir.appendingPathComponent("old_session_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: oldSessionDir, withIntermediateDirectories: true)
        let oldFile = oldSessionDir.appendingPathComponent("old_stale.mp3")
        try Data("old content".utf8).write(to: oldFile)
        
        let oldDate = Date().addingTimeInterval(-48 * 3600) // 48 hours ago
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldSessionDir.path)
        
        // 3. Run cleanupOldSessions()
        pool.cleanupOldSessions()
        
        // Old session must be deleted, fresh session must remain
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSessionDir.path), "Expired session directory must be purged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path), "Active fresh session file must remain intact")
        
        // 4. Test purgeAll()
        await pool.purgeAll()
        let count0 = await pool.cachedItemCount
        let size0 = await pool.totalCacheSizeBytes
        XCTAssertEqual(count0, 0)
        XCTAssertEqual(size0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshURL.path), "PurgeAll must physically remove all cached files")
    }
    
    // MARK: - Challenge 7: Low-Level POSIX File Descriptor Demuxing Compatibility
    
    func testLowLevelPOSIXFileDescriptorDemuxingCompatibility() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "CachePool")
        let poolDir = tempDirURL.appendingPathComponent("POSIXReadPool", isDirectory: true)
        let pool = ArchiveMediaCachePool(customRootDirectory: poolDir)
        
        let binaryHeader: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3] // Matroska/WebM EBML magic
        let payload = Data(binaryHeader + Array(repeating: UInt8(0x7F), count: 512))
        let stagedURL = try await pool.stageData(payload, fileName: "test_demux.mkv")
        
        // 1. Open with POSIX open(O_RDONLY)
        let fd = open(stagedURL.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0, "POSIX open() must succeed for CoreAudio file descriptor reading")
        defer { if fd >= 0 { close(fd) } }
        
        // 2. Read first 4 bytes via POSIX read()
        var buffer = [UInt8](repeating: 0, count: 4)
        let bytesRead = read(fd, &buffer, 4)
        XCTAssertEqual(bytesRead, 4, "POSIX read() must read exactly 4 bytes")
        XCTAssertEqual(buffer, binaryHeader, "POSIX read() bytes must match binary header exactly")
    }

    // MARK: - U2 Lease Protection & Concurrency Contracts

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

    private actor RecordedPath {
        private(set) var value: String?
        func record(_ path: String) { value = path }
    }

    private static func makeStubExtraction(payload: Data) -> ArchiveMediaCachePool.Extraction {
        ArchiveMediaCachePool.Extraction(
            toDisk: { _, entryPath, outputDirectory, _ in
                let name = ArchiveMediaCachePool.sanitizeFileName(entryPath)
                let destination = URL(fileURLWithPath: outputDirectory).appendingPathComponent(name)
                try payload.write(to: destination)
            },
            toMemory: { _, _, _ in payload }
        )
    }

    func testQuotaThrashingPreservesLeasedEntryAndReclaimsOnRelease() async throws {
        let root = try makeTemporaryDirectory(prefix: "MediaLeaseQuota")
        let pool = ArchiveMediaCachePool(
            maxQuotaBytes: 1024 * 1024,
            maxItemCount: 1,
            customRootDirectory: root.appendingPathComponent("pool", isDirectory: true)
        )
        let payloadA = Data("leased-entry-A".utf8)
        let payloadB = Data("unleased-entry-B".utf8)
        let payloadC = Data("unleased-entry-C".utf8)

        let leasedA = try await pool.acquireLeasedMedia(
            archivePath: "/fixture/quota.zip",
            entryPath: "a.mp4",
            uncompressedSize: Int64(payloadA.count),
            extraction: Self.makeStubExtraction(payload: payloadA)
        )
        let leaseCountBefore = await pool.activeLeaseCount(forKey: leasedA.lease.key)
        XCTAssertEqual(leaseCountBefore, 1, "Acquired entry must carry one active lease")

        let urlB = try await pool.getOrExtractMedia(
            archivePath: "/fixture/quota.zip",
            entryPath: "b.mp4",
            uncompressedSize: Int64(payloadB.count),
            extraction: Self.makeStubExtraction(payload: payloadB)
        )
        let urlC = try await pool.getOrExtractMedia(
            archivePath: "/fixture/quota.zip",
            entryPath: "c.mp4",
            uncompressedSize: Int64(payloadC.count),
            extraction: Self.makeStubExtraction(payload: payloadC)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: leasedA.url.path), "Leased entry A must survive quota thrashing")
        XCTAssertEqual(try Data(contentsOf: leasedA.url), payloadA, "Leased entry A bytes must remain intact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlB.path), "Unleased entry B must be evicted under maxItemCount=1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlC.path), "Most recent entry C must stay cached")

        await pool.releaseLease(leasedA.lease)

        let leaseCountAfter = await pool.activeLeaseCount(forKey: leasedA.lease.key)
        let finalCount = await pool.cachedItemCount
        XCTAssertEqual(leaseCountAfter, 0, "Released entry must hold zero leases")
        XCTAssertEqual(finalCount, 1, "Cache must converge back to maxItemCount=1 after lease release")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leasedA.url.path), "Releasing final lease must reclaim over-quota entry A")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leasedA.url.deletingLastPathComponent().path),
            "Entry A directory must be removed after reclamation"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlC.path), "Newest entry C must remain after A is reclaimed")
    }

    func testPurgeIdleEntriesPreservesLeasedEntryWhileDeletingUnleased() async throws {
        let root = try makeTemporaryDirectory(prefix: "MediaLeaseIdlePurge")
        let pool = ArchiveMediaCachePool(
            maxItemCount: 10,
            customRootDirectory: root.appendingPathComponent("pool", isDirectory: true)
        )
        let leasedPayload = Data("active-reader-bytes".utf8)
        let idlePayload1 = Data("idle-entry-1".utf8)
        let idlePayload2 = Data("idle-entry-2".utf8)

        let leased = try await pool.acquireLeasedMedia(
            archivePath: "/fixture/idle.zip",
            entryPath: "active.mp4",
            uncompressedSize: Int64(leasedPayload.count),
            extraction: Self.makeStubExtraction(payload: leasedPayload)
        )
        let idleURL1 = try await pool.getOrExtractMedia(
            archivePath: "/fixture/idle.zip",
            entryPath: "idle1.mp4",
            uncompressedSize: Int64(idlePayload1.count),
            extraction: Self.makeStubExtraction(payload: idlePayload1)
        )
        let idleURL2 = try await pool.getOrExtractMedia(
            archivePath: "/fixture/idle.zip",
            entryPath: "idle2.mp4",
            uncompressedSize: Int64(idlePayload2.count),
            extraction: Self.makeStubExtraction(payload: idlePayload2)
        )

        await pool.purgeIdleEntries(retentionRatio: 0.0)

        let countAfterIdlePurge = await pool.cachedItemCount
        XCTAssertEqual(countAfterIdlePurge, 1, "Only the leased entry must survive retentionRatio=0 idle purge")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leased.url.path), "Leased entry must remain readable")
        XCTAssertEqual(try Data(contentsOf: leased.url), leasedPayload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: idleURL1.path), "First unleased entry must be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: idleURL2.path), "Second unleased entry must be deleted")

        await pool.releaseLease(leased.lease)
        await pool.purgeIdleEntries(retentionRatio: 0.0)

        let countAfterRelease = await pool.cachedItemCount
        XCTAssertEqual(countAfterRelease, 0, "Released entry must be evicted on subsequent idle purge")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leased.url.path))
    }

    func testPurgeAllUnderConcurrentConsumerLeasesDefersDeletionUntilFinalRelease() async throws {
        let root = try makeTemporaryDirectory(prefix: "MediaLeasePurgeAll")
        let pool = ArchiveMediaCachePool(customRootDirectory: root.appendingPathComponent("pool", isDirectory: true))
        let sharedPayload = Data("shared-concurrent-media".utf8)
        let unleasedPayload = Data("ephemeral-unleased-media".utf8)

        let consumer1 = try await pool.acquireLeasedMedia(
            archivePath: "/fixture/purge.zip",
            entryPath: "shared.mp4",
            uncompressedSize: Int64(sharedPayload.count),
            extraction: Self.makeStubExtraction(payload: sharedPayload)
        )
        let consumer2 = try await pool.acquireLeasedMedia(
            archivePath: "/fixture/purge.zip",
            entryPath: "shared.mp4",
            uncompressedSize: Int64(sharedPayload.count),
            extraction: Self.makeStubExtraction(payload: sharedPayload)
        )
        let unleasedURL = try await pool.getOrExtractMedia(
            archivePath: "/fixture/purge.zip",
            entryPath: "unleased.mp4",
            uncompressedSize: Int64(unleasedPayload.count),
            extraction: Self.makeStubExtraction(payload: unleasedPayload)
        )
        XCTAssertEqual(consumer1.url, consumer2.url, "Concurrent consumers must share the cached media URL")
        let key = consumer1.lease.key
        let initialLeases = await pool.activeLeaseCount(forKey: key)
        XCTAssertEqual(initialLeases, 2)

        await pool.purgeAll()

        let countAfterPurge = await pool.cachedItemCount
        let deferredAfterPurge = await pool.pendingDeferredDeletionCount
        let leasesAfterPurge = await pool.activeLeaseCount(forKey: key)
        XCTAssertEqual(countAfterPurge, 0, "purgeAll must hide purged entries immediately from new lookups")
        XCTAssertEqual(deferredAfterPurge, 1, "Purged leased directory must enter deferred deletion queue")
        XCTAssertEqual(leasesAfterPurge, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unleasedURL.path), "Unleased entries must be deleted immediately by purgeAll")
        XCTAssertTrue(FileManager.default.fileExists(atPath: consumer1.url.path), "Leased file must remain readable after purgeAll")
        XCTAssertEqual(try Data(contentsOf: consumer1.url), sharedPayload)

        await pool.releaseLease(consumer1.lease)

        let deferredAfterFirstRelease = await pool.pendingDeferredDeletionCount
        let leasesAfterFirstRelease = await pool.activeLeaseCount(forKey: key)
        XCTAssertEqual(deferredAfterFirstRelease, 1, "Releasing consumer 1 must keep file alive for consumer 2")
        XCTAssertEqual(leasesAfterFirstRelease, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: consumer2.url.path))
        XCTAssertEqual(try Data(contentsOf: consumer2.url), sharedPayload)

        await pool.releaseLease(consumer2.lease)

        let deferredAfterFinalRelease = await pool.pendingDeferredDeletionCount
        let leasesAfterFinalRelease = await pool.activeLeaseCount(forKey: key)
        XCTAssertEqual(deferredAfterFinalRelease, 0, "Final consumer release must clear deferred deletion queue")
        XCTAssertEqual(leasesAfterFinalRelease, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: consumer2.url.path), "Final release must delete deferred file immediately")
        XCTAssertFalse(FileManager.default.fileExists(atPath: consumer2.url.deletingLastPathComponent().path))
    }

    func testPurgeAllAllowsCleanReacquisitionWhileDeferredLeaseRemainsActive() async throws {
        let root = try makeTemporaryDirectory(prefix: "MediaLeaseReacquire")
        let pool = ArchiveMediaCachePool(customRootDirectory: root.appendingPathComponent("pool", isDirectory: true))
        let oldPayload = Data("generation-0-secret".utf8)
        let newPayload = Data("generation-1-fresh".utf8)

        let oldLease = try await pool.acquireLeasedMedia(
            archivePath: "/fixture/reacquire.zip",
            entryPath: "clip.mp4",
            uncompressedSize: Int64(oldPayload.count),
            extraction: Self.makeStubExtraction(payload: oldPayload)
        )
        await pool.purgeAll()

        let newLease = try await pool.acquireLeasedMedia(
            archivePath: "/fixture/reacquire.zip",
            entryPath: "clip.mp4",
            uncompressedSize: Int64(oldPayload.count),
            extraction: Self.makeStubExtraction(payload: newPayload)
        )
        XCTAssertNotEqual(oldLease.url.path, newLease.url.path, "Post-purge extraction must isolate its directory from retired leases")
        XCTAssertEqual(try Data(contentsOf: oldLease.url), oldPayload)
        XCTAssertEqual(try Data(contentsOf: newLease.url), newPayload)

        await pool.releaseLease(oldLease.lease)

        let deferredAfterOldRelease = await pool.pendingDeferredDeletionCount
        let liveCountAfterOldRelease = await pool.cachedItemCount
        XCTAssertEqual(deferredAfterOldRelease, 0)
        XCTAssertEqual(liveCountAfterOldRelease, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLease.url.path), "Old retired directory must be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newLease.url.path), "Fresh generation directory must remain untouched")

        await pool.releaseLease(newLease.lease, reclaimImmediatelyIfIdle: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newLease.url.path))
    }

    func testMidFlightPurgeAllProtectsActiveExtractionAndDeletesOnRelease() async throws {
        let root = try makeTemporaryDirectory(prefix: "MediaLeaseMidFlight")
        let pool = ArchiveMediaCachePool(customRootDirectory: root.appendingPathComponent("pool", isDirectory: true))
        let barrier = AsyncBarrier()
        let payload = Data("slow-extraction-media-stream".utf8)
        let slowExtraction = ArchiveMediaCachePool.Extraction(
            toDisk: { _, entryPath, outputDirectory, _ in
                await barrier.markEnteredAndWaitForRelease()
                let name = ArchiveMediaCachePool.sanitizeFileName(entryPath)
                let destination = URL(fileURLWithPath: outputDirectory).appendingPathComponent(name)
                try payload.write(to: destination)
            },
            toMemory: { _, _, _ in nil }
        )

        let extractTask = Task {
            try await pool.acquireLeasedMedia(
                archivePath: "/fixture/midflight.zip",
                entryPath: "slow.mp4",
                uncompressedSize: Int64(payload.count),
                extraction: slowExtraction
            )
        }

        await barrier.waitUntilEntered()
        await pool.purgeAll()

        let countDuringPurge = await pool.cachedItemCount
        let deferredDuringPurge = await pool.pendingDeferredDeletionCount
        XCTAssertEqual(countDuringPurge, 0)
        XCTAssertEqual(deferredDuringPurge, 1, "In-flight leased extraction must be tracked as deferred deletion during purgeAll")

        await barrier.release()
        let leased = try await extractTask.value

        let countAfterExtract = await pool.cachedItemCount
        let deferredAfterExtract = await pool.pendingDeferredDeletionCount
        XCTAssertEqual(countAfterExtract, 0, "Mid-flight purged extraction must not re-enter live cache entries")
        XCTAssertEqual(deferredAfterExtract, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leased.url.path))
        XCTAssertEqual(try Data(contentsOf: leased.url), payload)

        await pool.releaseLease(leased.lease)

        let deferredAfterRelease = await pool.pendingDeferredDeletionCount
        XCTAssertEqual(deferredAfterRelease, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leased.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leased.url.deletingLastPathComponent().path))
    }

    func testVfsLoadResourceRangeSurvivesConcurrentMediaCachePurgeAll() async throws {
        await ArchiveMediaCachePool.shared.purgeAll()
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let requestedRange = 128...639
        let expectedSlice = payload.subdata(in: 128..<640)
        let barrier = AsyncBarrier()
        let recordedDir = RecordedPath()
        let provider = TTZipArchiveVfsProvider()

        await MainActor.run {
            provider.installReadAccess(.init(
                readEntry: { _, _, _ in
                    XCTFail("Leased media cache slice must succeed without falling back to full loadResource")
                    return nil
                },
                listEntrySizes: { _, _ in [] }
            ))
            provider.installMediaCacheExtraction(.init(
                toDisk: { _, entryPath, outputDirectory, _ in
                    await recordedDir.record(outputDirectory)
                    await barrier.markEnteredAndWaitForRelease()
                    let name = ArchiveMediaCachePool.sanitizeFileName(entryPath)
                    let destination = URL(fileURLWithPath: outputDirectory).appendingPathComponent(name)
                    try payload.write(to: destination)
                },
                toMemory: { _, _, _ in nil }
            ))
        }

        let archivePath = "/fixture/vfs-concurrent-\(UUID().uuidString).zip"
        let archiveId = provider.registerArchive(archivePath: archivePath)
        defer { provider.closeSession(archiveId: archiveId) }
        let uri = provider.makeVfsURL(archiveId: archiveId, entryPath: "media/clip.mp4").absoluteString

        let rangeTask = Task {
            try await provider.loadResourceRange(uri: uri, byteRange: requestedRange)
        }

        await barrier.waitUntilEntered()
        await ArchiveMediaCachePool.shared.purgeAll()
        let cachedDuringPurge = await ArchiveMediaCachePool.shared.cachedItemCount
        let deferredDuringPurge = await ArchiveMediaCachePool.shared.pendingDeferredDeletionCount
        XCTAssertEqual(cachedDuringPurge, 0)
        XCTAssertGreaterThanOrEqual(deferredDuringPurge, 1)

        await barrier.release()
        let rawResponse = try await rangeTask.value
        let response = try XCTUnwrap(rawResponse)

        XCTAssertEqual(response.data, expectedSlice, "Byte range slice must match exact expected payload bytes")
        XCTAssertEqual(response.fullSize, Int64(payload.count), "Full size must be read from open FileHandle while leased")
        XCTAssertEqual(response.mimeType, "video/mp4")

        let rawExtractedDir = await recordedDir.value
        let extractedDir = try XCTUnwrap(rawExtractedDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extractedDir), "Structured lease release must delete deferred directory before returning")
        let finalCached = await ArchiveMediaCachePool.shared.cachedItemCount
        let finalDeferred = await ArchiveMediaCachePool.shared.pendingDeferredDeletionCount
        XCTAssertEqual(finalCached, 0)
        XCTAssertEqual(finalDeferred, 0)
    }

    func testVfsLoadResourceRangePropagatesCancellationWithoutFallback() async throws {
        await ArchiveMediaCachePool.shared.purgeAll()
        let barrier = AsyncBarrier()
        let provider = TTZipArchiveVfsProvider()
        await MainActor.run {
            provider.installReadAccess(.init(
                readEntry: { _, _, _ in
                    XCTFail("Cancelled range read must not fall back to full in-memory loadResource")
                    return nil
                },
                listEntrySizes: { _, _ in [] }
            ))
            provider.installMediaCacheExtraction(.init(
                toDisk: { _, entryPath, outputDirectory, _ in
                    await barrier.markEnteredAndWaitForRelease()
                    let dst = URL(fileURLWithPath: outputDirectory).appendingPathComponent(ArchiveMediaCachePool.sanitizeFileName(entryPath))
                    try Data(repeating: 0x5A, count: 64).write(to: dst)
                },
                toMemory: { _, _, _ in nil }
            ))
        }
        let archivePath = "/fixture/vfs-cancel-\(UUID().uuidString).zip"
        let archiveId = provider.registerArchive(archivePath: archivePath)
        defer { provider.closeSession(archiveId: archiveId) }
        let uri = provider.makeVfsURL(archiveId: archiveId, entryPath: "media/cancel.mp4").absoluteString
        let rangeTask = Task { try await provider.loadResourceRange(uri: uri, byteRange: 0...15) }
        await barrier.waitUntilEntered()
        rangeTask.cancel()
        await barrier.release()
        do {
            _ = try await rangeTask.value
            XCTFail("Expected CancellationError when loadResourceRange task is cancelled mid-extraction")
        } catch is CancellationError {
            // Expected structured cancellation propagation.
        }
        let key = ArchiveMediaCachePool.computeCacheKey(archivePath: archivePath, entryPath: "media/cancel.mp4", uncompressedSize: 0, crc32: 0)
        let leasesAfterCancel = await ArchiveMediaCachePool.shared.activeLeaseCount(forKey: key)
        let deferredAfterCancel = await ArchiveMediaCachePool.shared.pendingDeferredDeletionCount
        XCTAssertEqual(leasesAfterCancel, 0)
        XCTAssertEqual(deferredAfterCancel, 0)
    }
}
