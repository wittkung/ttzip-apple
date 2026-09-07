// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AppKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class ImmersiveMediaBrowserTests: XCTestCase {
    
    nonisolated(unsafe) private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImmersiveMediaBrowserTests_\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Test 1: ImmersiveMediaItem Model Integrity
    
    func testImmersiveMediaItemModelIntegrity() {
        let sampleURL = tempDirURL.appendingPathComponent("document.pdf")
        let item1 = ImmersiveMediaItem(url: sampleURL, name: "document.pdf", fileSizeBytes: 1024)
        let item2 = ImmersiveMediaItem(url: sampleURL, name: "document.pdf", fileSizeBytes: 1024)
        let item3 = ImmersiveMediaItem(url: sampleURL.appendingPathExtension("backup"), name: "document.pdf.backup", fileSizeBytes: 2048)
        
        XCTAssertEqual(item1, item2, "Identical items must be equal via Hashable/Equatable")
        XCTAssertNotEqual(item1, item3, "Distinct URLs must not be equal")
        XCTAssertEqual(item1.fileSizeBytes, 1024)
        XCTAssertEqual(item1.name, "document.pdf")
        XCTAssertEqual(item1.url, sampleURL)
        
        // Optional fileSizeBytes defaulting
        let itemWithoutSize = ImmersiveMediaItem(url: sampleURL, name: "document.pdf")
        XCTAssertNil(itemWithoutSize.fileSizeBytes)
    }
    
    // MARK: - Test 2: OverlayState State Variables Toggle
    
    func testOverlayStateImmersiveMediaToggle() {
        let overlayState = OverlayState()
        XCTAssertFalse(overlayState.showImmersiveMediaBrowser)
        XCTAssertNil(overlayState.immersiveMediaItem)
        
        let sampleURL = tempDirURL.appendingPathComponent("photo.jpg")
        let item = ImmersiveMediaItem(url: sampleURL, name: "photo.jpg", fileSizeBytes: 4096)
        
        overlayState.immersiveMediaItem = item
        overlayState.showImmersiveMediaBrowser = true
        
        XCTAssertTrue(overlayState.showImmersiveMediaBrowser)
        XCTAssertEqual(overlayState.immersiveMediaItem, item)
        
        overlayState.showImmersiveMediaBrowser = false
        overlayState.immersiveMediaItem = nil
        
        XCTAssertFalse(overlayState.showImmersiveMediaBrowser)
        XCTAssertNil(overlayState.immersiveMediaItem)
    }
    
    // MARK: - Test 3: AppViewState Open and Close Actions & Forwarding
    
    func testAppViewStateOpenAndCloseImmersiveMedia() {
        let viewModel = AppViewState(fileViewer: NoOpFileViewer())
        let sampleURL = tempDirURL.appendingPathComponent("video.mp4")
        try? Data("mock video stream".utf8).write(to: sampleURL)
        
        XCTAssertFalse(viewModel.showImmersiveMediaBrowser)
        XCTAssertNil(viewModel.immersiveMediaItem)
        
        // Open
        viewModel.openImmersiveMedia(url: sampleURL, name: "video.mp4", fileSizeBytes: 17)
        
        XCTAssertTrue(viewModel.showImmersiveMediaBrowser)
        XCTAssertTrue(viewModel.overlayState.showImmersiveMediaBrowser)
        XCTAssertEqual(viewModel.immersiveMediaItem?.url, sampleURL)
        XCTAssertEqual(viewModel.immersiveMediaItem?.name, "video.mp4")
        XCTAssertEqual(viewModel.immersiveMediaItem?.fileSizeBytes, 17)
        XCTAssertEqual(viewModel.selectedDiskItem?.path, sampleURL.path)
        
        // Close
        viewModel.closeImmersiveMedia()
        
        XCTAssertFalse(viewModel.showImmersiveMediaBrowser)
        XCTAssertFalse(viewModel.overlayState.showImmersiveMediaBrowser)
        XCTAssertNil(viewModel.immersiveMediaItem)
        XCTAssertNil(viewModel.overlayState.immersiveMediaItem)
    }
    
    // MARK: - Test 4: Sibling File Navigation Across Directory
    
    func testMediaNavigationPreviousAndNextInDirectory() throws {
        let fileA = tempDirURL.appendingPathComponent("alpha.png")
        let fileB = tempDirURL.appendingPathComponent("bravo.mp4")
        let fileC = tempDirURL.appendingPathComponent("charlie.pdf")
        let ignoredArchive = tempDirURL.appendingPathComponent("delta.zip")
        
        try Data("img".utf8).write(to: fileA)
        try Data("vid".utf8).write(to: fileB)
        try Data("doc".utf8).write(to: fileC)
        try Data("zip".utf8).write(to: ignoredArchive)
        
        let viewModel = AppViewState(fileViewer: NoOpFileViewer())
        viewModel.currentDirectory = tempDirURL
        
        // Open the middle file: bravo.mp4
        viewModel.openImmersiveMedia(url: fileB, name: fileB.lastPathComponent)
        
        XCTAssertTrue(viewModel.hasPreviousMedia, "bravo.mp4 must have previous media (alpha.png)")
        XCTAssertTrue(viewModel.hasNextMedia, "bravo.mp4 must have next media (charlie.pdf)")
        
        // Navigate Previous -> should reach alpha.png
        viewModel.navigatePreviousMedia()
        XCTAssertEqual(viewModel.immersiveMediaItem?.name, fileA.lastPathComponent)
        XCTAssertEqual(viewModel.immersiveMediaItem?.url.resolvingSymlinksInPath(), fileA.resolvingSymlinksInPath())
        XCTAssertFalse(viewModel.hasPreviousMedia, "alpha.png is first; hasPreviousMedia must be false")
        XCTAssertTrue(viewModel.hasNextMedia, "alpha.png must have next media")
        
        // Navigate Next -> should reach bravo.mp4
        viewModel.navigateNextMedia()
        XCTAssertEqual(viewModel.immersiveMediaItem?.name, fileB.lastPathComponent)
        XCTAssertEqual(viewModel.immersiveMediaItem?.url.resolvingSymlinksInPath(), fileB.resolvingSymlinksInPath())
        
        // Navigate Next -> should reach charlie.pdf (and ignore delta.zip)
        viewModel.navigateNextMedia()
        XCTAssertEqual(viewModel.immersiveMediaItem?.name, fileC.lastPathComponent)
        XCTAssertEqual(viewModel.immersiveMediaItem?.url.resolvingSymlinksInPath(), fileC.resolvingSymlinksInPath())
        XCTAssertTrue(viewModel.hasPreviousMedia, "charlie.pdf must have previous media")
        XCTAssertFalse(viewModel.hasNextMedia, "charlie.pdf is last previewable file; hasNextMedia must be false")
    }
    
    // MARK: - Test 5: ImmersiveMediaBrowserView Instantiation & Hierarchy
    
    func testImmersiveMediaBrowserViewHierarchyRenders() {
        let fileURL = tempDirURL.appendingPathComponent("preview_test.jpg")
        try? Data("jpeg payload".utf8).write(to: fileURL)
        
        let item = ImmersiveMediaItem(url: fileURL, name: "preview_test.jpg", fileSizeBytes: 12)
        var didClose = false
        var didPrev = false
        var didNext = false
        
        let browserView = ImmersiveMediaBrowserView(
            item: item,
            onClose: { didClose = true },
            onNavigatePrevious: { didPrev = true },
            onNavigateNext: { didNext = true }
        )
        
        let hostView = NSHostingView(rootView: browserView)
        hostView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        hostView.layoutSubtreeIfNeeded()
        
        XCTAssertNotNil(hostView, "ImmersiveMediaBrowserView must render inside NSHostingView cleanly")
        XCTAssertFalse(didClose)
        XCTAssertFalse(didPrev)
        XCTAssertFalse(didNext)
    }
}
