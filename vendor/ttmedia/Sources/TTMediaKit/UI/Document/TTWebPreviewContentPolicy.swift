// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import WebKit

/// Shared offline content security policy, isolated script world, and external navigation guard
/// for HTML, SVG, and EPUB WKWebView preview components.
public enum TTWebPreviewContentPolicy {

    /// Isolated content world used exclusively for controlled reader/preview scripts
    /// (theme switching, typography variables, anchor scrolling).
    /// Never uses `WKContentWorld.page`.
    @MainActor
    public static let readerControlWorld: WKContentWorld = .defaultClient

    /// Strict offline Content-Security-Policy meta tag content.
    public static let offlineCSPDirective: String =
        "default-src 'none'; " +
        "img-src data: blob: ttzip-vfs: file:; " +
        "style-src 'unsafe-inline' data: ttzip-vfs: file:; " +
        "font-src data: ttzip-vfs: file:; " +
        "media-src data: blob: ttzip-vfs: file:; " +
        "script-src 'none'; " +
        "connect-src 'none'; " +
        "frame-src 'none'; " +
        "object-src 'none'; " +
        "base-uri 'none'; " +
        "form-action 'none';"

    /// Full `<meta>` tag injected into HTML/XHTML/SVG documents before loading into `WKWebView`.
    public static let offlineCSPMetaTag: String =
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(offlineCSPDirective)\">"

    /// Injectable handler for opening external HTTP/HTTPS links in the default system browser.
    @MainActor
    public static var externalLinkOpener: (@MainActor @Sendable (URL) -> Void) = { url in
        NSWorkspace.shared.open(url)
    }

    /// Configures a `WKWebViewConfiguration` for offline, non-persistent, script-isolated rendering.
    @MainActor
    public static func apply(to config: WKWebViewConfiguration) {
        config.websiteDataStore = .nonPersistent()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
    }

    /// Returns `true` only if the URL scheme is `http` or `https` (case-insensitive).
    public static func isAllowedExternalScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Opens the URL via `externalLinkOpener` if and only if its scheme is `http` or `https`.
    @discardableResult
    @MainActor
    public static func openExternalLinkIfAllowed(_ url: URL) -> Bool {
        guard isAllowedExternalScheme(url) else { return false }
        externalLinkOpener(url)
        return true
    }

    /// Injects the offline Content-Security-Policy `<meta>` tag into the real `<head>` of an HTML/XHTML document,
    /// using a deterministic lexical scanner that skips HTML comments, declarations, and quoted attributes.
    public static func injectOfflineCSP(into html: String) -> String {
        let cleaned = stripExistingCSPMetaTags(from: html)
        switch scanCSPInsertionTarget(in: cleaned) {
        case .insideHead(let index):
            var modified = cleaned
            modified.insert(contentsOf: "\n" + offlineCSPMetaTag, at: index)
            return modified
        case .wrapHead(let index):
            var modified = cleaned
            modified.insert(contentsOf: "<head>\(offlineCSPMetaTag)</head>\n", at: index)
            return modified
        }
    }

    /// Verifies that the offline CSP `<meta>` tag exists outside all HTML5 comments (`<!-->`, `<!--->`, `-->`, `--!>`).
    public static func isCSPMetaOutsideComments(in html: String) -> Bool {
        var idx = html.startIndex
        var nonCommentHTML = ""
        while idx < html.endIndex {
            if html[idx...].hasPrefix("<!--") {
                if let commentEnd = findHTMLCommentEnd(in: html, from: idx) {
                    idx = commentEnd
                } else {
                    break
                }
            } else {
                nonCommentHTML.append(html[idx])
                idx = html.index(after: idx)
            }
        }
        return nonCommentHTML.range(of: "http-equiv=\"Content-Security-Policy\"", options: .caseInsensitive) != nil
    }

    private enum CSPInsertionTarget {
        case insideHead(at: String.Index)
        case wrapHead(at: String.Index)
    }

    private struct ParsedHTMLTag {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        let range: Range<String.Index>
    }

    private static func stripExistingCSPMetaTags(from html: String) -> String {
        guard html.range(of: "Content-Security-Policy", options: .caseInsensitive) != nil else {
            return html
        }
        let metaPattern = #"<meta\b[^>]*http-equiv\s*=\s*["']?Content-Security-Policy["']?[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: metaPattern, options: .caseInsensitive) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }

    private static func scanCSPInsertionTarget(in html: String) -> CSPInsertionTarget {
        var idx = html.hasPrefix("\u{FEFF}") ? html.index(after: html.startIndex) : html.startIndex
        var preambleEnd = idx
        var htmlOpenEnd: String.Index?

        while idx < html.endIndex {
            if html[idx].isWhitespace {
                idx = html.index(after: idx)
                continue
            }
            guard html[idx] == "<" else {
                return .wrapHead(at: htmlOpenEnd ?? idx)
            }
            if let nextIdx = skipMarkupDeclarationOrComment(in: html, from: idx, preambleEnd: &preambleEnd) {
                idx = nextIdx
                continue
            }
            if isSpecialMarkupPrefix(in: html, at: idx) {
                return .wrapHead(at: htmlOpenEnd ?? idx)
            }
            guard let tag = parseHTMLTag(in: html, from: idx) else {
                return .wrapHead(at: htmlOpenEnd ?? idx)
            }
            if let target = classifyParsedTag(tag, htmlOpenEnd: &htmlOpenEnd) {
                return target
            }
            idx = tag.range.upperBound
        }
        return .wrapHead(at: htmlOpenEnd ?? preambleEnd)
    }

    private static func isSpecialMarkupPrefix(in html: String, at idx: String.Index) -> Bool {
        let rest = html[idx...]
        return rest.hasPrefix("<!--") || rest.hasPrefix("<?") || rest.hasPrefix("<!")
    }

    private static func classifyParsedTag(
        _ tag: ParsedHTMLTag,
        htmlOpenEnd: inout String.Index?
    ) -> CSPInsertionTarget? {
        if tag.name == "head" {
            let isOpenTag = !tag.isClosing && !tag.isSelfClosing
            return isOpenTag ? .insideHead(at: tag.range.upperBound) : .wrapHead(at: tag.range.lowerBound)
        }
        if tag.name == "html" && !tag.isClosing && !tag.isSelfClosing && htmlOpenEnd == nil {
            htmlOpenEnd = tag.range.upperBound
            return nil
        }
        return .wrapHead(at: htmlOpenEnd ?? tag.range.lowerBound)
    }

    /// Scans the end of an HTML5 comment starting with `<!--`, handling WHATWG HTML5 abrupt-closing
    /// comments (`<!-->`, `<!--->`) as well as standard (`-->`) and bang-terminated (`--!>`) comments.
    private static func findHTMLCommentEnd(in html: String, from commentStart: String.Index) -> String.Index? {
        let afterOpen = html.index(commentStart, offsetBy: 4)
        guard afterOpen < html.endIndex else { return nil }
        if html[afterOpen] == ">" {
            return html.index(after: afterOpen)
        }
        if html[afterOpen...].hasPrefix("->") {
            return html.index(afterOpen, offsetBy: 2)
        }
        let stdClose = html.range(of: "-->", range: afterOpen..<html.endIndex)
        let bangClose = html.range(of: "--!>", range: afterOpen..<html.endIndex)
        switch (stdClose, bangClose) {
        case let (s?, b?):
            return s.lowerBound <= b.lowerBound ? s.upperBound : b.upperBound
        case let (s?, nil):
            return s.upperBound
        case let (nil, b?):
            return b.upperBound
        case (nil, nil):
            return nil
        }
    }

    private static func skipMarkupDeclarationOrComment(
        in html: String,
        from idx: String.Index,
        preambleEnd: inout String.Index
    ) -> String.Index? {
        let rest = html[idx...]
        if rest.hasPrefix("<!--") {
            guard let commentEnd = findHTMLCommentEnd(in: html, from: idx) else {
                return nil
            }
            preambleEnd = commentEnd
            return commentEnd
        }
        if rest.lowercased().hasPrefix("<?xml") {
            let searchStart = html.index(idx, offsetBy: 2)
            guard let firstGt = html[searchStart...].firstIndex(of: ">"),
                  firstGt > searchStart,
                  html[html.index(before: firstGt)] == "?" else {
                return nil
            }
            let afterPI = html.index(after: firstGt)
            preambleEnd = afterPI
            return afterPI
        }
        if rest.lowercased().hasPrefix("<!doctype") {
            let searchStart = html.index(idx, offsetBy: 2)
            guard let firstGt = html[searchStart...].firstIndex(of: ">"),
                  let unquotedGt = findTagEndOutsideQuotes(in: html, from: searchStart),
                  firstGt == unquotedGt else {
                return nil
            }
            let afterDecl = html.index(after: firstGt)
            preambleEnd = afterDecl
            return afterDecl
        }
        return nil
    }

    private static func parseHTMLTag(in html: String, from start: String.Index) -> ParsedHTMLTag? {
        var cursor = html.index(after: start)
        guard cursor < html.endIndex else { return nil }

        var isClosing = false
        if html[cursor] == "/" {
            isClosing = true
            cursor = html.index(after: cursor)
        }

        let nameStart = cursor
        while cursor < html.endIndex {
            let c = html[cursor]
            if c.isLetter || c.isNumber || c == "-" || c == ":" {
                cursor = html.index(after: cursor)
            } else {
                break
            }
        }
        guard cursor > nameStart else { return nil }
        let tagName = html[nameStart..<cursor].lowercased()

        guard let closeIdx = findTagEndOutsideQuotes(in: html, from: cursor) else {
            return nil
        }
        let prevIdx = html.index(before: closeIdx)
        let isSelfClosing = !isClosing && html[prevIdx] == "/"
        let afterTag = html.index(after: closeIdx)
        return ParsedHTMLTag(
            name: tagName,
            isClosing: isClosing,
            isSelfClosing: isSelfClosing,
            range: start..<afterTag
        )
    }

    private static func findTagEndOutsideQuotes(in html: String, from start: String.Index) -> String.Index? {
        var cursor = start
        var activeQuote: Character?
        while cursor < html.endIndex {
            let ch = html[cursor]
            if let q = activeQuote {
                if ch == q { activeQuote = nil }
            } else if ch == "\"" || ch == "'" {
                activeQuote = ch
            } else if ch == ">" {
                return cursor
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    // MARK: - Book / Archive Resource Boundary Validation

    /// Verifies that an embedded resource or chapter URL stays strictly within the authorized book boundary.
    public static func isResourceWithinBookBoundary(
        assetURL: URL,
        chapterURL: URL,
        baseDirectory: URL?
    ) -> Bool {
        if containsNullByte(assetURL) || containsNullByte(chapterURL) {
            return false
        }
        if let baseDir = baseDirectory, containsNullByte(baseDir) {
            return false
        }

        let assetScheme = assetURL.scheme?.lowercased() ?? ""
        let chapterScheme = chapterURL.scheme?.lowercased() ?? ""
        guard !assetScheme.isEmpty, assetScheme == chapterScheme else {
            return false
        }
        if let baseDir = baseDirectory {
            let baseScheme = baseDir.scheme?.lowercased() ?? ""
            guard !baseScheme.isEmpty, assetScheme == baseScheme else {
                return false
            }
        }

        if assetScheme == "ttzip-vfs" {
            return isVfsURLWithinBoundary(assetURL: assetURL, chapterURL: chapterURL, baseDirectory: baseDirectory)
        }
        if assetURL.isFileURL && chapterURL.isFileURL {
            return isFileURLWithinBoundary(assetURL: assetURL, chapterURL: chapterURL, baseDirectory: baseDirectory)
        }
        return false
    }

    private static func containsNullByte(_ url: URL) -> Bool {
        let raw = url.absoluteString
        let decoded = raw.removingPercentEncoding ?? raw
        return raw.contains("\0") || decoded.contains("\0")
    }

    private static func hasMatchingVfsAuthority(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsHost = (lhs.host?.removingPercentEncoding ?? lhs.host ?? "").lowercased()
        let rhsHost = (rhs.host?.removingPercentEncoding ?? rhs.host ?? "").lowercased()
        guard !lhsHost.isEmpty, lhsHost == rhsHost else { return false }
        return lhs.user == rhs.user && lhs.password == rhs.password && lhs.port == rhs.port
    }

    private static func hasLocalFileAuthority(_ url: URL) -> Bool {
        guard url.isFileURL, url.user == nil, url.password == nil, url.port == nil else {
            return false
        }
        let host = (url.host?.removingPercentEncoding ?? url.host ?? "").lowercased()
        return host.isEmpty || host == "localhost"
    }

    private static func isVfsURLWithinBoundary(
        assetURL: URL,
        chapterURL: URL,
        baseDirectory: URL?
    ) -> Bool {
        guard hasMatchingVfsAuthority(assetURL, chapterURL) else {
            return false
        }
        if let baseDir = baseDirectory, !hasMatchingVfsAuthority(assetURL, baseDir) {
            return false
        }
        guard let assetSegments = normalizedNonEscapingSegments(for: assetURL),
              normalizedNonEscapingSegments(for: chapterURL) != nil else {
            return false
        }
        if let baseDir = baseDirectory {
            guard let baseSegments = normalizedNonEscapingSegments(for: baseDir),
                  assetSegments.count >= baseSegments.count,
                  Array(assetSegments.prefix(baseSegments.count)) == baseSegments else {
                return false
            }
        }
        return true
    }

    private static func normalizedNonEscapingSegments(for url: URL) -> [String]? {
        let decodedPath = (url.path.removingPercentEncoding ?? url.path)
            .replacingOccurrences(of: "\\", with: "/")
        var segments: [String] = []
        for segment in decodedPath.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." { continue }
            if segment == ".." {
                if segments.isEmpty { return nil }
                segments.removeLast()
            } else {
                segments.append(String(segment))
            }
        }
        return segments
    }

    private static func isFileURLWithinBoundary(
        assetURL: URL,
        chapterURL: URL,
        baseDirectory: URL?
    ) -> Bool {
        guard hasLocalFileAuthority(assetURL), hasLocalFileAuthority(chapterURL) else {
            return false
        }
        let bookRoot: URL
        if let baseDir = baseDirectory {
            guard hasLocalFileAuthority(baseDir) else { return false }
            bookRoot = baseDir
        } else {
            bookRoot = chapterURL.deletingLastPathComponent()
        }

        let stdRoot = bookRoot.standardizedFileURL.path
        let stdAsset = assetURL.standardizedFileURL.path
        let stdRootPrefix = stdRoot.hasSuffix("/") ? stdRoot : stdRoot + "/"
        guard stdAsset == stdRoot || stdAsset.hasPrefix(stdRootPrefix) else {
            return false
        }

        let resolvedRoot = bookRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedAsset = assetURL.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedRootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedAsset == resolvedRoot || resolvedAsset.hasPrefix(resolvedRootPrefix) else {
            return false
        }

        let suffix = String(stdAsset.dropFirst(stdRoot.count))
        var currentURL = bookRoot.standardizedFileURL
        for component in suffix.split(separator: "/", omittingEmptySubsequences: true) {
            currentURL.appendPathComponent(String(component))
            let stepResolved = currentURL.resolvingSymlinksInPath().path
            if stepResolved != resolvedRoot && !stepResolved.hasPrefix(resolvedRootPrefix) {
                return false
            }
        }
        return true
    }
}
