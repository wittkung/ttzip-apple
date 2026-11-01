// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import WebKit
@testable import TTMediaKit

@MainActor
private final class EPUBChapterLinkNavigationAction: WKNavigationAction {
    private let _request: URLRequest

    init(url: URL) {
        self._request = URLRequest(url: url)
        super.init()
    }

    override var request: URLRequest { _request }
    override var navigationType: WKNavigationType { .linkActivated }
    override var targetFrame: WKFrameInfo? { nil }
}

@MainActor
final class EPUBReaderWorkspaceContractTests: XCTestCase {
    func testIndependentLatinAndCJKFamiliesDoNotConflateSelections() {
        let css = EPUBNativeWKWebView.resolveFontFamilyCSS(for: "mono|kaiti")
        XCTAssertTrue(css.hasPrefix("Menlo, Courier"))
        XCTAssertTrue(css.contains("STKaiti"))
        XCTAssertFalse(css.contains("PingFang SC"))
        let alternative = EPUBNativeWKWebView.resolveFontFamilyCSS(for: "sans|serif")
        XCTAssertTrue(alternative.hasPrefix("Arial, Helvetica"))
        XCTAssertTrue(alternative.contains("Songti SC"))
    }

    func testAnnotationLocationWithinSameChapterRequestsAnchorWithoutJumpingToPageZero() {
        let controller = EPUBPaginationController(totalChapters: 3)
        controller.didSynchronizeWebViewPagination(
            chapterIndex: 0, pageIndex: 2, totalPages: 9, anchorBlockIndex: 4,
            readingDirectionRaw: "ltr"
        )
        var received: (Int, Int, Double)?
        controller.onRequestAnchorJump = { received = ($0, $1, $2) }
        controller.navigateToAnchor(chapterIndex: 0, blockIndex: 12, characterOffset: 42, ratio: 0.7)
        XCTAssertEqual(received?.0, 12)
        XCTAssertEqual(received?.1, 42)
        XCTAssertEqual(received?.2, 0.7)
        XCTAssertEqual(controller.currentPageIndex, 2, "Only a DOM measurement may replace the page index")
    }

    func testAnnotationLocationInAnotherChapterPreservesPreciseLanding() {
        let controller = EPUBPaginationController(totalChapters: 3)
        controller.didSynchronizeWebViewPagination(
            chapterIndex: 0, pageIndex: 0, totalPages: 2, anchorBlockIndex: 0,
            readingDirectionRaw: "ltr"
        )
        var requested: EPUBBoundaryLanding?
        controller.onRequestChapterIndexChange = { _, landing in requested = landing }
        controller.navigateToAnchor(chapterIndex: 2, blockIndex: 8, characterOffset: 19, ratio: 0.3)
        XCTAssertEqual(controller.currentChapterIndex, 2)
        XCTAssertEqual(requested, .preserveAnchor(progressRatio: 0.3, anchorBlockIndex: 8, anchorCharOffset: 19))
        XCTAssertTrue(controller.isChapterTransitionInFlight)
    }

    // MARK: - R2 Chapter Identity & Cross-Directory Link Resolution Regressions

    func testMultiDirectorySameBasenameSelectsExactPart2ChapterAndFragmentViaRealBridge() async throws {
        let fixture = try makeChapterIdentityFixture()
        defer { fixture.cleanup() }

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: fixture.bookModel.chapters.count)
        let readerView = InteractiveEPUBReaderView(bookModel: fixture.bookModel, paginationController: controller)
        let selectedBox = NavigationSelectionBox()
        let bridge = try mountChapterBridge(
            chapterIndex: 0,
            bookModel: fixture.bookModel,
            controller: controller,
            onNavigate: { targetURL in
                selectedBox.indices.append(readerView.selectChapter(matching: targetURL))
            }
        )
        defer { bridge.cleanup() }

        let ch0Ready = await waitUntilReady(timeout: 6.0) { controller.isPaginationReady }
        XCTAssertTrue(ch0Ready, "Initial part1/index.xhtml must finish pagination before activating link")

        let domResolvedHref = await evalReaderString(
            "document.getElementById('link-exact-part2') ? document.getElementById('link-exact-part2').href : ''",
            in: bridge.webView
        )
        let targetURL = try XCTUnwrap(URL(string: domResolvedHref ?? ""))
        let policy = await activateLink(targetURL, on: bridge)

        XCTAssertEqual(policy, .cancel, "Internal chapter link must be intercepted by EPUBNativeWKWebView")
        XCTAssertEqual(selectedBox.indices, [1], "Must select part2/index.xhtml (index 1), not part1/index.xhtml (index 0)")
        XCTAssertEqual(controller.currentChapterIndex, 1)
        XCTAssertEqual(controller.pendingLanding, .fragment("sec-target"))
    }

    func testUniqueBasenameLegacyLinkCompatibilitySelectsUniqueChapterViaRealBridge() async throws {
        let fixture = try makeChapterIdentityFixture()
        defer { fixture.cleanup() }

        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: fixture.bookModel.chapters.count)
        let readerView = InteractiveEPUBReaderView(bookModel: fixture.bookModel, paginationController: controller)
        let selectedBox = NavigationSelectionBox()
        let bridge = try mountChapterBridge(
            chapterIndex: 0,
            bookModel: fixture.bookModel,
            controller: controller,
            onNavigate: { targetURL in
                selectedBox.indices.append(readerView.selectChapter(matching: targetURL))
            }
        )
        defer { bridge.cleanup() }

        let ch0Ready = await waitUntilReady(timeout: 6.0) { controller.isPaginationReady }
        XCTAssertTrue(ch0Ready)

        let domResolvedHref = await evalReaderString(
            "document.getElementById('link-legacy-unique') ? document.getElementById('link-legacy-unique').href : ''",
            in: bridge.webView
        )
        let legacyURL = try XCTUnwrap(URL(string: domResolvedHref ?? ""))
        let policy = await activateLink(legacyURL, on: bridge)

        XCTAssertEqual(policy, .cancel)
        XCTAssertEqual(selectedBox.indices, [2], "Unique basename legacy link must resolve to text/unique_appendix.xhtml (index 2)")
        XCTAssertEqual(controller.currentChapterIndex, 2)
        XCTAssertEqual(controller.pendingLanding, .fragment("app-anchor"))
        XCTAssertEqual(
            bridge.coordinator.lastLoadedChapterURL,
            EPUBNativeWKWebView.stripFragment(from: fixture.bookModel.chapters[2].fileURL)
        )
    }

    func testAmbiguousMultiCandidateBasenameAndCrossBookLinkMustNotHijackChapter() async throws {
        let fixture = try makeChapterIdentityFixture()
        defer { fixture.cleanup() }

        let controller = EPUBPaginationController(initialChapterIndex: 1, totalChapters: fixture.bookModel.chapters.count)
        let readerView = InteractiveEPUBReaderView(bookModel: fixture.bookModel, paginationController: controller)
        let selectedBox = NavigationSelectionBox()
        let bridge = try mountChapterBridge(
            chapterIndex: 1,
            bookModel: fixture.bookModel,
            controller: controller,
            onNavigate: { targetURL in
                selectedBox.indices.append(readerView.selectChapter(matching: targetURL))
            }
        )
        defer { bridge.cleanup() }

        let ch1Ready = await waitUntilReady(timeout: 6.0) { controller.isPaginationReady }
        XCTAssertTrue(ch1Ready, "Initial part2/index.xhtml (chapter 1) must finish pagination")
        XCTAssertEqual(controller.currentChapterIndex, 1)
        let initialLanding = controller.pendingLanding
        let initialLoadedURL = bridge.coordinator.lastLoadedChapterURL

        let domResolvedHref = await evalReaderString(
            "document.getElementById('link-ambiguous-notes') ? document.getElementById('link-ambiguous-notes').href : ''",
            in: bridge.webView
        )
        let unindexedNotesURL = try XCTUnwrap(URL(string: domResolvedHref ?? ""))
        _ = await activateLink(unindexedNotesURL, on: bridge)
        let chapterAfterAmbiguousNotes = controller.currentChapterIndex
        let landingAfterAmbiguousNotes = controller.pendingLanding
        let loadedAfterAmbiguousNotes = bridge.coordinator.lastLoadedChapterURL

        let domNotesUniqueHref = await evalReaderString(
            "document.getElementById('link-notes-unique-name') ? document.getElementById('link-notes-unique-name').href : ''",
            in: bridge.webView
        )
        let nonSpineUniqueNameURL = try XCTUnwrap(URL(string: domNotesUniqueHref ?? ""))
        _ = await activateLink(nonSpineUniqueNameURL, on: bridge)

        let crossBookURL = try XCTUnwrap(URL(string: "ttzip-vfs://other-foreign-archive/OEBPS/text/unique_appendix.xhtml#sec"))
        let crossBookSelected = readerView.selectChapter(matching: crossBookURL)

        XCTAssertEqual(
            selectedBox.indices,
            [nil, nil],
            "Ambiguous basename 'index.xhtml' and non-spine 'notes/unique_appendix.xhtml' must not bind to spine chapters"
        )
        XCTAssertEqual(
            chapterAfterAmbiguousNotes,
            1,
            "Unindexed ambiguous link must not hijack currentChapterIndex from chapter 1 (part2) to chapter 0 (part1)"
        )
        XCTAssertEqual(landingAfterAmbiguousNotes, initialLanding, "Ambiguous link must not mutate pendingLanding")
        XCTAssertEqual(loadedAfterAmbiguousNotes, initialLoadedURL, "Unresolved non-spine link must not navigate active WebView")
        XCTAssertNil(crossBookSelected, "Cross-book URL must not match current book chapters via basename fallback")
    }

    func testContainerBoundarySamePrefixSiblingAndCrossSchemeAuthorityRejectionAndSameBookPositive() throws {
        let fixture = try makeChapterIdentityFixture()
        defer { fixture.cleanup() }

        let siblingRoot = URL(fileURLWithPath: fixture.rootDir.path + "2", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: siblingRoot) }

        let controller = EPUBPaginationController(initialChapterIndex: 1, totalChapters: fixture.bookModel.chapters.count)
        let readerView = InteractiveEPUBReaderView(bookModel: fixture.bookModel, paginationController: controller)
        let cleanupProgress = makeProgressDefaultsCleanup(for: [fixture.bookModel.url])
        defer { cleanupProgress() }

        let siblingExactURL = try XCTUnwrap(URL(string: siblingRoot.appendingPathComponent("OEBPS/part1/index.xhtml").absoluteString + "#sec"))
        let siblingUniqueURL = try XCTUnwrap(URL(string: siblingRoot.appendingPathComponent("OEBPS/text/unique_appendix.xhtml").absoluteString + "#app"))
        let traversalSiblingURL = try XCTUnwrap(URL(
            string: fixture.rootDir.appendingPathComponent("../\(siblingRoot.lastPathComponent)/OEBPS/text/unique_appendix.xhtml").absoluteString
        ))
        let customSchemeSamePathURL = try XCTUnwrap(URL(string: "custom://" + fixture.bookModel.chapters[0].fileURL.path + "#frag"))
        let remoteFileHostURL = try XCTUnwrap(URL(string: "file://evilhost" + fixture.bookModel.chapters[0].fileURL.path))

        for forbiddenURL in [siblingExactURL, siblingUniqueURL, traversalSiblingURL, customSchemeSamePathURL, remoteFileHostURL] {
            XCTAssertNil(readerView.selectChapter(matching: forbiddenURL), "Must reject out-of-boundary URL: \(forbiddenURL)")
            XCTAssertEqual(controller.currentChapterIndex, 1)
            XCTAssertEqual(controller.pendingLanding, .firstPage)
        }

        try verifyVfsContainerBoundaryPositiveAndNegativeControls()
    }

    func testCaseOnlyChapterNameDifferenceResolvesByActualURLIdentityWithoutLowercaseCollision() throws {
        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-r2-case-\(UUID().uuidString)", isDirectory: true)
        let bookURL = rootDir.appendingPathComponent("case-book.epub")
        let cleanupProgress = makeProgressDefaultsCleanup(for: [bookURL])
        defer {
            cleanupProgress()
            try? FileManager.default.removeItem(at: rootDir)
        }

        let upperURL = rootDir.appendingPathComponent("OEBPS/text/Chapter.xhtml")
        let lowerURL = rootDir.appendingPathComponent("OEBPS/text/chapter.xhtml")
        let appendixURL = rootDir.appendingPathComponent("OEBPS/text/UniqueAppendix.xhtml")
        let chapters = [
            EPUBChapterItem(id: "0", title: "Upper Chapter", fileURL: upperURL),
            EPUBChapterItem(id: "1", title: "Lower chapter", fileURL: lowerURL),
            EPUBChapterItem(id: "2", title: "Appendix", fileURL: appendixURL)
        ]
        let model = EPUBBookModel(url: bookURL, title: "Case Book", chapters: chapters, extractDir: rootDir)
        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: chapters.count)
        let readerView = InteractiveEPUBReaderView(bookModel: model, paginationController: controller)

        let targetLower = try XCTUnwrap(URL(string: lowerURL.absoluteString + "#lower-sec"))
        XCTAssertEqual(
            readerView.selectChapter(matching: targetLower),
            1,
            "Exact lower-case chapter URL must select chapter 1 ('chapter.xhtml'), not collide with chapter 0 ('Chapter.xhtml')"
        )
        XCTAssertEqual(controller.currentChapterIndex, 1)
        XCTAssertEqual(controller.pendingLanding, .fragment("lower-sec"))

        let targetUpper = try XCTUnwrap(URL(string: upperURL.absoluteString + "#upper-sec"))
        XCTAssertEqual(readerView.selectChapter(matching: targetUpper), 0)
        XCTAssertEqual(controller.currentChapterIndex, 0)
        XCTAssertEqual(controller.pendingLanding, .fragment("upper-sec"))

        let ambiguousAllCaps = try XCTUnwrap(URL(string: rootDir.appendingPathComponent("OEBPS/text/CHAPTER.xhtml").absoluteString + "#amb"))
        let unindexedNotesLower = try XCTUnwrap(URL(string: rootDir.appendingPathComponent("OEBPS/notes/chapter.xhtml").absoluteString + "#note"))
        XCTAssertNil(readerView.selectChapter(matching: ambiguousAllCaps))
        XCTAssertNil(readerView.selectChapter(matching: unindexedNotesLower))
        XCTAssertEqual(controller.currentChapterIndex, 0)
        XCTAssertEqual(controller.pendingLanding, .fragment("upper-sec"))
    }
}

@MainActor
private final class NavigationSelectionBox {
    var indices: [Int?] = []
}

@MainActor
private extension EPUBReaderWorkspaceContractTests {
    struct ChapterIdentityFixture {
        let rootDir: URL
        let bookModel: EPUBBookModel
        let progressKeyPrefix: String

        func cleanup() {
            for suffix in ["_chapter", "_page", "_anchor", "_char", "_ratio"] {
                UserDefaults.standard.removeObject(forKey: progressKeyPrefix + suffix)
            }
            try? FileManager.default.removeItem(at: rootDir)
        }
    }

    struct MountedChapterBridge {
        let window: NSWindow
        let webView: EPUBReaderWKWebView
        let coordinator: EPUBNativeWKWebView.Coordinator

        @MainActor
        func cleanup() {
            EPUBNativeWKWebView.dismantleNSView(webView, coordinator: coordinator)
            window.orderOut(nil)
        }
    }

    func makeProgressDefaultsCleanup(for bookURLs: [URL]) -> () -> Void {
        let prefixes = bookURLs.map { url -> String in
            let cleanPath = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "TTMedia_EPUB_Progress_" + InteractiveEPUBReaderView.stableBookDigest(for: cleanPath)
        }
        return {
            for prefix in prefixes {
                for suffix in ["_chapter", "_page", "_anchor", "_char", "_ratio"] {
                    UserDefaults.standard.removeObject(forKey: prefix + suffix)
                }
            }
        }
    }

    func verifyVfsContainerBoundaryPositiveAndNegativeControls() throws {
        let vfsBookURL = try XCTUnwrap(URL(string: "ttzip-vfs://archive-alpha/book.epub"))
        let vfsRoot = try XCTUnwrap(URL(string: "ttzip-vfs://archive-alpha/"))
        let vfsCh0 = try XCTUnwrap(URL(string: "ttzip-vfs://archive-alpha/OEBPS/part1/index.xhtml"))
        let vfsCh1 = try XCTUnwrap(URL(string: "ttzip-vfs://archive-alpha/OEBPS/part2/index.xhtml"))
        let vfsCh2 = try XCTUnwrap(URL(string: "ttzip-vfs://archive-alpha/OEBPS/text/unique_appendix.xhtml"))
        let vfsChapters = [
            EPUBChapterItem(id: "0", title: "Part 1", fileURL: vfsCh0),
            EPUBChapterItem(id: "1", title: "Part 2", fileURL: vfsCh1),
            EPUBChapterItem(id: "2", title: "Appendix", fileURL: vfsCh2)
        ]
        let vfsModel = EPUBBookModel(url: vfsBookURL, title: "VFS Book", chapters: vfsChapters, extractDir: vfsRoot)
        let vfsController = EPUBPaginationController(initialChapterIndex: 0, totalChapters: vfsChapters.count)
        let vfsReader = InteractiveEPUBReaderView(bookModel: vfsModel, paginationController: vfsController)
        let vfsDigest = InteractiveEPUBReaderView.stableBookDigest(for: "ttzip-vfs://archive-alpha/book.epub")
        defer {
            for suffix in ["_chapter", "_page", "_anchor", "_char", "_ratio"] {
                UserDefaults.standard.removeObject(forKey: "TTMedia_EPUB_Progress_" + vfsDigest + suffix)
            }
        }

        let sameBookExact = try XCTUnwrap(URL(string: "ttzip-vfs://archive-alpha/OEBPS/part2/index.xhtml#vfs-sec"))
        XCTAssertEqual(vfsReader.selectChapter(matching: sameBookExact), 1)
        XCTAssertEqual(vfsController.pendingLanding, .fragment("vfs-sec"))

        let sameBookLegacyUnique = try XCTUnwrap(URL(string: "ttzip-vfs://archive-alpha/OEBPS/part1/unique_appendix.xhtml#vfs-app"))
        XCTAssertEqual(vfsReader.selectChapter(matching: sameBookLegacyUnique), 2)
        XCTAssertEqual(vfsController.pendingLanding, .fragment("vfs-app"))

        let samePrefixHost = try XCTUnwrap(URL(string: "ttzip-vfs://archive-alpha-2/OEBPS/part2/index.xhtml"))
        let differentPort = try XCTUnwrap(URL(string: "ttzip-vfs://archive-alpha:8080/OEBPS/part2/index.xhtml"))
        let differentUser = try XCTUnwrap(URL(string: "ttzip-vfs://reader@archive-alpha/OEBPS/part2/index.xhtml"))
        let crossSchemeFile = try XCTUnwrap(URL(string: "file:///OEBPS/part2/index.xhtml"))
        for rejected in [samePrefixHost, differentPort, differentUser, crossSchemeFile] {
            XCTAssertNil(vfsReader.selectChapter(matching: rejected), "Must reject cross-container VFS URL: \(rejected)")
            XCTAssertEqual(vfsController.currentChapterIndex, 2)
            XCTAssertEqual(vfsController.pendingLanding, .fragment("vfs-app"))
        }
    }

    func makeChapterIdentityFixture() throws -> ChapterIdentityFixture {
        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-r2-identity-\(UUID().uuidString)", isDirectory: true)
        let oebps = rootDir.appendingPathComponent("OEBPS", isDirectory: true)
        let part1Dir = oebps.appendingPathComponent("part1", isDirectory: true)
        let part2Dir = oebps.appendingPathComponent("part2", isDirectory: true)
        let textDir = oebps.appendingPathComponent("text", isDirectory: true)
        let notesDir = oebps.appendingPathComponent("notes", isDirectory: true)
        for dir in [part1Dir, part2Dir, textDir, notesDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let part1URL = part1Dir.appendingPathComponent("index.xhtml")
        let part2URL = part2Dir.appendingPathComponent("index.xhtml")
        let appendixURL = textDir.appendingPathComponent("unique_appendix.xhtml")
        let notesURL = notesDir.appendingPathComponent("index.xhtml")
        let notesUniqueURL = notesDir.appendingPathComponent("unique_appendix.xhtml")

        try """
        <!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/></head><body>
        <h1>Part 1</h1>
        <p><a id="link-exact-part2" href="../part2/index.xhtml#sec-target">Part 2 Target</a></p>
        <p><a id="link-legacy-unique" href="unique_appendix.xhtml#app-anchor">Legacy Unique Appendix</a></p>
        </body></html>
        """.write(to: part1URL, atomically: true, encoding: .utf8)

        try """
        <!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/></head><body>
        <h1>Part 2</h1><h2 id="sec-target">Section Target</h2>
        <p><a id="link-ambiguous-notes" href="../notes/index.xhtml#fn-1">Footnote 1</a></p>
        <p><a id="link-notes-unique-name" href="../notes/unique_appendix.xhtml#fn-2">Footnote 2</a></p>
        </body></html>
        """.write(to: part2URL, atomically: true, encoding: .utf8)

        try """
        <!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/></head><body>
        <h1 id="app-anchor">Unique Appendix</h1>
        </body></html>
        """.write(to: appendixURL, atomically: true, encoding: .utf8)

        try """
        <!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/></head><body>
        <aside id="fn-1">Non-spine Footnote</aside>
        </body></html>
        """.write(to: notesURL, atomically: true, encoding: .utf8)

        try """
        <!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/></head><body>
        <aside id="fn-2">Non-spine Appendix Note</aside>
        </body></html>
        """.write(to: notesUniqueURL, atomically: true, encoding: .utf8)

        let bookURL = rootDir.appendingPathComponent("sample.epub")
        let chapters = [
            EPUBChapterItem(id: "0", title: "Part 1", fileURL: part1URL),
            EPUBChapterItem(id: "1", title: "Part 2", fileURL: part2URL),
            EPUBChapterItem(id: "2", title: "Appendix", fileURL: appendixURL)
        ]
        let model = EPUBBookModel(url: bookURL, title: "R2 Sample", chapters: chapters, extractDir: rootDir)
        let cleanBookPath = bookURL.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let digest = InteractiveEPUBReaderView.stableBookDigest(for: cleanBookPath)
        return ChapterIdentityFixture(rootDir: rootDir, bookModel: model, progressKeyPrefix: "TTMedia_EPUB_Progress_" + digest)
    }

    func mountChapterBridge(
        chapterIndex: Int,
        bookModel: EPUBBookModel,
        controller: EPUBPaginationController,
        onNavigate: @escaping @MainActor @Sendable (URL) -> Void
    ) throws -> MountedChapterBridge {
        let chapterURL = bookModel.chapters[chapterIndex].fileURL
        let rep = EPUBNativeWKWebView(
            chapterURL: chapterURL,
            baseDirectory: bookModel.extractDir,
            fontSize: 17.0,
            fontStyle: "serif",
            readerTheme: "light",
            chapterIndex: chapterIndex,
            chapters: bookModel.chapters,
            paginationController: controller,
            onNavigateToChapterURL: onNavigate,
            layoutMode: controller.layoutMode.rawValue
        )
        let coordinator = rep.makeCoordinator()
        let config = WKWebViewConfiguration()
        TTWebPreviewContentPolicy.apply(to: config)
        config.userContentController.add(
            coordinator.inputStateMessageHandler,
            contentWorld: TTWebPreviewContentPolicy.readerControlWorld,
            name: EPUBReaderWebKitPagerBridge.inputStateHandlerName
        )
        let size = NSSize(width: 380, height: 280)
        let webView = EPUBReaderWKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        webView.readerInstanceID = controller.instanceID
        webView.paginationController = controller
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.bindPaginationAndFocusCallbacks(to: webView)
        let clean = EPUBNativeWKWebView.stripFragment(from: chapterURL)
        coordinator.loadChapterURL(
            clean,
            fragment: chapterURL.fragment,
            resolvedBaseURL: EPUBNativeWKWebView.resolveBaseURL(for: clean),
            baseDir: bookModel.extractDir,
            fontSize: 17.0,
            fontStyle: "serif",
            readerTheme: "light",
            in: webView
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        return MountedChapterBridge(window: window, webView: webView, coordinator: coordinator)
    }

    func activateLink(_ url: URL, on bridge: MountedChapterBridge) async -> WKNavigationActionPolicy {
        await withCheckedContinuation { continuation in
            let action = EPUBChapterLinkNavigationAction(url: url)
            bridge.coordinator.webView(bridge.webView, decidePolicyFor: action) { policy in
                continuation.resume(returning: policy)
            }
        }
    }

    func evalReaderString(_ js: String, in webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { outcome in
                continuation.resume(returning: (try? outcome.get()) as? String)
            }
        }
    }

    func waitUntilReady(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }
}
