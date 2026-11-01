// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import WebKit

// MARK: - WKWebView NSViewRepresentable Wrapper

public struct HTMLWKWebViewRepresentable: NSViewRepresentable {
    public let content: String
    public let fileURL: URL?
    public let reloadToken: Int
    public let pageZoom: Double
    
    public init(content: String, fileURL: URL?, reloadToken: Int = 0, pageZoom: Double = 1.0) {
        self.content = content
        self.fileURL = fileURL
        self.reloadToken = reloadToken
        self.pageZoom = pageZoom
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        TTWebPreviewContentPolicy.apply(to: config)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        let isSVG = Self.isStandaloneSVG(content: content, fileURL: fileURL)
        webView.setValue(!isSVG, forKey: "drawsBackground")
        webView.pageZoom = CGFloat(pageZoom)
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.lastLoadedURL = fileURL
        context.coordinator.lastLoadedContent = content
        context.coordinator.lastPageZoom = pageZoom
        loadHTML(in: webView, coordinator: context.coordinator)
        return webView
    }
    
    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if abs(context.coordinator.lastPageZoom - pageZoom) > 0.001 {
            context.coordinator.lastPageZoom = pageZoom
            webView.pageZoom = CGFloat(pageZoom)
        }
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.lastLoadedURL = fileURL
            context.coordinator.lastLoadedContent = content
            loadHTML(in: webView, coordinator: context.coordinator)
        } else if context.coordinator.lastLoadedURL != fileURL {
            context.coordinator.lastLoadedURL = fileURL
            context.coordinator.lastLoadedContent = content
            loadHTML(in: webView, coordinator: context.coordinator)
        } else if context.coordinator.lastLoadedContent != content {
            context.coordinator.lastLoadedContent = content
            loadHTML(in: webView, coordinator: context.coordinator)
        }
    }
    
    public static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
    }
    
    static func isStandaloneSVG(content: String, fileURL: URL?) -> Bool {
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Only the document root may select the SVG canvas. Inline icons do not.
            return locateRootSVGOpeningTagRange(in: content) != nil
        }
        let ext = fileURL?.pathExtension.lowercased() ?? ""
        return ext == "svg" || ext == "svgz"
    }

    /// Scans only the XML/HTML document preamble (UTF-8 BOM, whitespace, `<?...?>`, `<!--...-->`,
    /// and `<!DOCTYPE ...>` including optional `[...]` internal subsets without expanding entities)
    /// and returns the range of the root `<svg ...>` opening tag when `<svg` is the root element.
    static func locateRootSVGOpeningTagRange(in content: String) -> Range<String.Index>? {
        guard let rootTagStart = advancePastDocumentPreamble(in: content) else { return nil }
        return matchRootSVGOpeningTag(in: content, at: rootTagStart)
    }

    private static func advancePastDocumentPreamble(in content: String) -> String.Index? {
        var idx = content.hasPrefix("\u{FEFF}") ? content.index(after: content.startIndex) : content.startIndex
        while idx < content.endIndex {
            if content[idx].isWhitespace {
                idx = content.index(after: idx)
                continue
            }
            guard content[idx] == "<" else { return nil }
            if let nextIdx = stepOverPreambleConstruct(in: content, at: idx) {
                idx = nextIdx
                continue
            }
            return idx
        }
        return nil
    }

    private static func stepOverPreambleConstruct(in content: String, at idx: String.Index) -> String.Index? {
        let rest = content[idx...]
        if rest.hasPrefix("<!--") {
            return skipXMLComment(in: content, from: idx) ?? content.endIndex
        }
        if rest.hasPrefix("<?") {
            let searchStart = content.index(idx, offsetBy: 2)
            return content.range(of: "?>", range: searchStart..<content.endIndex)?.upperBound ?? content.endIndex
        }
        if rest.lowercased().hasPrefix("<!doctype") {
            return skipDoctypePreamble(in: content, from: idx) ?? content.endIndex
        }
        return nil
    }

    private static func matchRootSVGOpeningTag(in content: String, at idx: String.Index) -> Range<String.Index>? {
        guard content[idx...].lowercased().hasPrefix("<svg") else { return nil }
        let afterName = content.index(idx, offsetBy: 4)
        guard afterName < content.endIndex else { return nil }
        let boundaryChar = content[afterName]
        guard isSVGTagNameBoundary(boundaryChar),
              let closeGt = findTagCloseOutsideQuotes(in: content, from: afterName) else {
            return nil
        }
        return idx..<content.index(after: closeGt)
    }

    private static func isSVGTagNameBoundary(_ ch: Character) -> Bool {
        ch.isWhitespace || ch == "/" || ch == ">"
    }

    private static func skipXMLComment(in text: String, from start: String.Index) -> String.Index? {
        let afterOpen = text.index(start, offsetBy: 4)
        guard afterOpen < text.endIndex else { return nil }
        if text[afterOpen] == ">" { return text.index(after: afterOpen) }
        if text[afterOpen...].hasPrefix("->") { return text.index(afterOpen, offsetBy: 2) }
        return text.range(of: "-->", range: afterOpen..<text.endIndex)?.upperBound
    }

    private static func skipDoctypePreamble(in text: String, from start: String.Index) -> String.Index? {
        var cursor = text.index(start, offsetBy: 9)
        guard cursor < text.endIndex, text[cursor].isWhitespace else { return nil }
        var bracketDepth = 0
        while cursor < text.endIndex {
            if text[cursor...].hasPrefix("<!--") {
                guard let afterComment = skipXMLComment(in: text, from: cursor) else { return nil }
                cursor = afterComment
                continue
            }
            let ch = text[cursor]
            if ch == "\"" || ch == "'" {
                guard let afterQuote = skipQuotedSpan(in: text, from: cursor, quote: ch) else { return nil }
                cursor = afterQuote
                continue
            }
            if ch == ">" && bracketDepth == 0 {
                return text.index(after: cursor)
            }
            bracketDepth = updatedBracketDepth(bracketDepth, for: ch)
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func updatedBracketDepth(_ depth: Int, for ch: Character) -> Int {
        if ch == "[" { return depth + 1 }
        if ch == "]" && depth > 0 { return depth - 1 }
        return depth
    }

    private static func skipQuotedSpan(in text: String, from quoteIndex: String.Index, quote: Character) -> String.Index? {
        var cursor = text.index(after: quoteIndex)
        while cursor < text.endIndex {
            if text[cursor] == quote {
                return text.index(after: cursor)
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func findTagCloseOutsideQuotes(in text: String, from start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < text.endIndex {
            let ch = text[cursor]
            if ch == "\"" || ch == "'" {
                guard let afterQuote = skipQuotedSpan(in: text, from: cursor, quote: ch) else { return nil }
                cursor = afterQuote
                continue
            }
            if ch == ">" { return cursor }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func extractRootSVGAttributes(in rootTag: String) -> [String: String] {
        var result: [String: String] = [:]
        guard rootTag.lowercased().hasPrefix("<svg") else { return result }
        var cursor = rootTag.index(rootTag.startIndex, offsetBy: 4)
        while let (name, value, nextCursor) = scanNextSVGAttribute(in: rootTag, from: cursor) {
            if !name.isEmpty, result[name] == nil {
                result[name] = value
            }
            cursor = nextCursor
        }
        return result
    }

    private static func scanNextSVGAttribute(
        in tag: String,
        from start: String.Index
    ) -> (name: String, value: String, next: String.Index)? {
        let nameStart = skipSVGAttributeDelimiters(in: tag, from: start)
        guard nameStart < tag.endIndex, tag[nameStart] != ">" else { return nil }
        let nameEnd = scanSVGAttributeNameEnd(in: tag, from: nameStart)
        let attrName = tag[nameStart..<nameEnd].lowercased()
        let eqIdx = skipWhitespace(in: tag, from: nameEnd)
        guard eqIdx < tag.endIndex else { return nil }
        guard tag[eqIdx] == "=" else {
            return (name: "", value: "", next: eqIdx)
        }
        let valStart = skipWhitespace(in: tag, from: tag.index(after: eqIdx))
        guard valStart < tag.endIndex else { return nil }
        let (value, nextCursor) = scanSVGAttributeValue(in: tag, from: valStart)
        return (name: attrName, value: value, next: nextCursor)
    }

    private static func skipSVGAttributeDelimiters(in tag: String, from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < tag.endIndex, tag[cursor].isWhitespace || tag[cursor] == "/" {
            cursor = tag.index(after: cursor)
        }
        return cursor
    }

    private static func skipWhitespace(in tag: String, from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < tag.endIndex, tag[cursor].isWhitespace {
            cursor = tag.index(after: cursor)
        }
        return cursor
    }

    private static func scanSVGAttributeNameEnd(in tag: String, from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < tag.endIndex, !isSVGAttributeNameTerminator(tag[cursor]) {
            cursor = tag.index(after: cursor)
        }
        return cursor
    }

    private static func isSVGAttributeNameTerminator(_ ch: Character) -> Bool {
        ch == "=" || ch.isWhitespace || ch == "/" || ch == ">"
    }

    private static func scanSVGAttributeValue(
        in tag: String,
        from start: String.Index
    ) -> (value: String, next: String.Index) {
        let quote = tag[start]
        if quote == "\"" || quote == "'" {
            let contentStart = tag.index(after: start)
            let closeIdx = tag[contentStart...].firstIndex(of: quote) ?? tag.endIndex
            let nextIdx = closeIdx < tag.endIndex ? tag.index(after: closeIdx) : tag.endIndex
            return (String(tag[contentStart..<closeIdx]), nextIdx)
        }
        var cursor = start
        while cursor < tag.endIndex, !isSVGTagNameBoundary(tag[cursor]) {
            cursor = tag.index(after: cursor)
        }
        return (String(tag[start..<cursor]), cursor)
    }

    private static func parseUserCoordinateDimension(_ rawValue: String?) -> Double? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let numericPart: String
        if trimmed.lowercased().hasSuffix("px") {
            numericPart = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            numericPart = trimmed
        }
        guard !numericPart.isEmpty,
              let value = Double(numericPart),
              value.isFinite,
              value > 0 else {
            return nil
        }
        return value
    }

    /// Detects whether an HTML document declares explicit author background or text colors
    /// so we can separate unstyled documents (which adapt to dark/light system theme) from
    /// author-styled documents (whose explicit palette must not be overridden).
    public static func hasExplicitAuthorColorPalette(in html: String) -> Bool {
        let pattern = #"(?i)(?:background(?:-color)?\s*:|(?<![-\w])color\s*:|bgcolor\s*=|color-scheme\s*:)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.firstMatch(in: html, options: [], range: nsRange) != nil
    }

    private static func defaultThemeStyleBlock(adaptsToDarkTheme: Bool) -> String {
        let darkMediaRule: String
        if adaptsToDarkTheme {
            darkMediaRule = """
              @media (prefers-color-scheme: dark) {
                :where(html, body) {
                  background-color: #1e1e1e;
                  color: #e5e5e7;
                }
                :where(a) { color: #58a6ff; }
              }
            """
        } else {
            darkMediaRule = ""
        }
        return """
        <style data-ttmedia-default-theme>
          :root { color-scheme: \(adaptsToDarkTheme ? "light dark" : "light"); }
          :where(html, body) {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            line-height: 1.6;
            background-color: #ffffff;
            color: #1c1c1e;
          }
          :where(body) {
            margin: 0;
            padding: 16px;
            word-wrap: break-word;
          }
          :where(a) { color: #0969da; }
          :where(pre, code) {
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
          }
          :where(img, svg, video, canvas) {
            max-width: 100%;
            height: auto;
          }
        \(darkMediaRule)
        </style>
        """
    }
    
    public func preparedHTMLContent(_ html: String) -> String {
        let lower = html.lowercased()
        let hasAuthorPalette = Self.hasExplicitAuthorColorPalette(in: html)
        let styleBlock = Self.defaultThemeStyleBlock(adaptsToDarkTheme: !hasAuthorPalette)
        let wrapped: String
        if lower.contains("<html") || lower.contains("<body") {
            wrapped = html
        } else {
            wrapped = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            </head>
            <body>
            \(html)
            </body>
            </html>
            """
        }
        let cspInjected = TTWebPreviewContentPolicy.injectOfflineCSP(into: wrapped)
        if let metaRange = cspInjected.range(of: TTWebPreviewContentPolicy.offlineCSPMetaTag) {
            var styled = cspInjected
            styled.insert(contentsOf: "\n" + styleBlock, at: metaRange.upperBound)
            return styled
        }
        return styleBlock + cspInjected
    }
    
    private func resolveDocumentOrRenderSVGZFailure(in webView: WKWebView, coordinator: Coordinator?) -> String? {
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        guard let url = fileURL, url.isFileURL else { return "" }
        if url.pathExtension.lowercased() == "svgz" {
            do {
                return try SVGZBoundedDecompressor.decompressSVGZ(from: url)
            } catch {
                coordinator?.allowedDocumentURL = nil
                webView.setValue(true, forKey: "drawsBackground")
                let fallback = Self.sourceFallbackHTML(String(describing: error))
                webView.loadHTMLString(preparedHTMLContent(fallback), baseURL: nil)
                return nil
            }
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func loadHTML(in webView: WKWebView, coordinator: Coordinator? = nil) {
        coordinator?.loadTask?.cancel()
        coordinator?.loadTask = nil
        webView.stopLoading()
        guard let rawContent = resolveDocumentOrRenderSVGZFailure(in: webView, coordinator: coordinator) else {
            return
        }
        
        let isMHTML = MHTMLMimeBoundaryGuard.isMultipartMHTML(text: rawContent)
        if isMHTML {
            loadMHTML(in: webView, source: rawContent, coordinator: coordinator)
            return
        }
        let isSVG = !rawContent.isEmpty && Self.locateRootSVGOpeningTagRange(in: rawContent) != nil
        
        webView.setValue(!isSVG, forKey: "drawsBackground")
        
        if isSVG {
            loadSVGEnvelope(in: webView, rawContent: rawContent, coordinator: coordinator)
        } else {
            if !rawContent.isEmpty {
                let targetBaseURL = fileURL
                coordinator?.allowedDocumentURL = targetBaseURL
                webView.loadHTMLString(preparedHTMLContent(rawContent), baseURL: targetBaseURL)
            } else if let url = fileURL, url.isFileURL {
                coordinator?.allowedDocumentURL = url
                webView.loadFileURL(url, allowingReadAccessTo: url)
            } else {
                coordinator?.allowedDocumentURL = nil
                webView.loadHTMLString(TTWebPreviewContentPolicy.injectOfflineCSP(into: ""), baseURL: nil)
            }
        }
    }
    
    private func loadMHTML(in webView: WKWebView, source: String, coordinator: Coordinator?) {
        coordinator?.allowedDocumentURL = fileURL
        webView.setValue(true, forKey: "drawsBackground")
        let decodeTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return "" }
            guard source.utf8.count <= 8 * 1024 * 1024 else {
                return Self.sourceFallbackHTML(source)
            }
            let html = MHTMLMimeBoundaryGuard.inspectMHTMLSource(text: source)?.renderedHTML
            return html ?? Self.sourceFallbackHTML(source)
        }
        let loadTask = Task { @MainActor [weak webView] in
            let html = await withTaskCancellationHandler {
                await decodeTask.value
            } onCancel: {
                decodeTask.cancel()
            }
            guard !Task.isCancelled, let webView else { return }
            webView.loadHTMLString(preparedHTMLContent(html), baseURL: fileURL)
        }
        coordinator?.loadTask = loadTask
    }

    nonisolated private static func sourceFallbackHTML(_ source: String) -> String {
        // The source pane retains the full document; keep the render fallback bounded.
        let escaped = String(source.prefix(64 * 1024)).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<html><body><pre>\(escaped)</pre></body></html>"
    }

    private func loadSVGEnvelope(in webView: WKWebView, rawContent: String, coordinator: Coordinator?) {
        var processedSVG = rawContent
        if let rootTagRange = Self.locateRootSVGOpeningTagRange(in: processedSVG) {
            let rootTag = String(processedSVG[rootTagRange])
            let attrs = Self.extractRootSVGAttributes(in: rootTag)
            if attrs["viewbox"] == nil,
               let w = Self.parseUserCoordinateDimension(attrs["width"]),
               let h = Self.parseUserCoordinateDimension(attrs["height"]) {
                let wStr = Int(exactly: w).map(String.init) ?? String(w)
                let hStr = Int(exactly: h).map(String.init) ?? String(h)
                let insertIdx = processedSVG.index(rootTagRange.lowerBound, offsetBy: 4)
                processedSVG.insert(contentsOf: " viewBox=\"0 0 \(wStr) \(hStr)\"", at: insertIdx)
            }
        }
        
        let htmlEnvelope = """
        <!DOCTYPE html>
        <html>
        <head>
        \(TTWebPreviewContentPolicy.offlineCSPMetaTag)
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
          :root { color-scheme: light dark; }
          html, body {
            margin: 0;
            padding: 16px;
            width: 100%;
            height: 100%;
            box-sizing: border-box;
            display: flex;
            background: transparent;
            color: #1c1c1e;
            overflow: auto;
          }
          @media (prefers-color-scheme: dark) {
            html, body { color: #e5e5e7; }
          }
          body > svg[viewBox] {
            margin: auto;
            width: 100% !important;
            height: 100% !important;
            max-width: 100%;
            max-height: 100%;
            object-fit: contain;
          }
          body > svg:not([viewBox]) {
            margin: auto;
            flex-shrink: 0;
          }
        </style>
        </head>
        <body>
        \(processedSVG)
        </body>
        </html>
        """
        coordinator?.allowedDocumentURL = fileURL
        webView.loadHTMLString(htmlEnvelope, baseURL: fileURL)
    }
    
    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: HTMLWKWebViewRepresentable
        var lastReloadToken: Int = 0
        var lastPageZoom: Double = 1.0
        var lastLoadedURL: URL? = nil
        var lastLoadedContent: String? = nil
        var allowedDocumentURL: URL? = nil
        var loadTask: Task<Void, Never>?
        
        public init(_ parent: HTMLWKWebViewRepresentable) {
            self.parent = parent
            self.allowedDocumentURL = parent.fileURL
            self.lastPageZoom = parent.pageZoom
            super.init()
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
            guard let url = navigationAction.request.url,
                  navigationAction.targetFrame?.isMainFrame != false else {
                decisionHandler(.cancel)
                return
            }
            
            switch navigationAction.navigationType {
            case .linkActivated:
                decisionHandler(policyForActivatedLink(url, in: webView))
            case .other:
                decisionHandler(isAllowedInitialDocumentLoad(url) ? .allow : .cancel)
            default:
                decisionHandler(.cancel)
            }
        }
        
        private func policyForActivatedLink(_ url: URL, in webView: WKWebView) -> WKNavigationActionPolicy {
            let expectedURL = allowedDocumentURL ?? parent.fileURL
            if isSameDocumentFragmentJump(targetURL: url, currentURL: webView.url ?? expectedURL) {
                return .allow
            }
            if TTWebPreviewContentPolicy.isAllowedExternalScheme(url) {
                TTWebPreviewContentPolicy.openExternalLinkIfAllowed(url)
            }
            return .cancel
        }
        
        private func isAllowedInitialDocumentLoad(_ url: URL) -> Bool {
            let scheme = url.scheme?.lowercased() ?? ""
            if url.absoluteString == "about:blank" || scheme == "data" {
                return true
            }
            guard let expected = allowedDocumentURL ?? parent.fileURL else {
                return false
            }
            return isMatchingDocumentURL(url, expected)
        }
        
        private func isMatchingDocumentURL(_ candidate: URL, _ expected: URL) -> Bool {
            if candidate.isFileURL && expected.isFileURL {
                return candidate.standardizedFileURL.path == expected.standardizedFileURL.path
            }
            return stripFragment(candidate) == stripFragment(expected)
        }
        
        private func isSameDocumentFragmentJump(targetURL: URL, currentURL: URL?) -> Bool {
            guard let fragment = targetURL.fragment, !fragment.isEmpty else {
                return false
            }
            if targetURL.absoluteString.hasPrefix("about:blank#") {
                return true
            }
            guard let currentURL else { return false }
            return isMatchingDocumentURL(targetURL, currentURL)
        }
        
        private func stripFragment(_ url: URL) -> String {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
            comps?.fragment = nil
            return comps?.string ?? url.absoluteString
        }
    }
}
