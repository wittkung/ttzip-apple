// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
@testable import TTMediaKit

final class TTMediaVideoAndServicesTests: XCTestCase {
    
    // MARK: - TTMediaTheme Verification
    
    func testTTMediaThemeTokens() {
        XCTAssertNotNil(TTMediaTheme.kintsugiGold)
        XCTAssertNotNil(TTMediaTheme.bambooGreen)
        XCTAssertNotNil(TTMediaTheme.cinnabarRed)
        XCTAssertNotNil(TTMediaTheme.archiveAmber)
        XCTAssertNotNil(TTMediaTheme.hairlineBorder)
        
        XCTAssertEqual(TTMediaTheme.Radius.xs, 4)
        XCTAssertEqual(TTMediaTheme.Radius.sm, 6)
        XCTAssertEqual(TTMediaTheme.Radius.md, 10)
        XCTAssertEqual(TTMediaTheme.Radius.lg, 14)
        XCTAssertEqual(TTMediaTheme.Radius.xl, 18)
        
        XCTAssertNotNil(Animation.ttMicro)
        XCTAssertNotNil(Animation.ttLayout)
        XCTAssertNotNil(Animation.ttSnap)
        XCTAssertNotNil(Animation.ttSheet)
    }
    
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
}
