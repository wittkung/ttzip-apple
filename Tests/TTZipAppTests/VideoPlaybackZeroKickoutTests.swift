// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AVFoundation
@testable import TTZipCore
@testable import TTZipApp

final class VideoPlaybackZeroKickoutTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    private let allSixteenContainers: [(ext: String, magic: [UInt8])] = [
        ("mkv", [0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x00, 0x00, 0x00]),
        ("mp4", [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x70, 0x34, 0x32]),
        ("webm", [0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81]),
        ("avi", [0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x41, 0x56, 0x49, 0x20]),
        ("flv", [0x46, 0x4C, 0x56, 0x01, 0x05, 0x00, 0x00, 0x00, 0x09]),
        ("ts", [0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x0D]),
        ("wmv", [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9]),
        ("vob", [0x00, 0x00, 0x01, 0xBA, 0x44, 0x00, 0x04, 0x00]),
        ("rmvb", [0x2E, 0x52, 0x4D, 0x46, 0x00, 0x00, 0x00, 0x12]),
        ("ogv", [0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00]),
        ("3gp", [0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x33, 0x67, 0x70, 0x34]),
        ("m2ts", [0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x0D]),
        ("mov", [0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20]),
        ("m4v", [0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x56, 0x20]),
        ("f4v", [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x66, 0x34, 0x76, 0x20]),
        ("asf", [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9])
    ]
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("VideoMatrix_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Test 1: Full 16-Container Matrix Detection & View Hierarchy Mount
    
    @MainActor
    func testAllSixteenVideoContainersMatrixCoverage() async throws {
        for item in allSixteenContainers {
            let ext = item.ext
            let videoURL = tempDirURL.appendingPathComponent("sample_video.\(ext)")
            var payload = Data(item.magic)
            payload.append(Data(repeating: 0x00, count: 1024))
            try payload.write(to: videoURL)
            
            // 1. Synchronous type detection
            let syncType = MediaPreviewFactory.detectType(url: videoURL)
            switch syncType {
            case .video(let detectedURL):
                XCTAssertEqual(detectedURL, videoURL, "Format .\(ext) sync detection mismatch")
            default:
                XCTFail("Format .\(ext) must detect as .video, got: \(syncType)")
            }
            
            // 2. Asynchronous type detection
            let asyncType = await MediaPreviewFactory.detectTypeAsync(url: videoURL)
            switch asyncType {
            case .video(let detectedURL):
                XCTAssertEqual(detectedURL, videoURL, "Format .\(ext) async detection mismatch")
            default:
                XCTFail("Format .\(ext) must asynchronously detect as .video, got: \(asyncType)")
            }
            
            // 3. Icon name
            XCTAssertEqual(MediaPreviewFactory.iconName(for: "sample.\(ext)"), "film.fill")
            
            // 4. View generation and UI mount
            let previewView = MediaPreviewFactory.makePreviewView(
                type: .video(videoURL),
                fileName: "sample_video.\(ext)",
                fileURL: videoURL
            )
            XCTAssertNotNil(previewView, "makePreviewView must return non-nil view for .\(ext)")
            
            // 5. Mount in UIHierarchyInspector and assert clean rendering tree
            let inspector = UIHierarchyInspector(rootView: previewView, size: CGSize(width: 360, height: 280))
            let subviews = inspector.allSubviews()
            XCTAssertFalse(subviews.isEmpty, "View hierarchy for .\(ext) must contain subviews")
            inspector.assertNoOccludingModalCard()
        }
    }
    
    // MARK: - Test 2: SharedVideoPlayerStore Lifecycle and AVPlayer Setup
    
    @MainActor
    func testSharedVideoPlayerStoreLifecycle() throws {
        let store = SharedVideoPlayerStore()
        let mkvURL = tempDirURL.appendingPathComponent("movie_trailer.mkv")
        try Data("mock ebml mkv video stream".utf8).write(to: mkvURL)
        
        store.setup(url: mkvURL)
        XCTAssertNotNil(store.player)
        XCTAssertEqual(store.currentURL, mkvURL)
        XCTAssertFalse(store.isPlaying)
        
        store.togglePlayPause()
        XCTAssertTrue(store.isPlaying)
        store.togglePlayPause()
        XCTAssertFalse(store.isPlaying)
        
        store.seek(to: 15.0)
        XCTAssertEqual(store.currentTime, 15.0)
        store.seekBy(5.0)
        XCTAssertEqual(store.currentTime, 20.0)
        
        store.cleanUp()
        XCTAssertNil(store.player)
        XCTAssertNil(store.currentURL)
        XCTAssertFalse(store.isPlaying)
    }
}

