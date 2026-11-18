// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

extension TTMarkdownParser {
    /// Parses Markdown text into structured `DocumentBlock` values with deterministic unique IDs.
    nonisolated public static func parseDocumentBlocks(_ markdown: String) -> [DocumentBlock] {
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

    nonisolated private static func splitGFMTableCells(_ line: String) -> [String] {
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

    /// Parses inline Markdown (`**bold**`, `*italic*`, `` `code` ``, `[link](url)`, `~~strikethrough~~`) into an `AttributedString`.
    nonisolated public static func parseInlineAttributedString(_ text: String) -> AttributedString {
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
}
