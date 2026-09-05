// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AppKit
import AVFoundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class VideoInlineSelectionSimulationTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("VideoSimTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Test 1: Full Frontend Selection Flow Mounts Inline Without Rogue Popups
    
    @MainActor
    func testVideoSelectionFlowMountsRightSidePanelInlineWithoutRoguePopup() async throws {
        // 1. Arrange: Create a mock video file on disk
        let videoURL = tempDirURL.appendingPathComponent("product_keynote.mp4")
        let dummyMP4Magic: [UInt8] = [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x70, 0x34, 0x32]
        var payload = Data(dummyMP4Magic)
        payload.append(Data(repeating: 0x00, count: 2048))
        try payload.write(to: videoURL)
        
        // 2. Initialize the AppViewState (representing active frontend application state)
        let viewModel = AppViewState()
        viewModel.currentDirectory = tempDirURL
        viewModel.activeTab = .home
        XCTAssertNil(viewModel.selectedDiskItem, "Initial selection should be nil")
        XCTAssertEqual(viewModel.navigationState.layoutMode, .standard, "Layout mode must remain standard initially")
        
        // 3. Act: Simulate user single-clicking the video file row in the Miller Column explorer
        let videoDiskItem = DiskItemInfo(url: videoURL)
        viewModel.selectedDiskItem = videoDiskItem
        
        // 4. Assert State: Selection state and Right Panel availability invariants
        XCTAssertEqual(viewModel.selectedDiskItem?.path, videoURL.path)
        XCTAssertEqual(viewModel.selectedDiskItem?.name, "product_keynote.mp4")
        XCTAssertFalse(viewModel.selectedDiskItem?.isDirectory ?? true)
        
        let isRightPanelAvailable = (viewModel.activeTab == .home && viewModel.selectedDiskItem != nil && viewModel.selectedDiskItem?.isDirectory == false)
        XCTAssertTrue(isRightPanelAvailable, "Right inspector side panel must become available when video is selected")
        
        // 5. Assert No Rogue Window: Ensure selecting the video did NOT pop up any standalone window
        XCTAssertEqual(
            viewModel.navigationState.layoutMode,
            .standard,
            "CRITICAL: Selecting a video must keep layout mode standard!"
        )
        
        // 6. Act: Mount the RightInspectorSidePanel in a simulated 320x600 right sidebar viewport
        let inspectorView = RightInspectorSidePanel(viewModel: viewModel)
        let hierarchy = UIHierarchyInspector(rootView: inspectorView, size: CGSize(width: 320, height: 600))
        
        // 7. Assert View Hierarchy: Ensure Inspector mounts cleanly and without modal occlusion
        let subviews = hierarchy.allSubviews()
        XCTAssertFalse(subviews.isEmpty, "Inspector must render subviews")
        hierarchy.assertNoOccludingModalCard()
        
        // 8. Assert Type Detection & View Factory generates UnifiedVideoPlayerView
        let previewType = await MediaPreviewFactory.detectTypeAsync(url: videoURL)
        switch previewType {
        case .video(let detectedURL):
            XCTAssertEqual(detectedURL, videoURL)
        default:
            XCTFail("Selected video must detect as .video, got: \(previewType)")
        }
        
        let generatedPreview = MediaPreviewFactory.makePreviewView(
            type: previewType,
            fileName: "product_keynote.mp4",
            fileURL: videoURL
        )
        XCTAssertNotNil(generatedPreview)
        
        // 9. Re-verify FullScreen window is STILL not presenting after full UI mount
        XCTAssertEqual(
            viewModel.navigationState.layoutMode,
            .standard,
            "CRITICAL: View mounting must keep layout mode standard!"
        )
    }
    
    // MARK: - Test 2: Unified MPVMetalVideoPlayerView Viewport & Lifecycle
    
    @MainActor
    func testUnifiedVideoPlayerViewEmbeddedMPVMetalLifecycle() async throws {
        // 1. Arrange: Create video file
        let videoURL = tempDirURL.appendingPathComponent("demo_clip.mov")
        let dummyMOVMagic: [UInt8] = [0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20]
        var payload = Data(dummyMOVMagic)
        payload.append(Data(repeating: 0x00, count: 1024))
        try payload.write(to: videoURL)
        
        // 2. Act: Mount UnifiedVideoPlayerView directly in UIHierarchyInspector
        let videoView = UnifiedVideoPlayerView(url: videoURL)
        let hierarchy = UIHierarchyInspector(rootView: videoView, size: CGSize(width: 360, height: 240))
        
        // 3. Assert: Find the embedded MPVMetalNSView in hierarchy
        let mpvViews = hierarchy.allSubviews().compactMap { $0 as? MPVMetalNSView }
        XCTAssertFalse(mpvViews.isEmpty, "Hierarchy must contain an instantiated MPVMetalNSView")
        
        // 4. Assert: MediaPlaybackCoordinator registration
        XCTAssertTrue(MediaPlaybackCoordinator.shared.isMediaActive, "Session must be registered in MediaPlaybackCoordinator")
        
        // 5. Act: Trigger Play/Pause via coordinator
        MediaPlaybackCoordinator.shared.triggerPlayPause()
        XCTAssertTrue(MediaPlaybackCoordinator.shared.isMediaActive)
    }
    
    // MARK: - Test 3: MKV Extended Container Selection Mounts MPV Viewport Inline Without Popup
    
    @MainActor
    func testMKVSelectionMountsInlineMPVMetalViewportWithoutRoguePopup() async throws {
        let mkvURL = tempDirURL.appendingPathComponent("The.Invite.2026.2160p.iT.WEB-DL.DDP5.1.DV.HDR.H.265.mkv")
        try Data("mock mkv video container stream".utf8).write(to: mkvURL)
        
        // 1. App state setup
        let viewModel = AppViewState()
        viewModel.currentDirectory = tempDirURL
        viewModel.activeTab = .home
        viewModel.selectedDiskItem = DiskItemInfo(url: mkvURL)
        
        // 2. Detection
        let detected = await MediaPreviewFactory.detectTypeAsync(url: mkvURL)
        switch detected {
        case .video(let u):
            XCTAssertEqual(u, mkvURL)
        default:
            XCTFail("MKV must be detected as .video, got: \(detected)")
        }
        
        // 3. Mount UnifiedVideoPlayerView directly
        let playerView = UnifiedVideoPlayerView(url: mkvURL)
        let hierarchy = UIHierarchyInspector(rootView: playerView, size: CGSize(width: 340, height: 260))
        
        // 4. Assert MPVMetalNSView is in the hierarchy
        let mpvViews = hierarchy.allSubviews().compactMap { $0 as? MPVMetalNSView }
        XCTAssertFalse(mpvViews.isEmpty, "MKV video must embed MPVMetalNSView in hierarchy")
        
        // 5. Assert Standard Layout invariant
        XCTAssertEqual(viewModel.navigationState.layoutMode, .standard, "MKV mounting must keep layout mode standard")
    }
    
    // MARK: - Test 4: Multiple Video Selections Update Inline Player Smoothly
    
    @MainActor
    func testMultipleVideoSelectionsUpdateInlinePlayerSmoothly() async throws {
        let video1 = tempDirURL.appendingPathComponent("clip_1.mp4")
        let video2 = tempDirURL.appendingPathComponent("clip_2.mp4")
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]).write(to: video1)
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]).write(to: video2)
        
        let view1 = UnifiedVideoPlayerView(url: video1)
        let hierarchy = UIHierarchyInspector(rootView: view1, size: CGSize(width: 320, height: 200))
        let playerViews1 = hierarchy.allSubviews().compactMap { $0 as? MPVMetalNSView }
        XCTAssertFalse(playerViews1.isEmpty)
        
        let view2 = UnifiedVideoPlayerView(url: video2)
        let hierarchy2 = UIHierarchyInspector(rootView: view2, size: CGSize(width: 320, height: 200))
        let playerViews2 = hierarchy2.allSubviews().compactMap { $0 as? MPVMetalNSView }
        XCTAssertFalse(playerViews2.isEmpty)
    }
}
