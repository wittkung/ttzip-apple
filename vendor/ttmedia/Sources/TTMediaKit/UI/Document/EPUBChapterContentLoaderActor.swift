// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

// MARK: - Dedicated Actor for EPUB Chapter Reading, Resource Inlining & Content Caching

public actor EPUBChapterContentLoaderActor {
    public static let shared = EPUBChapterContentLoaderActor()

    public struct ChapterLoadTelemetry: Sendable, Equatable {
        public let html: String
        public let chapterReadMs: Double
        public let resourceAuthAndInlineMs: Double
        public let inlinedResourceCount: Int
        public let authenticatedCacheHitCount: Int

        public init(
            html: String,
            chapterReadMs: Double,
            resourceAuthAndInlineMs: Double,
            inlinedResourceCount: Int,
            authenticatedCacheHitCount: Int
        ) {
            self.html = html
            self.chapterReadMs = chapterReadMs
            self.resourceAuthAndInlineMs = resourceAuthAndInlineMs
            self.inlinedResourceCount = inlinedResourceCount
            self.authenticatedCacheHitCount = authenticatedCacheHitCount
        }
    }

    public typealias CustomURLDataProvider = @Sendable (URL) async -> Data?
    private static let _providerLock = NSLock()
    nonisolated(unsafe) private static var _customDataProvider: CustomURLDataProvider?

    public static var customDataProvider: CustomURLDataProvider? {
        get {
            _providerLock.lock()
            defer { _providerLock.unlock() }
            return _customDataProvider
        }
        set {
            _providerLock.lock()
            defer { _providerLock.unlock() }
            _customDataProvider = newValue
        }
    }

    private var authenticatedDataURICache: [String: String] = [:]
    private var authenticatedCacheOrder: [String] = []
    private var authenticatedCacheBytes: Int = 0
    private let maxCacheEntries = 64
    private let maxCacheBytes = 16 * 1024 * 1024

    private init() {}

    public func clearAuthenticatedCache() {
        authenticatedDataURICache.removeAll()
        authenticatedCacheOrder.removeAll()
        authenticatedCacheBytes = 0
    }

    /// Verifies that an embedded resource or chapter URL stays strictly within the authorized book boundary.
    public nonisolated static func isResourceWithinBookBoundary(
        assetURL: URL,
        chapterURL: URL,
        baseDirectory: URL?
    ) -> Bool {
        TTWebPreviewContentPolicy.isResourceWithinBookBoundary(
            assetURL: assetURL,
            chapterURL: chapterURL,
            baseDirectory: baseDirectory
        )
    }

    public func loadChapter(
        at chapterURL: URL,
        customCSS: String,
        baseDirectory: URL? = nil
    ) async -> String? {
        await loadChapterWithTelemetry(
            at: chapterURL,
            customCSS: customCSS,
            baseDirectory: baseDirectory
        )?.html
    }

    public func loadChapterWithTelemetry(
        at chapterURL: URL,
        customCSS: String,
        baseDirectory: URL? = nil
    ) async -> ChapterLoadTelemetry? {
        let cleanChapterURL = EPUBNativeWKWebView.stripFragment(from: chapterURL)
        guard Self.isResourceWithinBookBoundary(
            assetURL: cleanChapterURL,
            chapterURL: cleanChapterURL,
            baseDirectory: baseDirectory
        ) else {
            return nil
        }
        let readStart = ProcessInfo.processInfo.systemUptime
        let rawHTML = await readRawChapterString(from: cleanChapterURL)
        let chapterReadMs = max(0, (ProcessInfo.processInfo.systemUptime - readStart) * 1000.0)

        guard let html = rawHTML else { return nil }
        let inlineStart = ProcessInfo.processInfo.systemUptime
        let inlineResult = await inlineEmbeddedResources(
            in: html,
            chapterURL: cleanChapterURL,
            baseDirectory: baseDirectory
        )
        let styledHTML: String
        if let range = inlineResult.html.range(of: "</head>", options: .caseInsensitive) {
            var modifiedHTML = inlineResult.html
            modifiedHTML.insert(contentsOf: customCSS, at: range.lowerBound)
            styledHTML = modifiedHTML
        } else {
            styledHTML = customCSS + inlineResult.html
        }
        let finalHTML = TTWebPreviewContentPolicy.injectOfflineCSP(into: styledHTML)
        let resourceAuthAndInlineMs = max(0, (ProcessInfo.processInfo.systemUptime - inlineStart) * 1000.0)
        return ChapterLoadTelemetry(
            html: finalHTML,
            chapterReadMs: chapterReadMs,
            resourceAuthAndInlineMs: resourceAuthAndInlineMs,
            inlinedResourceCount: inlineResult.inlinedCount,
            authenticatedCacheHitCount: inlineResult.cacheHits
        )
    }

    private func readRawChapterString(from cleanChapterURL: URL) async -> String? {
        if let provider = Self.customDataProvider, let data = await provider(cleanChapterURL) {
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        guard cleanChapterURL.isFileURL else { return nil }
        if let str = try? String(contentsOf: cleanChapterURL, encoding: .utf8) {
            return str
        }
        if let data = try? Data(contentsOf: cleanChapterURL) {
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        return nil
    }

    private func inlineImages(
        in html: String,
        chapterURL: URL,
        baseDirectory: URL?
    ) async -> (html: String, count: Int, hits: Int) {
        var processedHTML = html
        var count = 0
        var hits = 0
        let imgPattern = #"(?:xlink:href|href|src)=["\x27]([^"\x27]+\.(?:jpg|jpeg|png|gif|webp|svg))["\x27]"#
        guard let imgRegex = try? NSRegularExpression(pattern: imgPattern, options: .caseInsensitive) else {
            return (processedHTML, 0, 0)
        }
        let matches = imgRegex.matches(in: processedHTML, range: NSRange(processedHTML.startIndex..., in: processedHTML))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: processedHTML),
                  let pathRange = Range(match.range(at: 1), in: processedHTML) else { continue }
            let relativePath = String(processedHTML[pathRange])
            guard let assetURL = resolveAuthorizedAssetURL(
                relativePath: relativePath,
                chapterURL: chapterURL,
                baseDirectory: baseDirectory
            ) else { continue }
            guard let resolvedURI = await loadOrCacheAuthorizedDataURI(
                from: assetURL,
                relativePath: relativePath,
                chapterURL: chapterURL
            ) else { continue }
            count += 1
            if resolvedURI.fromCache { hits += 1 }
            let fullMatched = String(processedHTML[fullRange])
            if fullMatched.starts(with: "xlink:href") {
                let replacement = "xlink:href=\"\(resolvedURI.value)\" href=\"\(resolvedURI.value)\""
                processedHTML.replaceSubrange(fullRange, with: replacement)
            } else {
                let replaced = fullMatched.replacingOccurrences(of: relativePath, with: resolvedURI.value)
                processedHTML.replaceSubrange(fullRange, with: replaced)
            }
        }
        return (processedHTML, count, hits)
    }

    private func inlineStylesheets(
        in html: String,
        chapterURL: URL,
        baseDirectory: URL?
    ) async -> (html: String, count: Int, hits: Int) {
        var processedHTML = html
        var count = 0
        var hits = 0
        guard processedHTML.range(of: ".css", options: .caseInsensitive) != nil else {
            return (processedHTML, 0, 0)
        }
        let cssPattern = #"<link[^>]+href=["\x27]([^"\x27]+\.css)["\x27][^>]*>"#
        guard let cssRegex = try? NSRegularExpression(pattern: cssPattern, options: .caseInsensitive) else {
            return (processedHTML, 0, 0)
        }
        let matches = cssRegex.matches(in: processedHTML, range: NSRange(processedHTML.startIndex..., in: processedHTML))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: processedHTML),
                  let pathRange = Range(match.range(at: 1), in: processedHTML) else { continue }
            let relativePath = String(processedHTML[pathRange])
            guard let assetURL = resolveAuthorizedAssetURL(
                relativePath: relativePath,
                chapterURL: chapterURL,
                baseDirectory: baseDirectory
            ) else { continue }
            guard let resolvedCSS = await loadOrCacheAuthorizedCSS(
                from: assetURL,
                relativePath: relativePath,
                chapterURL: chapterURL
            ) else { continue }
            count += 1
            if resolvedCSS.fromCache { hits += 1 }
            processedHTML.replaceSubrange(fullRange, with: resolvedCSS.styleTag)
        }
        return (processedHTML, count, hits)
    }

    private func inlineEmbeddedResources(
        in html: String,
        chapterURL: URL,
        baseDirectory: URL? = nil
    ) async -> (html: String, inlinedCount: Int, cacheHits: Int) {
        let strippedHTML = stripRemoteResourceURLs(in: html)
        let (withImages, imgCount, imgHits) = await inlineImages(
            in: strippedHTML,
            chapterURL: chapterURL,
            baseDirectory: baseDirectory
        )
        let (finalHTML, cssCount, cssHits) = await inlineStylesheets(
            in: withImages,
            chapterURL: chapterURL,
            baseDirectory: baseDirectory
        )
        return (finalHTML, imgCount + cssCount, imgHits + cssHits)
    }

    private func loadOrCacheAuthorizedDataURI(
        from assetURL: URL,
        relativePath: String,
        chapterURL: URL
    ) async -> (value: String, fromCache: Bool)? {
        let cacheKey = "img::\(assetURL.absoluteString)"
        if Self.customDataProvider == nil, let cached = authenticatedDataURICache[cacheKey] {
            return (cached, true)
        }
        guard let data = await loadAuthorizedAssetData(from: assetURL, chapterURL: chapterURL),
              !data.isEmpty else { return nil }
        let mime = Self.imageMimeType(for: relativePath)
        let dataURI = "data:\(mime);base64,\(data.base64EncodedString())"
        if Self.customDataProvider == nil {
            storeInAuthenticatedCache(key: cacheKey, value: dataURI)
        }
        return (dataURI, false)
    }

    private func loadOrCacheAuthorizedCSS(
        from assetURL: URL,
        relativePath: String,
        chapterURL: URL
    ) async -> (styleTag: String, fromCache: Bool)? {
        let cacheKey = "css::\(assetURL.absoluteString)"
        if Self.customDataProvider == nil, let cached = authenticatedDataURICache[cacheKey] {
            return (cached, true)
        }
        guard let data = await loadAuthorizedAssetData(from: assetURL, chapterURL: chapterURL) else { return nil }
        let cssString = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let sanitizedCSS = stripRemoteCSSURLs(in: cssString)
        let styleTag = "<style>/* inlined: \(relativePath) */\n\(sanitizedCSS)\n</style>"
        if Self.customDataProvider == nil {
            storeInAuthenticatedCache(key: cacheKey, value: styleTag)
        }
        return (styleTag, false)
    }

    private func storeInAuthenticatedCache(key: String, value: String) {
        let entryBytes = value.utf8.count
        guard entryBytes <= maxCacheBytes / 2 else { return }
        while (authenticatedDataURICache.count >= maxCacheEntries || authenticatedCacheBytes + entryBytes > maxCacheBytes),
              !authenticatedCacheOrder.isEmpty {
            let evictedKey = authenticatedCacheOrder.removeFirst()
            if let removed = authenticatedDataURICache.removeValue(forKey: evictedKey) {
                authenticatedCacheBytes = max(0, authenticatedCacheBytes - removed.utf8.count)
            }
        }
        authenticatedDataURICache[key] = value
        authenticatedCacheOrder.append(key)
        authenticatedCacheBytes += entryBytes
    }

    private func resolveAuthorizedAssetURL(
        relativePath: String,
        chapterURL: URL,
        baseDirectory: URL?
    ) -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        if trimmed.isEmpty || trimmed.contains("\0") || decoded.contains("\0") {
            return nil
        }
        let lowerPath = trimmed.lowercased()
        if lowerPath.hasPrefix("data:") || lowerPath.hasPrefix("http://") || lowerPath.hasPrefix("https://") {
            return nil
        }
        let resolvedURL: URL?
        if chapterURL.isFileURL && !trimmed.contains("://") {
            let chapterDir = chapterURL.deletingLastPathComponent()
            let cleanRel = decoded.replacingOccurrences(of: "\\", with: "/")
            if cleanRel.hasPrefix("/") {
                return nil
            }
            resolvedURL = URL(fileURLWithPath: cleanRel, relativeTo: chapterDir).standardizedFileURL
        } else {
            resolvedURL = URL(string: trimmed, relativeTo: chapterURL)?.absoluteURL
        }
        guard let candidate = resolvedURL,
              Self.isResourceWithinBookBoundary(
                  assetURL: candidate,
                  chapterURL: chapterURL,
                  baseDirectory: baseDirectory
              ) else {
            return nil
        }
        return candidate
    }

    private func loadAuthorizedAssetData(from assetURL: URL, chapterURL: URL) async -> Data? {
        if let provider = Self.customDataProvider {
            if let provided = await provider(assetURL) {
                return provided
            }
        }
        if chapterURL.isFileURL && assetURL.isFileURL {
            return try? Data(contentsOf: assetURL)
        }
        return nil
    }

    private nonisolated static func imageMimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }

    private func stripRemoteResourceURLs(in html: String) -> String {
        guard html.range(of: "http", options: .caseInsensitive) != nil else {
            return html
        }
        var result = html
        let remoteLinkPattern = #"<link\b[^>]*\bhref\s*=\s*["']https?://[^"']*["'][^>]*/?>"#
        if let regex = try? NSRegularExpression(pattern: remoteLinkPattern, options: .caseInsensitive) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        let remoteSrcPattern = #"(\b(?:src|xlink:href)\s*=\s*["'])https?://[^"']*(["'])"#
        if let regex = try? NSRegularExpression(pattern: remoteSrcPattern, options: .caseInsensitive) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1about:blank$2")
        }
        return result
    }

    private func stripRemoteCSSURLs(in css: String) -> String {
        guard css.range(of: "http", options: .caseInsensitive) != nil else {
            return css
        }
        let remoteCSSUrlPattern = #"url\(\s*["']?https?://[^)"']+["']?\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: remoteCSSUrlPattern, options: .caseInsensitive) else {
            return css
        }
        let range = NSRange(css.startIndex..., in: css)
        return regex.stringByReplacingMatches(in: css, range: range, withTemplate: "url(about:blank)")
    }
}
