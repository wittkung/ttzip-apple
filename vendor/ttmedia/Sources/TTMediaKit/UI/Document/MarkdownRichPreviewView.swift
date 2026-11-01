// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Dual-mode Markdown viewer with rich typography rendering, source editing, and live sync.
public struct MarkdownRichPreviewView: View {
    public let initialMarkdown: String
    public let initialByteCount: Int64
    public let sourceEncoding: TTTextSourceEncoding
    public let isTruncatedForPreview: Bool
    public let fileURL: URL?
    public let fileName: String
    public let isReadOnly: Bool
    public let resourceContext: TTPreviewResourceContext?
    private let usesDefaultTitle: Bool
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.previewResourceContext) private var envResourceContext
    private let explicitReadingPreferenceStore: TTTextReadingPreferenceStore?
    @State private var mode: MarkdownPreviewMode = .rich
    @State private var markdownContent: String = ""
    @State private var isEdited: Bool = false
    @State private var isSavedToastPresented: Bool = false
    @State private var saveErrorMessage: String? = nil
    @State private var runtimeByteCountOverride: Int64? = nil
    @State private var runtimeEncodingOverride: TTTextSourceEncoding? = nil
    
    private static let validMarkdownExtensions: Set<String> = TTMediaCapabilityMatrix.markdownExtensions

    public var effectiveSourceEncoding: TTTextSourceEncoding {
        runtimeEncodingOverride ?? sourceEncoding
    }
    
    /// Resolves the effective `TTPreviewResourceContext` from explicit argument, SwiftUI environment, or fallback inspection.
    public var resolvedResourceContext: TTPreviewResourceContext {
        if let explicit = resourceContext {
            return isReadOnly ? explicit.forcingReadOnly() : explicit
        }
        if envResourceContext.origin != .unknown(readableURL: nil) {
            return isReadOnly ? envResourceContext.forcingReadOnly() : envResourceContext
        }
        guard let url = fileURL else {
            return .inMemory(fileName: fileName)
        }
        if TTPreviewResourceContext.isManagedPreviewStagingURL(url) {
            return TTPreviewResourceContext(
                origin: .diskFile(url: url.standardizedFileURL),
                displayFileName: fileName,
                allowsEditingWhenAuthorized: false,
                isPreviewTruncated: isTruncatedForPreview,
                isDerivedRepresentation: false
            )
        }
        return .diskFile(
            url: url,
            fileName: fileName,
            allowsEditing: !isReadOnly,
            isTruncated: isTruncatedForPreview
        )
    }

    /// Validated disk target URL for in-place saving, or `nil` when read-only, archive-staged, truncated, or non-UTF-8.
    public var validatedSaveURL: URL? {
        guard !isReadOnly,
              !isTruncatedForPreview,
              effectiveSourceEncoding.allowsUTF8InPlaceSave else {
            return nil
        }
        return resolvedResourceContext.validateInPlaceSaveTarget(
            expectedFileURL: fileURL,
            fileName: fileName,
            allowedExtensions: Self.validMarkdownExtensions,
            isTruncated: isTruncatedForPreview
        )
    }

    /// Determines whether the document is a native, genuinely writable UTF-8 Markdown file on the local filesystem.
    public var isNativeWritableMarkdown: Bool {
        validatedSaveURL != nil
    }

    /// Alias matching `CodeTextEditorContainerView` save capability query.
    public var canSaveInPlace: Bool {
        isNativeWritableMarkdown
    }

    /// Whether the file is read-only specifically because its source encoding is non-UTF-8.
    public var isNonUTF8ReadOnly: Bool {
        !effectiveSourceEncoding.allowsUTF8InPlaceSave && (fileURL != nil || resolvedResourceContext.readableURL != nil)
    }

    /// Authentic byte count: reports raw file bytes on disk when unedited, or UTF-8 (+ BOM) byte length after user edits.
    public var displayedByteCount: Int64 {
        if isNativeWritableMarkdown && isEdited {
            return Int64(markdownContent.utf8.count + (effectiveSourceEncoding == .utf8BOM ? 3 : 0))
        }
        return runtimeByteCountOverride ?? initialByteCount
    }
    
    public init(
        initialMarkdown: String,
        fileURL: URL? = nil,
        fileName: String = "",
        initialByteCount: Int64? = nil,
        isReadOnly: Bool = false,
        resourceContext: TTPreviewResourceContext? = nil,
        initialMode: MarkdownPreviewMode = .rich,
        readingPreferenceStore: TTTextReadingPreferenceStore? = nil
    ) {
        self.initialMarkdown = initialMarkdown
        self.fileURL = fileURL
        self.isReadOnly = isReadOnly
        self.resourceContext = resourceContext
        self.explicitReadingPreferenceStore = readingPreferenceStore
        let urlName = fileURL?.lastPathComponent
        let hasExplicitOrURLName = !fileName.isEmpty || (urlName != nil && urlName?.isEmpty == false)
        self.usesDefaultTitle = !hasExplicitOrURLName
        self.fileName = fileName.isEmpty ? (urlName ?? TextAndDocumentPreviewLocalization.text(.markdownDefaultTitle)) : fileName
        let readableForInspection = fileURL ?? resourceContext?.readableURL
        let inspection = TTTextSourceInspection.inspect(
            url: readableForInspection,
            fallbackText: initialMarkdown,
            explicitByteCount: initialByteCount
        )
        self.initialByteCount = inspection.byteCount
        self.sourceEncoding = inspection.encoding
        let (display, truncated) = CodeTextEditorContainerView.truncateForPreview(initialMarkdown)
        self.isTruncatedForPreview = truncated
        self._mode = State(initialValue: initialMode)
        self._markdownContent = State(initialValue: display)
    }

    private var activeReadingPreferenceStore: TTTextReadingPreferenceStore {
        explicitReadingPreferenceStore ?? .shared
    }
    
    private var displayFileName: String {
        usesDefaultTitle ? TextAndDocumentPreviewLocalization.text(.markdownDefaultTitle) : fileName
    }
    
    private var characterCount: Int { markdownContent.count }
    private var wordCount: Int { markdownContent.split { $0.isWhitespace || $0.isPunctuation }.count }
    private var lineCount: Int { markdownContent.components(separatedBy: "\n").count }
    
    public var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width <= 560
            let resolvedTitle = displayFileName
            VStack(spacing: 0) {
                // 1. Top Control & Mode Switcher Bar
                MarkdownPreviewToolbarView(
                    isCompact: isCompact,
                    fileName: resolvedTitle,
                    fileURL: fileURL,
                    lineCount: lineCount,
                    wordCount: wordCount,
                    characterCount: characterCount,
                    byteCount: displayedByteCount,
                    encodingBadge: effectiveSourceEncoding.displayBadge,
                    isNativeWritableMarkdown: isNativeWritableMarkdown,
                    isEdited: isNativeWritableMarkdown && isEdited,
                    isSavedToastPresented: isSavedToastPresented,
                    mode: $mode,
                    onCopy: { copyMarkdownToClipboard() },
                    onSave: { _ = saveFile() }
                )

                if isTruncatedForPreview {
                    truncationWarningBanner
                } else if isNonUTF8ReadOnly {
                    encodingReadOnlyBanner
                }
                
                Divider()
                
                // 2. Main Content Canvas (Rich Preview vs Source Editor)
                ZStack {
                    if mode == .rich {
                        TTRichDocumentView(
                            markdown: markdownContent,
                            metadata: nil
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        CodeHighlightingEditorNSView(
                            text: $markdownContent,
                            fileName: fileName.isEmpty ? "document.md" : fileName,
                            showLineNumbers: true,
                            isEditable: isNativeWritableMarkdown,
                            isSoftWrapEnabled: activeReadingPreferenceStore.isSoftWrapEnabled,
                            readingBackgroundMode: activeReadingPreferenceStore.mode,
                            isDarkAppearance: colorScheme == .dark,
                            onTextChange: isNativeWritableMarkdown ? { newText in
                                isEdited = (newText != initialMarkdown)
                            } : nil,
                            onSaveShortcut: isNativeWritableMarkdown ? { _ = saveFile() } : nil
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: "\(fileName)|\(initialByteCount)|\(sourceEncoding.rawValue)|\(resolvedResourceContext.readableURL?.path ?? "")|\(initialMarkdown.prefix(64))") {
            let (display, _) = CodeTextEditorContainerView.truncateForPreview(initialMarkdown)
            markdownContent = display
            isEdited = false
            if fileURL == nil, let envReadURL = resolvedResourceContext.readableURL {
                let envInspection = TTTextSourceInspection.inspect(url: envReadURL, fallbackText: initialMarkdown)
                runtimeByteCountOverride = envInspection.byteCount
                runtimeEncodingOverride = envInspection.encoding
            } else {
                runtimeByteCountOverride = nil
                runtimeEncodingOverride = nil
            }
        }
    }

    private var truncationWarningBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(CodeTextEditorContainerView.truncationBannerMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.12))
    }

    private var encodingReadOnlyBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.doc.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
            Text(TextAndDocumentPreviewLocalization.encodingReadOnlyBanner(encodingName: sourceEncoding.displayBadge))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
    }
    
    // MARK: - Actions
    
    private func copyMarkdownToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdownContent, forType: .string)
    }
    
    @discardableResult
    public func saveFile(contentOverride: String? = nil) -> Bool {
        guard isNativeWritableMarkdown,
              let targetURL = validatedSaveURL else {
            return false
        }
        let payload = contentOverride ?? markdownContent
        guard payload.utf8.count <= CodeTextEditorContainerView.maxInteractiveTextUTF8Bytes else {
            return false
        }
        do {
            let outputData = CodeTextEditorContainerView.encodeForSave(payload: payload, encoding: sourceEncoding)
            try outputData.write(to: targetURL, options: .atomic)
            withAnimation {
                isEdited = false
                isSavedToastPresented = true
                saveErrorMessage = nil
            }
            NotificationCenter.default.post(name: NSNotification.Name("TTMediaArchiveUnlockedRefreshNotification"), object: nil)
            NotificationCenter.default.post(name: .ttMediaFileContentDidChange, object: targetURL)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.0))
                withAnimation {
                    isSavedToastPresented = false
                }
            }
            return true
        } catch {
            saveErrorMessage = error.localizedDescription
            return false
        }
    }
    
    // MARK: - Rich Preview Preprocessing & Typography Scales
    
    /// Injected CSS defining H5 (13px semibold) and H6 (12px semibold) typography scales.
    public nonisolated static let headingTypographyCSS: String = """
    <style>
    h5 {
        font-size: 13px !important;
        font-weight: 600 !important;
        margin-top: 1.2em;
        margin-bottom: 0.4em;
        line-height: 1.25;
    }
    h6 {
        font-size: 12px !important;
        font-weight: 600 !important;
        margin-top: 1.1em;
        margin-bottom: 0.3em;
        line-height: 1.25;
    }
    @media (max-width: 520px) {
        h5 { font-size: 12px !important; }
        h6 { font-size: 11px !important; }
    }
    </style>
    """
    
    /// Standard HTML element tags that must be preserved rather than escaped as generic entities.
    private nonisolated static let recognizedHTMLTags: Set<String> = [
        "a", "abbr", "address", "article", "aside", "b", "bdi", "bdo", "blockquote",
        "body", "br", "caption", "cite", "code", "col", "colgroup", "data", "dd",
        "del", "details", "dfn", "div", "dl", "dt", "em", "embed", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head",
        "header", "hr", "html", "i", "iframe", "img", "input", "ins", "kbd", "label",
        "legend", "li", "main", "mark", "meta", "nav", "noscript", "object", "ol",
        "optgroup", "option", "p", "param", "picture", "pre", "progress", "q",
        "rp", "rt", "ruby", "s", "samp", "script", "section", "select", "small",
        "source", "span", "strong", "style", "sub", "summary", "sup", "table",
        "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "time",
        "title", "tr", "track", "u", "ul", "var", "video", "wbr"
    ]
    
    /// Prepares Markdown content for rich WebKit preview by injecting heading CSS and escaping generic angle brackets.
    nonisolated public static func prepareMarkdownForRichPreview(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        var inFencedCodeBlock = false
        
        for idx in 0..<lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFencedCodeBlock.toggle()
                continue
            }
            
            if inFencedCodeBlock {
                continue
            }
            
            lines[idx] = processLineGenericEntities(line)
        }
        
        return headingTypographyCSS + "\n" + lines.joined(separator: "\n")
    }
    
    /// Processes a single line outside fenced code blocks, escaping angle-bracket generic entities and inline code brackets.
    nonisolated private static func processLineGenericEntities(_ line: String) -> String {
        guard line.contains("<") || line.contains("`") else {
            return line
        }
        
        var result = ""
        result.reserveCapacity(line.count + 32)
        
        let chars = Array(line)
        var i = 0
        let count = chars.count
        
        while i < count {
            let ch = chars[i]
            if ch == "`" {
                i = consumeInlineCodeSpan(in: chars, from: i, into: &result)
                continue
            }
            if ch == "<" {
                if let nextIndex = consumeHTMLOrAutolinkSpan(in: chars, from: i, into: &result) {
                    i = nextIndex
                    continue
                }
                i = consumeGenericEntitySpan(in: chars, from: i, into: &result)
                continue
            }
            result.append(ch)
            i += 1
        }
        
        return result
    }
    
    nonisolated private static func consumeInlineCodeSpan(in chars: [Character], from i: Int, into result: inout String) -> Int {
        guard let nextBacktick = chars[(i + 1)...].firstIndex(of: "`") else {
            result.append(chars[i])
            return i + 1
        }
        result.append("`")
        for j in (i + 1)..<nextBacktick {
            appendEscapedAngleBracket(chars[j], into: &result)
        }
        result.append("`")
        return nextBacktick + 1
    }
    
    nonisolated private static func consumeHTMLOrAutolinkSpan(in chars: [Character], from i: Int, into result: inout String) -> Int? {
        let remainder = chars[i...]
        if remainder.starts(with: ["<", "!", "-", "-"]),
           let closeComment = findSubsequence(in: chars, from: i + 4, target: ["-", "-", ">"]) {
            result.append(contentsOf: chars[i...closeComment + 2])
            return closeComment + 3
        }
        if let closeTagNext = consumeClosingHTMLTag(in: chars, from: i, into: &result) {
            return closeTagNext
        }
        if let autolinkNext = consumeAutolinkSpan(in: chars, from: i, into: &result) {
            return autolinkNext
        }
        return consumeOpeningHTMLTag(in: chars, from: i, into: &result)
    }
    
    nonisolated private static func consumeClosingHTMLTag(in chars: [Character], from i: Int, into result: inout String) -> Int? {
        let count = chars.count
        guard count - i >= 2, chars[i + 1] == "/" else { return nil }
        var tagEnd = i + 2
        while tagEnd < count && (chars[tagEnd].isLetter || chars[tagEnd].isNumber) {
            tagEnd += 1
        }
        let tagName = String(chars[(i + 2)..<tagEnd]).lowercased()
        guard !tagName.isEmpty, recognizedHTMLTags.contains(tagName) else { return nil }
        while tagEnd < count && chars[tagEnd] != ">" {
            tagEnd += 1
        }
        guard tagEnd < count && chars[tagEnd] == ">" else { return nil }
        result.append(contentsOf: chars[i...tagEnd])
        return tagEnd + 1
    }
    
    nonisolated private static func consumeAutolinkSpan(in chars: [Character], from i: Int, into result: inout String) -> Int? {
        let autolinkPrefixes = ["<http://", "<https://", "<ftp://", "<mailto:"]
        let remainderStr = String(chars[i...])
        let hasSchemePrefix = autolinkPrefixes.contains { remainderStr.hasPrefix($0) }
        let hasEmailForm: Bool = {
            guard remainderStr.contains("@"), let closeIdx = remainderStr.firstIndex(of: ">") else { return false }
            return !remainderStr.prefix(upTo: closeIdx).contains(" ")
        }()
        guard (hasSchemePrefix || hasEmailForm), let closeIndex = chars[i...].firstIndex(of: ">") else {
            return nil
        }
        result.append(contentsOf: chars[i...closeIndex])
        return closeIndex + 1
    }
    
    nonisolated private static func consumeOpeningHTMLTag(in chars: [Character], from i: Int, into result: inout String) -> Int? {
        let count = chars.count
        guard count - i >= 2, chars[i + 1].isLetter else { return nil }
        var tagEnd = i + 1
        while tagEnd < count && (chars[tagEnd].isLetter || chars[tagEnd].isNumber) {
            tagEnd += 1
        }
        let tagName = String(chars[(i + 1)..<tagEnd]).lowercased()
        guard recognizedHTMLTags.contains(tagName),
              let tagClose = findHTMLTagClosingBracket(in: chars, from: tagEnd) else {
            return nil
        }
        result.append(contentsOf: chars[i...tagClose])
        return tagClose + 1
    }
    
    nonisolated private static func findHTMLTagClosingBracket(in chars: [Character], from start: Int) -> Int? {
        var inQuotes = false
        var quoteChar: Character = "\""
        var idx = start
        while idx < chars.count {
            let tc = chars[idx]
            if !inQuotes && (tc == "\"" || tc == "'") {
                inQuotes = true
                quoteChar = tc
            } else if inQuotes && tc == quoteChar {
                inQuotes = false
            } else if !inQuotes && tc == ">" {
                return idx
            }
            idx += 1
        }
        return nil
    }
    
    nonisolated private static func consumeGenericEntitySpan(in chars: [Character], from i: Int, into result: inout String) -> Int {
        result.append("&lt;")
        guard let closeIndex = findMatchingGenericClose(in: chars, from: i + 1) else {
            return i + 1
        }
        for j in (i + 1)..<closeIndex {
            appendEscapedAngleBracket(chars[j], into: &result)
        }
        result.append("&gt;")
        return closeIndex + 1
    }
    
    nonisolated private static func appendEscapedAngleBracket(_ c: Character, into result: inout String) {
        if c == "<" {
            result.append("&lt;")
        } else if c == ">" {
            result.append("&gt;")
        } else {
            result.append(c)
        }
    }
    
    nonisolated private static func findMatchingGenericClose(in chars: [Character], from start: Int) -> Int? {
        var depth = 1
        var j = start
        let count = chars.count
        
        while j < count {
            let c = chars[j]
            if c == ";" || c == "=" || c == "{" || c == "}" || c == "(" || c == ")" || c == "\"" {
                return nil
            }
            if c == "<" {
                depth += 1
            } else if c == ">" {
                depth -= 1
                if depth == 0 {
                    return j
                }
            }
            j += 1
        }
        return nil
    }
    
    nonisolated private static func findSubsequence(in chars: [Character], from start: Int, target: [Character]) -> Int? {
        guard target.count > 0, start <= chars.count - target.count else { return nil }
        for idx in start...(chars.count - target.count) {
            if chars[idx..<(idx + target.count)].elementsEqual(target) {
                return idx
            }
        }
        return nil
    }
}
