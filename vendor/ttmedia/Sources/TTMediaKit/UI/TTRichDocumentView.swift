// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Document metadata descriptors displayed in header banner.
public struct DocumentMetadata: Sendable {
    public var title: String?
    public var author: String?
    public var date: String?
    public var wordCount: Int?
    public var tags: [String]

    public init(
        title: String? = nil,
        author: String? = nil,
        date: String? = nil,
        wordCount: Int? = nil,
        tags: [String] = []
    ) {
        self.title = title
        self.author = author
        self.date = date
        self.wordCount = wordCount
        self.tags = tags
    }
}

/// Callout styling variants.
/// Callout styling variants.
public enum DocumentCalloutType: String, Sendable, Equatable, Hashable {
    case info
    case tip
    case warning
    case note

    public var systemImage: String {
        switch self {
        case .info: return "info.circle.fill"
        case .tip: return "lightbulb.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .note: return "bookmark.fill"
        }
    }

    public var color: Color {
        switch self {
        case .info: return .blue
        case .tip: return .green
        case .warning: return .orange
        case .note: return .purple
        }
    }
}

/// Structured document primitive blocks with deterministic, collision-free identities.
public enum DocumentBlock: Identifiable, Equatable, Sendable {
    case title(String, subtitle: String? = nil, occurrence: Int = 0)
    case heading(level: Int, text: String, occurrence: Int = 0)
    case paragraph(String, occurrence: Int = 0)
    case quote(String, occurrence: Int = 0)
    case code(language: String?, code: String, occurrence: Int = 0)
    case callout(type: DocumentCalloutType, text: String, occurrence: Int = 0)
    case bullet(String, occurrence: Int = 0)
    case table(headers: [String], rows: [[String]], occurrence: Int = 0)
    case divider(occurrence: Int = 0)

    /// Backward-compatible convenience member for `.divider` without arguments.
    public static var divider: DocumentBlock { .divider(occurrence: 0) }

    public var id: String {
        switch self {
        case .title(let t, let s, let occ):
            return "title-\(Self.fnv1a64("\(t)|\(s ?? "")"))-\(occ)"
        case .heading(let l, let t, let occ):
            return "heading-\(l)-\(Self.fnv1a64(t))-\(occ)"
        case .paragraph(let t, let occ):
            return "p-\(Self.fnv1a64(t))-\(occ)"
        case .quote(let t, let occ):
            return "quote-\(Self.fnv1a64(t))-\(occ)"
        case .code(let lang, let c, let occ):
            return "code-\(lang ?? "")-\(Self.fnv1a64(c))-\(occ)"
        case .callout(let type, let t, let occ):
            return "callout-\(type.rawValue)-\(Self.fnv1a64(t))-\(occ)"
        case .bullet(let t, let occ):
            return "bullet-\(Self.fnv1a64(t))-\(occ)"
        case .table(let headers, let rows, let occ):
            let payload = headers.joined(separator: "\u{1F}") + "\u{1E}" + rows.map { $0.joined(separator: "\u{1F}") }.joined(separator: "\u{1E}")
            return "table-\(Self.fnv1a64(payload))-\(occ)"
        case .divider(let occ):
            return "divider-\(occ)"
        }
    }

    nonisolated internal var baseKey: String {
        switch self {
        case .title(let t, let s, _): return "title:\(t)|\(s ?? "")"
        case .heading(let l, let t, _): return "heading:\(l):\(t)"
        case .paragraph(let t, _): return "p:\(t)"
        case .quote(let t, _): return "quote:\(t)"
        case .code(let lang, let c, _): return "code:\(lang ?? ""):\(c)"
        case .callout(let type, let t, _): return "callout:\(type.rawValue):\(t)"
        case .bullet(let t, _): return "bullet:\(t)"
        case .table(let headers, let rows, _):
            return "table:\(headers.joined(separator: "|")):\(rows.count)"
        case .divider: return "divider"
        }
    }

    nonisolated internal func withOccurrence(_ occ: Int) -> DocumentBlock {
        switch self {
        case .title(let t, let s, _): return .title(t, subtitle: s, occurrence: occ)
        case .heading(let l, let t, _): return .heading(level: l, text: t, occurrence: occ)
        case .paragraph(let t, _): return .paragraph(t, occurrence: occ)
        case .quote(let t, _): return .quote(t, occurrence: occ)
        case .code(let lang, let c, _): return .code(language: lang, code: c, occurrence: occ)
        case .callout(let type, let t, _): return .callout(type: type, text: t, occurrence: occ)
        case .bullet(let t, _): return .bullet(t, occurrence: occ)
        case .table(let h, let r, _): return .table(headers: h, rows: r, occurrence: occ)
        case .divider: return .divider(occurrence: occ)
        }
    }

    nonisolated private static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// Declarative, structured document viewer rendering H1-H6 headings, paragraphs,
/// GFM tables, styled blockquotes, callout cards, inline Markdown styles, and code blocks.
public struct TTRichDocumentView: View {
    public let blocks: [DocumentBlock]
    public let metadata: DocumentMetadata?
    public var maxReadableWidth: CGFloat

    public init(
        blocks: [DocumentBlock],
        metadata: DocumentMetadata? = nil,
        maxReadableWidth: CGFloat = 720.0
    ) {
        self.blocks = Self.disambiguateOccurrences(in: blocks)
        self.metadata = metadata
        self.maxReadableWidth = maxReadableWidth
    }

    /// Initializes from a markdown formatted string by auto-parsing into structured blocks.
    public init(
        markdown: String,
        metadata: DocumentMetadata? = nil,
        maxReadableWidth: CGFloat = 720.0
    ) {
        self.blocks = Self.parseMarkdown(markdown)
        self.metadata = metadata
        self.maxReadableWidth = maxReadableWidth
    }

    /// Initializes from plain text.
    public init(text: String, title: String? = nil) {
        let meta = title != nil ? DocumentMetadata(title: title) : nil
        self.init(markdown: text, metadata: meta)
    }

    /// Parses inline Markdown (`**bold**`, `*italic*`, `` `code` ``, `[link](url)`, `~~strikethrough~~`) into an `AttributedString`.
    nonisolated public static func renderInlineAttributedString(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: text, options: options) {
            return parsed
        }
        return AttributedString(text)
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                if let metadata {
                    metadataHeaderView(metadata)
                    Divider().padding(.bottom, 6)
                }

                ForEach(blocks) { block in
                    blockView(block)
                }
            }
            .frame(maxWidth: maxReadableWidth, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.clear)
    }

    @ViewBuilder
    private func inlineMarkdownText(_ rawText: String) -> some View {
        Text(Self.renderInlineAttributedString(rawText))
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: DocumentBlock) -> some View {
        switch block {
        case .title(let title, let subtitle, _):
            titleBlockView(title: title, subtitle: subtitle)
        case .heading(let level, let text, _):
            headingBlockView(level: level, text: text)
        case .paragraph(let text, _):
            inlineMarkdownText(text)
                .font(.body)
                .lineSpacing(5)
                .foregroundStyle(.primary)
        case .quote(let text, _):
            quoteBlockView(text: text)
        case .code(let language, let code, _):
            CodeBlockView(language: language, code: code)
        case .callout(let type, let text, _):
            calloutBlockView(type: type, text: text)
        case .bullet(let text, _):
            bulletBlockView(text: text)
        case .table(let headers, let rows, _):
            GFMTableBlockView(headers: headers, rows: rows)
        case .divider:
            Divider().padding(.vertical, 8)
        }
    }

    private func titleBlockView(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func headingBlockView(level: Int, text: String) -> some View {
        let clamped = min(max(level, 1), 6)
        VStack(alignment: .leading, spacing: 6) {
            inlineMarkdownText(text)
                .font(headingFont(for: clamped))
                .foregroundStyle(clamped >= 5 ? .secondary : .primary)
            if clamped <= 2 {
                Divider().opacity(0.45)
            }
        }
        .padding(.top, clamped <= 2 ? 12 : 6)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .system(size: 24, weight: .bold)
        case 2: return .system(size: 20, weight: .bold)
        case 3: return .system(size: 17, weight: .semibold)
        case 4: return .system(size: 15, weight: .semibold)
        case 5: return .system(size: 13.5, weight: .semibold)
        default: return .system(size: 12.5, weight: .semibold)
        }
    }

    private func quoteBlockView(text: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 4)
            inlineMarkdownText(text)
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .padding(.vertical, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func calloutBlockView(type: DocumentCalloutType, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: type.systemImage)
                .foregroundStyle(type.color)
                .font(.title3)
            inlineMarkdownText(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(type.color.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(type.color.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func bulletBlockView(text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.secondary)
                .frame(width: 5, height: 5)
                .padding(.top, 8)
            inlineMarkdownText(text)
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(4)
        }
    }

    private func metadataHeaderView(_ meta: DocumentMetadata) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = meta.title {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 14) {
                if let author = meta.author {
                    Label(author, systemImage: "person.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let date = meta.date {
                    Label(date, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let count = meta.wordCount {
                    Label(TextAndDocumentPreviewLocalization.wordCount(count), systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !meta.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(meta.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Markdown Block Parser

    /// Parses Markdown text into structured `DocumentBlock` values with deterministic unique IDs.
    nonisolated public static func parseMarkdown(_ markdown: String) -> [DocumentBlock] {
        var rawBlocks: [DocumentBlock] = []
        let lines = markdown.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                i += 1
                continue
            }
            if let (codeBlock, nextIndex) = parseCodeFenceBlock(lines: lines, startIndex: i) {
                rawBlocks.append(codeBlock)
                i = nextIndex
                continue
            }
            if let (tableBlock, nextIndex) = parseGFMTableBlock(lines: lines, startIndex: i) {
                rawBlocks.append(tableBlock)
                i = nextIndex
                continue
            }
            if isHorizontalDivider(trimmed) {
                rawBlocks.append(.divider)
                i += 1
                continue
            }
            if let headingBlock = parseHeadingLine(trimmed) {
                rawBlocks.append(headingBlock)
                i += 1
                continue
            }
            if trimmed == ">" || trimmed.hasPrefix("> ") || trimmed.hasPrefix(">\t") {
                let (quoteOrCallout, nextIndex) = parseBlockquoteOrCallout(lines: lines, startIndex: i)
                rawBlocks.append(quoteOrCallout)
                i = nextIndex
                continue
            }
            if let bulletText = parseListItemText(trimmed) {
                rawBlocks.append(.bullet(bulletText))
                i += 1
                continue
            }
            rawBlocks.append(.paragraph(trimmed))
            i += 1
        }

        return disambiguateOccurrences(in: rawBlocks)
    }

    nonisolated internal static func disambiguateOccurrences(in blocks: [DocumentBlock]) -> [DocumentBlock] {
        var counts: [String: Int] = [:]
        return blocks.map { block in
            let key = block.baseKey
            let occ = counts[key, default: 0]
            counts[key] = occ + 1
            return block.withOccurrence(occ)
        }
    }

    nonisolated private static func parseCodeFenceBlock(lines: [String], startIndex: Int) -> (DocumentBlock, Int)? {
        let trimmed = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let fenceMarker: String
        if trimmed.hasPrefix("```") {
            fenceMarker = "```"
        } else if trimmed.hasPrefix("~~~") {
            fenceMarker = "~~~"
        } else {
            return nil
        }
        let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var codeLines: [String] = []
        var i = startIndex + 1
        while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fenceMarker) {
            codeLines.append(lines[i])
            i += 1
        }
        if i < lines.count { i += 1 }
        return (.code(language: lang.isEmpty ? nil : lang, code: codeLines.joined(separator: "\n")), i)
    }

    nonisolated private static func parseHeadingLine(_ trimmed: String) -> DocumentBlock? {
        var hashCount = 0
        for ch in trimmed {
            if ch == "#" { hashCount += 1 } else { break }
        }
        guard (1...6).contains(hashCount) else { return nil }
        let remainder = trimmed.dropFirst(hashCount)
        guard remainder.isEmpty || remainder.first == " " || remainder.first == "\t" else {
            return nil
        }
        let content = remainder.trimmingCharacters(in: .whitespaces)
        return .heading(level: hashCount, text: content)
    }

    nonisolated private static func isHorizontalDivider(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first else { return false }
        guard first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    nonisolated private static func parseBlockquoteOrCallout(lines: [String], startIndex: Int) -> (DocumentBlock, Int) {
        var collected: [String] = []
        var i = startIndex
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t == ">" || t.hasPrefix("> ") || t.hasPrefix(">\t") else { break }
            let stripped = String(t.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty {
                collected.append(stripped)
            }
            i += 1
        }
        if let first = collected.first, let calloutType = detectCalloutTag(in: first) {
            let restOfFirst = stripCalloutTag(from: first)
            var bodyParts: [String] = []
            if !restOfFirst.isEmpty { bodyParts.append(restOfFirst) }
            bodyParts.append(contentsOf: collected.dropFirst())
            let body = bodyParts.joined(separator: " ")
            return (.callout(type: calloutType, text: body.isEmpty ? first : body), i)
        }
        return (.quote(collected.joined(separator: "\n")), i)
    }

    nonisolated private static func detectCalloutTag(in line: String) -> DocumentCalloutType? {
        let upper = line.uppercased()
        if upper.hasPrefix("[!NOTE]") { return .note }
        if upper.hasPrefix("[!TIP]") { return .tip }
        if upper.hasPrefix("[!IMPORTANT]") { return .info }
        if upper.hasPrefix("[!WARNING]") || upper.hasPrefix("[!CAUTION]") { return .warning }
        return nil
    }

    nonisolated private static func stripCalloutTag(from line: String) -> String {
        guard let closeBracket = line.firstIndex(of: "]") else { return line }
        return String(line[line.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func parseListItemText(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return String(trimmed.dropFirst(2))
        }
        var idx = trimmed.startIndex
        var digits = 0
        while idx < trimmed.endIndex && trimmed[idx].isNumber {
            digits += 1
            idx = trimmed.index(after: idx)
        }
        guard digits > 0, idx < trimmed.endIndex, trimmed[idx] == "." || trimmed[idx] == ")" else {
            return nil
        }
        let afterMarker = trimmed.index(after: idx)
        guard afterMarker < trimmed.endIndex, trimmed[afterMarker].isWhitespace else {
            return nil
        }
        return String(trimmed[trimmed.index(after: afterMarker)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - GFM Pipe Table Parser

    nonisolated private static func parseGFMTableBlock(lines: [String], startIndex: Int) -> (DocumentBlock, Int)? {
        guard startIndex + 1 < lines.count else { return nil }
        let headerLine = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let delimiterLine = lines[startIndex + 1].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|"),
              delimiterLine.contains("|"),
              isGFMTableDelimiterLine(delimiterLine) else {
            return nil
        }
        let headers = splitGFMTableCells(headerLine)
        guard !headers.isEmpty else { return nil }
        var rows: [[String]] = []
        var i = startIndex + 2
        while i < lines.count {
            let rowTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard !rowTrimmed.isEmpty && rowTrimmed.contains("|") else { break }
            var cells = splitGFMTableCells(rowTrimmed)
            if cells.count < headers.count {
                cells.append(contentsOf: Array(repeating: "", count: headers.count - cells.count))
            } else if cells.count > headers.count {
                cells = Array(cells.prefix(headers.count))
            }
            rows.append(cells)
            i += 1
        }
        return (.table(headers: headers, rows: rows), i)
    }

    nonisolated private static func isGFMTableDelimiterLine(_ line: String) -> Bool {
        let cells = splitGFMTableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }

    nonisolated internal static func splitGFMTableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in text {
            if escaped {
                if ch == "|" { current.append("|") }
                else { current.append("\\"); current.append(ch) }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

/// Structured GFM table block view with horizontal overflow scroll and inline Markdown cells.
private struct GFMTableBlockView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { idx, header in
                        Text(TTRichDocumentView.renderInlineAttributedString(header))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        if idx < headers.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(Color.primary.opacity(0.06))

                Divider()

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                            Text(TTRichDocumentView.renderInlineAttributedString(cell))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                            if colIdx < row.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .background(rowIdx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                    if rowIdx < rows.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
    }
}

/// Standalone code block card with copy clipboard action and language label.
private struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var isCopied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    copyToClipboard(code)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCopied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        withAnimation { isCopied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                        Text(TextAndDocumentPreviewLocalization.text(isCopied ? .copiedCodeButton : .copyCodeButton))
                            .font(.caption2)
                    }
                    .foregroundStyle(isCopied ? Color.green : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider().opacity(0.3)

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
