// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
@testable import TTZipApp

final class HexDataPreviewLayoutTests: XCTestCase {
    private var tempFileURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("HexLayoutTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempFileURL = tempDir.appendingPathComponent("fixture.bin")
        let sampleBytes: [UInt8] = (0..<512).map { UInt8($0 % 256) }
        try Data(sampleBytes).write(to: tempFileURL)
    }
    
    override func tearDownWithError() throws {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        try super.tearDownWithError()
    }
    
    @MainActor
    func testHexDataPreviewViewMountsInNarrowSidebarWidths() {
        let testData = (try? Data(contentsOf: tempFileURL)) ?? Data([0x7F, 0x45, 0x4C, 0x46])
        let hexView = HexDataPreviewView(data: testData, fileURL: tempFileURL, fileName: "fixture.bin")
        
        let narrowWidths: [CGFloat] = [200.0, 260.0, 320.0, 340.0, 600.0]
        for width in narrowWidths {
            let hostingController = NSHostingController(
                rootView: hexView
                    .frame(width: width, height: 400)
            )
            hostingController.view.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            hostingController.view.layoutSubtreeIfNeeded()
            
            XCTAssertEqual(hostingController.view.frame.width, width, "View frame width must strictly obey outer width \(width)pt without expanding to 558pt")
        }
    }
    
    @MainActor
    func testHexEditorNSViewConfiguredForOuterHorizontalScroll() {
        let testData = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        let editor = HexEditorNSView(pageData: testData, startOffset: 0)
        
        let hostingController = NSHostingController(rootView: editor.frame(width: 620, height: 300))
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 620, height: 300)
        hostingController.view.layoutSubtreeIfNeeded()
        
        // Find inner NSScrollView
        func findScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView { return sv }
            for sub in view.subviews {
                if let found = findScrollView(in: sub) { return found }
            }
            return nil
        }
        
        let scrollView = findScrollView(in: hostingController.view)
        XCTAssertNotNil(scrollView, "HexEditorNSView must produce an NSScrollView")
        if let sv = scrollView {
            XCTAssertFalse(sv.hasHorizontalScroller, "Inner NSScrollView must NOT have horizontal scroller to avoid gesture collision with outer ScrollView")
            XCTAssertTrue(sv.hasVerticalScroller, "Inner NSScrollView must retain vertical scroller for pagination browsing")
        }
    }
}
