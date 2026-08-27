// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import Foundation
@testable import TTZipApp

@MainActor
final class MediaPlaylistStoreTests: XCTestCase {
    
    nonisolated(unsafe) private var tempDirectory: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipPlaylistTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let dir = tempDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Test 1: Sibling Discovery & Natural Alphanumeric Sorting
    
    func testSiblingDiscoveryAndNaturalSorting() {
        let store = MediaPlaylistStore()
        
        let urls = [
            URL(fileURLWithPath: "/media/Episode 10.mp4"),
            URL(fileURLWithPath: "/media/Episode 2.mkv"),
            URL(fileURLWithPath: "/media/Episode 1.mp4"),
            URL(fileURLWithPath: "/media/Episode 20.ts"),
            URL(fileURLWithPath: "/media/readme.txt"),
            URL(fileURLWithPath: "/media/poster.jpg"),
            URL(fileURLWithPath: "/media/audio_track.flac"),
            URL(fileURLWithPath: "/media/bonus.avi")
        ]
        
        let currentURL = URL(fileURLWithPath: "/media/Episode 2.mkv")
        store.populate(from: currentURL, allSiblings: urls)
        
        XCTAssertEqual(store.count, 6, "Should only include supported video and audio extensions (excluding .txt and .jpg)")
        
        let titles = store.items.map(\.title)
        let expectedTitles = [
            "audio_track",
            "bonus",
            "Episode 1",
            "Episode 2",
            "Episode 10",
            "Episode 20"
        ]
        XCTAssertEqual(titles, expectedTitles, "Media items must be sorted naturally using localizedStandardCompare")
        
        XCTAssertEqual(store.currentIndex, 3)
        XCTAssertEqual(store.currentItem?.title, "Episode 2")
        XCTAssertTrue(store.currentItem?.isCurrent == true)
        XCTAssertEqual(store.currentItem?.format, "mkv")
    }
    
    // MARK: - Test 2: File System Directory Scan
    
    func testDirectoryScanPopulation() throws {
        let fileNames = [
            "Track 03.flac",
            "Track 01.mp3",
            "Track 02.wav",
            "notes.docx",
            "album_art.png"
        ]
        
        for name in fileNames {
            let fileURL = tempDirectory.appendingPathComponent(name)
            try Data("dummy media payload".utf8).write(to: fileURL)
        }
        
        let store = MediaPlaylistStore()
        let initialURL = tempDirectory.appendingPathComponent("Track 01.mp3")
        
        store.populate(from: initialURL)
        
        XCTAssertEqual(store.count, 3, "Only the 3 audio files should be populated from directory")
        XCTAssertEqual(store.items[0].title, "Track 01")
        XCTAssertEqual(store.items[1].title, "Track 02")
        XCTAssertEqual(store.items[2].title, "Track 03")
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(store.currentItem?.url.standardizedFileURL.path, initialURL.standardizedFileURL.path)
    }
    
    // MARK: - Test 3: Track Navigation in Repeat Off Mode
    
    func testNavigationRepeatOffMode() {
        let store = MediaPlaylistStore()
        let urls = [
            URL(fileURLWithPath: "/media/Track1.mp3"),
            URL(fileURLWithPath: "/media/Track2.mp3"),
            URL(fileURLWithPath: "/media/Track3.mp3")
        ]
        
        store.populate(from: urls[0], allSiblings: urls)
        store.repeatMode = .off
        
        XCTAssertTrue(store.hasNext)
        XCTAssertFalse(store.hasPrevious)
        XCTAssertEqual(store.currentIndex, 0)
        
        // Advance to next track
        let next1 = store.playNext()
        XCTAssertEqual(next1?.title, "Track2")
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertTrue(store.hasNext)
        XCTAssertTrue(store.hasPrevious)
        
        // Advance to last track
        let next2 = store.playNext()
        XCTAssertEqual(next2?.title, "Track3")
        XCTAssertEqual(store.currentIndex, 2)
        XCTAssertFalse(store.hasNext)
        XCTAssertTrue(store.hasPrevious)
        
        // Attempting to advance past last track returns nil
        let next3 = store.playNext()
        XCTAssertNil(next3)
        XCTAssertEqual(store.currentIndex, 2)
        
        // Go back
        let prev1 = store.playPrevious()
        XCTAssertEqual(prev1?.title, "Track2")
        XCTAssertEqual(store.currentIndex, 1)
        
        let prev2 = store.playPrevious()
        XCTAssertEqual(prev2?.title, "Track1")
        XCTAssertEqual(store.currentIndex, 0)
        
        // Attempting to go before first track returns nil
        let prev3 = store.playPrevious()
        XCTAssertNil(prev3)
        XCTAssertEqual(store.currentIndex, 0)
    }
    
    // MARK: - Test 4: Repeat All Mode (Looping)
    
    func testNavigationRepeatAllMode() {
        let store = MediaPlaylistStore()
        let urls = [
            URL(fileURLWithPath: "/media/Track1.mp3"),
            URL(fileURLWithPath: "/media/Track2.mp3")
        ]
        
        store.populate(from: urls[0], allSiblings: urls)
        store.repeatMode = .all
        
        XCTAssertTrue(store.hasNext)
        XCTAssertTrue(store.hasPrevious)
        
        // Advance to Track 2
        _ = store.playNext()
        XCTAssertEqual(store.currentIndex, 1)
        
        // Next wraps around to Track 1
        let loopedNext = store.playNext()
        XCTAssertEqual(loopedNext?.title, "Track1")
        XCTAssertEqual(store.currentIndex, 0)
        
        // Previous wraps back to Track 2
        let loopedPrev = store.playPrevious()
        XCTAssertEqual(loopedPrev?.title, "Track2")
        XCTAssertEqual(store.currentIndex, 1)
    }
    
    // MARK: - Test 5: Repeat One Mode
    
    func testNavigationRepeatOneMode() {
        let store = MediaPlaylistStore()
        let urls = [
            URL(fileURLWithPath: "/media/Track1.mp3"),
            URL(fileURLWithPath: "/media/Track2.mp3")
        ]
        
        store.populate(from: urls[1], allSiblings: urls)
        store.repeatMode = .one
        
        XCTAssertTrue(store.hasNext)
        XCTAssertTrue(store.hasPrevious)
        
        let next = store.playNext()
        XCTAssertEqual(next?.title, "Track2", "Repeat one should re-select current item")
        XCTAssertEqual(store.currentIndex, 1)
        
        let prev = store.playPrevious()
        XCTAssertEqual(prev?.title, "Track2", "Repeat one should re-select current item")
        XCTAssertEqual(store.currentIndex, 1)
    }
    
    // MARK: - Test 6: Repeat Mode Toggling
    
    func testRepeatModeToggle() {
        var mode: PlaylistRepeatMode = .off
        XCTAssertEqual(mode.title, "Repeat Off")
        
        mode.toggle()
        XCTAssertEqual(mode, .all)
        XCTAssertEqual(mode.title, "Repeat All")
        
        mode.toggle()
        XCTAssertEqual(mode, .one)
        XCTAssertEqual(mode.title, "Repeat Current")
        
        mode.toggle()
        XCTAssertEqual(mode, .off)
    }
    
    // MARK: - Test 7: Auto-Playback & End-of-Playback Flow
    
    func testHandlePlaybackEnded() {
        let store = MediaPlaylistStore()
        let urls = [
            URL(fileURLWithPath: "/media/Video1.mp4"),
            URL(fileURLWithPath: "/media/Video2.mp4")
        ]
        
        var requestedItem: PlaylistItem? = nil
        store.onPlayItemRequested = { item in
            requestedItem = item
        }
        
        store.populate(from: urls[0], allSiblings: urls)
        store.repeatMode = .off
        store.isAutoPlayEnabled = true
        
        // 1. Playback ended on Video1 -> should auto advance to Video2
        let nextItem = store.handlePlaybackEnded()
        XCTAssertEqual(nextItem?.title, "Video2")
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(requestedItem?.title, "Video2")
        
        // 2. Playback ended on Video2 (end of playlist, repeat off) -> should return nil
        let endedNil = store.handlePlaybackEnded()
        XCTAssertNil(endedNil)
        XCTAssertEqual(store.currentIndex, 1)
        
        // 3. Repeat One test
        store.repeatMode = .one
        requestedItem = nil
        let repeatedItem = store.handlePlaybackEnded()
        XCTAssertEqual(repeatedItem?.title, "Video2")
        XCTAssertEqual(requestedItem?.title, "Video2")
        
        // 4. AutoPlay disabled test
        store.isAutoPlayEnabled = false
        let disabledResult = store.handlePlaybackEnded()
        XCTAssertNil(disabledResult)
    }
    
    // MARK: - Test 8: Direct Index & Item Playback
    
    func testDirectIndexAndItemPlay() {
        let store = MediaPlaylistStore()
        let urls = [
            URL(fileURLWithPath: "/media/A.mp4"),
            URL(fileURLWithPath: "/media/B.mp4"),
            URL(fileURLWithPath: "/media/C.mp4")
        ]
        store.populate(from: urls[0], allSiblings: urls)
        
        let item = store.playIndex(2)
        XCTAssertEqual(item?.title, "C")
        XCTAssertEqual(store.currentIndex, 2)
        XCTAssertTrue(store.items[2].isCurrent)
        XCTAssertFalse(store.items[0].isCurrent)
        
        let outOfBounds = store.playIndex(99)
        XCTAssertNil(outOfBounds)
        XCTAssertEqual(store.currentIndex, 2)
        
        let targetItem = store.items[1]
        let played = store.playItem(targetItem)
        XCTAssertEqual(played?.title, "B")
        XCTAssertEqual(store.currentIndex, 1)
    }
    
    // MARK: - Test 9: Mutation Utilities
    
    func testPlaylistMutations() {
        let store = MediaPlaylistStore()
        let item1 = PlaylistItem(url: URL(fileURLWithPath: "/media/1.mp4"), isCurrent: true)
        let item2 = PlaylistItem(url: URL(fileURLWithPath: "/media/2.mp4"))
        let item3 = PlaylistItem(url: URL(fileURLWithPath: "/media/3.mp4"))
        
        store.setItems([item1, item2, item3], activeIndex: 0)
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.currentIndex, 0)
        
        // Update duration
        store.updateDuration(for: item2.url, duration: 125.5)
        XCTAssertEqual(store.items[1].duration, 125.5)
        
        // Remove current item (index 0)
        store.removeItem(at: 0)
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(store.currentItem?.title, "2")
        
        // Clear
        store.clear()
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.currentIndex)
    }
}
