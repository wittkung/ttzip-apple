// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import WebKit

// MARK: - Native WKWebView EPUB Chapter Viewport

public struct EPUBNativeWKWebView: NSViewRepresentable {
    public let chapterURL: URL
    public let baseDirectory: URL
    public let fontSize: Double
    public let fontStyle: String
    public let readerTheme: String
    public var chapterIndex: Int
    public var chapters: [EPUBChapterItem] = []
    public var paginationController: EPUBPaginationController?
    public var onNavigateToChapterURL: (@MainActor @Sendable (URL) -> Void)?
    public var layoutMode: String = "paginated"
    public var annotationSession: EPUBReaderAnnotationSession?

    public init(
        chapterURL: URL,
        baseDirectory: URL,
        fontSize: Double,
        fontStyle: String,
        readerTheme: String,
        chapterIndex: Int = 0,
        chapters: [EPUBChapterItem] = [],
        paginationController: EPUBPaginationController? = nil,
        onNavigateToChapterURL: (@MainActor @Sendable (URL) -> Void)? = nil,
        layoutMode: String = "paginated",
        annotationSession: EPUBReaderAnnotationSession? = nil
    ) {
        self.chapterURL = chapterURL
        self.baseDirectory = baseDirectory
        self.fontSize = fontSize
        self.fontStyle = fontStyle
        self.readerTheme = readerTheme
        self.chapterIndex = chapterIndex
        self.chapters = chapters
        self.paginationController = paginationController
        self.onNavigateToChapterURL = onNavigateToChapterURL
        self.layoutMode = layoutMode
        self.annotationSession = annotationSession
    }

    public typealias ConfigurationCustomizer = @Sendable @MainActor (WKWebViewConfiguration) -> Void
    @MainActor public static var webViewConfigurationCustomizer: ConfigurationCustomizer?

    public func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(parent: self)
        coordinator.baseDirectory = baseDirectory
        return coordinator
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        TTWebPreviewContentPolicy.apply(to: config)
        Self.webViewConfigurationCustomizer?(config)
        let coordinator = context.coordinator
        config.userContentController.removeScriptMessageHandler(
            forName: EPUBReaderWebKitPagerBridge.inputStateHandlerName,
            contentWorld: TTWebPreviewContentPolicy.readerControlWorld
        )
        config.userContentController.add(
            coordinator.inputStateMessageHandler,
            contentWorld: TTWebPreviewContentPolicy.readerControlWorld,
            name: EPUBReaderWebKitPagerBridge.inputStateHandlerName
        )
        let webView = EPUBReaderWKWebView(frame: .zero, configuration: config)
        if let paginationController {
            webView.readerInstanceID = paginationController.instanceID
            webView.paginationController = paginationController
        }
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        coordinator.bindPaginationAndFocusCallbacks(to: webView)
        coordinator.bindAnnotationCallbacks(to: webView)
        return webView
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.currentLoadTask?.cancel()
        coordinator.currentLoadTask = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: EPUBReaderWebKitPagerBridge.inputStateHandlerName,
            contentWorld: TTWebPreviewContentPolicy.readerControlWorld
        )
        coordinator.inputStateMessageHandler.onInputStateChanged = nil
        if let readerWebView = webView as? EPUBReaderWKWebView {
            TTPreviewKeyboardOwnershipCoordinator.shared.unregisterSession(instanceID: readerWebView.readerInstanceID)
            readerWebView.onViewportResized = nil
            readerWebView.paginationController = nil
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.lastLoadedChapterURL = nil
        coordinator.lastLoadedChapterContent = nil
        coordinator.lastLoadedBaseURL = nil
        coordinator.isLoadingChapterURL = nil
        coordinator.pendingFragment = nil
        coordinator.pendingNavigation = nil
        coordinator.parent = nil
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.baseDirectory = baseDirectory
        coordinator.bindPaginationAndFocusCallbacks(to: webView)
        coordinator.bindAnnotationCallbacks(to: webView)

        let cleanChapterURL = Self.stripFragment(from: chapterURL)
        let incomingFragment = chapterURL.fragment
        let resolvedBaseURL = Self.resolveBaseURL(for: cleanChapterURL)

        let fontFamilyCSS = Self.resolveFontFamilyCSS(for: fontStyle)
        let escapedFontFamily = fontFamilyCSS.replacingOccurrences(of: "'", with: "\\'")

        let currentCleanLoaded = coordinator.lastLoadedChapterURL.map { Self.stripFragment(from: $0) }
        let chapterChanged = (currentCleanLoaded != cleanChapterURL)
        if !chapterChanged && coordinator.lastLoadedChapterContent != nil {
            let fontSizeChanged = (coordinator.currentFontSize != CGFloat(fontSize))
            let themeChanged = (coordinator.currentTheme != readerTheme)
            let fontStyleChanged = (coordinator.currentFontStyle != fontStyle)
            let layoutModeChanged = (coordinator.currentLayoutMode != layoutMode)

            if fontSizeChanged || themeChanged || fontStyleChanged || layoutModeChanged {
                coordinator.currentFontSize = CGFloat(fontSize)
                coordinator.currentTheme = readerTheme
                coordinator.currentFontStyle = fontStyle
                coordinator.currentLayoutMode = layoutMode
                paginationController?.prepareAnchorPreservationBeforeRelayout()
                coordinator.applyTypographyAndRelayout(
                    in: webView,
                    fontSize: fontSize,
                    escapedFontFamily: escapedFontFamily,
                    readerTheme: readerTheme
                )
            }
            if let fragment = incomingFragment, !fragment.isEmpty {
                coordinator.scrollToFragment(fragment, in: webView)
            }
            return
        }

        if let loadingURL = coordinator.isLoadingChapterURL,
           Self.stripFragment(from: loadingURL) == cleanChapterURL {
            coordinator.currentFontSize = CGFloat(fontSize)
            coordinator.currentTheme = readerTheme
            coordinator.currentFontStyle = fontStyle
            coordinator.currentLayoutMode = layoutMode
            if let fragment = incomingFragment, !fragment.isEmpty {
                coordinator.pendingFragment = fragment
            }
            return
        }

        coordinator.loadChapterURL(
            cleanChapterURL,
            fragment: incomingFragment,
            resolvedBaseURL: resolvedBaseURL,
            baseDir: baseDirectory,
            fontSize: fontSize,
            fontStyle: fontStyle,
            readerTheme: readerTheme,
            in: webView
        )
    }

    public nonisolated static func resolveBaseURL(for chapterURL: URL) -> URL {
        let parentURL = chapterURL.deletingLastPathComponent()
        let parentStr = parentURL.absoluteString
        return URL(string: parentStr.hasSuffix("/") ? parentStr : parentStr + "/") ?? parentURL
    }

    public nonisolated static func stripFragment(from url: URL) -> URL {
        guard url.fragment != nil else { return url }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
        comps?.fragment = nil
        return comps?.url ?? url
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        public var parent: EPUBNativeWKWebView?
        public var lastLoadedChapterURL: URL?
        public var lastLoadedChapterContent: String?
        public var lastLoadedBaseURL: URL?
        public var baseDirectory: URL?
        public var currentTheme: String?
        public var currentFontSize: CGFloat?
        public var currentFontStyle: String?
        public var currentLayoutMode: String?
        public var isLoadingChapterURL: URL?
        public var pendingFragment: String?
        public var currentLoadTask: Task<Void, Never>?
        /// Identity of the navigation this coordinator is currently waiting for. `didFinish` for any other
        /// navigation (a previous book/chapter, or a stale load after teardown) is ignored.
        public var pendingNavigation: WKNavigation?
        /// Book generation captured when the current load started; stale callbacks carrying an older
        /// generation must not write back pagination or telemetry.
        public var pendingLoadGeneration: Int = 0
        public var latestFirstScreenMetrics: EPUBFirstScreenPerfMetrics?
        public let inputStateMessageHandler = EPUBReaderInputStateScriptMessageHandler()
        internal var pendingLoadStartUptime: TimeInterval = 0
        internal var pendingWebKitStartUptime: TimeInterval = 0
        internal var pendingLoadTelemetry: EPUBChapterContentLoaderActor.ChapterLoadTelemetry?
        internal let logger = TTMediaLogger(category: "EPUBNativeWKWebView")

        public init(parent: EPUBNativeWKWebView? = nil) {
            self.parent = parent
            super.init()
        }

        public func loadChapterURL(
            _ cleanURL: URL,
            fragment: String?,
            resolvedBaseURL: URL,
            baseDir: URL,
            fontSize: Double,
            fontStyle: String,
            readerTheme: String,
            in webView: WKWebView
        ) {
            isLoadingChapterURL = cleanURL
            lastLoadedChapterURL = cleanURL
            pendingFragment = fragment
            currentFontSize = CGFloat(fontSize)
            currentTheme = readerTheme
            currentFontStyle = fontStyle
            currentLayoutMode = parent?.layoutMode ?? "paginated"
            pendingLoadStartUptime = ProcessInfo.processInfo.systemUptime
            pendingNavigation = nil
            pendingLoadGeneration = parent?.paginationController?.bookGeneration ?? 0
            parent?.paginationController?.beginChapterLoad(chapterIndex: parent?.chapterIndex ?? 0)
            if let readerWebView = webView as? EPUBReaderWKWebView {
                readerWebView.clearMarkedTextState()
                TTPreviewKeyboardOwnershipCoordinator.shared.updateSessionDOMInputLifecycle(
                    instanceID: readerWebView.readerInstanceID,
                    isInputActive: false,
                    isIMEComposing: false
                )
            }

            let fontFamilyCSS = EPUBNativeWKWebView.resolveFontFamilyCSS(for: fontStyle)
            let customCSS = EPUBNativeWKWebView.buildCustomCSS(
                fontSize: fontSize,
                fontFamilyCSS: fontFamilyCSS,
                readerTheme: readerTheme
            )

            currentLoadTask?.cancel()
            currentLoadTask = Task { @MainActor [weak self, weak webView] in
                let telemetry = await EPUBChapterContentLoaderActor.shared.loadChapterWithTelemetry(
                    at: cleanURL,
                    customCSS: customCSS,
                    baseDirectory: baseDir
                )
                guard !Task.isCancelled, let self, let webView else { return }
                self.isLoadingChapterURL = nil
                guard self.lastLoadedChapterURL == cleanURL else { return }
                self.pendingLoadTelemetry = telemetry
                self.pendingWebKitStartUptime = ProcessInfo.processInfo.systemUptime

                if let injectedHTML = telemetry?.html {
                    self.lastLoadedChapterContent = injectedHTML
                    self.lastLoadedBaseURL = resolvedBaseURL
                    self.pendingNavigation = webView.loadHTMLString(injectedHTML, baseURL: resolvedBaseURL)
                } else if cleanURL.isFileURL,
                          EPUBChapterContentLoaderActor.isResourceWithinBookBoundary(
                              assetURL: cleanURL,
                              chapterURL: cleanURL,
                              baseDirectory: baseDir
                          ),
                          FileManager.default.fileExists(atPath: cleanURL.path) {
                    self.lastLoadedChapterContent = cleanURL.path
                    self.lastLoadedBaseURL = resolvedBaseURL
                    self.pendingNavigation = webView.loadFileURL(cleanURL, allowingReadAccessTo: baseDir)
                } else {
                    let placeholder = Self.makePlaceholderHTML(
                        for: cleanURL,
                        customCSS: customCSS,
                        readerTheme: readerTheme
                    )
                    self.lastLoadedChapterContent = placeholder
                    self.lastLoadedBaseURL = nil
                    self.pendingNavigation = webView.loadHTMLString(placeholder, baseURL: nil)
                }
            }
        }

        public func scrollToFragment(_ fragment: String, in webView: WKWebView) {
            scrollToFragmentAndSyncPager(fragment, in: webView)
        }

        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                TTWebPreviewContentPolicy.openExternalLinkIfAllowed(url)
            }
            return nil
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            // Block iframes / subframes
            if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
                decisionHandler(.cancel)
                return
            }

            // Block form submissions
            if navigationAction.navigationType == .formSubmitted ||
               navigationAction.navigationType == .formResubmitted {
                decisionHandler(.cancel)
                return
            }

            if navigationAction.navigationType == .linkActivated {
                handleActivatedLink(url, in: webView, decisionHandler: decisionHandler)
                return
            }

            if navigationAction.navigationType == .other,
               navigationAction.targetFrame?.isMainFrame != false {
                if isAllowedInitialLoad(url) {
                    decisionHandler(.allow)
                    return
                }
            }

            decisionHandler(.cancel)
        }

        private func isAllowedInitialLoad(_ url: URL) -> Bool {
            let scheme = url.scheme?.lowercased() ?? ""
            if url.absoluteString == "about:blank" || scheme == "data" {
                return true
            }
            if let base = lastLoadedBaseURL,
               EPUBNativeWKWebView.stripFragment(from: url) == EPUBNativeWKWebView.stripFragment(from: base) {
                return true
            }
            if let chapter = lastLoadedChapterURL,
               EPUBNativeWKWebView.stripFragment(from: url) == EPUBNativeWKWebView.stripFragment(from: chapter) {
                return true
            }
            if scheme == "ttzip-vfs", let base = lastLoadedBaseURL ?? lastLoadedChapterURL,
               url.host == base.host {
                return true
            }
            return false
        }

        private func handleActivatedLink(
            _ url: URL,
            in webView: WKWebView,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if TTWebPreviewContentPolicy.isAllowedExternalScheme(url) {
                TTWebPreviewContentPolicy.openExternalLinkIfAllowed(url)
                decisionHandler(.cancel)
                return
            }

            let cleanTarget = EPUBNativeWKWebView.stripFragment(from: url)
            let currentChapter = lastLoadedChapterURL.map { EPUBNativeWKWebView.stripFragment(from: $0) }
            let currentBase = lastLoadedBaseURL.map { EPUBNativeWKWebView.stripFragment(from: $0) }

            // Check if this is an in-page fragment anchor on the current chapter
            if let fragment = url.fragment, !fragment.isEmpty {
                let isSameAsCurrent = (cleanTarget == currentChapter) ||
                                      (cleanTarget == currentBase) ||
                                      url.absoluteString.hasPrefix("about:blank#")
                if isSameAsCurrent {
                    scrollToFragment(fragment, in: webView)
                    decisionHandler(.cancel)
                    return
                }
            }

            // Check if this is an internal EPUB chapter navigation within the same book
            if isInternalBookURL(cleanTarget) {
                parent?.onNavigateToChapterURL?(url)
                guard let targetToLoad = resolveInternalChapterNavigationTarget(
                    for: url,
                    cleanTarget: cleanTarget
                ) else {
                    decisionHandler(.cancel)
                    return
                }
                let resolvedBase = EPUBNativeWKWebView.resolveBaseURL(for: targetToLoad)
                let baseDir = baseDirectory ?? resolvedBase
                loadChapterURL(
                    targetToLoad,
                    fragment: url.fragment,
                    resolvedBaseURL: resolvedBase,
                    baseDir: baseDir,
                    fontSize: Double(currentFontSize ?? 17.0),
                    fontStyle: currentFontStyle ?? "serif",
                    readerTheme: currentTheme ?? "light",
                    in: webView
                )
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }

        private func resolveInternalChapterNavigationTarget(for url: URL, cleanTarget: URL) -> URL? {
            guard let chapters = parent?.chapters, !chapters.isEmpty else {
                return cleanTarget
            }
            guard let matchedIndex = InteractiveEPUBReaderView.resolveChapterIndex(
                matching: url,
                in: chapters,
                baseDirectory: baseDirectory
            ) else {
                return nil
            }
            return EPUBNativeWKWebView.stripFragment(from: chapters[matchedIndex].fileURL)
        }

        public func isInternalBookURL(_ targetURL: URL) -> Bool {
            guard let refChapter = lastLoadedChapterURL ?? baseDirectory ?? lastLoadedBaseURL else {
                return false
            }
            return EPUBChapterContentLoaderActor.isResourceWithinBookBoundary(
                assetURL: targetURL,
                chapterURL: refChapter,
                baseDirectory: baseDirectory
            )
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard parent != nil else { return }
            guard let expected = pendingNavigation, navigation === expected else {
                logger.debug("[EPUBNativeWKWebView] Ignoring stale didFinish for a superseded navigation")
                return
            }
            pendingNavigation = nil
            synchronizePaginationAndRecordTelemetryOnFinish(in: webView)
            refreshAnnotationHighlights(in: webView)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            logger.error("[EPUBNativeWKWebView] Navigation failed: \(error.localizedDescription)")
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            logger.error("[EPUBNativeWKWebView] Provisional navigation failed: \(error.localizedDescription)")
        }
    }
}
