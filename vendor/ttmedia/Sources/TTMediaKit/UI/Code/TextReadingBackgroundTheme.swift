// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import Observation

/// Three-state reading background preference for text and code previews.
/// Operates independently of W2's global application appearance while adapting foreground contrast when in `.fluidTransparent` mode.
public enum TTTextReadingBackgroundMode: String, CaseIterable, Sendable, Equatable, Identifiable {
    case black = "black"
    case white = "white"
    case fluidTransparent = "fluidTransparent"

    public var id: String { rawValue }

    /// Canonical default reading background mode across all text/code preview entry points.
    public static let defaultMode: TTTextReadingBackgroundMode = .fluidTransparent

    /// Persistent `UserDefaults` key shared across all text preview components.
    public static let userDefaultsKey: String = "ttmedia.preview.text.readingBackgroundMode"

    /// SF Symbol icon representing each background state.
    public var iconName: String {
        switch self {
        case .black: return "moon.fill"
        case .white: return "sun.max.fill"
        case .fluidTransparent: return "drop.halffill"
        }
    }

    /// True when the canvas lets the underlying fluid glass material shine through.
    public var isFluidTransparent: Bool {
        self == .fluidTransparent
    }

    /// True when the scroll view and text view draw an opaque solid canvas background.
    public var drawsOpaqueBackground: Bool {
        self != .fluidTransparent
    }

    /// Resolves whether the foreground and syntax tokens should use dark-canvas (light ink) or light-canvas (dark ink) styling.
    public func effectiveIsDark(isAppDarkAppearance: Bool) -> Bool {
        switch self {
        case .black: return true
        case .white: return false
        case .fluidTransparent: return isAppDarkAppearance
        }
    }

    /// Dynamic localized label resolved from `LocalizationState.shared`.
    @MainActor
    public var localizedTitle: String {
        switch self {
        case .black:
            return TextAndDocumentPreviewLocalization.text(.readingBackgroundBlack)
        case .white:
            return TextAndDocumentPreviewLocalization.text(.readingBackgroundWhite)
        case .fluidTransparent:
            return TextAndDocumentPreviewLocalization.text(.readingBackgroundFluidTransparent)
        }
    }

    /// Dynamic localized tooltip / accessibility help resolved from `LocalizationState.shared`.
    @MainActor
    public var localizedHelpText: String {
        switch self {
        case .black:
            return TextAndDocumentPreviewLocalization.text(.readingBackgroundBlackHelp)
        case .white:
            return TextAndDocumentPreviewLocalization.text(.readingBackgroundWhiteHelp)
        case .fluidTransparent:
            return TextAndDocumentPreviewLocalization.text(.readingBackgroundFluidTransparentHelp)
        }
    }
}

/// Complete resolved visual palette for text body, gutter, selection, insertion point, search highlights, and syntax tokens.
public struct TTTextReadingPalette: @unchecked Sendable, Equatable {
    public let mode: TTTextReadingBackgroundMode
    public let effectiveIsDark: Bool
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

    public static func resolve(
        mode: TTTextReadingBackgroundMode,
        isDarkAppearance: Bool
    ) -> TTTextReadingPalette {
        let isDark = mode.effectiveIsDark(isAppDarkAppearance: isDarkAppearance)
        switch mode {
        case .black:
            return makeDarkPalette(mode: .black, isOpaque: true)
        case .white:
            return makeLightPalette(mode: .white, isOpaque: true)
        case .fluidTransparent:
            return isDark
                ? makeDarkPalette(mode: .fluidTransparent, isOpaque: false)
                : makeLightPalette(mode: .fluidTransparent, isOpaque: false)
        }
    }

    private static func makeDarkPalette(
        mode: TTTextReadingBackgroundMode,
        isOpaque: Bool
    ) -> TTTextReadingPalette {
        let canvasNS = isOpaque
            ? NSColor(srgbRed: 0.067, green: 0.075, blue: 0.094, alpha: 1.0)
            : NSColor.clear
        let containerSwiftUI = isOpaque
            ? Color(nsColor: canvasNS)
            : Color.clear
        let gutterBG = isOpaque
            ? NSColor(srgbRed: 0.086, green: 0.098, blue: 0.125, alpha: 1.0)
            : NSColor.clear
        let gutterBorder = isOpaque
            ? NSColor(srgbRed: 0.165, green: 0.180, blue: 0.224, alpha: 1.0)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.12)

        return TTTextReadingPalette(
            mode: mode,
            effectiveIsDark: true,
            drawsOpaqueBackground: isOpaque,
            containerBackgroundColor: containerSwiftUI,
            nsCanvasBackgroundColor: canvasNS,
            nsGutterBackgroundColor: gutterBG,
            nsGutterBorderColor: gutterBorder,
            nsGutterLabelColor: NSColor(srgbRed: 0.545, green: 0.580, blue: 0.620, alpha: 1.0),
            nsForegroundColor: NSColor(srgbRed: 0.925, green: 0.929, blue: 0.941, alpha: 1.0),
            nsInsertionPointColor: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            nsSelectionBackgroundColor: NSColor(srgbRed: 0.149, green: 0.310, blue: 0.471, alpha: 0.88),
            nsSelectionTextColor: NSColor(srgbRed: 0.960, green: 0.969, blue: 0.980, alpha: 1.0),
            nsSearchMatchBackgroundColor: NSColor(srgbRed: 0.420, green: 0.325, blue: 0.078, alpha: 0.92),
            nsSearchMatchTextColor: NSColor(srgbRed: 1.0, green: 0.898, blue: 0.561, alpha: 1.0),
            syntaxKeywordColor: NSColor(srgbRed: 1.0, green: 0.482, blue: 0.447, alpha: 1.0),
            syntaxStringColor: NSColor(srgbRed: 0.647, green: 0.839, blue: 1.0, alpha: 1.0),
            syntaxCommentColor: NSColor(srgbRed: 0.545, green: 0.580, blue: 0.620, alpha: 1.0),
            syntaxNumberColor: NSColor(srgbRed: 0.475, green: 0.753, blue: 1.0, alpha: 1.0),
            syntaxTypeColor: NSColor(srgbRed: 1.0, green: 0.651, blue: 0.341, alpha: 1.0)
        )
    }

    private static func makeLightPalette(
        mode: TTTextReadingBackgroundMode,
        isOpaque: Bool
    ) -> TTTextReadingPalette {
        let canvasNS = isOpaque
            ? NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            : NSColor.clear
        let containerSwiftUI = isOpaque
            ? Color(nsColor: canvasNS)
            : Color.clear
        let gutterBG = isOpaque
            ? NSColor(srgbRed: 0.965, green: 0.969, blue: 0.976, alpha: 1.0)
            : NSColor.clear
        let gutterBorder = isOpaque
            ? NSColor(srgbRed: 0.847, green: 0.871, blue: 0.894, alpha: 1.0)
            : NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.12)

        return TTTextReadingPalette(
            mode: mode,
            effectiveIsDark: false,
            drawsOpaqueBackground: isOpaque,
            containerBackgroundColor: containerSwiftUI,
            nsCanvasBackgroundColor: canvasNS,
            nsGutterBackgroundColor: gutterBG,
            nsGutterBorderColor: gutterBorder,
            nsGutterLabelColor: NSColor(srgbRed: 0.341, green: 0.376, blue: 0.416, alpha: 1.0),
            nsForegroundColor: NSColor(srgbRed: 0.094, green: 0.098, blue: 0.110, alpha: 1.0),
            nsInsertionPointColor: NSColor(srgbRed: 0.094, green: 0.098, blue: 0.110, alpha: 1.0),
            nsSelectionBackgroundColor: NSColor(srgbRed: 0.706, green: 0.847, blue: 0.992, alpha: 0.90),
            nsSelectionTextColor: NSColor(srgbRed: 0.059, green: 0.067, blue: 0.078, alpha: 1.0),
            nsSearchMatchBackgroundColor: NSColor(srgbRed: 1.0, green: 0.949, blue: 0.659, alpha: 0.95),
            nsSearchMatchTextColor: NSColor(srgbRed: 0.094, green: 0.098, blue: 0.110, alpha: 1.0),
            syntaxKeywordColor: NSColor(srgbRed: 0.812, green: 0.133, blue: 0.180, alpha: 1.0),
            syntaxStringColor: NSColor(srgbRed: 0.039, green: 0.188, blue: 0.412, alpha: 1.0),
            syntaxCommentColor: NSColor(srgbRed: 0.067, green: 0.388, blue: 0.161, alpha: 1.0),
            syntaxNumberColor: NSColor(srgbRed: 0.020, green: 0.314, blue: 0.682, alpha: 1.0),
            syntaxTypeColor: NSColor(srgbRed: 0.584, green: 0.220, blue: 0.0, alpha: 1.0)
        )
    }

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

/// Shared observable preference store for the 3-state text reading background and soft wrap toggle.
/// Persists across file switches and app launches without mutating W2's global application appearance.
@MainActor
@Observable
public final class TTTextReadingPreferenceStore {
    public static let shared = TTTextReadingPreferenceStore()

    /// Canonical default soft wrap state across all plain text and code previews (`true`).
    nonisolated public static let defaultSoftWrapEnabled: Bool = true

    /// Persistent `UserDefaults` key shared across all plain text and code preview components.
    nonisolated public static let softWrapUserDefaultsKey: String = "ttmedia.preview.text.softWrapEnabled"

    private let defaults: UserDefaults
    public let storageKey: String
    public let softWrapStorageKey: String

    public var mode: TTTextReadingBackgroundMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: storageKey)
        }
    }

    public var isSoftWrapEnabled: Bool {
        didSet {
            guard isSoftWrapEnabled != oldValue else { return }
            defaults.set(isSoftWrapEnabled, forKey: softWrapStorageKey)
        }
    }

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = TTTextReadingBackgroundMode.userDefaultsKey,
        softWrapStorageKey: String = TTTextReadingPreferenceStore.softWrapUserDefaultsKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.softWrapStorageKey = softWrapStorageKey
        if let raw = defaults.string(forKey: storageKey),
           let stored = TTTextReadingBackgroundMode(rawValue: raw) {
            self.mode = stored
        } else {
            self.mode = TTTextReadingBackgroundMode.defaultMode
        }
        if let storedWrap = defaults.object(forKey: softWrapStorageKey) as? Bool {
            self.isSoftWrapEnabled = storedWrap
        } else {
            self.isSoftWrapEnabled = Self.defaultSoftWrapEnabled
        }
    }

    /// Resets the reading background preference to `.fluidTransparent`, soft wrap to `true`, and clears custom overrides.
    public func resetToDefault() {
        mode = TTTextReadingBackgroundMode.defaultMode
        defaults.set(mode.rawValue, forKey: storageKey)
        isSoftWrapEnabled = Self.defaultSoftWrapEnabled
        defaults.set(isSoftWrapEnabled, forKey: softWrapStorageKey)
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
