// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

// MARK: - Lightweight, High-Performance Markdown-to-HTML Parser

public enum TTMarkdownParser: Sendable {
    
    /// Parses GitHub-flavored Markdown text into sanitized HTML for web view presentation.
    public static func parseToHTML(markdown: String) -> String {
        var renderer = HTMLRenderer()
        for rawLine in markdown.components(separatedBy: "\n") {
            renderer.appendLine(rawLine)
        }
        return renderer.finish()
    }

    private struct HTMLRenderer {
        private enum ActiveBlock: Equatable {
            case none
            case codeBlock
            case blockquote
            case unorderedList
            case orderedList
            case table(headerParsed: Bool)
        }

        private var output = ""
        private var activeBlock: ActiveBlock = .none

        mutating func appendLine(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                toggleCodeBlock(trimmed)
                return
            }
            if activeBlock == .codeBlock {
                output += TTMarkdownParser.escapeHTML(line) + "\n"
                return
            }
            if appendStandaloneBlockIfMatched(trimmed) {
                return
            }
            if trimmed.hasPrefix(">") {
                appendBlockquoteLine(trimmed)
                return
            }
            if activeBlock == .blockquote {
                closeNonCodeBlock()
            }
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                appendTableLine(trimmed)
                return
            }
            if case .table = activeBlock {
                closeNonCodeBlock()
            }
            if appendListLineIfMatched(trimmed) {
                return
            }
            closeNonCodeBlock()
            output += "<p>\(TTMarkdownParser.parseInline(line))</p>\n"
        }

        mutating func finish() -> String {
            if activeBlock == .codeBlock {
                output += "</code></pre>\n"
                activeBlock = .none
            } else {
                closeNonCodeBlock()
            }
            return output
        }

        private mutating func closeNonCodeBlock() {
            switch activeBlock {
            case .unorderedList:
                output += "</ul>\n"
            case .orderedList:
                output += "</ol>\n"
            case .blockquote:
                output += "</blockquote>\n"
            case .table:
                output += "</tbody></table>\n"
            case .none, .codeBlock:
                return
            }
            activeBlock = .none
        }

        private mutating func toggleCodeBlock(_ trimmed: String) {
            if activeBlock == .codeBlock {
                output += "</code></pre>\n"
                activeBlock = .none
                return
            }
            closeNonCodeBlock()
            let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            output += "<pre><code class=\"language-\(lang)\">"
            activeBlock = .codeBlock
        }

        private mutating func appendStandaloneBlockIfMatched(_ trimmed: String) -> Bool {
            if trimmed.isEmpty {
                closeNonCodeBlock()
                return true
            }
            if Self.isHorizontalRule(trimmed) {
                closeNonCodeBlock()
                output += "<hr>\n"
                return true
            }
            if let heading = Self.parseHeading(trimmed) {
                closeNonCodeBlock()
                output += "<h\(heading.level)>\(TTMarkdownParser.parseInline(heading.text))</h\(heading.level)>\n"
                return true
            }
            return false
        }

        private mutating func appendBlockquoteLine(_ trimmed: String) {
            if activeBlock != .blockquote {
                closeNonCodeBlock()
                output += "<blockquote>\n"
                activeBlock = .blockquote
            }
            let quoteText = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            output += "<p>\(TTMarkdownParser.parseInline(quoteText))</p>\n"
        }

        private mutating func appendTableLine(_ trimmed: String) {
            let cells = trimmed.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
            if Self.isTableDivider(cells) {
                if case .table = activeBlock {
                    activeBlock = .table(headerParsed: true)
                }
                return
            }
            guard case .table(let headerParsed) = activeBlock else {
                closeNonCodeBlock()
                output += "<table>\n"
                activeBlock = .table(headerParsed: false)
                appendTableRow(cells, isHeader: true)
                return
            }
            appendTableRow(cells, isHeader: !headerParsed)
        }

        private mutating func appendTableRow(_ cells: [String], isHeader: Bool) {
            let tag = isHeader ? "th" : "td"
            output += isHeader ? "<thead><tr>\n" : "<tr>\n"
            for cell in cells {
                output += "<\(tag)>\(TTMarkdownParser.parseInline(cell))</\(tag)>\n"
            }
            output += isHeader ? "</tr></thead>\n<tbody>\n" : "</tr>\n"
        }

        private mutating func appendListLineIfMatched(_ trimmed: String) -> Bool {
            if let task = Self.parseTaskListItem(trimmed) {
                openList(.unorderedList)
                let checkedAttr = task.isChecked ? "checked" : ""
                output += "<li class=\"task-item\"><input type=\"checkbox\" \(checkedAttr) disabled> \(TTMarkdownParser.parseInline(task.text))</li>\n"
                return true
            }
            if let itemText = Self.parseUnorderedListItem(trimmed) {
                openList(.unorderedList)
                output += "<li>\(TTMarkdownParser.parseInline(itemText))</li>\n"
                return true
            }
            if let itemText = Self.parseOrderedListItem(trimmed) {
                openList(.orderedList)
                output += "<li>\(TTMarkdownParser.parseInline(itemText))</li>\n"
                return true
            }
            return false
        }

        private mutating func openList(_ target: ActiveBlock) {
            guard activeBlock != target else { return }
            closeNonCodeBlock()
            output += (target == .unorderedList) ? "<ul>\n" : "<ol>\n"
            activeBlock = target
        }

        private static func isHorizontalRule(_ trimmed: String) -> Bool {
            trimmed == "---" || trimmed == "***" || trimmed == "___"
        }

        private static func isTableDivider(_ cells: [String]) -> Bool {
            cells.allSatisfy { cell in
                cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } && cell.contains("-")
            }
        }

        private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
            guard trimmed.hasPrefix("#") else { return nil }
            let level = trimmed.prefix { $0 == "#" }.count
            guard (1...6).contains(level),
                  trimmed.count > level,
                  trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " else {
                return nil
            }
            let text = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
            return (level, text)
        }

        private static func parseTaskListItem(_ trimmed: String) -> (isChecked: Bool, text: String)? {
            if trimmed.hasPrefix("- [ ] ") {
                return (false, String(trimmed.dropFirst(6)))
            }
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                return (true, String(trimmed.dropFirst(6)))
            }
            return nil
        }

        private static func parseUnorderedListItem(_ trimmed: String) -> String? {
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") else {
                return nil
            }
            return String(trimmed.dropFirst(2))
        }

        private static func parseOrderedListItem(_ trimmed: String) -> String? {
            guard let firstDot = trimmed.firstIndex(of: "."),
                  Int(trimmed[..<firstDot]) != nil else {
                return nil
            }
            let afterDot = trimmed.index(after: firstDot)
            guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else {
                return nil
            }
            return String(trimmed[trimmed.index(after: afterDot)...])
        }
    }
    
    // MARK: - Inline Parser & Precompiled Regexes
    
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: "`([^`]+)`", options: [])
    private static let imageRegex = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(([^\\)]+)\\)", options: [])
    private static let linkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^\\)]+)\\)", options: [])
    private static let boldAsteriskRegex = try! NSRegularExpression(pattern: "\\*\\*([^*]+)\\*\\*", options: [])
    private static let boldUnderscoreRegex = try! NSRegularExpression(pattern: "__([^_]+)__", options: [])
    private static let italicAsteriskRegex = try! NSRegularExpression(pattern: "\\*([^*]+)\\*", options: [])
    private static let italicUnderscoreRegex = try! NSRegularExpression(pattern: "_([^_]+)_", options: [])
    private static let strikethroughRegex = try! NSRegularExpression(pattern: "~~([^~]+)~~", options: [])
    
    private static func parseInline(_ text: String) -> String {
        var str = text
        
        // 1. Inline Code `code`
        str = replacePattern(in: str, regex: inlineCodeRegex, template: "<code>$1</code>")
        
        // 2. Images ![alt](url)
        str = replacePattern(in: str, regex: imageRegex, template: "<img src=\"$2\" alt=\"$1\">")
        
        // 3. Links [title](url)
        str = replacePattern(in: str, regex: linkRegex, template: "<a href=\"$2\">$1</a>")
        
        // 4. Bold **text** or __text__
        str = replacePattern(in: str, regex: boldAsteriskRegex, template: "<strong>$1</strong>")
        str = replacePattern(in: str, regex: boldUnderscoreRegex, template: "<strong>$1</strong>")
        
        // 5. Italic *text* or _text_
        str = replacePattern(in: str, regex: italicAsteriskRegex, template: "<em>$1</em>")
        str = replacePattern(in: str, regex: italicUnderscoreRegex, template: "<em>$1</em>")
        
        // 6. Strikethrough ~~text~~
        str = replacePattern(in: str, regex: strikethroughRegex, template: "<del>$1</del>")
        
        return str
    }
    
    private static func replacePattern(in string: String, regex: NSRegularExpression, template: String) -> String {
        let range = NSRange(location: 0, length: string.utf16.count)
        return regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: template)
    }
    
    private static func escapeHTML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Compatibility Aliases

public typealias TTMediaMarkdownParser = TTMarkdownParser
