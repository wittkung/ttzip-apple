// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import TTMediaKit
import TTZipUI
@testable import TTZipCore
@testable import TTZipPreviewKit
@testable import TTZipApp

@MainActor
final class PreviewKitFullscreenNotificationTests: XCTestCase {

    nonisolated override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            AppLocalizationState.shared.setLanguage(.en)
        }
    }

    // MARK: - Component Interaction & Fullscreen Gesture Triggers

    func testAVSampleBufferPlayerNSViewFKeyTriggersFullscreenCallback() {
        let playerView = AVSampleBufferPlayerNSView(frame: .zero)
        var callbackFired = false
        playerView.onToggleFullScreen = {
            callbackFired = true
        }

        guard let fEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3
        ) else {
            XCTFail("Failed to construct F key event")
            return
        }

        playerView.keyDown(with: fEvent)
        XCTAssertTrue(callbackFired, "onToggleFullScreen callback must be executed on 'f' key")
    }

    func testAVSampleBufferPlayerNSViewDoubleClickTriggersFullscreenCallback() {
        let playerView = AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var fullscreenFired = false
        playerView.onToggleFullScreen = {
            fullscreenFired = true
        }

        let doubleClickEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 50, y: 120),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1.0
        )!

        playerView.mouseUp(with: doubleClickEvent)
        XCTAssertTrue(fullscreenFired, "Double click on player view must trigger onToggleFullScreen")
    }

    func testAVSampleBufferPlayerNSViewCanvasDoubleClickOverridesFullscreenCallback() {
        let playerView = AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var canvasDoubleClickFired = false
        var defaultFullscreenFired = false

        playerView.onCanvasDoubleClick = {
            canvasDoubleClickFired = true
        }
        playerView.onToggleFullScreen = {
            defaultFullscreenFired = true
        }

        let doubleClickEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 50, y: 120),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1.0
        )!

        playerView.mouseUp(with: doubleClickEvent)
        XCTAssertTrue(canvasDoubleClickFired, "Custom onCanvasDoubleClick must execute")
        XCTAssertFalse(defaultFullscreenFired, "Default onToggleFullScreen must be bypassed when onCanvasDoubleClick is provided")
    }

    // MARK: - Rich Preview Component Properties & State

    func testHTMLWebRichPreviewViewPropertiesAndState() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "PreviewKitFS")
        let testURL = tempDir.appendingPathComponent("test.html")
        let htmlBody = "<html><body><h1>TTZip Rich Web Preview</h1></body></html>"

        let view = HTMLWebRichPreviewView(
            content: htmlBody,
            fileURL: testURL,
            fileName: "test.html"
        )
        XCTAssertEqual(view.content, htmlBody)
        XCTAssertEqual(view.fileURL, testURL)
        XCTAssertEqual(view.fileName, "test.html")

        let defaultNameView = HTMLWebRichPreviewView(
            content: htmlBody,
            fileURL: testURL
        )
        XCTAssertEqual(defaultNameView.fileName, "test.html")

        let fallbackView = HTMLWebRichPreviewView(content: "<div/>")
        XCTAssertEqual(fallbackView.fileName, "Web Document")
        XCTAssertNil(fallbackView.fileURL)
    }

    func testMarkdownRichPreviewViewPropertiesAndState() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "PreviewKitFS")
        let testURL = tempDir.appendingPathComponent("document.md")
        let markdown = "# TTZip Engineering Invariants\n\n- Zero false positives\n- Full verification"

        let readOnlyView = MarkdownRichPreviewView(
            initialMarkdown: markdown,
            fileURL: testURL,
            fileName: "document.md",
            isReadOnly: true
        )
        XCTAssertEqual(readOnlyView.initialMarkdown, markdown)
        XCTAssertEqual(readOnlyView.fileURL, testURL)
        XCTAssertEqual(readOnlyView.fileName, "document.md")
        XCTAssertTrue(readOnlyView.isReadOnly)

        let writableView = MarkdownRichPreviewView(
            initialMarkdown: markdown,
            fileURL: testURL,
            fileName: "document.md",
            isReadOnly: false
        )
        XCTAssertFalse(writableView.isReadOnly)

        let fallbackView = MarkdownRichPreviewView(initialMarkdown: "hello")
        XCTAssertEqual(fallbackView.fileName, TextAndDocumentPreviewLocalization.text(.markdownDefaultTitle))
        XCTAssertNil(fallbackView.fileURL)
        XCTAssertFalse(fallbackView.isReadOnly)
    }

    // MARK: - MediaPreviewView Routing & Configuration

    func testMediaPreviewViewPropertiesAndTypeInvariants() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "PreviewKitFS")
        let testImageURL = tempDir.appendingPathComponent("photo.png")
        let imageView = MediaPreviewView(fileURL: testImageURL, fileName: "photo.png")
        XCTAssertEqual(imageView.fileURL, testImageURL)
        XCTAssertEqual(imageView.fileName, "photo.png")
        XCTAssertNil(imageView.isImmersiveFullscreen)

        let testVideoURL = tempDir.appendingPathComponent("clip.mp4")
        let videoView = MediaPreviewView(fileURL: testVideoURL, fileName: "clip.mp4")
        XCTAssertEqual(videoView.fileURL, testVideoURL)
        XCTAssertEqual(videoView.fileName, "clip.mp4")
        XCTAssertNil(videoView.isImmersiveFullscreen)

        let testWebURL = tempDir.appendingPathComponent("page.html")
        let webView = MediaPreviewView(fileURL: testWebURL, fileName: "page.html")
        XCTAssertEqual(webView.fileURL, testWebURL)
        XCTAssertEqual(webView.fileName, "page.html")
        XCTAssertNil(webView.isImmersiveFullscreen)

        let testMdURL = tempDir.appendingPathComponent("notes.md")
        let mdView = MediaPreviewView(fileURL: testMdURL, fileName: "notes.md")
        XCTAssertEqual(mdView.fileURL, testMdURL)
        XCTAssertEqual(mdView.fileName, "notes.md")
        XCTAssertNil(mdView.isImmersiveFullscreen)
    }

    func testMediaPreviewViewImmersiveFullscreenConfiguration() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "PreviewKitFS")
        let testImageURL = tempDir.appendingPathComponent("photo.png")
        let defaultView = MediaPreviewView(fileURL: testImageURL, fileName: "photo.png")
        XCTAssertNil(defaultView.isImmersiveFullscreen)

        let immersiveView = MediaPreviewView(fileURL: testImageURL, fileName: "photo.png", isImmersiveFullscreen: true)
        XCTAssertEqual(immersiveView.isImmersiveFullscreen, true)

        let windowedView = MediaPreviewView(fileURL: testImageURL, fileName: "photo.png", isImmersiveFullscreen: false)
        XCTAssertEqual(windowedView.isImmersiveFullscreen, false)
    }

    // MARK: - AppViewState Media Focus State Machine

    func testAppViewStateFullscreenNotificationHandlingAndStateTransition() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "PreviewKitFS")
        let viewModel = AppViewState(fileViewer: NoOpFileViewer())
        XCTAssertFalse(viewModel.showImmersiveMediaBrowser)
        XCTAssertNil(viewModel.immersiveMediaItem)

        let testFileURL = tempDir.appendingPathComponent("focus_sample.pdf")
        try? Data("PDF-1.7".utf8).write(to: testFileURL)

        viewModel.openImmersiveMedia(url: testFileURL, name: "focus_sample.pdf", fileSizeBytes: 1024)
        XCTAssertTrue(viewModel.showImmersiveMediaBrowser)
        XCTAssertTrue(viewModel.overlayState.showImmersiveMediaBrowser)
        XCTAssertEqual(viewModel.immersiveMediaItem?.url, testFileURL)
        XCTAssertEqual(viewModel.immersiveMediaItem?.name, "focus_sample.pdf")
        XCTAssertEqual(viewModel.immersiveMediaItem?.fileSizeBytes, 1024)
        XCTAssertEqual(viewModel.selectedDiskItem?.path, testFileURL.path)

        viewModel.closeImmersiveMedia()
        XCTAssertFalse(viewModel.showImmersiveMediaBrowser)
        XCTAssertFalse(viewModel.overlayState.showImmersiveMediaBrowser)
        XCTAssertNil(viewModel.immersiveMediaItem)
        XCTAssertNil(viewModel.overlayState.immersiveMediaItem)
    }
}
