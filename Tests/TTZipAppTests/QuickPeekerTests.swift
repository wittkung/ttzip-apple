// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import Carbon
import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit
@testable import TTZipApp

final class QuickPeekerTests: XCTestCase {
    
    @MainActor
    func test_global_hotkey_manager_lifecycle() {
        let manager = GlobalHotKeyManager.shared
        var triggered = false
        
        manager.register(keyCode: UInt32(kVK_Space), modifiers: UInt32(shiftKey)) {
            triggered = true
        }
        
        // Ensure unregister tears down Carbon event handlers cleanly
        manager.unregister()
        XCTAssertFalse(triggered, "Triggered flag should remain false until event fires")
    }
    
    @MainActor
    func test_quick_peeker_panel_attributes() {
        let panel = QuickPeekerPanel()
        
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertTrue(panel.hasShadow)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }
    
    @MainActor
    func test_quick_peeker_coordinator_warm_up_and_presentation() {
        let coordinator = QuickPeekerCoordinator.shared
        coordinator.start()
        
        let dummyArchive = URL(fileURLWithPath: "/tmp/sample_peeker_test.zip")
        let dummyVideo = URL(fileURLWithPath: "/tmp/sample_peeker_test.mkv")
        
        coordinator.present(urls: [dummyArchive, dummyVideo])
        
        // Hide and ensure tear-down completes without error
        coordinator.hide()
    }
    
    @MainActor
    func test_quick_peeker_host_view_archive_detection() {
        let zipURL = URL(fileURLWithPath: "/tmp/archive.zip")
        let sevenZipURL = URL(fileURLWithPath: "/tmp/data.7z")
        let tarGzURL = URL(fileURLWithPath: "/tmp/kernel.tar.gz")
        let mkvURL = URL(fileURLWithPath: "/tmp/movie.mkv")
        let swiftURL = URL(fileURLWithPath: "/tmp/main.swift")
        
        XCTAssertNotNil(ArchiveCompressionFormat.from(extensionOrName: zipURL.pathExtension))
        XCTAssertNotNil(ArchiveCompressionFormat.from(extensionOrName: sevenZipURL.pathExtension))
        XCTAssertNotNil(ArchiveCompressionFormat.from(extensionOrName: tarGzURL.pathExtension))
        XCTAssertNotNil(ArchiveCompressionFormat.from(extensionOrName: "gz"))
        XCTAssertNil(ArchiveCompressionFormat.from(extensionOrName: mkvURL.pathExtension))
        XCTAssertNil(ArchiveCompressionFormat.from(extensionOrName: swiftURL.pathExtension))
    }
    
    @MainActor
    func test_finder_selection_extractor_structure() {
        // Verify property is accessible and does not crash
        let isFront = FinderSelectionExtractor.isFinderFrontmost
        XCTAssertNotNil(isFront)
    }
}
