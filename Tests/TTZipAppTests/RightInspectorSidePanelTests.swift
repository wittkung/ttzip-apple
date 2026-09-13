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

final class RightInspectorSidePanelTests: XCTestCase {
    
    private var tempDir: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("right_inspector_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() async throws {
        if let t = tempDir {
            try? FileManager.default.removeItem(at: t)
        }
        try await super.tearDown()
    }
    
    @MainActor
    func testRightInspectorSidePanelUnselectedMount() {
        let viewModel = AppViewState()
        viewModel.currentDirectory = tempDir
        viewModel.selectedDiskItem = nil
        
        let panel = RightInspectorSidePanel(viewModel: viewModel)
        let hosting = NSHostingView(rootView: panel)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        
        XCTAssertNotNil(hosting)
        XCTAssertNil(viewModel.selectedDiskItem)
    }
    
    @MainActor
    func testRightInspectorSidePanelSelectedItemAndOpenImmersiveMedia() throws {
        let testFile = tempDir.appendingPathComponent("sample_document.pdf")
        try "Mock PDF Content".write(to: testFile, atomically: true, encoding: .utf8)
        
        let item = DiskItemInfo(url: testFile)
        let viewModel = AppViewState()
        viewModel.currentDirectory = tempDir
        viewModel.selectedDiskItem = item
        
        let panel = RightInspectorSidePanel(viewModel: viewModel)
        let hosting = NSHostingView(rootView: panel)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        
        XCTAssertNotNil(hosting)
        XCTAssertEqual(viewModel.selectedDiskItem?.path, testFile.path)
        
        // Test convenience openImmersiveMedia(for:)
        viewModel.openImmersiveMedia(for: item)
        XCTAssertTrue(viewModel.overlayState.showImmersiveMediaBrowser)
        XCTAssertEqual(viewModel.overlayState.immersiveMediaItem?.url.path, testFile.path)
        XCTAssertEqual(viewModel.overlayState.immersiveMediaItem?.name, item.displayName)
    }
}
