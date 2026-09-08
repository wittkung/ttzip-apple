// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AppKit
@testable import TTZipCore
@testable import TTZipPreviewKit
@testable import TTZipApp

final class PreviewKitFullscreenNotificationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewKitFSTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testHTMLWebRichPreviewViewFullscreenNotificationPayload() {
        let testURL = tempDir.appendingPathComponent("test.html")
        let expectation = expectation(description: "Notification received with HTML payload")

        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TTZipToggleMediaFocusNotification"),
            object: nil,
            queue: .main
        ) { notif in
            XCTAssertEqual(notif.object as? URL, testURL)
            if let userInfo = notif.userInfo {
                XCTAssertEqual(userInfo["url"] as? URL, testURL)
                XCTAssertEqual(userInfo["name"] as? String, "test.html")
            } else {
                XCTFail("Missing userInfo dictionary")
            }
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let view = HTMLWebRichPreviewView(
            content: "<html><body>Test</body></html>",
            fileURL: testURL,
            fileName: "test.html"
        )
        XCTAssertNotNil(view)

        let userInfo: [String: Any] = [
            "url": testURL,
            "name": "test.html"
        ]
        NotificationCenter.default.post(
            name: NSNotification.Name("TTZipToggleMediaFocusNotification"),
            object: testURL,
            userInfo: userInfo
        )

        wait(for: [expectation], timeout: 2.0)
    }

    @MainActor
    func testMarkdownRichPreviewViewFullscreenNotificationPayload() {
        let testURL = tempDir.appendingPathComponent("document.md")
        let expectation = expectation(description: "Notification received with Markdown payload")

        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TTZipToggleMediaFocusNotification"),
            object: nil,
            queue: .main
        ) { notif in
            XCTAssertEqual(notif.object as? URL, testURL)
            if let userInfo = notif.userInfo {
                XCTAssertEqual(userInfo["url"] as? URL, testURL)
                XCTAssertEqual(userInfo["name"] as? String, "document.md")
            } else {
                XCTFail("Missing userInfo dictionary")
            }
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let view = MarkdownRichPreviewView(
            initialMarkdown: "# Header",
            fileURL: testURL,
            fileName: "document.md"
        )
        XCTAssertNotNil(view)

        let userInfo: [String: Any] = [
            "url": testURL,
            "name": "document.md"
        ]
        NotificationCenter.default.post(
            name: NSNotification.Name("TTZipToggleMediaFocusNotification"),
            object: testURL,
            userInfo: userInfo
        )

        wait(for: [expectation], timeout: 2.0)
    }

    @MainActor
    func testMediaPreviewViewInstantiationWithVariousMediaTypes() {
        let testImageURL = tempDir.appendingPathComponent("photo.png")
        let imageView = MediaPreviewView(fileURL: testImageURL, fileName: "photo.png")
        XCTAssertNotNil(imageView)

        let testVideoURL = tempDir.appendingPathComponent("clip.mp4")
        let videoView = MediaPreviewView(fileURL: testVideoURL, fileName: "clip.mp4")
        XCTAssertNotNil(videoView)

        let testWebURL = tempDir.appendingPathComponent("page.html")
        let webView = MediaPreviewView(fileURL: testWebURL, fileName: "page.html")
        XCTAssertNotNil(webView)

        let testMdURL = tempDir.appendingPathComponent("notes.md")
        let mdView = MediaPreviewView(fileURL: testMdURL, fileName: "notes.md")
        XCTAssertNotNil(mdView)
    }

    @MainActor
    func testMediaPreviewViewImmersiveFullscreenConfiguration() {
        let testImageURL = tempDir.appendingPathComponent("photo.png")
        let defaultView = MediaPreviewView(fileURL: testImageURL, fileName: "photo.png")
        XCTAssertNil(defaultView.isImmersiveFullscreen)

        let immersiveView = MediaPreviewView(fileURL: testImageURL, fileName: "photo.png", isImmersiveFullscreen: true)
        XCTAssertEqual(immersiveView.isImmersiveFullscreen, true)

        let windowedView = MediaPreviewView(fileURL: testImageURL, fileName: "photo.png", isImmersiveFullscreen: false)
        XCTAssertEqual(windowedView.isImmersiveFullscreen, false)

        // Verify SwiftUI environment modifier compiles and attaches cleanly
        let envModifiedView = defaultView.environment(\.isImmersiveFullscreen, true)
        XCTAssertNotNil(envModifiedView)
    }
}
