// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import CoreFoundation
import SwiftUI
import XCTest
@testable import TTMediaKit

@MainActor
final class TextHostViewportRenderingTests: XCTestCase {
    func testDetectedSRTFactoryHostPaintsBodyAfterZeroMountAcrossThemesAndResizes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("text-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("真实字幕 Timeline.srt")
        let source = Self.subtitleSource
        try source.write(to: url, atomically: true, encoding: .utf8)
        let detected = await TTMediaDetector.detectTypeAsync(url: url)
        guard case .text(let detectedText) = detected else {
            XCTFail("SRT must reach the text route through the actual detector")
            return
        }
        XCTAssertEqual(detectedText, source)
        let preferences = TTTextReadingPreferenceStore.shared
        let previousMode = preferences.mode
        defer { preferences.mode = previousMode }
        preferences.mode = .black
        let content = TTMediaPreviewFactory.makePreviewView(
            type: detected,
            fileName: url.lastPathComponent,
            fileURL: url
        ).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.frame = .zero
        XCTAssertEqual(host.frame.size, .zero)
        let initialEditor = try await waitForEditor(in: host, source: source, requireViewport: false)
        XCTAssertEqual(initialEditor.string, source)
        resize(host, window: window, width: 420)
        let editor = try await waitForEditor(in: host, source: source, requireViewport: true)
        let selection = (source as NSString).range(of: "tail selection")
        XCTAssertNotEqual(selection.location, NSNotFound)
        editor.setSelectedRange(selection)
        for mode in [TTTextReadingBackgroundMode.black, .white] {
            preferences.mode = mode
            for width in [280.0, 720.0, 340.0] {
                resize(host, window: window, width: width)
                let current = try await waitForEditor(in: host, source: source, requireViewport: true, mode: mode)
                XCTAssertTrue(current === editor, "A theme or resize must not replace the editing session")
                XCTAssertEqual(current.string, source)
                XCTAssertEqual(current.selectedRange(), selection)
                try assertBodyGlyphsVisible(current)
                try assertContrastingBodyPixels(current, dark: mode == .black)
            }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source, "Previewing must not write the source file")
        XCTAssertFalse(window.isVisible, "The regression must not take over the user's frontmost window")
    }

    func testShortPlainTextPaintsAcrossNativeAppearancesAndReadingBackgrounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("text-appearance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("README.txt")
        let source = "TTZip acceptance\n中文预览检查：内容应可见。\nThis file belongs to the test.\n"
        try source.write(to: url, atomically: true, encoding: .utf8)
        let detected = await TTMediaDetector.detectTypeAsync(url: url)
        guard case .text(let detectedText) = detected else {
            return XCTFail("Plain text must enter the real text preview route")
        }
        XCTAssertEqual(detectedText, source)
        let preferences = TTTextReadingPreferenceStore.shared
        let previousMode = preferences.mode
        defer { preferences.mode = previousMode }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let dark = appearance == .darkAqua
            for mode in [TTTextReadingBackgroundMode.white, .black] {
                preferences.mode = mode
                let content = TTMediaPreviewFactory.makePreviewView(
                    type: detected,
                    fileName: url.lastPathComponent,
                    fileURL: url
                ).environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []
                let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                defer {
                    window.contentView = nil
                    window.close()
                }
                resize(host, window: window, width: 420)
                let editor = try await waitForEditor(in: host, source: source, requireViewport: true, mode: mode)
                XCTAssertEqual(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), appearance)
                XCTAssertEqual(editor.selectedRange().length, 0, "Selection must not supply the contrasting pixels")
                try assertBodyGlyphsVisible(editor)
                try assertContrastingBodyPixels(editor, dark: mode == .black)
                try assertCompositedBodyPixels(editor, host: host, dark: mode == .black)
                XCTAssertFalse(window.isVisible)
            }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }

    func testRulerDrawingCannotOverwriteBodyOrHeaderWithOversizedDirtyRect() throws {
        for mode in [TTTextReadingBackgroundMode.white, .black] {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
            let editor = NSTextView(frame: scroll.bounds)
            editor.string = "Body remains visible"
            scroll.documentView = editor
            let ruler = LineNumberRulerView(scrollView: scroll, textView: editor)
            ruler.readingPalette = .resolve(mode: mode, isDarkAppearance: false)
            ruler.frame = NSRect(x: 0, y: 0, width: 36, height: 80)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 160,
                pixelsHigh: 160,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            NSColor.magenta.setFill()
            NSRect(x: 0, y: 0, width: 160, height: 160).fill()
            let before = try bitmapBytes(bitmap)
            let transform = NSAffineTransform()
            transform.translateX(by: 40, yBy: 40)
            transform.concat()
            ruler.draw(NSRect(x: -40, y: -40, width: 160, height: 160))
            let after = try bitmapBytes(bitmap)
            var gutterChanges = 0
            var neighboringChanges = 0
            for y in 0..<160 {
                for x in 0..<160 {
                    let offset = y * bitmap.bytesPerRow + x * 4
                    let changed = before[offset..<(offset + 4)] != after[offset..<(offset + 4)]
                    if (40..<76).contains(x) && (40..<120).contains(y) {
                        if changed {
                            gutterChanges += 1
                        }
                    } else if changed {
                        neighboringChanges += 1
                    }
                }
            }
            XCTAssertGreaterThan(gutterChanges, 20, "The real ruler must actually paint its gutter")
            XCTAssertEqual(neighboringChanges, 0, "Ruler drawing must preserve adjacent body and header pixels")
            NSColor.green.setFill()
            NSRect(x: 90, y: -40, width: 8, height: 160).fill()
            let control = try XCTUnwrap(bitmap.colorAt(x: 134, y: 80)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(control.greenComponent, 0.9, "Drawing must restore its caller's graphics clip")
            XCTAssertLessThan(control.redComponent, 0.1)
        }
    }

    private func bitmapBytes(_ bitmap: NSBitmapImageRep) throws -> [UInt8] {
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        return Array(UnsafeBufferPointer(start: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }

    private static var subtitleSource: String {
        let opening = "1\n00:00:01,000 --> 00:00:03,000\n中文正文 Visible subtitle\n\n"
        let body = (2...80).map { index in
            let suffix = index == 80 ? "tail selection" : "remains visible"
            return "\(index)\n00:00:04,000 --> 00:00:06,000\n中文字幕 line \(index) \(suffix)\n"
        }.joined(separator: "\n")
        return opening + body
    }

    private func resize<Content: View>(_ host: NSHostingView<Content>, window: NSWindow, width: CGFloat) {
        let size = NSSize(width: width, height: 320)
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
    }

    private func waitForEditor<Content: View>(
        in host: NSHostingView<Content>,
        source: String,
        requireViewport: Bool,
        mode: TTTextReadingBackgroundMode? = nil
    ) async throws -> LargeTextEditorTextView {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            flushPendingHostLayout(host)
            if let editor = findEditor(in: host), editor.string == source {
                let hasViewport = !editor.visibleRect.isEmpty && editor.frame.width > 0 && editor.frame.height > 0
                let matchesPalette = mode.map {
                    editor.backgroundColor == TTTextReadingPalette.resolve(mode: $0, isDarkAppearance: true).nsCanvasBackgroundColor
                } ?? true
                if (!requireViewport || hasViewport) && matchesPalette {
                    return editor
                }
            }
            await Task.yield()
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw XCTUnwrapFailure.missingEditor
    }

    private func flushPendingHostLayout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        CFRunLoopRunInMode(.defaultMode, 0, true)
    }

    private func findEditor(in root: NSView) -> LargeTextEditorTextView? {
        if let editor = root as? LargeTextEditorTextView {
            return editor
        }
        for child in root.subviews {
            if let editor = findEditor(in: child) {
                return editor
            }
        }
        return nil
    }

    private func assertBodyGlyphsVisible(_ editor: LargeTextEditorTextView) throws {
        let manager = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        let range = manager.glyphRange(forCharacterRange: NSRange(location: 0, length: 36), actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: range, in: container)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        XCTAssertFalse(rect.isEmpty)
        XCTAssertTrue(rect.intersects(editor.visibleRect), "Stored text outside the visible viewport is not a rendered body")
    }

    private func assertContrastingBodyPixels(_ editor: LargeTextEditorTextView, dark: Bool) throws {
        let visible = editor.visibleRect.intersection(editor.bounds)
        let rect = NSRect(
            x: visible.minX,
            y: visible.minY,
            width: min(400, visible.width),
            height: min(100, visible.height)
        )
        XCTAssertGreaterThan(rect.width, 20)
        XCTAssertGreaterThan(rect.height, 20)
        let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: rect))
        editor.cacheDisplay(in: rect, to: bitmap)
        var ink = 0
        for y in 8..<bitmap.pixelsHigh {
            for x in 8..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = TTTextReadingPalette.relativeLuminance(of: color)
                if dark ? luminance > 0.3 : luminance < 0.4 {
                    ink += 1
                }
            }
        }
        XCTAssertGreaterThan(ink, 20, "Only body-view pixels count; gutter labels cannot make this assertion pass")
    }

    private func assertCompositedBodyPixels(_ editor: NSTextView, host: NSView, dark: Bool) throws {
        let local = NSRect(
            x: editor.visibleRect.minX + 8,
            y: editor.visibleRect.minY + 8,
            width: min(350, editor.visibleRect.width - 16),
            height: 80
        )
        let rect = host.convert(local, from: editor).intersection(host.bounds)
        XCTAssertGreaterThan(rect.width, 20)
        XCTAssertGreaterThan(rect.height, 20)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: bitmap)
        var ink = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = TTTextReadingPalette.relativeLuminance(of: color)
                if dark ? luminance > 0.3 : luminance < 0.4 {
                    ink += 1
                }
            }
        }
        XCTAssertGreaterThan(ink, 20, "The hosting composition must retain the document's contrasting body pixels")
    }

    private enum XCTUnwrapFailure: Error {
        case missingEditor
    }

    func testContentFirstFloatingToolsKeepViewportAndLineOneInvariantAcrossThreeStatesAndMidScroll() async throws {
        assertFloatingToolsStateMachine()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-content-first-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.txt")
        let source = Self.subtitleSource
        try Data(source.utf8).write(to: file)

        let driver = ViewportFloatingToolsTestDriver()
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ViewportDrivenFloatingToolsContainer(driver: driver, source: source, file: file))
        host.sizingOptions = []
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        resize(host, window: window, width: 720)

        let editor = try await waitForEditor(in: host, source: source, requireViewport: true, mode: .black)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        let baselineScrollRect = host.convert(scrollView.bounds, from: scrollView)
        let baselineLineOneRect = try firstLineHostRect(editor: editor, host: host)
        XCTAssertEqual(baselineScrollRect.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(baselineScrollRect.origin.y, 0, accuracy: 0.5)
        XCTAssertEqual(baselineScrollRect.width, host.bounds.width, accuracy: 0.5)
        XCTAssertEqual(
            baselineScrollRect.height,
            host.bounds.height,
            accuracy: 0.5,
            "Document viewport must occupy 100% of the container in quietReading state"
        )

        for targetState in [TTTextFloatingToolsPresentationState.controlsVisible, .popoverExpanded, .quietReading] {
            driver.state = targetState
            for _ in 0..<4 {
                flushPendingHostLayout(host)
                await Task.yield()
            }
            let currentScrollRect = host.convert(scrollView.bounds, from: scrollView)
            let currentLineOneRect = try firstLineHostRect(editor: editor, host: host)
            XCTAssertEqual(currentScrollRect.origin.x, baselineScrollRect.origin.x, accuracy: 0.05)
            XCTAssertEqual(currentScrollRect.origin.y, baselineScrollRect.origin.y, accuracy: 0.05)
            XCTAssertEqual(currentScrollRect.width, baselineScrollRect.width, accuracy: 0.05)
            XCTAssertEqual(
                currentScrollRect.height,
                baselineScrollRect.height,
                accuracy: 0.05,
                "State \(targetState.rawValue) must never alter the body viewport height or frame origin"
            )
            XCTAssertEqual(
                currentLineOneRect.minY,
                baselineLineOneRect.minY,
                accuracy: 0.05,
                "State \(targetState.rawValue) must never push or shift line 1"
            )
            try assertBodyGlyphsVisible(editor)
            try assertContrastingBodyPixels(editor, dark: true)
            try assertNoFullWidthTopHeaderBar(in: host)
        }
        try await assertMidScrollInvariance(
            editor: editor,
            scrollView: scrollView,
            host: host,
            driver: driver,
            sourceLength: source.count
        )
    }

    private func assertFloatingToolsStateMachine() {
        XCTAssertEqual(CodeTextEditorContainerView.resolveFloatingToolsState(isImmersiveFullscreen: false), .controlsVisible)
        XCTAssertEqual(CodeTextEditorContainerView.resolveFloatingToolsState(isImmersiveFullscreen: true), .quietReading)
        XCTAssertEqual(
            CodeTextEditorContainerView.resolveFloatingToolsState(isImmersiveFullscreen: true, isPointerInContainer: true),
            .controlsVisible
        )
        XCTAssertEqual(
            CodeTextEditorContainerView.resolveFloatingToolsState(isImmersiveFullscreen: true, isClusterFocused: true),
            .controlsVisible
        )
        XCTAssertEqual(
            CodeTextEditorContainerView.resolveFloatingToolsState(isImmersiveFullscreen: true, isPopoverPresented: true),
            .popoverExpanded
        )
    }

    private func assertMidScrollInvariance(
        editor: LargeTextEditorTextView,
        scrollView: NSScrollView,
        host: NSView,
        driver: ViewportFloatingToolsTestDriver,
        sourceLength: Int
    ) async throws {
        editor.scrollRangeToVisible(NSRange(location: sourceLength / 2, length: 24))
        flushPendingHostLayout(host)
        let midScrollOrigin = scrollView.contentView.bounds.origin
        XCTAssertGreaterThan(midScrollOrigin.y, 120, "Long document must actually be scrolled to middle")
        for targetState in [TTTextFloatingToolsPresentationState.controlsVisible, .popoverExpanded, .quietReading] {
            driver.state = targetState
            for _ in 0..<4 {
                flushPendingHostLayout(host)
                await Task.yield()
            }
            XCTAssertEqual(
                scrollView.contentView.bounds.origin.y,
                midScrollOrigin.y,
                accuracy: 0.05,
                "Showing/hiding floating tools or popover at mid-scroll must never jump scrollOffset"
            )
        }
    }

    private func firstLineHostRect(editor: LargeTextEditorTextView, host: NSView) throws -> NSRect {
        let manager = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        let range = manager.glyphRange(forCharacterRange: NSRange(location: 0, length: 18), actualCharacterRange: nil)
        let localRect = manager.boundingRect(forGlyphRange: range, in: container)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        return host.convert(localRect, from: editor)
    }

    private func assertNoFullWidthTopHeaderBar(in host: NSView) throws {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let yTop = 14
        let bg = TTTextReadingPalette.resolve(mode: .black, isDarkAppearance: true).nsCanvasBackgroundColor
            .usingColorSpace(.sRGB)!
        var matchingTopCanvas = 0
        for x in stride(from: 80, to: Int(host.bounds.width) - 80, by: 20) {
            guard let color = bitmap.colorAt(x: x, y: yTop)?.usingColorSpace(.sRGB) else { continue }
            let delta = abs(color.redComponent - bg.redComponent)
                + abs(color.greenComponent - bg.greenComponent)
                + abs(color.blueComponent - bg.blueComponent)
            if delta < 0.08 {
                matchingTopCanvas += 1
            }
        }
        XCTAssertGreaterThan(
            matchingTopCanvas,
            18,
            "Top strip across the window must remain pure document canvas without a full-width header bar"
        )
    }
}

@MainActor
private final class ViewportFloatingToolsTestDriver: ObservableObject {
    @Published var state: TTTextFloatingToolsPresentationState? = .quietReading
    @Published var mode: TTTextReadingBackgroundMode = .black
}

private struct ViewportDrivenFloatingToolsContainer: View {
    @ObservedObject var driver: ViewportFloatingToolsTestDriver
    let source: String
    let file: URL

    var body: some View {
        CodeTextEditorContainerView(
            initialText: source,
            fileURL: file,
            fileName: file.lastPathComponent,
            isReadOnly: false,
            resourceContext: .diskFile(url: file, fileName: file.lastPathComponent, allowsEditing: true),
            readingBackgroundMode: $driver.mode,
            floatingToolsState: $driver.state
        )
        .environment(\.isImmersiveFullscreen, true)
        .environment(\.previewBottomTrailingReservedWidth, 34.0)
        .environment(\.colorScheme, .dark)
    }
}
