// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

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
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveMediaAdversarial_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Challenge 1: 100-Way High-Concurrency Stampede on Same Entry
    
    func testHighConcurrencyStampedeOnSameEntry() async throws {
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
                        let url = try pool.stageData(testPayload, fileName: "stampede_track.flac")
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
        XCTAssertEqual(pool.cachedItemCount, 1, "Cache pool must contain exactly 1 entry for deduplicated resource")
        XCTAssertEqual(pool.totalCacheSizeBytes, Int64(testPayload.count))
    }
    
    // MARK: - Challenge 2: Multi-Threaded Concurrent Extraction of Distinct Items
    
    func testMultiThreadedConcurrentExtractionOfDistinctItems() async throws {
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
                    let url = try? pool.stageData(data, fileName: name)
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
        
        XCTAssertEqual(pool.cachedItemCount, itemCount)
    }
    
    // MARK: - Challenge 3: Extreme LRU Quota Thrashing & Zero Orphan Leaks
    
    func testExtremeLRUQuotaThrashingAndZeroOrphanLeaks() throws {
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
        
        let group = DispatchGroup()
        for i in 0..<totalInserts {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let chunk = Data(repeating: UInt8(i % 250 + 1), count: itemSize)
                _ = try? pool.stageData(chunk, fileName: "thrash_\(i).mkv")
                group.leave()
            }
        }
        group.wait()
        
        // Assert strict invariants after storm of insertions
        XCTAssertLessThanOrEqual(pool.cachedItemCount, maxItems, "Item count must strictly stay within quota (\(maxItems))")
        XCTAssertLessThanOrEqual(pool.totalCacheSizeBytes, maxQuota, "Cache size must strictly stay within byte budget (\(maxQuota))")
        
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
    
    func testAdversarialZipSlipAndPathTraversalMatrix() throws {
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
            let stagedURL = try pool.stageData(dummyData, fileName: vector)
            let standardPath = stagedURL.standardizedFileURL.path
            
            XCTAssertTrue(
                standardPath.hasPrefix(normalizedRoot),
                "Staged file '\(standardPath)' MUST be strictly contained inside sandbox root '\(normalizedRoot)' for input '\(vector)'"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: standardPath), "File must be created at safe location")
        }
    }
    
    // MARK: - Challenge 5: POSIX Permission Hardening Verification
    
    func testPOSIXPermissionHardening() throws {
        let poolDir = tempDirURL.appendingPathComponent("PermissionsPool", isDirectory: true)
        let pool = ArchiveMediaCachePool(customRootDirectory: poolDir)
        
        let testData = Data("strictly confidential media buffer".utf8)
        let stagedURL = try pool.stageData(testData, fileName: "secure_audio.opus")
        
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
    
    func testLifecycleCleanupAndOldSessionEviction() throws {
        let poolDir = tempDirURL.appendingPathComponent("LifecyclePool", isDirectory: true)
        let pool = ArchiveMediaCachePool(customRootDirectory: poolDir)
        
        // 1. Create a fresh item
        let freshURL = try pool.stageData(Data("fresh session data".utf8), fileName: "fresh.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path))
        XCTAssertEqual(pool.cachedItemCount, 1)
        
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
        pool.purgeAll()
        XCTAssertEqual(pool.cachedItemCount, 0)
        XCTAssertEqual(pool.totalCacheSizeBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshURL.path), "PurgeAll must physically remove all cached files")
    }
    
    // MARK: - Challenge 7: Low-Level POSIX File Descriptor Demuxing Compatibility
    
    func testLowLevelPOSIXFileDescriptorDemuxingCompatibility() throws {
        let poolDir = tempDirURL.appendingPathComponent("POSIXReadPool", isDirectory: true)
        let pool = ArchiveMediaCachePool(customRootDirectory: poolDir)
        
        let binaryHeader: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3] // Matroska/WebM EBML magic
        let payload = Data(binaryHeader + Array(repeating: UInt8(0x7F), count: 512))
        let stagedURL = try pool.stageData(payload, fileName: "test_demux.mkv")
        
        // 1. Open with POSIX open(O_RDONLY)
        let fd = open(stagedURL.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0, "POSIX open() must succeed for libmpv / CoreAudio file descriptor reading")
        defer { if fd >= 0 { close(fd) } }
        
        // 2. Read first 4 bytes via POSIX read()
        var buffer = [UInt8](repeating: 0, count: 4)
        let bytesRead = read(fd, &buffer, 4)
        XCTAssertEqual(bytesRead, 4, "POSIX read() must read exactly 4 bytes")
        XCTAssertEqual(buffer, binaryHeader, "POSIX read() bytes must match binary header exactly")
    }
}
