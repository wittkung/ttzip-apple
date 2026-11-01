// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import WebKit
@testable import TTMediaKit

@MainActor
extension EPUBRealPageReadingAndThemeTests {
    // MARK: - Test Harness & HTML Generators

    struct TestHarness {
        let window: NSWindow
        let webView: EPUBReaderWKWebView
        let coordinator: EPUBNativeWKWebView.Coordinator
        let baseDirectory: URL
        let paginationController: EPUBPaginationController

        @MainActor
        func updateChapter(url: URL, chapterIndex: Int, landing: EPUBBoundaryLanding = .firstPage) {
            paginationController.selectChapterExplicitly(chapterIndex, landing: landing)
            coordinator.parent?.chapterIndex = chapterIndex
            let clean = EPUBNativeWKWebView.stripFragment(from: url)
            coordinator.loadChapterURL(
                clean,
                fragment: url.fragment,
                resolvedBaseURL: EPUBNativeWKWebView.resolveBaseURL(for: clean),
                baseDir: baseDirectory,
                fontSize: 17.0,
                fontStyle: "serif",
                readerTheme: coordinator.currentTheme ?? "light",
                in: webView
            )
        }

        @MainActor
        func updateTypography(fontSize: Double, fontStyle: String, theme: String) {
            coordinator.currentFontSize = CGFloat(fontSize)
            coordinator.currentFontStyle = fontStyle
            coordinator.currentTheme = theme
            paginationController.prepareAnchorPreservationBeforeRelayout()
            let escaped = EPUBNativeWKWebView.resolveFontFamilyCSS(for: fontStyle)
                .replacingOccurrences(of: "'", with: "\\'")
            coordinator.applyTypographyAndRelayout(
                in: webView,
                fontSize: fontSize,
                escapedFontFamily: escaped,
                readerTheme: theme
            )
        }

        @MainActor
        func updateLayoutMode(_ mode: EPUBReadingLayoutMode) {
            coordinator.parent?.layoutMode = mode.rawValue
            paginationController.setLayoutMode(mode)
            updateTypography(fontSize: 17, fontStyle: "serif", theme: "light")
        }

        @MainActor
        func resizeViewport(to newSize: NSSize) {
            window.setContentSize(newSize)
            webView.setFrameSize(newSize)
        }

        @MainActor
        func cleanup() {
            EPUBNativeWKWebView.dismantleNSView(webView, coordinator: coordinator)
            window.orderOut(nil)
        }
    }

    func makeTestHarness(
        chapterURL: URL,
        baseDirectory: URL,
        chapterIndex: Int,
        paginationController: EPUBPaginationController,
        viewportSize: NSSize
    ) throws -> TestHarness {
        let rep = EPUBNativeWKWebView(
            chapterURL: chapterURL,
            baseDirectory: baseDirectory,
            fontSize: 17.0,
            fontStyle: "serif",
            readerTheme: "light",
            chapterIndex: chapterIndex,
            paginationController: paginationController,
            layoutMode: paginationController.layoutMode.rawValue
        )
        let coordinator = rep.makeCoordinator()
        let config = WKWebViewConfiguration()
        TTWebPreviewContentPolicy.apply(to: config)
        config.userContentController.add(
            coordinator.inputStateMessageHandler,
            contentWorld: TTWebPreviewContentPolicy.readerControlWorld,
            name: EPUBReaderWebKitPagerBridge.inputStateHandlerName
        )
        let webView = EPUBReaderWKWebView(frame: NSRect(origin: .zero, size: viewportSize), configuration: config)
        webView.readerInstanceID = paginationController.instanceID
        webView.paginationController = paginationController
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.bindPaginationAndFocusCallbacks(to: webView)
        let clean = EPUBNativeWKWebView.stripFragment(from: chapterURL)
        coordinator.loadChapterURL(
            clean,
            fragment: chapterURL.fragment,
            resolvedBaseURL: EPUBNativeWKWebView.resolveBaseURL(for: clean),
            baseDir: baseDirectory,
            fontSize: 17.0,
            fontStyle: "serif",
            readerTheme: "light",
            in: webView
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: viewportSize),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let rootContainer = NSView(frame: NSRect(origin: .zero, size: viewportSize))
        webView.frame = NSRect(origin: .zero, size: viewportSize)
        webView.autoresizingMask = [.width, .height]
        rootContainer.addSubview(webView)
        window.contentView = rootContainer
        return TestHarness(
            window: window,
            webView: webView,
            coordinator: coordinator,
            baseDirectory: baseDirectory,
            paginationController: paginationController
        )
    }

    static func queryScrollPageIndex(in webView: WKWebView) async -> Int {
        await withCheckedContinuation { continuation in
            let js = "Math.round((window.scrollX || 0) / Math.max(window.innerWidth || 1, 1))"
            webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { outcome in
                let idx = ((try? outcome.get()) as? NSNumber)?.intValue ?? 0
                continuation.resume(returning: idx)
            }
        }
    }

    static func evalString(_ js: String, in webView: WKWebView) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { outcome in
                switch outcome {
                case .success(let val):
                    if let opt = val as? String {
                        continuation.resume(returning: opt)
                    } else if val is NSNull {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: "\(val)")
                    }
                case .failure(let err):
                    print("evalString error for [\(js)]: \(err)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    static func makeRichChapterXHTML(title: String, paragraphCount: Int) -> String {
        let paragraphs = (0..<paragraphCount).map { idx in
            "<p id=\"p\(idx)\">[\(title) §\(idx)] MetastudyLine EPUB reading engine enforces exact horizontal column pagination, single-page stepping via horizontal arrow keys, and boundary-checked transitions between adjacent chapters.</p>"
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
        <head><meta charset="utf-8"/><title>\(title)</title></head>
        <body>
            <h1>\(title)</h1>
            \(paragraphs)
        </body>
        </html>
        """
    }

    static func makeStylingVerificationXHTML() -> String {
        return """
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
        <head>
            <meta charset="utf-8"/><title>Dark Theme Verification</title>
            <style>
                .author-callout-card { border-left: 4px solid #f59e0b; padding: 8px 12px; margin: 12px 0; }
                .author-dark-text { color: #111111; font-weight: 600; }
            </style>
        </head>
        <body>
            <h1>Dark Theme &amp; Styling Invariants</h1>
            <p>Body text with an inline <a id="test-link" href="#anchor">Hyperlink Anchor</a> and <code>inline code snippet</code>.</p>
            <div id="author-box" class="author-callout-card">Author Custom Callout Box</div>
            <p id="author-dark" class="author-dark-text">Author CSS class with near-black text</p>
            <p id="inline-dark" style="color: #000000 !important">Author inline black text</p>
            <p><span id="accent-span" style="color: #cc0000">Chromatic emphasis must survive</span></p>
            <p><img id="test-img" src="data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><rect fill='%236366f1' width='40' height='40'/></svg>"/></p>
            <svg id="test-svg" xmlns="http://www.w3.org/2000/svg" width="40" height="20"><circle id="svg-shape" cx="20" cy="10" r="8" fill="#22c55e" style="color: black"/></svg>
        </body>
        </html>
        """
    }

    func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 35_000_000)
        }
        return await condition()
    }

    static func makeSinglePageChapterXHTML(title: String) -> String {
        "<html><head><meta charset='utf-8'/></head><body><p>\(title)</p></body></html>"
    }

    static func evalDouble(_ script: String, in webView: WKWebView) async -> Double {
        guard let raw = await evalString(script, in: webView), let value = Double(raw) else {
            XCTFail("JavaScript did not return a number: \(script)")
            return .nan
        }
        return value
    }

    func sendArrow(_ keyCode: UInt16, to harness: TestHarness) throws {
        XCTAssertTrue(harness.window.makeFirstResponder(harness.webView))
        TTPreviewKeyboardOwnershipCoordinator.shared.setReaderFocusState(
            instanceID: harness.paginationController.instanceID, isFocused: true, source: .readingArea
        )
        let character = keyCode == 124 ? "\u{F703}" : keyCode == 123 ? "\u{F702}" : "\u{F701}"
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode
        ))
        harness.webView.keyDown(with: event)
    }

    func assertIllustrationsPreserved(in webView: WKWebView) async {
        // 4. Verify image does not have destructive inversion filter
        let imgFilter = await Self.evalString("getComputedStyle(document.getElementById('test-img')).filter", in: webView) ?? ""
        XCTAssertEqual(imgFilter, "none", "EPUB illustrations must not have destructive inversion filter")

        // 5. Verify images keep full opacity and inline SVG survives untouched
        let imgOpacity = await Self.evalString("getComputedStyle(document.getElementById('test-img')).opacity", in: webView) ?? ""
        XCTAssertEqual(imgOpacity, "1", "Theme handling must not lower image opacity")
        let svgVisible = await Self.evalString(
            "(function(){var s=document.getElementById('test-svg');return s && s.getBoundingClientRect().width > 0 ? 'yes' : 'no';})()",
            in: webView
        ) ?? ""
        XCTAssertEqual(svgVisible, "yes", "Inline SVG illustrations must be preserved in dark mode")

        let svgColor = await Self.evalString(
            "getComputedStyle(document.getElementById('svg-shape')).color", in: webView
        )
        XCTAssertEqual(svgColor, "rgb(0, 0, 0)", "Dark theme must not recolour SVG descendants")
    }
}
