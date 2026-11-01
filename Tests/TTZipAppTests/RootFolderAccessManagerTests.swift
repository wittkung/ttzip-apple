// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
@testable import TTZipCore
@testable import TTZipApp

final class RootFolderAccessManagerTests: XCTestCase {
    
    private let testBookmarksKey = "TTZipSecurityScopedBookmarksKey"
    
    @MainActor
    func test_canonical_directory_url_preserves_home_subdirectory_path() {
        let manager = RootFolderAccessManager.shared
        let homeURL = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath()
        let subURL = homeURL.appendingPathComponent("Downloads/Sub")
        
        let canonical = manager.canonicalDirectoryURL(for: subURL)
        XCTAssertEqual(canonical.path, subURL.path)
        XCTAssertNotEqual(canonical.path, homeURL.path)
        XCTAssertNotEqual(canonical.path, "/")
    }
    
    @MainActor
    func test_canonical_directory_url_preserves_external_volume_subdirectory_path() {
        let manager = RootFolderAccessManager.shared
        let volumeSubURL = URL(fileURLWithPath: "/Volumes/BackupDrive/Archives/2026")
        
        let canonical = manager.canonicalDirectoryURL(for: volumeSubURL)
        XCTAssertEqual(canonical.path, volumeSubURL.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertNotEqual(canonical.path, "/Volumes/BackupDrive")
        XCTAssertNotEqual(canonical.path, "/")
    }
    
    @MainActor
    func test_canonical_directory_url_preserves_system_paths_without_escalation() {
        let manager = RootFolderAccessManager.shared
        let appSupportURL = URL(fileURLWithPath: "/Library/Application Support")
        
        let canonical = manager.canonicalDirectoryURL(for: appSupportURL)
        XCTAssertEqual(canonical.path, appSupportURL.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertNotEqual(canonical.path, "/")
    }
    
    @MainActor
    func test_offline_bookmark_retention_across_restore_cycles() {
        let manager = RootFolderAccessManager.shared
        
        // Backup any existing UserDefaults bookmark payload
        let originalPayload = UserDefaults.standard.data(forKey: testBookmarksKey)
        defer {
            if let original = originalPayload {
                UserDefaults.standard.set(original, forKey: testBookmarksKey)
            } else {
                UserDefaults.standard.removeObject(forKey: testBookmarksKey)
            }
            manager.restoreBookmarks()
        }
        
        // Construct a mock dictionary containing an unresolved dummy bookmark representing an offline disk
        let dummyOfflineData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        let offlineVolumePath = "/Volumes/OfflineHardDrive"
        let mockDict: [String: Data] = [offlineVolumePath: dummyOfflineData]
        
        guard let encoded = try? PropertyListEncoder().encode(mockDict) else {
            XCTFail("Failed to encode mock bookmark payload")
            return
        }
        UserDefaults.standard.set(encoded, forKey: testBookmarksKey)
        
        // Invoke restoreBookmarks: resolving dummy data will fail (offline volume)
        manager.restoreBookmarks()
        
        // Verify that the offline bookmark was NOT wiped out from UserDefaults
        guard let persistedData = UserDefaults.standard.data(forKey: testBookmarksKey),
              let restoredDict = try? PropertyListDecoder().decode([String: Data].self, from: persistedData) else {
            XCTFail("UserDefaults was wiped or unreadable after restoreBookmarks()")
            return
        }
        
        XCTAssertEqual(
            restoredDict[offlineVolumePath],
            dummyOfflineData,
            "Offline volume bookmark must be retained across restoreBookmarks() cycles"
        )
    }
    
    @MainActor
    func test_revoke_all_access_cleans_bookmarks() {
        let manager = RootFolderAccessManager.shared
        
        let originalPayload = UserDefaults.standard.data(forKey: testBookmarksKey)
        defer {
            if let original = originalPayload {
                UserDefaults.standard.set(original, forKey: testBookmarksKey)
            } else {
                UserDefaults.standard.removeObject(forKey: testBookmarksKey)
            }
            manager.restoreBookmarks()
        }
        
        let dummyData = Data([0x01, 0x02, 0x03, 0x04])
        let dict = ["/Volumes/TemporaryTestDrive": dummyData]
        if let encoded = try? PropertyListEncoder().encode(dict) {
            UserDefaults.standard.set(encoded, forKey: testBookmarksKey)
        }
        manager.restoreBookmarks()
        
        manager.revokeAllAccess()
        
        XCTAssertNil(UserDefaults.standard.data(forKey: testBookmarksKey))
    }

    @MainActor
    func test_parent_bookmark_child_leases_balance_to_zero() throws {
        let manager = RootFolderAccessManager.shared
        let originalPayload = UserDefaults.standard.data(forKey: testBookmarksKey)
        defer {
            if let original = originalPayload {
                UserDefaults.standard.set(original, forKey: testBookmarksKey)
            } else {
                UserDefaults.standard.removeObject(forKey: testBookmarksKey)
            }
            manager.restoreBookmarks()
        }
        manager.revokeAllAccess()

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipLeaseTest_\(UUID().uuidString)", isDirectory: true)
        let subDirB = tempRoot.appendingPathComponent("B", isDirectory: true)
        let subDirC = tempRoot.appendingPathComponent("C/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: subDirB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subDirC, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let child1 = subDirB.appendingPathComponent("archive1.zip")
        let child2 = subDirC.appendingPathComponent("archive2.zip")
        let child3 = subDirC.appendingPathComponent("archive3.zip")
        try Data("zip1".utf8).write(to: child1)
        try Data("zip2".utf8).write(to: child2)
        try Data("zip3".utf8).write(to: child3)

        let canonicalRoot = manager.canonicalDirectoryURL(for: tempRoot)
        XCTAssertNotNil(manager.persistBookmark(for: canonicalRoot))
        XCTAssertEqual(
            manager.activeLeaseCount(for: canonicalRoot),
            0,
            "Persisting bookmark alone must not increment activeLeaseCount"
        )

        guard let lease1 = manager.acquireLease(for: child1),
              let lease2 = manager.acquireLease(for: child2),
              let lease3 = manager.acquireLease(for: child3) else {
            XCTFail("Expected child leases under bookmarked parent directory to succeed")
            return
        }

        XCTAssertEqual(lease1.leaseKey, canonicalRoot.path)
        XCTAssertEqual(lease2.leaseKey, canonicalRoot.path)
        XCTAssertEqual(lease3.leaseKey, canonicalRoot.path)
        XCTAssertEqual(lease1.url.path, manager.canonicalDirectoryURL(for: child1).path)
        XCTAssertEqual(manager.canonicalDirectoryURL(for: lease1.activatedURL).path, canonicalRoot.path)
        XCTAssertTrue(lease1.ownsSecurityScope)
        XCTAssertEqual(manager.activeLeaseCount(for: canonicalRoot), 3)
        XCTAssertEqual(manager.activeLeaseCount(forKey: canonicalRoot.path), 3)

        // Idempotent release of lease1
        lease1.release()
        lease1.release()
        XCTAssertTrue(lease1.isReleased)
        XCTAssertEqual(manager.activeLeaseCount(for: canonicalRoot), 2)

        lease2.release()
        XCTAssertEqual(manager.activeLeaseCount(for: canonicalRoot), 1)

        lease3.release()
        XCTAssertEqual(manager.activeLeaseCount(for: canonicalRoot), 0)
        XCTAssertEqual(manager.totalActiveLeaseCount, 0)

        // Unaccessible nonexistent external path must return nil and leave zero count
        let missingURL = tempRoot.appendingPathComponent("nonexistent_outside_\(UUID().uuidString).zip")
        manager.revokeAccess(for: canonicalRoot)
        XCTAssertNil(manager.acquireLease(for: missingURL))
        XCTAssertEqual(manager.totalActiveLeaseCount, 0)
    }

    @MainActor
    func test_repeated_ensure_access_does_not_leak_active_leases() async throws {
        let manager = RootFolderAccessManager.shared
        let originalPayload = UserDefaults.standard.data(forKey: testBookmarksKey)
        defer {
            if let original = originalPayload {
                UserDefaults.standard.set(original, forKey: testBookmarksKey)
            } else {
                UserDefaults.standard.removeObject(forKey: testBookmarksKey)
            }
            manager.restoreBookmarks()
        }
        manager.revokeAllAccess()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipEnsureAccessTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let childFile = tempDir.appendingPathComponent("nested.zip")
        try Data("payload".utf8).write(to: childFile)
        _ = manager.persistBookmark(for: tempDir)

        for _ in 0..<25 {
            let syncParent: Bool = { manager.ensureAccess(for: tempDir) }()
            let syncChild: Bool = { manager.ensureAccess(for: childFile) }()
            XCTAssertTrue(syncParent)
            XCTAssertTrue(syncChild)
            let asyncParent = await manager.ensureAccess(for: tempDir)
            let asyncChild = await manager.ensureAccess(for: childFile)
            XCTAssertTrue(asyncParent)
            XCTAssertTrue(asyncChild)
        }

        XCTAssertEqual(
            manager.activeLeaseCount(for: tempDir),
            0,
            "Repeated ensureAccess calls must never accumulate unreleased lease counts"
        )
        XCTAssertEqual(manager.totalActiveLeaseCount, 0)
    }

    @MainActor
    func test_task_cancellation_and_repeated_open_close_lease_balance() async throws {
        let manager = RootFolderAccessManager.shared
        let originalPayload = UserDefaults.standard.data(forKey: testBookmarksKey)
        defer {
            if let original = originalPayload {
                UserDefaults.standard.set(original, forKey: testBookmarksKey)
            } else {
                UserDefaults.standard.removeObject(forKey: testBookmarksKey)
            }
            manager.restoreBookmarks()
        }
        manager.revokeAllAccess()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipCancelBalance_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleTxt = tempDir.appendingPathComponent("hello.txt")
        try "Hello TTZip".write(to: sampleTxt, atomically: true, encoding: .utf8)
        let zipURL = tempDir.appendingPathComponent("sample.zip")
        try await ArchiveWriter().createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [sampleTxt.path]
        )

        _ = manager.persistBookmark(for: tempDir)
        let sut = AppViewState(fileViewer: NoOpFileViewer())

        // Repeated open, cancel, and complete cycles
        for idx in 0..<10 {
            let task = sut.openArchive(at: zipURL)
            if idx % 2 == 0 {
                task.cancel()
            }
            _ = await task.value
            sut.closeCurrentArchive()
        }

        XCTAssertEqual(
            manager.activeLeaseCount(for: tempDir),
            0,
            "All leases must be balanced to 0 after repeated open/cancel/close cycles"
        )
        XCTAssertEqual(manager.totalActiveLeaseCount, 0)
    }

    @MainActor
    func test_active_bookmark_session_survives_async_intent_and_invalidates_on_completion() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipBookmarkSession_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleTxt = tempDir.appendingPathComponent("note.txt")
        try "Bookmark session test".write(to: sampleTxt, atomically: true, encoding: .utf8)
        let zipURL = tempDir.appendingPathComponent("session_test.zip")
        try await ArchiveWriter().createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [sampleTxt.path]
        )

        let sut = AppViewState(fileViewer: NoOpFileViewer())
        let scope = SecurityScopedResourceScope()
        scope.add(zipURL, isSecurityScoped: false)

        let invalidateExpectation = expectation(description: "ActiveBookmarkSession invalidated after async openArchive")
        let session = ActiveBookmarkSession(scope: scope) {
            invalidateExpectation.fulfill()
        }
        XCTAssertFalse(session.isInvalidated)

        let openTask = sut.openArchive(at: zipURL, bookmarkSession: session)
        let loaded = await openTask.value
        XCTAssertTrue(loaded)
        await fulfillment(of: [invalidateExpectation], timeout: 2.0)
        XCTAssertTrue(session.isInvalidated)
        XCTAssertTrue(scope.isCleanedUp)

        // Verify deinit fallback invalidates an un-invalidated session
        let deinitExpectation = expectation(description: "ActiveBookmarkSession deinit fallback")
        do {
            let ephemeralSession = ActiveBookmarkSession {
                deinitExpectation.fulfill()
            }
            XCTAssertFalse(ephemeralSession.isInvalidated)
        }
        await fulfillment(of: [deinitExpectation], timeout: 1.0)
    }

    @MainActor
    func test_recent_archive_retained_when_inaccessible_and_reauthorized_on_open() async throws {
        let manager = RootFolderAccessManager.shared
        let recentKey = "TTZipRecentArchivesKey"
        let originalBookmarks = UserDefaults.standard.data(forKey: testBookmarksKey)
        let originalRecents = UserDefaults.standard.data(forKey: recentKey)
        defer {
            manager.authorizationPromptHandler = nil
            if let originalBookmarks {
                UserDefaults.standard.set(originalBookmarks, forKey: testBookmarksKey)
            } else {
                UserDefaults.standard.removeObject(forKey: testBookmarksKey)
            }
            if let originalRecents {
                UserDefaults.standard.set(originalRecents, forKey: recentKey)
            } else {
                UserDefaults.standard.removeObject(forKey: recentKey)
            }
            manager.restoreBookmarks()
        }
        manager.revokeAllAccess()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipRecentRetention_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleTxt = tempDir.appendingPathComponent("doc.txt")
        try "Recent archive content".write(to: sampleTxt, atomically: true, encoding: .utf8)
        let zipURL = tempDir.appendingPathComponent("recent.zip")
        try await ArchiveWriter().createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [sampleTxt.path]
        )

        // 1. Seed storage with both an inaccessible/unmounted path and our local archive
        let offlinePath = "/Volumes/UnmountedDrive_\(UUID().uuidString)/offline_backup.zip"
        let initialState = AppViewState(fileViewer: NoOpFileViewer())
        initialState.recordRecentArchive(url: zipURL)
        var seededRecords = initialState.recentArchives
        seededRecords.append(RecentArchiveRecord(path: offlinePath))
        let encodedRecents = try JSONEncoder().encode(seededRecords)
        UserDefaults.standard.set(encodedRecents, forKey: recentKey)

        // 2. Simulate restart: loadRecentArchivesFromStorage must NOT purge the inaccessible path
        let restartedState = AppViewState(fileViewer: NoOpFileViewer())
        XCTAssertTrue(
            restartedState.recentArchives.contains(where: { $0.path == offlinePath }),
            "Inaccessible recent archive record must be preserved across restarts"
        )
        XCTAssertTrue(
            restartedState.recentArchives.contains(where: { $0.path == zipURL.path }),
            "Valid recent archive record must be preserved with bookmarkData"
        )

        // 3. Simulate sandbox permission expiration (chmod 000) and verify re-authorization flow
        _ = chmod(zipURL.path, 0)
        defer { _ = chmod(zipURL.path, mode_t(0o644)) }

        if !FileManager.default.isReadableFile(atPath: zipURL.path) {
            var promptedURL: URL?
            manager.authorizationPromptHandler = { suggestedURL, _ in
                promptedURL = suggestedURL
                _ = chmod(zipURL.path, mode_t(0o644))
                return suggestedURL
            }

            let success = await restartedState.openArchive(at: zipURL).value
            XCTAssertTrue(success, "Archive must open after user grants re-authorization")
            XCTAssertEqual(
                promptedURL?.path,
                manager.canonicalDirectoryURL(for: zipURL.deletingLastPathComponent()).path,
                "Re-authorization must suggest the archive's parent directory"
            )
            XCTAssertTrue(
                restartedState.recentArchives.contains(where: { $0.path == zipURL.path }),
                "Recent archive record must never be deleted when temporarily unreadable"
            )
        }
    }
}
