// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import WebKit
import Darwin
@testable import TTMediaKit

// MARK: - Lightweight Local Loopback HTTP Probe Server

private final class LoopbackHTTPProbeServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private let lock = NSLock()
    private var _requestPaths: [String] = []
    private var isStopped = false
    private var acceptThread: Thread?

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var requestPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _requestPaths
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestPaths.count
    }

    func reset() {
        lock.lock()
        _requestPaths.removeAll()
        lock.unlock()
    }

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var yes: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0, Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &addrLen)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.qualityOfService = .userInitiated
        self.acceptThread = thread
        thread.start()
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let stopped = isStopped
            lock.unlock()
            if stopped { break }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &clientLen)
                }
            }
            guard clientFD >= 0 else { break }

            var buffer = [UInt8](repeating: 0, count: 2048)
            let bytesRead = Darwin.read(clientFD, &buffer, buffer.count - 1)
            if bytesRead > 0 {
                let reqStr = String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
                let firstLine = reqStr.components(separatedBy: "\r\n").first ?? ""
                let parts = firstLine.split(separator: " ")
                let path = parts.count >= 2 ? String(parts[1]) : "/"
                lock.lock()
                _requestPaths.append(path)
                lock.unlock()
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
            _ = response.withCString { ptr in
                Darwin.write(clientFD, ptr, strlen(ptr))
            }
            Darwin.close(clientFD)
        }
    }

    func stop() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        lock.unlock()
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }

    deinit {
        stop()
    }
}

// MARK: - Synthetic WKNavigationAction Stub & Helpers

@MainActor
private final class URLRecorder {
    var urls: [URL] = []
}

@MainActor
private final class SyntheticNavigationAction: WKNavigationAction {
    private let _request: URLRequest
    private let _navigationType: WKNavigationType
    private let _hasMainTargetFrame: Bool

    init(url: URL, navigationType: WKNavigationType, isMainFrame: Bool = true) {
        self._request = URLRequest(url: url)
        self._navigationType = navigationType
        self._hasMainTargetFrame = isMainFrame
        super.init()
    }

    override var request: URLRequest { _request }
    override var navigationType: WKNavigationType { _navigationType }
    override var targetFrame: WKFrameInfo? {
        _hasMainTargetFrame ? nil : SubframeStub.shared
    }
}

@MainActor
private final class SubframeStub: WKFrameInfo {
    static let shared: SubframeStub = {
        let raw = class_createInstance(SubframeStub.self, 0) as AnyObject
        return raw as! SubframeStub
    }()

    override var isMainFrame: Bool { false }
}

// MARK: - Web & EPUB Content Policy Tests

@MainActor
final class WebEPUBContentPolicyTests: XCTestCase {

    private static let safe1x1PNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    private var retainedObjects: [AnyObject] = []

    override func tearDown() {
        retainedObjects.removeAll()
        TTWebPreviewContentPolicy.externalLinkOpener = { url in
            NSWorkspace.shared.open(url)
        }
        super.tearDown()
    }

    // MARK: - Test 1: HTML Offline, Positive Probe Control & Legitimate Local Assets

    func testHTMLOfflineAndScriptIsolationBlocksScriptAndNetworkRequests() async throws {
        let server = try LoopbackHTTPProbeServer()
        defer { server.stop() }
        try await assertProbeServerPositiveReachability(server)
        let port = server.port

        let maliciousHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta http-equiv="refresh" content="0;url=http://127.0.0.1:\(port)/redirect">
            <link rel="stylesheet" href="http://127.0.0.1:\(port)/style.css">
            <style>
                body { background-color: rgb(18, 52, 86); color: rgb(250, 251, 252); }
            </style>
            <script>
                window.__bookScriptExecuted = true;
                fetch('http://127.0.0.1:\(port)/fetch');
            </script>
        </head>
        <body>
            <h1 id="headline">Offline Preview Isolation</h1>
            <img id="safe-img" src="data:image/png;base64,\(Self.safe1x1PNGBase64)" alt="safe">
            <img src="http://127.0.0.1:\(port)/pixel.png" alt="remote">
            <iframe src="http://127.0.0.1:\(port)/iframe.html"></iframe>
            <form id="exfil" action="http://127.0.0.1:\(port)/form" method="GET">
                <input type="text" name="secret" value="token">
            </form>
        </body>
        </html>
        """

        let (webView, coordinator) = makeConfiguredHTMLWebView(content: maliciousHTML, fileURL: nil)
        defer { _ = coordinator }
        XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)

        try await waitUntilWebViewReady(webView, expectedElementId: "headline")
        try await waitUntilImageComplete(webView, elementId: "safe-img")
        try await Task.sleep(for: .milliseconds(300))

        let scriptFlag = try await evalString(in: webView, js: "typeof window.__bookScriptExecuted")
        XCTAssertEqual(scriptFlag, "undefined", "Inline page script must not execute")
        XCTAssertEqual(server.requestCount, 0, "Expected 0 loopback requests, got: \(server.requestPaths)")

        let safeImgLoaded = try await evalString(
            in: webView,
            js: "(document.getElementById('safe-img').complete && document.getElementById('safe-img').naturalWidth === 1) ? 'yes' : 'no'"
        )
        let bgColor = try await evalString(in: webView, js: "window.getComputedStyle(document.body).backgroundColor")
        let fgColor = try await evalString(in: webView, js: "window.getComputedStyle(document.body).color")
        XCTAssertEqual(safeImgLoaded, "yes", "Legitimate inline data: image must load in WKWebView")
        XCTAssertEqual(bgColor, "rgb(18, 52, 86)", "Legitimate local CSS background-color must apply")
        XCTAssertEqual(fgColor, "rgb(250, 251, 252)", "Legitimate local CSS color must apply")
    }

    // MARK: - Test 1b: Comment Fake-<head> & Malformed HTML Counterexamples in WKWebView

    func testCommentFakeHeadAndMalformedHTMLCounterexamplesInWKWebView() async throws {
        let server = try LoopbackHTTPProbeServer()
        defer { server.stop() }
        try await assertProbeServerPositiveReachability(server)
        let port = server.port

        let counterexamples: [(String, String)] = [
            ("<!-- <head> --><head><title>Real Head</title></head><body><h1 id=\"ce1-ready\">CE1</h1><img src=\"http://127.0.0.1:\(port)/comment-head-bypass.png\"><script>fetch(\"http://127.0.0.1:\(port)/comment-head-js\")</script></body>", "ce1-ready"),
            ("<!-- <head> --> <!-- <html> --> <div id=\"ce2-ready\">CE2</div><img src=\"http://127.0.0.1:\(port)/malformed-img.png\"><link rel=\"stylesheet\" href=\"http://127.0.0.1:\(port)/malformed.css\"><iframe src=\"http://127.0.0.1:\(port)/malformed-frame.html\"></iframe>", "ce2-ready"),
            ("<!-- <head> --><HEAD data-quote=\">\"><title>Quoted</title></HEAD><body><div id=\"ce3-ready\">CE3</div><img src=\"http://127.0.0.1:\(port)/quoted-attr.png\"></body>", "ce3-ready"),
            ("<!--><div id=\"ce4-ready\">CE4</div><img src=\"http://127.0.0.1:\(port)/abrupt-comment.png\"><!-- -->", "ce4-ready"),
            ("<!---><head><title>AbruptDash</title></head><body><div id=\"ce5-ready\">CE5</div><img src=\"http://127.0.0.1:\(port)/abrupt-dash.png\"></body><!-- <head> -->", "ce5-ready"),
            ("<!-- comment --!><div id=\"ce6-ready\">CE6</div><img src=\"http://127.0.0.1:\(port)/bang-comment.png\"><!-- <head> -->", "ce6-ready"),
            ("<! \" ><div id=\"ce7-ready\">CE7</div><img src=\"http://127.0.0.1:\(port)/bogus-decl.png\"><!-- \" >", "ce7-ready")
        ]

        for (rawHTML, readyID) in counterexamples {
            let injected = TTWebPreviewContentPolicy.injectOfflineCSP(into: rawHTML)
            XCTAssertTrue(
                TTWebPreviewContentPolicy.isCSPMetaOutsideComments(in: injected),
                "Injected CSP meta tag must not reside inside HTML5 comments: \(injected)"
            )
            let (webView, coordinator) = makeConfiguredHTMLWebView(content: rawHTML, fileURL: nil)
            defer { _ = coordinator }
            try await waitUntilWebViewReady(webView, expectedElementId: readyID)
            try await Task.sleep(for: .milliseconds(200))

            let hasCSPMetaInDOM = try await evalString(
                in: webView,
                js: "document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]') !== null ? 'yes' : 'no'"
            )
            XCTAssertEqual(hasCSPMetaInDOM, "yes", "DOM must contain active CSP <meta> element for \(readyID)")
            XCTAssertEqual(server.requestCount, 0, "Counterexample \(readyID) leaked network requests: \(server.requestPaths)")
        }

        let unclosedCommentHTML = "<!-- <head><img src=\"http://127.0.0.1:\(port)/unclosed.png\">"
        let injectedUnclosed = TTWebPreviewContentPolicy.injectOfflineCSP(into: unclosedCommentHTML)
        XCTAssertTrue(TTWebPreviewContentPolicy.isCSPMetaOutsideComments(in: injectedUnclosed))
    }

    // MARK: - Test 2: External Link Scheme Policy & Popup Blocking

    func testExternalLinkSchemePolicyAndPopupBlocking() async throws {
        let openedBox = URLRecorder()
        TTWebPreviewContentPolicy.externalLinkOpener = { url in
            openedBox.urls.append(url)
        }

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("preview_\(UUID().uuidString).html")
        let representable = HTMLWKWebViewRepresentable(content: "<p>Test</p>", fileURL: tempFile)
        let coordinator = representable.makeCoordinator()
        let config = WKWebViewConfiguration()
        TTWebPreviewContentPolicy.apply(to: config)
        let webView = WKWebView(frame: .zero, configuration: config)

        let safeURL = try XCTUnwrap(URL(string: "https://example.com/safe"))
        let safePolicy = await queryPolicy(
            coordinator: coordinator,
            webView: webView,
            action: SyntheticNavigationAction(url: safeURL, navigationType: .linkActivated, isMainFrame: true)
        )
        XCTAssertEqual(safePolicy, .cancel)
        XCTAssertEqual(openedBox.urls, [safeURL])

        let passwdURL = URL(fileURLWithPath: "/etc/passwd")
        let sysPrefURL = try XCTUnwrap(URL(string: "x-apple.systempreferences:com.apple.preference.security"))
        let jsURL = try XCTUnwrap(URL(string: "javascript:alert(1)"))

        for blockedURL in [passwdURL, sysPrefURL, jsURL] {
            let policy = await queryPolicy(
                coordinator: coordinator,
                webView: webView,
                action: SyntheticNavigationAction(url: blockedURL, navigationType: .linkActivated, isMainFrame: true)
            )
            XCTAssertEqual(policy, .cancel)
            XCTAssertEqual(openedBox.urls.count, 1, "Blocked scheme \(blockedURL) must not invoke externalLinkOpener")
        }

        try await assertFrameFormAndPopupPolicies(
            coordinator: coordinator,
            webView: webView,
            config: config,
            tempFile: tempFile,
            safeURL: safeURL,
            passwdURL: passwdURL,
            openedBox: openedBox
        )
    }

    private func assertFrameFormAndPopupPolicies(
        coordinator: HTMLWKWebViewRepresentable.Coordinator,
        webView: WKWebView,
        config: WKWebViewConfiguration,
        tempFile: URL,
        safeURL: URL,
        passwdURL: URL,
        openedBox: URLRecorder
    ) async throws {
        let fragmentURL = try XCTUnwrap(URL(string: tempFile.absoluteString + "#section-2"))
        let fragmentPolicy = await queryPolicy(
            coordinator: coordinator,
            webView: webView,
            action: SyntheticNavigationAction(url: fragmentURL, navigationType: .linkActivated, isMainFrame: true)
        )
        XCTAssertEqual(fragmentPolicy, .allow)
        XCTAssertEqual(openedBox.urls.count, 1)

        let iframePolicy = await queryPolicy(
            coordinator: coordinator,
            webView: webView,
            action: SyntheticNavigationAction(url: safeURL, navigationType: .other, isMainFrame: false)
        )
        XCTAssertEqual(iframePolicy, .cancel)

        let formPolicy = await queryPolicy(
            coordinator: coordinator,
            webView: webView,
            action: SyntheticNavigationAction(url: safeURL, navigationType: .formSubmitted, isMainFrame: true)
        )
        XCTAssertEqual(formPolicy, .cancel)

        let popupURL = try XCTUnwrap(URL(string: "http://example.com/popup"))
        let popupWebView = coordinator.webView(
            webView,
            createWebViewWith: config,
            for: SyntheticNavigationAction(url: popupURL, navigationType: .linkActivated, isMainFrame: false),
            windowFeatures: WKWindowFeatures()
        )
        XCTAssertNil(popupWebView, "createWebViewWith must return nil to block popups")
        XCTAssertEqual(openedBox.urls, [safeURL, popupURL])

        let forbiddenPopup = coordinator.webView(
            webView,
            createWebViewWith: config,
            for: SyntheticNavigationAction(url: passwdURL, navigationType: .linkActivated, isMainFrame: false),
            windowFeatures: WKWindowFeatures()
        )
        XCTAssertNil(forbiddenPopup)
        XCTAssertEqual(openedBox.urls.count, 2)
    }

    // MARK: - Test 3: EPUB Reader Isolated World, Local Assets & Navigation

    func testEPUBReaderIsolatedWorldAndNavigation() async throws {
        let server = try LoopbackHTTPProbeServer()
        defer { server.stop() }
        try await assertProbeServerPositiveReachability(server)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBPolicy_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (ch1URL, ch2URL) = try writeSyntheticEPUBChapters(in: tempDir, port: server.port)
        let navRecorder = URLRecorder()
        let view = EPUBNativeWKWebView(
            chapterURL: ch1URL,
            baseDirectory: tempDir,
            fontSize: 16.0,
            fontStyle: "serif",
            readerTheme: "dark",
            onNavigateToChapterURL: { url in navRecorder.urls.append(url) }
        )

        let coordinator = view.makeCoordinator()
        let config = WKWebViewConfiguration()
        TTWebPreviewContentPolicy.apply(to: config)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        coordinator.loadChapterURL(
            ch1URL,
            fragment: nil,
            resolvedBaseURL: EPUBNativeWKWebView.resolveBaseURL(for: ch1URL),
            baseDir: tempDir,
            fontSize: 16.0,
            fontStyle: "serif",
            readerTheme: "dark",
            in: webView
        )

        try await waitUntilWebViewReady(webView, expectedElementId: "ch1-title")
        try await waitUntilImageComplete(webView, elementId: "safe-epub-img")
        let pwnedValue = try await evalString(in: webView, js: "document.body.dataset.pwned || 'clean'")
        XCTAssertEqual(pwnedValue, "clean", "Book inline script must be blocked")
        XCTAssertEqual(server.requestCount, 0, "Remote resources in EPUB must be stripped and blocked")
        let initialBodyClass = try await evalString(in: webView, js: "document.body.className")
        XCTAssertEqual(initialBodyClass, "theme-dark")
        let epubImgLoaded = try await evalString(
            in: webView,
            js: "(document.getElementById('safe-epub-img').complete && document.getElementById('safe-epub-img').naturalWidth === 1) ? 'yes' : 'no'"
        )
        let titleSpacing = try await evalString(
            in: webView,
            js: "window.getComputedStyle(document.getElementById('ch1-title')).letterSpacing"
        )
        XCTAssertEqual(epubImgLoaded, "yes", "Legitimate in-book EPUB image must load in WKWebView")
        XCTAssertEqual(titleSpacing, "3px", "Legitimate EPUB CSS styling must apply in WKWebView")

        try await verifyEPUBThemeAndChapterNavigation(
            webView: webView,
            coordinator: coordinator,
            tempDir: tempDir,
            ch1URL: ch1URL,
            ch2URL: ch2URL,
            navRecorder: navRecorder
        )
    }

    private func writeSyntheticEPUBChapters(in tempDir: URL, port: UInt16) throws -> (URL, URL) {
        let safePNGData = try XCTUnwrap(Data(base64Encoded: Self.safe1x1PNGBase64))
        try safePNGData.write(to: tempDir.appendingPathComponent("safe-epub.png"))

        let ch1URL = tempDir.appendingPathComponent("ch1.xhtml")
        let ch2URL = tempDir.appendingPathComponent("ch2.xhtml")
        let ch1Content = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>Chapter 1</title>
            <link rel="stylesheet" href="http://127.0.0.1:\(port)/evil.css"/>
            <style>#ch1-title { letter-spacing: 3px; }</style>
            <script>if (document.body) { document.body.dataset.pwned = 'yes'; }</script>
        </head>
        <body>
            <script>document.body.dataset.pwned = 'yes';</script>
            <h1 id="ch1-title">Chapter One</h1>
            <img id="safe-epub-img" src="safe-epub.png" alt="safe"/>
            <p><a id="link-anchor" href="#sec2">Jump to Section 2</a></p>
            <p><a id="link-ch2" href="ch2.xhtml#target">Go to Chapter 2 Target</a></p>
            <div style="height: 1200px;">Spacer</div>
            <h2 id="sec2">Section 2 Anchor</h2>
            <img src="http://127.0.0.1:\(port)/remote.png"/>
        </body>
        </html>
        """
        let ch2Content = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter 2</title></head>
        <body>
            <h1 id="ch2-title">Chapter Two</h1>
            <div style="height: 1000px;">Intro</div>
            <h2 id="target">Chapter 2 Target Heading</h2>
        </body>
        </html>
        """
        try ch1Content.write(to: ch1URL, atomically: true, encoding: .utf8)
        try ch2Content.write(to: ch2URL, atomically: true, encoding: .utf8)
        return (ch1URL, ch2URL)
    }

    private func verifyEPUBThemeAndChapterNavigation(
        webView: WKWebView,
        coordinator: EPUBNativeWKWebView.Coordinator,
        tempDir: URL,
        ch1URL: URL,
        ch2URL: URL,
        navRecorder: URLRecorder
    ) async throws {
        let updateJS = """
        document.documentElement.style.setProperty('--reader-font-size', '22.0pt');
        document.body.className = 'theme-sepia';
        'ok';
        """
        _ = try await evalString(in: webView, js: updateJS)
        coordinator.currentTheme = "sepia"
        coordinator.currentFontSize = 22.0

        let updatedClass = try await evalString(in: webView, js: "document.body.className")
        let updatedFontSize = try await evalString(
            in: webView,
            js: "document.documentElement.style.getPropertyValue('--reader-font-size')"
        )
        XCTAssertEqual(updatedClass, "theme-sepia")
        XCTAssertEqual(updatedFontSize, "22.0pt")

        let inPageAnchorURL = try XCTUnwrap(URL(string: ch1URL.absoluteString + "#sec2"))
        let anchorPolicy = await queryPolicy(
            coordinator: coordinator,
            webView: webView,
            action: SyntheticNavigationAction(url: inPageAnchorURL, navigationType: .linkActivated, isMainFrame: true)
        )
        XCTAssertEqual(anchorPolicy, .cancel)
        try await Task.sleep(for: .milliseconds(100))
        let locationHash = try await evalString(in: webView, js: "window.location.hash")
        XCTAssertEqual(locationHash, "#sec2")

        let ch2TargetURL = try XCTUnwrap(URL(string: ch2URL.absoluteString + "#target"))
        let ch2Policy = await queryPolicy(
            coordinator: coordinator,
            webView: webView,
            action: SyntheticNavigationAction(url: ch2TargetURL, navigationType: .linkActivated, isMainFrame: true)
        )
        XCTAssertEqual(ch2Policy, .cancel)
        XCTAssertEqual(navRecorder.urls, [ch2TargetURL])

        coordinator.loadChapterURL(
            ch2URL,
            fragment: "target",
            resolvedBaseURL: EPUBNativeWKWebView.resolveBaseURL(for: ch2URL),
            baseDir: tempDir,
            fontSize: 22.0,
            fontStyle: "serif",
            readerTheme: "sepia",
            in: webView
        )
        try await waitUntilWebViewReady(webView, expectedElementId: "ch2-title")
        try await Task.sleep(for: .milliseconds(100))
        let ch2BodyClass = try await evalString(in: webView, js: "document.body.className")
        let ch2Hash = try await evalString(in: webView, js: "window.location.hash")
        XCTAssertEqual(ch2BodyClass, "theme-sepia")
        XCTAssertEqual(ch2Hash, "#target")
    }

    // MARK: - Test 4: EPUB Resource Boundary, Symlink & Fallback Isolation

    private struct BoundaryFixture {
        let workspaceDir: URL
        let bookDir: URL
        let chapterURL: URL
        let safeImageURL: URL
        let outsideSecretURL: URL
        let siblingSecretURL: URL
        let directSymlinkURL: URL
        let chainedTargetURL: URL
        let safeImageBytes: Data
        let outsideSecretBytes: Data
        let siblingSecretBytes: Data
    }

    private func buildBoundaryFixture() throws -> BoundaryFixture {
        let workspaceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBBoundaryTest_\(UUID().uuidString)", isDirectory: true)
        let bookDir = workspaceDir.appendingPathComponent("book", isDirectory: true)
        let textDir = bookDir.appendingPathComponent("OEBPS/text", isDirectory: true)
        let imgDir = bookDir.appendingPathComponent("OEBPS/images", isDirectory: true)
        let siblingEvilDir = workspaceDir.appendingPathComponent("book-evil", isDirectory: true)
        let outsideDir = workspaceDir.appendingPathComponent("outside", isDirectory: true)
        let subDir = imgDir.appendingPathComponent("sub", isDirectory: true)

        for dir in [textDir, imgDir, siblingEvilDir, outsideDir, subDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let safeImageBytes = Data("SAFE_BOOK_IMAGE_PAYLOAD".utf8)
        let outsideSecretBytes = Data("OUTSIDE_SECRET_DO_NOT_INLINE".utf8)
        let siblingSecretBytes = Data("SIBLING_PREFIX_SECRET_DO_NOT_INLINE".utf8)

        let safeImageURL = imgDir.appendingPathComponent("safe.png")
        let outsideSecretURL = outsideDir.appendingPathComponent("outside_secret.png")
        let siblingSecretURL = siblingEvilDir.appendingPathComponent("secret.png")
        try safeImageBytes.write(to: safeImageURL)
        try outsideSecretBytes.write(to: outsideSecretURL)
        try siblingSecretBytes.write(to: siblingSecretURL)
        try Data("body { content: 'OUTSIDE_CSS_SECRET'; }".utf8).write(to: outsideDir.appendingPathComponent("evil.css"))

        let directSymlinkURL = imgDir.appendingPathComponent("symlink_outside.png")
        try FileManager.default.createSymbolicLink(at: directSymlinkURL, withDestinationURL: outsideSecretURL)
        let chainedLeafURL = subDir.appendingPathComponent("link2.png")
        try FileManager.default.createSymbolicLink(atPath: chainedLeafURL.path, withDestinationPath: "../../../../outside/outside_secret.png")
        let chainedEntryDirURL = imgDir.appendingPathComponent("link1")
        try FileManager.default.createSymbolicLink(atPath: chainedEntryDirURL.path, withDestinationPath: "sub")

        let chapterURL = textDir.appendingPathComponent("ch1.xhtml")
        let chapterHTML = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><link rel="stylesheet" href="../../../outside/evil.css"/></head>
        <body>
            <img id="safe" src="../images/safe.png"/>
            <img id="traversal" src="../../../outside/outside_secret.png"/>
            <img id="sibling" src="../../../book-evil/secret.png"/>
            <img id="direct-symlink" src="../images/symlink_outside.png"/>
            <img id="chained-symlink" src="../images/link1/link2.png"/>
        </body>
        </html>
        """
        try chapterHTML.write(to: chapterURL, atomically: true, encoding: .utf8)

        return BoundaryFixture(
            workspaceDir: workspaceDir,
            bookDir: bookDir,
            chapterURL: chapterURL,
            safeImageURL: safeImageURL,
            outsideSecretURL: outsideSecretURL,
            siblingSecretURL: siblingSecretURL,
            directSymlinkURL: directSymlinkURL,
            chainedTargetURL: chainedEntryDirURL.appendingPathComponent("link2.png"),
            safeImageBytes: safeImageBytes,
            outsideSecretBytes: outsideSecretBytes,
            siblingSecretBytes: siblingSecretBytes
        )
    }

    func testEPUBResourceBoundaryBlocksTraversalSiblingSymlinksAndLocalFallback() async throws {
        let fixture = try buildBoundaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspaceDir) }

        XCTAssertTrue(EPUBChapterContentLoaderActor.isResourceWithinBookBoundary(
            assetURL: fixture.safeImageURL, chapterURL: fixture.chapterURL, baseDirectory: fixture.bookDir
        ))
        for forbiddenURL in [fixture.outsideSecretURL, fixture.siblingSecretURL, fixture.directSymlinkURL, fixture.chainedTargetURL] {
            XCTAssertFalse(EPUBChapterContentLoaderActor.isResourceWithinBookBoundary(
                assetURL: forbiddenURL, chapterURL: fixture.chapterURL, baseDirectory: fixture.bookDir
            ))
        }

        let vfsBase = try XCTUnwrap(URL(string: "ttzip-vfs://archive-alpha/"))
        let vfsChapter = try XCTUnwrap(URL(string: "ttzip-vfs://archive-alpha/OEBPS/text/ch1.xhtml"))
        let vfsSameAsset = try XCTUnwrap(URL(string: "ttzip-vfs://archive-alpha/OEBPS/images/cover.png"))
        let vfsCrossArchiveAsset = try XCTUnwrap(URL(string: "ttzip-vfs://archive-beta/OEBPS/images/secret.png"))
        XCTAssertTrue(EPUBChapterContentLoaderActor.isResourceWithinBookBoundary(
            assetURL: vfsSameAsset, chapterURL: vfsChapter, baseDirectory: vfsBase
        ))
        XCTAssertFalse(EPUBChapterContentLoaderActor.isResourceWithinBookBoundary(
            assetURL: vfsCrossArchiveAsset, chapterURL: vfsChapter, baseDirectory: vfsBase
        ))

        let previousProvider = EPUBChapterContentLoaderActor.customDataProvider
        defer { EPUBChapterContentLoaderActor.customDataProvider = previousProvider }
        let requestedProviderURLs = NSLock()
        nonisolated(unsafe) var recordedURLs: [URL] = []
        EPUBChapterContentLoaderActor.customDataProvider = { url in
            requestedProviderURLs.withLock { recordedURLs.append(url) }
            return nil
        }

        let rawRenderedHTML = await EPUBChapterContentLoaderActor.shared.loadChapter(
            at: fixture.chapterURL, customCSS: "<style>body{}</style>", baseDirectory: fixture.bookDir
        )
        let renderedHTML = try XCTUnwrap(rawRenderedHTML)
        XCTAssertTrue(renderedHTML.contains(fixture.safeImageBytes.base64EncodedString()))
        XCTAssertFalse(renderedHTML.contains(fixture.outsideSecretBytes.base64EncodedString()))
        XCTAssertFalse(renderedHTML.contains(fixture.siblingSecretBytes.base64EncodedString()))
        XCTAssertFalse(renderedHTML.contains("OUTSIDE_CSS_SECRET"))

        for calledURL in recordedURLs {
            XCTAssertTrue(EPUBChapterContentLoaderActor.isResourceWithinBookBoundary(
                assetURL: calledURL, chapterURL: fixture.chapterURL, baseDirectory: fixture.bookDir
            ))
        }

        let view = EPUBNativeWKWebView(
            chapterURL: fixture.chapterURL, baseDirectory: fixture.bookDir, fontSize: 16.0, fontStyle: "serif", readerTheme: "light"
        )
        let coordinator = view.makeCoordinator()
        coordinator.lastLoadedChapterURL = fixture.chapterURL
        XCTAssertTrue(coordinator.isInternalBookURL(fixture.safeImageURL))
        for forbiddenURL in [fixture.siblingSecretURL, fixture.directSymlinkURL, fixture.chainedTargetURL] {
            XCTAssertFalse(coordinator.isInternalBookURL(forbiddenURL))
        }
    }

    // MARK: - Helpers

    private func queryPolicy(
        coordinator: WKNavigationDelegate,
        webView: WKWebView,
        action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        await withCheckedContinuation { continuation in
            coordinator.webView?(webView, decidePolicyFor: action) { policy in
                continuation.resume(returning: policy)
            }
        }
    }

    private func evalString(in webView: WKWebView, js: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value as? String)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func assertProbeServerPositiveReachability(_ server: LoopbackHTTPProbeServer) async throws {
        let probeURL = server.baseURL.appendingPathComponent("positive-control")
        let (data, response) = try await URLSession.shared.data(from: probeURL)
        let httpResp = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResp.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "OK")
        XCTAssertEqual(server.requestCount, 1, "Positive control request must reach LoopbackHTTPProbeServer")
        XCTAssertEqual(server.requestPaths, ["/positive-control"])
        server.reset()
        XCTAssertEqual(server.requestCount, 0)
    }

    private func makeConfiguredHTMLWebView(
        content: String,
        fileURL: URL?
    ) -> (WKWebView, HTMLWKWebViewRepresentable.Coordinator) {
        let representable = HTMLWKWebViewRepresentable(content: content, fileURL: fileURL)
        let coordinator = representable.makeCoordinator()
        let config = WKWebViewConfiguration()
        TTWebPreviewContentPolicy.apply(to: config)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        retainedObjects.append(coordinator)
        retainedObjects.append(webView)
        representable.loadHTML(in: webView, coordinator: coordinator)
        return (webView, coordinator)
    }

    private func waitUntilWebViewReady(_ webView: WKWebView, expectedElementId: String, timeoutSeconds: Double = 5.0) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let found = try? await evalString(
                in: webView,
                js: "document.getElementById('\(expectedElementId)') ? 'yes' : 'no'"
            ), found == "yes" {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for element #\(expectedElementId) in WKWebView")
    }

    private func waitUntilImageComplete(_ webView: WKWebView, elementId: String, timeoutSeconds: Double = 5.0) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let ready = try? await evalString(
                in: webView,
                js: "(document.getElementById('\(elementId)') && document.getElementById('\(elementId)').complete && document.getElementById('\(elementId)').naturalWidth > 0) ? 'yes' : 'no'"
            ), ready == "yes" {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for image #\(elementId) to decode in WKWebView")
    }
}
