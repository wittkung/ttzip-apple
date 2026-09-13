// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

// MARK: - Lightweight, Robust Markdown-to-HTML Parser

public enum TTZipMarkdownParser {
    
    public static func parseToHTML(markdown: String) -> String {
        let rawLines = markdown.components(separatedBy: "\n")
        var result = ""
        var inCodeBlock = false
        var inBlockquote = false
        var inUnorderedList = false
        var inOrderedList = false
        var inTable = false
        var tableHeaderParsed = false
        
        func closeBlocks() {
            if inUnorderedList {
                result += "</ul>\n"
                inUnorderedList = false
            }
            if inOrderedList {
                result += "</ol>\n"
                inOrderedList = false
            }
            if inBlockquote {
                result += "</blockquote>\n"
                inBlockquote = false
            }
            if inTable {
                result += "</tbody></table>\n"
                inTable = false
                tableHeaderParsed = false
            }
        }
        
        for rawLine in rawLines {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // 1. Fenced Code Block
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    result += "</code></pre>\n"
                    inCodeBlock = false
                } else {
                    closeBlocks()
                    let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    result += "<pre><code class=\"language-\(lang)\">"
                    inCodeBlock = true
                }
                continue
            }
            
            if inCodeBlock {
                result += escapeHTML(line) + "\n"
                continue
            }
            
            // 2. Empty Line
            if trimmed.isEmpty {
                closeBlocks()
                continue
            }
            
            // 3. Horizontal Rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                closeBlocks()
                result += "<hr>\n"
                continue
            }
            
            // 4. Headings (# H1 to ###### H6)
            if trimmed.hasPrefix("#") {
                closeBlocks()
                var level = 0
                for char in trimmed {
                    if char == "#" { level += 1 } else { break }
                }
                if level >= 1 && level <= 6 && trimmed.count > level && trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " {
                    let headingText = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
                    result += "<h\(level)>\(parseInline(headingText))</h\(level)>\n"
                    continue
                }
            }
            
            // 5. Blockquote (> text)
            if trimmed.hasPrefix(">") {
                if inUnorderedList || inOrderedList || inTable {
                    closeBlocks()
                }
                if !inBlockquote {
                    result += "<blockquote>\n"
                    inBlockquote = true
                }
                let quoteText = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                result += "<p>\(parseInline(quoteText))</p>\n"
                continue
            } else if inBlockquote {
                result += "</blockquote>\n"
                inBlockquote = false
            }
            
            // 6. Tables (| col1 | col2 |)
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                let cells = trimmed.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
                // Check if divider row like |---|---|
                let isDivider = cells.allSatisfy { cell in
                    cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } && cell.contains("-")
                }
                
                if isDivider {
                    tableHeaderParsed = true
                    continue
                }
                
                if !inTable {
                    closeBlocks()
                    result += "<table>\n"
                    inTable = true
                    tableHeaderParsed = false
                }
                
                if !tableHeaderParsed {
                    result += "<thead><tr>\n"
                    for cell in cells {
                        result += "<th>\(parseInline(cell))</th>\n"
                    }
                    result += "</tr></thead>\n<tbody>\n"
                } else {
                    result += "<tr>\n"
                    for cell in cells {
                        result += "<td>\(parseInline(cell))</td>\n"
                    }
                    result += "</tr>\n"
                }
                continue
            } else if inTable {
                result += "</tbody></table>\n"
                inTable = false
                tableHeaderParsed = false
            }
            
            // 7. Task Lists (- [ ] or - [x])
            if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                if inOrderedList {
                    result += "</ol>\n"
                    inOrderedList = false
                }
                if !inUnorderedList {
                    result += "<ul>\n"
                    inUnorderedList = true
                }
                let isChecked = trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ")
                let taskText = String(trimmed.dropFirst(6))
                result += "<li class=\"task-item\"><input type=\"checkbox\" \(isChecked ? "checked" : "") disabled> \(parseInline(taskText))</li>\n"
                continue
            }
            
            // 8. Unordered Lists (- , * , + )
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                if inOrderedList {
                    result += "</ol>\n"
                    inOrderedList = false
                }
                if !inUnorderedList {
                    result += "<ul>\n"
                    inUnorderedList = true
                }
                let itemText = String(trimmed.dropFirst(2))
                result += "<li>\(parseInline(itemText))</li>\n"
                continue
            }
            
            // 9. Ordered Lists (1. 2. etc)
            let isNumberedList: Bool = {
                guard let firstDot = trimmed.firstIndex(of: ".") else { return false }
                let prefix = trimmed[..<firstDot]
                return Int(prefix) != nil && trimmed.index(after: firstDot) < trimmed.endIndex && trimmed[trimmed.index(after: firstDot)] == " "
            }()
            
            if isNumberedList {
                if inUnorderedList {
                    result += "</ul>\n"
                    inUnorderedList = false
                }
                if !inOrderedList {
                    result += "<ol>\n"
                    inOrderedList = true
                }
                if let firstDot = trimmed.firstIndex(of: ".") {
                    let itemText = String(trimmed[trimmed.index(firstDot, offsetBy: 2)...])
                    result += "<li>\(parseInline(itemText))</li>\n"
                }
                continue
            }
            
            // 10. Regular Paragraph
            closeBlocks()
            result += "<p>\(parseInline(line))</p>\n"
        }
        
        closeBlocks()
        if inCodeBlock {
            result += "</code></pre>\n"
        }
        
        return result
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
