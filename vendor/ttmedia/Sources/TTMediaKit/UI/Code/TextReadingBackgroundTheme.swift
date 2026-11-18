// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Complete resolved visual palette for text body, gutter, selection, insertion point, search highlights, and syntax tokens.
public struct TTTextReadingPalette: @unchecked Sendable, Equatable {
    public let drawsOpaqueBackground: Bool

    public let containerBackgroundColor: Color
    public let nsCanvasBackgroundColor: NSColor
    public let nsGutterBackgroundColor: NSColor
    public let nsGutterBorderColor: NSColor
    public let nsGutterLabelColor: NSColor

    public let nsForegroundColor: NSColor
    public let nsInsertionPointColor: NSColor
    public let nsSelectionBackgroundColor: NSColor
    public let nsSelectionTextColor: NSColor
    public let nsSearchMatchBackgroundColor: NSColor
    public let nsSearchMatchTextColor: NSColor

    public let syntaxKeywordColor: NSColor
    public let syntaxStringColor: NSColor
    public let syntaxCommentColor: NSColor
    public let syntaxNumberColor: NSColor
    public let syntaxTypeColor: NSColor

    public init(
        drawsOpaqueBackground: Bool,
        containerBackgroundColor: Color,
        nsCanvasBackgroundColor: NSColor,
        nsGutterBackgroundColor: NSColor,
        nsGutterBorderColor: NSColor,
        nsGutterLabelColor: NSColor,
        nsForegroundColor: NSColor,
        nsInsertionPointColor: NSColor,
        nsSelectionBackgroundColor: NSColor,
        nsSelectionTextColor: NSColor,
        nsSearchMatchBackgroundColor: NSColor,
        nsSearchMatchTextColor: NSColor,
        syntaxKeywordColor: NSColor,
        syntaxStringColor: NSColor,
        syntaxCommentColor: NSColor,
        syntaxNumberColor: NSColor,
        syntaxTypeColor: NSColor
    ) {
        self.drawsOpaqueBackground = drawsOpaqueBackground
        self.containerBackgroundColor = containerBackgroundColor
        self.nsCanvasBackgroundColor = nsCanvasBackgroundColor
        self.nsGutterBackgroundColor = nsGutterBackgroundColor
        self.nsGutterBorderColor = nsGutterBorderColor
        self.nsGutterLabelColor = nsGutterLabelColor
        self.nsForegroundColor = nsForegroundColor
        self.nsInsertionPointColor = nsInsertionPointColor
        self.nsSelectionBackgroundColor = nsSelectionBackgroundColor
        self.nsSelectionTextColor = nsSelectionTextColor
        self.nsSearchMatchBackgroundColor = nsSearchMatchBackgroundColor
        self.nsSearchMatchTextColor = nsSearchMatchTextColor
        self.syntaxKeywordColor = syntaxKeywordColor
        self.syntaxStringColor = syntaxStringColor
        self.syntaxCommentColor = syntaxCommentColor
        self.syntaxNumberColor = syntaxNumberColor
        self.syntaxTypeColor = syntaxTypeColor
    }

    public static let system = TTTextReadingPalette(
        drawsOpaqueBackground: true,
        containerBackgroundColor: Color(nsColor: .textBackgroundColor),
        nsCanvasBackgroundColor: .textBackgroundColor,
        nsGutterBackgroundColor: .textBackgroundColor,
        nsGutterBorderColor: .separatorColor,
        nsGutterLabelColor: .secondaryLabelColor,
        nsForegroundColor: .textColor,
        nsInsertionPointColor: .textColor,
        nsSelectionBackgroundColor: .selectedTextBackgroundColor,
        nsSelectionTextColor: .selectedTextColor,
        nsSearchMatchBackgroundColor: .findHighlightColor,
        nsSearchMatchTextColor: .textColor,
        syntaxKeywordColor: .textColor,
        syntaxStringColor: .textColor,
        syntaxCommentColor: .secondaryLabelColor,
        syntaxNumberColor: .textColor,
        syntaxTypeColor: .textColor
    )

    /// Computes WCAG 2.1 relative luminance in sRGB space (`0.0 ... 1.0`).
    public static func relativeLuminance(of color: NSColor) -> Double {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func linearize(_ channel: CGFloat) -> Double {
            let c = Double(max(0, min(1, channel)))
            return c <= 0.03928 ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linearize(srgb.redComponent)
        let g = linearize(srgb.greenComponent)
        let b = linearize(srgb.blueComponent)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Computes WCAG 2.1 contrast ratio (`1.0 ... 21.0`) between two colors.
    public static func contrastRatio(between first: NSColor, and second: NSColor) -> Double {
        let l1 = relativeLuminance(of: first)
        let l2 = relativeLuminance(of: second)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// Rendering strategy separating plain prose/log text files from syntax-highlighted source code.
public enum TTTextSyntaxRenderMode: Sendable, Equatable {
    case plainText
    case syntaxHighlighted(languageExt: String)

    public var isSyntaxHighlighted: Bool {
        if case .syntaxHighlighted = self { return true }
        return false
    }

    public var languageExtension: String? {
        if case .syntaxHighlighted(let ext) = self { return ext }
        return nil
    }

    /// Extensions that must render as clean plain text without code lexical tokenization.
    public static let plainTextExtensions: Set<String> = [
        "", "txt", "text", "log", "asc", "nfo", "out", "err"
    ]

    /// Recognized source code, markup, and structured configuration extensions eligible for syntax highlighting.
    public static let highlightedCodeExtensions: Set<String> = [
        "swift", "rs", "py", "pyw", "js", "mjs", "cjs", "ts", "mts", "cts", "jsx", "tsx",
        "json", "jsonc", "jsonl", "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm",
        "go", "java", "kt", "kts", "cs", "rb", "php", "sh", "bash", "zsh", "fish", "command",
        "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "plist", "svg",
        "html", "htm", "xhtml", "css", "scss", "sass", "less", "sql", "graphql", "gql",
        "proto", "dockerfile", "makefile", "mk", "cmake", "lua", "pl", "pm", "r",
        "dart", "scala", "zig", "nim", "erl", "hrl", "ex", "exs", "hs", "clj", "cljs",
        "lisp", "el", "vim", "md", "markdown", "bazel", "bzl"
    ]

    /// Resolves the rendering mode from the filename and optional caller override.
    /// Prevents plain `.txt` files from receiving false-positive comment/string/number coloring.
    public static func resolve(
        fileName: String,
        overrideMode: TTTextSyntaxRenderMode? = nil
    ) -> TTTextSyntaxRenderMode {
        if let overrideMode {
            return overrideMode
        }
        let baseName = ((fileName as NSString).lastPathComponent).lowercased()
        if baseName == "cmakelists.txt" {
            return .syntaxHighlighted(languageExt: "cmake")
        }
        if baseName == "makefile" || baseName == "gnumakefile" {
            return .syntaxHighlighted(languageExt: "makefile")
        }
        if baseName == "dockerfile" || baseName.hasPrefix("dockerfile.") {
            return .syntaxHighlighted(languageExt: "dockerfile")
        }
        if baseName == "build" || baseName == "workspace" {
            return .syntaxHighlighted(languageExt: "bazel")
        }

        let ext = (baseName as NSString).pathExtension.lowercased()
        if plainTextExtensions.contains(ext) {
            return .plainText
        }
        if highlightedCodeExtensions.contains(ext) {
            return .syntaxHighlighted(languageExt: ext)
        }
        return .plainText
    }
}

/// First-screen performance timing telemetry for text/code preview mounting, line indexing, and syntax tokenization.
public struct TTTextPreviewPerformanceMetrics: Sendable, Equatable {
    public let fileName: String
    public let syntaxMode: TTTextSyntaxRenderMode
    public let totalSourceBytes: Int64
    public let mountedUTF8Bytes: Int
    public let lineCount: Int
    public let sourceInspectDurationMs: Double
    public let initialMountDurationMs: Double
    public let lineStartScanDurationMs: Double
    public let firstHighlightBatchDurationMs: Double
    public let generation: UInt64

    public init(
        fileName: String,
        syntaxMode: TTTextSyntaxRenderMode,
        totalSourceBytes: Int64,
        mountedUTF8Bytes: Int,
        lineCount: Int,
        sourceInspectDurationMs: Double,
        initialMountDurationMs: Double,
        lineStartScanDurationMs: Double,
        firstHighlightBatchDurationMs: Double,
        generation: UInt64
    ) {
        self.fileName = fileName
        self.syntaxMode = syntaxMode
        self.totalSourceBytes = totalSourceBytes
        self.mountedUTF8Bytes = mountedUTF8Bytes
        self.lineCount = lineCount
        self.sourceInspectDurationMs = sourceInspectDurationMs
        self.initialMountDurationMs = initialMountDurationMs
        self.lineStartScanDurationMs = lineStartScanDurationMs
        self.firstHighlightBatchDurationMs = firstHighlightBatchDurationMs
        self.generation = generation
    }

    public var summaryDescription: String {
        String(
            format: "[TTTextPreviewPerf gen=%llu file=%@ mode=%@ bytes=%lld/%d lines=%d read=%.2fms mount=%.2fms lineIdx=%.2fms highlight=%.2fms]",
            generation,
            fileName,
            syntaxMode.isSyntaxHighlighted ? (syntaxMode.languageExtension ?? "code") : "plainText",
            totalSourceBytes,
            mountedUTF8Bytes,
            lineCount,
            sourceInspectDurationMs,
            initialMountDurationMs,
            lineStartScanDurationMs,
            firstHighlightBatchDurationMs
        )
    }
}

// MARK: - Reading Theme Application & Search/Token Coloring

extension CodeHighlightingEditorNSView.Coordinator {
    @MainActor
    public struct SyntaxPalette {
        public let comment: NSColor
        public let string: NSColor
        public let keyword: NSColor
        public let number: NSColor
        public let type: NSColor
        public let defaultColor: NSColor
        public let defaultFont: NSFont
        public let semiboldFont: NSFont

        public init(readingPalette: TTTextReadingPalette, fontSize: CGFloat = 12.5) {
            self.comment = readingPalette.syntaxCommentColor
            self.string = readingPalette.syntaxStringColor
            self.keyword = readingPalette.syntaxKeywordColor
            self.number = readingPalette.syntaxNumberColor
            self.type = readingPalette.syntaxTypeColor
            self.defaultColor = readingPalette.nsForegroundColor
            self.defaultFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            self.semiboldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        }
    }

    /// Applies a new `TTTextReadingPalette` in-place without remounting or losing selection, scroll position, or unsaved edits.
    public func applyReadingTheme(
        _ palette: TTTextReadingPalette,
        to tv: NSTextView,
        scrollView: NSScrollView?,
        recolorStorage: Bool
    ) {
        let didChangeFontSize = abs(activeFontSize - parent.fontSize) > 0.05
        let activeScrollView = scrollView ?? tv.enclosingScrollView
        let fontAnchor = didChangeFontSize ? captureViewportAnchor(in: tv, scrollView: activeScrollView) : nil
        activeReadingPalette = palette
        activeFontSize = parent.fontSize
        let savedSelection = tv.selectedRanges
        let savedOrigin = activeScrollView?.contentView.bounds.origin

        if let activeScrollView {
            activeScrollView.drawsBackground = palette.drawsOpaqueBackground
            activeScrollView.backgroundColor = palette.nsCanvasBackgroundColor
            activeScrollView.contentView.drawsBackground = palette.drawsOpaqueBackground
            activeScrollView.contentView.backgroundColor = palette.nsCanvasBackgroundColor
        }

        tv.drawsBackground = palette.drawsOpaqueBackground
        tv.backgroundColor = palette.nsCanvasBackgroundColor
        tv.insertionPointColor = palette.nsInsertionPointColor
        tv.selectedTextAttributes = [
            .backgroundColor: palette.nsSelectionBackgroundColor,
            .foregroundColor: palette.nsSelectionTextColor
        ]

        var typingAttrs = tv.typingAttributes
        typingAttrs[.paragraphStyle] = CodeHighlightingEditorNSView.codeParagraphStyle
        typingAttrs[.font] = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
        typingAttrs[.foregroundColor] = palette.nsForegroundColor
        tv.typingAttributes = typingAttrs

        rulerView?.readingPalette = palette
        rulerView?.needsDisplay = true

        if tv.hasMarkedText() {
            needsHighlightAfterMarkedText = true
            return
        }

        tv.textColor = palette.nsForegroundColor
        tv.font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)

        if recolorStorage, let storage = tv.textStorage ?? textStorageRef, storage.length > 0 {
            recolorStorageInPlace(storage, with: palette)
        }

        if tv.selectedRanges != savedSelection {
            tv.selectedRanges = savedSelection
        }
        if didChangeFontSize {
            (activeScrollView as? CodePreviewScrollView)?.synchronizeDocumentViewport(force: true)
            if let fontAnchor {
                restoreViewportAnchor(
                    fontAnchor,
                    in: tv,
                    scrollView: activeScrollView,
                    isSoftWrapEnabled: activeSoftWrapEnabled
                )
            }
        } else if let activeScrollView, let savedOrigin, activeScrollView.contentView.bounds.origin != savedOrigin {
            activeScrollView.contentView.scroll(to: savedOrigin)
            activeScrollView.reflectScrolledClipView(activeScrollView.contentView)
        }
    }

    internal func recolorStorageInPlace(_ storage: NSTextStorage, with palette: TTTextReadingPalette) {
        guard textStorageRef == nil || textStorageRef === storage else { return }
        if let tv = textView, tv.hasMarkedText() {
            needsHighlightAfterMarkedText = true
            return
        }
        let syntaxPalette = SyntaxPalette(readingPalette: palette, fontSize: parent.fontSize)
        isProgrammaticUpdate = true
        storage.beginEditing()
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.setAttributes([
            .font: syntaxPalette.defaultFont,
            .foregroundColor: syntaxPalette.defaultColor,
            .paragraphStyle: CodeHighlightingEditorNSView.codeParagraphStyle
        ], range: fullRange)

        if activeSyntaxMode.isSyntaxHighlighted && !cachedTokenSpans.isEmpty {
            applyTokens(cachedTokenSpans, to: storage, palette: syntaxPalette)
        }
        if !activeSearchQuery.isEmpty {
            refreshSearchMatchRanges(in: storage, options: activeSearchOptions)
        }
        applySearchHighlightsToStorage(storage, palette: palette)
        storage.endEditing()
        isProgrammaticUpdate = false
    }

    /// Handles IME marked-text composition updates and defers storage recolor until composition ends.
    internal func handleMarkedTextDidUpdate(in tv: NSTextView) {
        guard !isProgrammaticUpdate,
              self.textView === tv,
              let storage = tv.textStorage,
              self.textStorageRef === storage else { return }
        if parent.effectiveIsEditable && (fullPreviewText != tv.string || parent.text != tv.string) {
            synchronizeTextStateFromEditor(tv, forceNotifyBinding: true)
        }
        if tv.hasMarkedText() {
            needsHighlightAfterMarkedText = true
            cancelDebounceTask()
        }
    }

    /// Consumes a deferred IME highlight request once composition ends and schedules the latest syntax pass idempotently.
    internal func handleMarkedTextDidCommit(in tv: NSTextView) {
        guard !isProgrammaticUpdate,
              !tv.hasMarkedText(),
              self.textView === tv,
              let storage = tv.textStorage,
              self.textStorageRef === storage else { return }
        if parent.effectiveIsEditable && (fullPreviewText != tv.string || parent.text != tv.string) {
            synchronizeTextStateFromEditor(tv, forceNotifyBinding: true)
        }
        guard needsHighlightAfterMarkedText else { return }
        needsHighlightAfterMarkedText = false
        cancelDebounceTask()
        if !activeSearchQuery.isEmpty {
            refreshSearchMatchRanges(in: storage, options: activeSearchOptions)
        }
        let targetFileName = lastMountedFileName.isEmpty ? parent.fileName : lastMountedFileName
        highlightSyntaxProgressive(in: tv, fileName: targetFileName)
    }

    /// Computes and highlights all search matches in the mounted `NSTextStorage` using the active reading palette.
    public func updateSearchHighlights(
        query: String,
        options: NSString.CompareOptions = [.caseInsensitive],
        in tv: NSTextView
    ) {
        activeSearchQuery = query
        activeSearchOptions = options
        guard let storage = tv.textStorage ?? textStorageRef else { return }
        refreshSearchMatchRanges(in: storage, options: options)
        recolorStorageInPlace(storage, with: activeReadingPalette)
    }

    internal func refreshSearchMatchRanges(
        in storage: NSTextStorage,
        options: NSString.CompareOptions = [.caseInsensitive]
    ) {
        searchMatchRanges.removeAll(keepingCapacity: true)
        guard !activeSearchQuery.isEmpty && storage.length > 0 else { return }
        let nsText = storage.string as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)
        while searchRange.location < nsText.length {
            let found = nsText.range(of: activeSearchQuery, options: options, range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            searchMatchRanges.append(found)
            let nextStart = NSMaxRange(found)
            guard nextStart <= nsText.length else { break }
            searchRange = NSRange(location: nextStart, length: nsText.length - nextStart)
            if searchMatchRanges.count >= 2000 { break }
        }
    }

    internal func applySearchHighlightsToStorage(_ storage: NSTextStorage, palette: TTTextReadingPalette) {
        guard !searchMatchRanges.isEmpty else { return }
        let storageLen = storage.length
        for match in searchMatchRanges where NSMaxRange(match) <= storageLen {
            storage.addAttribute(.backgroundColor, value: palette.nsSearchMatchBackgroundColor, range: match)
            storage.addAttribute(.foregroundColor, value: palette.nsSearchMatchTextColor, range: match)
        }
    }

    internal func applyTokens(_ tokens: [TokenSpan], to storage: NSTextStorage, palette: SyntaxPalette) {
        for token in tokens {
            guard token.range.location + token.range.length <= storage.length else { continue }
            switch token.colorType {
            case .comment:
                storage.addAttribute(.foregroundColor, value: palette.comment, range: token.range)
            case .string:
                storage.addAttribute(.foregroundColor, value: palette.string, range: token.range)
            case .keyword:
                storage.addAttribute(.foregroundColor, value: palette.keyword, range: token.range)
                storage.addAttribute(.font, value: palette.semiboldFont, range: token.range)
            case .number:
                storage.addAttribute(.foregroundColor, value: palette.number, range: token.range)
            case .type:
                storage.addAttribute(.foregroundColor, value: palette.type, range: token.range)
            }
        }
    }
}
