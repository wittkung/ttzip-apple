// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import WebKit

extension EPUBNativeWKWebView.Coordinator {
    internal static func makePlaceholderHTML(
        for cleanURL: URL,
        customCSS: String,
        readerTheme: String,
        loading: EPUBReaderAppearance.LoadingPlaceholder?
    ) -> String {
        let title = cleanURL.lastPathComponent
            .replacingOccurrences(of: ".xhtml", with: "")
            .replacingOccurrences(of: ".html", with: "")
        let message = loading.map { "<p\(styleAttribute($0.messageStyle))>\(escapedHTML($0.message))</p>" } ?? ""
        return TTWebPreviewContentPolicy.injectOfflineCSP(into: """
        <!DOCTYPE html>
        <html><head>\(customCSS)</head>
        <body class="theme-\(escapedHTML(readerTheme))">
        <div\(styleAttribute(loading?.containerStyle))>
            <h2\(styleAttribute(loading?.titleStyle))>\(escapedHTML(title))</h2>
            \(message)
        </div>
        </body></html>
        """)
    }

    private static func styleAttribute(_ style: String?) -> String {
        guard let style else { return "" }
        return " style='\(escapedHTML(style))'"
    }

    private static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func bindReaderWebViewEvents(
        to webView: WKWebView,
        instanceID: UUID,
        pagination: EPUBPaginationController?
    ) {
        guard let readerWebView = webView as? EPUBReaderWKWebView else { return }
        readerWebView.readerInstanceID = instanceID
        readerWebView.paginationController = pagination
        readerWebView.onViewportResized = { [weak self, weak webView] _ in
            guard let self, let webView, self.lastLoadedChapterContent != nil else { return }
            self.parent?.paginationController?.prepareAnchorPreservationBeforeRelayout()
            self.relayoutPreserveAnchor(in: webView)
        }
    }

    private func registerKeyboardSession(
        instanceID: UUID,
        webView: WKWebView,
        pagination: EPUBPaginationController?
    ) {
        let resolvedLayoutMode = EPUBReadingLayoutPreference.resolve(
            stored: parent?.layoutMode ?? pagination?.layoutMode.rawValue
        )
        TTPreviewKeyboardOwnershipCoordinator.shared.registerOrUpdateSession(
            instanceID: instanceID,
            windowNumber: webView.window?.windowNumber,
            ownsHorizontalArrowKeys: false,
            layoutMode: resolvedLayoutMode,
            onVerticalArrowKey: { [weak pagination] isDown in
                guard let pagination else { return false }
                return pagination.handleVerticalArrow(isDownArrow: isDown)
            }
        ) { [weak pagination] isRightArrow in
            guard let pagination else { return false }
            _ = pagination.handleHorizontalArrow(isRightArrow: isRightArrow)
            return true
        }
        TTPreviewKeyboardOwnershipCoordinator.shared.bindReaderViews(
            instanceID: instanceID,
            webView: webView as? EPUBReaderWKWebView,
            containerView: webView.superview
        )
        inputStateMessageHandler.onInputStateChanged = { message in
            TTPreviewKeyboardOwnershipCoordinator.shared.updateSessionDOMInputLifecycle(
                instanceID: instanceID,
                isInputActive: message.isInputActive,
                isIMEComposing: message.isIMEComposing
            )
        }
    }

    private func bindControllerRequests(
        to webView: WKWebView,
        instanceID: UUID,
        pagination: EPUBPaginationController?
    ) {
        guard let pagination else { return }
        pagination.onRequestWebViewPageJump = { [weak self, weak webView] pageIndex in
            guard let self, let webView else { return }
            self.jumpToPageInWebView(pageIndex, in: webView)
        }
        pagination.onRequestAnchorJump = { [weak self, weak webView] block, character, ratio in
            guard let self, let webView else { return }
            self.restoreAnnotationAnchor(block: block, character: character, ratio: ratio, in: webView)
        }
        pagination.onRequestVerticalScroll = { [weak self, weak webView] isDown in
            guard let self, let webView else { return }
            self.scrollVerticalInWebView(isDown: isDown, in: webView)
        }
        pagination.onRequestRestoreReaderFocus = { [weak webView] in
            guard let webView else { return }
            TTPreviewKeyboardOwnershipCoordinator.shared.notifyToolbarInteraction(instanceID: instanceID)
            if let window = webView.window, window.firstResponder !== webView {
                window.makeFirstResponder(webView)
            }
        }
    }

    public func bindPaginationAndFocusCallbacks(to webView: WKWebView) {
        let pagination = parent?.paginationController
        let instanceID = pagination?.instanceID ?? (webView as? EPUBReaderWKWebView)?.readerInstanceID ?? UUID()
        bindReaderWebViewEvents(to: webView, instanceID: instanceID, pagination: pagination)
        registerKeyboardSession(instanceID: instanceID, webView: webView, pagination: pagination)
        bindControllerRequests(to: webView, instanceID: instanceID, pagination: pagination)
    }

    public func scrollVerticalInWebView(isDown: Bool, in webView: WKWebView) {
        let generation = currentBookGeneration
        let js = "\(EPUBReaderWebKitPagerBridge.bootstrapScript); window.__ttPager.scrollVertical(\(isDown ? "true" : "false"));"
        webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self] outcome in
            guard let self, self.isCurrentBookGeneration(generation) else { return }
            guard let dict = try? outcome.get() as? [String: Any] else { return }
            guard let pagination = self.parent?.paginationController else { return }
            let atBoundary = (dict["atBoundary"] as? String) ?? "none"
            if atBoundary == "bottom" || atBoundary == "top" {
                // Vertical keys only scroll the chapter body; crossing chapters stays on the horizontal
                // arrow keys so a held Down key can never skip a chapter.
                pagination.synchronizeScrollingPageIndex((dict["pageIndex"] as? NSNumber)?.intValue)
                return
            }
            if let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: dict) {
                let chapterIdx = self.parent?.chapterIndex ?? pagination.currentChapterIndex
                self.updatePaginationFromSnapshot(snapshot, chapterIndex: chapterIdx, generation: generation)
            }
        }
    }

    private var currentBookGeneration: Int {
        parent?.paginationController?.bookGeneration ?? 0
    }

    private func isCurrentBookGeneration(_ generation: Int) -> Bool {
        guard let controller = parent?.paginationController else { return false }
        return controller.bookGeneration == generation
    }

    private func resolvedLayoutMode() -> EPUBReadingLayoutMode {
        if let stored = parent?.layoutMode {
            return EPUBReadingLayoutPreference.resolve(stored: stored)
        }
        return parent?.paginationController?.layoutMode ?? .paginated
    }

    private func scriptString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }

    private func darkContrastJS(theme: String) -> String {
        let dark = appearance.colors(for: "dark").text
        return "window.__ttPager.applyDarkThemeContrast(\(theme == "dark"), \(scriptString(dark)));"
    }

    private func themeApplicationJS(theme: String, fontSize: Double, escapedFontFamily: String) -> String {
        let colors = appearance.colors(for: theme)
        let themeToken = scriptString(theme)
        return """
        document.documentElement.style.setProperty('--reader-font-size', '\(fontSize)pt');
        document.documentElement.style.setProperty('--reader-font-family', '\(escapedFontFamily)');
        var themeBg = \(scriptString(colors.background));
        var themeColor = \(scriptString(colors.text));
        document.documentElement.style.setProperty('--reader-bg', themeBg);
        document.documentElement.style.setProperty('--reader-text', themeColor);
        if (document.body) {
            document.body.classList.remove('theme-light', 'theme-sepia', 'theme-dark', 'theme-transparent');
            document.body.classList.add('theme-' + \(themeToken));
            document.documentElement.setAttribute('data-reader-theme', \(themeToken));
            document.body.style.setProperty('background-color', themeBg, 'important');
            document.body.style.setProperty('color', themeColor, 'important');
        }
        """
    }

    public func synchronizePaginationAndRecordTelemetryOnFinish(in webView: WKWebView) {
        let didFinishUptime = ProcessInfo.processInfo.systemUptime
        let webKitMs = pendingWebKitStartUptime > 0
            ? max(0, (didFinishUptime - pendingWebKitStartUptime) * 1000.0)
            : 0.0
        let theme = currentTheme ?? "light"
        let fontSize = Double(currentFontSize ?? 17.0)
        let fontStyle = currentFontStyle ?? "serif"
        let escapedFont = EPUBNativeWKWebView.resolveFontFamilyCSS(for: fontStyle)
            .replacingOccurrences(of: "'", with: "\\'")
        let activeFragment = pendingFragment
        pendingFragment = nil
        let relayoutArgs = buildRelayoutInvocationArgs(fragment: activeFragment)
        let mode = resolvedLayoutMode().rawValue
        let generation = currentBookGeneration

        let js = """
        window.__ttReaderChapterIndex = \(parent?.chapterIndex ?? 0);
        window.__ttReaderBookGeneration = \(generation);
        \(EPUBReaderWebKitPagerBridge.bootstrapScript)
        \(themeApplicationJS(theme: theme, fontSize: fontSize, escapedFontFamily: escapedFont))
        \(darkContrastJS(theme: theme))
        window.__ttPager.relayout(\(relayoutArgs), '\(mode)');
        """
        let callbackStart = ProcessInfo.processInfo.systemUptime
        let chapterIdx = (webView as? EPUBReaderWKWebView)?.paginationController?.currentChapterIndex
            ?? parent?.paginationController?.currentChapterIndex
            ?? parent?.chapterIndex
            ?? 0
        webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self, weak webView] outcome in
            guard let self, self.isCurrentBookGeneration(generation) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let layoutCallbackMs = max(0, (now - callbackStart) * 1000.0)
            let totalMs = self.pendingLoadStartUptime > 0
                ? max(0, (now - self.pendingLoadStartUptime) * 1000.0)
                : (webKitMs + layoutCallbackMs)
            let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: try? outcome.get())
            self.publishTelemetryAndSync(
                snapshot: snapshot,
                chapterIndex: chapterIdx,
                webKitMs: webKitMs,
                layoutCallbackMs: layoutCallbackMs,
                totalMs: totalMs,
                webView: webView,
                generation: generation
            )
        }
    }

    private func buildRelayoutInvocationArgs(fragment: String?) -> String {
        if let fragment, !fragment.isEmpty {
            return formatFragmentRelayoutArg(fragment)
        }
        switch parent?.paginationController?.pendingLanding {
        case .lastPage:
            return "'last', 1, -1, null, 0"
        case .preserveAnchor(let ratio, let anchorIdx, let charOff):
            return "'anchor', \(ratio), \(anchorIdx ?? -1), null, \(charOff)"
        case .fragment(let frag):
            return formatFragmentRelayoutArg(frag)
        default:
            return "'first', 0, -1, null, 0"
        }
    }

    private func formatFragmentRelayoutArg(_ fragment: String) -> String {
        let escaped = fragment
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'fragment', 0, -1, decodeURIComponent('\(escaped)'), 0"
    }

    private func recordTelemetryIfPresent(
        totalPages: Int,
        webKitMs: Double,
        layoutCallbackMs: Double,
        totalMs: Double
    ) {
        guard let chapterURL = lastLoadedChapterURL else { return }
        let telemetry = pendingLoadTelemetry
        let metrics = EPUBFirstScreenPerfMetrics(
            chapterURL: chapterURL,
            isVFSSource: chapterURL.scheme?.lowercased() == "ttzip-vfs",
            chapterReadMs: telemetry?.chapterReadMs ?? 0.0,
            resourceAuthAndInlineMs: telemetry?.resourceAuthAndInlineMs ?? 0.0,
            webKitLoadToFinishMs: webKitMs,
            firstPaginationLayoutCallbackMs: layoutCallbackMs,
            totalToPaginationCallbackMs: totalMs,
            inlinedResourceCount: telemetry?.inlinedResourceCount ?? 0,
            authenticatedCacheHitCount: telemetry?.authenticatedCacheHitCount ?? 0,
            initialPageCount: totalPages
        )
        latestFirstScreenMetrics = metrics
        parent?.paginationController?.recordFirstScreenMetrics(metrics)
    }

    internal func updatePaginationFromSnapshot(
        _ snapshot: EPUBReaderWebKitPagerBridge.PagerSnapshot,
        chapterIndex: Int,
        generation: Int? = nil
    ) {
        guard let controller = parent?.paginationController else { return }
        if let generation, generation != controller.bookGeneration { return }
        controller.didSynchronizeWebViewPagination(
            chapterIndex: chapterIndex,
            pageIndex: snapshot.pageIndex,
            totalPages: snapshot.totalPages,
            anchorBlockIndex: snapshot.anchorBlockIndex,
            anchorCharOffset: snapshot.anchorCharOffset,
            readingDirectionRaw: snapshot.readingDirection,
            bookGeneration: controller.bookGeneration,
            isLayoutReady: snapshot.isLayoutReady
        )
    }

    private func syncPaginationAndInput(
        snapshot: EPUBReaderWebKitPagerBridge.PagerSnapshot?,
        chapterIndex: Int,
        pageIndex: Int,
        totalPages: Int,
        webView: WKWebView?,
        generation: Int
    ) {
        if let snapshot {
            updatePaginationFromSnapshot(snapshot, chapterIndex: chapterIndex, generation: generation)
        } else {
            parent?.paginationController?.didSynchronizeWebViewPagination(
                chapterIndex: chapterIndex,
                pageIndex: pageIndex,
                totalPages: totalPages,
                anchorBlockIndex: nil,
                anchorCharOffset: 0,
                readingDirectionRaw: nil,
                bookGeneration: generation,
                isLayoutReady: false
            )
        }
        guard let readerWebView = webView as? EPUBReaderWKWebView else { return }
        TTPreviewKeyboardOwnershipCoordinator.shared.updateSessionDOMInputLifecycle(
            instanceID: readerWebView.readerInstanceID,
            isInputActive: snapshot?.isInputActive ?? false,
            isIMEComposing: snapshot?.isIMEComposing ?? false
        )
    }

    private func publishTelemetryAndSync(
        snapshot: EPUBReaderWebKitPagerBridge.PagerSnapshot?,
        chapterIndex: Int,
        webKitMs: Double,
        layoutCallbackMs: Double,
        totalMs: Double,
        webView: WKWebView?,
        generation: Int
    ) {
        let pageIndex = snapshot?.pageIndex ?? 0
        let totalPages = snapshot?.totalPages ?? 1
        recordTelemetryIfPresent(
            totalPages: totalPages,
            webKitMs: webKitMs,
            layoutCallbackMs: layoutCallbackMs,
            totalMs: totalMs
        )
        syncPaginationAndInput(
            snapshot: snapshot,
            chapterIndex: chapterIndex,
            pageIndex: pageIndex,
            totalPages: totalPages,
            webView: webView,
            generation: generation
        )
    }

    public func applyTypographyAndRelayout(
        in webView: WKWebView,
        fontSize: Double,
        escapedFontFamily: String,
        readerTheme: String
    ) {
        let ratio = parent?.paginationController?.normalizedProgressInChapter ?? 0.0
        let anchorIdx = parent?.paginationController?.anchorBlockIndex ?? -1
        let chapterIdx = parent?.chapterIndex ?? parent?.paginationController?.currentChapterIndex ?? 0
        let mode = resolvedLayoutMode().rawValue
        let generation = currentBookGeneration
        let js = """
        \(EPUBReaderWebKitPagerBridge.bootstrapScript)
        var capturedAnchor = window.__ttPager.captureAnchor();
        var capturedCharOff = window.__ttPager.anchorCharOffset || 0;
        \(themeApplicationJS(theme: readerTheme, fontSize: fontSize, escapedFontFamily: escapedFontFamily))
        \(darkContrastJS(theme: readerTheme))
        window.__ttPager.relayout('anchor', \(ratio), capturedAnchor >= 0 ? capturedAnchor : \(anchorIdx), null, capturedCharOff, '\(mode)');
        """
        webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self] outcome in
            guard let self, self.isCurrentBookGeneration(generation) else { return }
            guard let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: try? outcome.get()) else { return }
            self.updatePaginationFromSnapshot(snapshot, chapterIndex: chapterIdx, generation: generation)
        }
    }

    public func relayoutPreserveAnchor(in webView: WKWebView) {
        let ratio = parent?.paginationController?.normalizedProgressInChapter ?? 0.0
        let anchorIdx = parent?.paginationController?.anchorBlockIndex ?? -1
        let charOff = parent?.paginationController?.anchorCharOffset ?? 0
        let chapterIdx = parent?.chapterIndex ?? parent?.paginationController?.currentChapterIndex ?? 0
        let mode = resolvedLayoutMode().rawValue
        let theme = currentTheme ?? "light"
        let generation = currentBookGeneration
        let js = """
        \(EPUBReaderWebKitPagerBridge.bootstrapScript)
        \(darkContrastJS(theme: theme))
        window.__ttPager.relayout('anchor', \(ratio), \(anchorIdx), null, \(charOff), '\(mode)');
        """
        webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self] outcome in
            guard let self, self.isCurrentBookGeneration(generation) else { return }
            guard let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: try? outcome.get()) else { return }
            self.updatePaginationFromSnapshot(snapshot, chapterIndex: chapterIdx, generation: generation)
        }
    }

    public func jumpToPageInWebView(_ targetPage: Int, in webView: WKWebView) {
        let chapterIdx = parent?.chapterIndex ?? parent?.paginationController?.currentChapterIndex ?? 0
        let generation = currentBookGeneration
        let js = """
        \(EPUBReaderWebKitPagerBridge.bootstrapScript)
        window.__ttPager.goToPage(\(targetPage));
        """
        webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self] outcome in
            guard let self, self.isCurrentBookGeneration(generation) else { return }
            guard let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: try? outcome.get()) else { return }
            self.updatePaginationFromSnapshot(snapshot, chapterIndex: chapterIdx, generation: generation)
        }
    }

    public func scrollToFragmentAndSyncPager(_ fragment: String, in webView: WKWebView) {
        let escaped = fragment
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let chapterIdx = parent?.chapterIndex ?? parent?.paginationController?.currentChapterIndex ?? 0
        let mode = resolvedLayoutMode().rawValue
        let generation = currentBookGeneration
        let js = """
        (function() {
            var id = decodeURIComponent('\(escaped)');
            var el = document.getElementById(id) || document.getElementsByName(id)[0];
            if (el) {
                window.location.hash = '#' + id;
            }
            if (window.__ttPager) {
                return window.__ttPager.relayout('fragment', 0, -1, id, 0, '\(mode)');
            }
            if (el) { el.scrollIntoView(); }
            return null;
        })();
        """
        webView.evaluateJavaScript(js, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self] outcome in
            guard let self, self.isCurrentBookGeneration(generation) else { return }
            guard let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: try? outcome.get()) else { return }
            self.updatePaginationFromSnapshot(snapshot, chapterIndex: chapterIdx, generation: generation)
        }
    }
}
