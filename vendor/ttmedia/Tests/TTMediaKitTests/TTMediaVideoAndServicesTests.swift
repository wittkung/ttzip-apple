// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
@testable import TTMediaKit

final class TTMediaVideoAndServicesTests: XCTestCase {
    
    // MARK: - AutoSeriesMatcher Verification
    
    func testAutoSeriesMatcherParsing() {
        let matcher = AutoSeriesMatcher.shared
        
        // Standard S01E02
        let url1 = URL(fileURLWithPath: "/media/Shows/Breaking.Bad.S01E02.1080p.mkv")
        let ep1 = matcher.parseEpisode(from: url1)
        XCTAssertNotNil(ep1)
        XCTAssertEqual(ep1?.seasonNumber, 1)
        XCTAssertEqual(ep1?.episodeNumber, 2)
        
        // 2x05 format
        let url2 = URL(fileURLWithPath: "/media/Shows/Sherlock.2x05.mp4")
        let ep2 = matcher.parseEpisode(from: url2)
        XCTAssertNotNil(ep2)
        XCTAssertEqual(ep2?.seasonNumber, 2)
        XCTAssertEqual(ep2?.episodeNumber, 5)
        
        // EP08 format
        let url3 = URL(fileURLWithPath: "/media/Anime/Show.EP08.mkv")
        let ep3 = matcher.parseEpisode(from: url3)
        XCTAssertNotNil(ep3)
        XCTAssertEqual(ep3?.episodeNumber, 8)
        
        // Chinese 第12集
        let url4 = URL(fileURLWithPath: "/media/Drama/三国演义.第12集.mp4")
        let ep4 = matcher.parseEpisode(from: url4)
        XCTAssertNotNil(ep4)
        XCTAssertEqual(ep4?.episodeNumber, 12)
        
        // Brackets [06]
        let url5 = URL(fileURLWithPath: "/media/Anime/[Group] Frieren [06] [1080p].mkv")
        let ep5 = matcher.parseEpisode(from: url5)
        XCTAssertNotNil(ep5)
        XCTAssertEqual(ep5?.episodeNumber, 6)
    }
    
    // MARK: - MediaPlaylistStore Verification
    
    @MainActor
    func testMediaPlaylistStoreWorkflow() {
        let store = MediaPlaylistStore()
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.count, 0)
        
        let urlA = URL(fileURLWithPath: "/tmp/video_ep1.mp4")
        let urlB = URL(fileURLWithPath: "/tmp/video_ep2.mp4")
        let urlC = URL(fileURLWithPath: "/tmp/video_ep3.mp4")
        
        store.populate(from: urlB, allSiblings: [urlC, urlA, urlB])
        
        XCTAssertEqual(store.count, 3)
        XCTAssertFalse(store.isEmpty)
        XCTAssertEqual(store.currentIndex, 1) // Naturally sorted: ep1 (0), ep2 (1), ep3 (2)
        XCTAssertEqual(store.currentItem?.url.lastPathComponent, "video_ep2.mp4")
        
        // Next track
        let nextItem = store.playNext()
        XCTAssertNotNil(nextItem)
        XCTAssertEqual(nextItem?.url.lastPathComponent, "video_ep3.mp4")
        XCTAssertEqual(store.currentIndex, 2)
        
        // At end with repeatMode = .off
        store.repeatMode = .off
        let afterEnd = store.playNext()
        XCTAssertNil(afterEnd)
        
        // With repeatMode = .all
        store.repeatMode = .all
        let loopedItem = store.playNext()
        XCTAssertNotNil(loopedItem)
        XCTAssertEqual(loopedItem?.url.lastPathComponent, "video_ep1.mp4")
        XCTAssertEqual(store.currentIndex, 0)
    }
    
    // MARK: - GIFExportOptions Verification
    
    func testGIFExportOptionsBounds() {
        let defaultOpts = GIFExportOptions()
        XCTAssertEqual(defaultOpts.fps, 15)
        XCTAssertEqual(defaultOpts.width, 480)
        XCTAssertTrue(defaultOpts.dither)
        
        // Clamping check
        let clampedLow = GIFExportOptions(fps: 2, width: 100, dither: false)
        XCTAssertEqual(clampedLow.fps, 10)
        XCTAssertEqual(clampedLow.width, 320)
        XCTAssertFalse(clampedLow.dither)
        
        let clampedHigh = GIFExportOptions(fps: 120, width: 2560, dither: true)
        XCTAssertEqual(clampedHigh.fps, 30)
        XCTAssertEqual(clampedHigh.width, 720)
    }
    
    // MARK: - RemoteCommandCoordinator Verification
    
    @MainActor
    func testRemoteCommandCoordinatorSetup() {
        let coordinator = TTRemoteCommandCoordinator.shared
        var playCalled = false
        var pauseCalled = false
        
        coordinator.setupRemoteCommands(
            playHandler: { playCalled = true },
            pauseHandler: { pauseCalled = true }
        )
        
        XCTAssertNotNil(coordinator.playHandler)
        XCTAssertNotNil(coordinator.pauseHandler)
        
        coordinator.playHandler?()
        XCTAssertTrue(playCalled)
        
        coordinator.pauseHandler?()
        XCTAssertTrue(pauseCalled)
        
        coordinator.disableCommands()
    }

    @MainActor
    func testGIFExportCancelledOperationCleanupDoesNotDeleteReplacementStagingOrState() throws {
        let manager = GIFExportManager.shared
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFExportScopeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stageA = tempDir.appendingPathComponent("a.gif.staging")
        let stageB = tempDir.appendingPathComponent("b.gif.staging")
        try Data("stage-a".utf8).write(to: stageA)
        try Data("stage-b".utf8).write(to: stageB)

        let opA = UUID()
        let opB = UUID()
        manager.beginOperationForTesting(operationID: opB, stagingURL: stageB)

        // Late unwinding cleanup from cancelled operation A must remove stageA only and leave opB untouched
        manager.cleanupPartialAndReset(stagingURL: stageA, operationID: opA)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stageA.path), "Operation A's own staging file must be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stageB.path), "Operation B's active staging file must NOT be deleted by A")
        XCTAssertTrue(manager.isExporting, "Operation B must remain active when stale operation A unwinds")

        // Cleanup for the active operation B removes stageB and resets state
        manager.cleanupPartialAndReset(stagingURL: stageB, operationID: opB)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stageB.path))
        XCTAssertFalse(manager.isExporting)
    }
}
