// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import WebKit
import TTZipCore
import TTZipUI

/// Preview mode for Markdown document viewing.
public enum MarkdownPreviewMode: String, CaseIterable, Identifiable {
    case rich = "Rich Preview"
    case source = "Source Code"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .rich: return "doc.richtext.fill"
        case .source: return "curlybraces"
        }
    }
}

/// Dual-mode Markdown viewer with rich typography rendering, source editing, and live sync.
public struct MarkdownRichPreviewView: View {
    public let initialMarkdown: String
    public let fileURL: URL?
    public let fileName: String
    
    @State private var mode: MarkdownPreviewMode = .rich
    @State private var markdownContent: String = ""
    @State private var isEdited: Bool = false
    @State private var isSavedToastPresented: Bool = false
    @State private var saveErrorMessage: String? = nil
    
    public init(initialMarkdown: String, fileURL: URL? = nil, fileName: String = "") {
        self.initialMarkdown = initialMarkdown
        self.fileURL = fileURL
        self.fileName = fileName.isEmpty ? (fileURL?.lastPathComponent ?? "Markdown Document") : fileName
        self._markdownContent = State(initialValue: initialMarkdown)
    }
    
    private var characterCount: Int {
        markdownContent.count
    }
    
    private var wordCount: Int {
        markdownContent.split { $0.isWhitespace || $0.isPunctuation }.count
    }
    
    private var lineCount: Int {
        markdownContent.components(separatedBy: "\n").count
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // 1. Top Control & Mode Switcher Bar
            topControlBar
            
            Divider()
            
            // 2. Main Content Canvas (Rich Preview vs Source Editor)
            ZStack {
                if mode == .rich {
                    MarkdownNativeWKWebView(markdownText: markdownContent, baseURL: fileURL)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CodeHighlightingEditorNSView(
                        text: $markdownContent,
                        fileName: fileName.isEmpty ? "document.md" : fileName,
                        onTextChange: { newText in
                            if newText != initialMarkdown {
                                isEdited = true
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: initialMarkdown) {
            markdownContent = initialMarkdown
            isEdited = false
        }
    }
    
    // MARK: - Subviews
    
    private var topControlBar: some View {
        HStack(spacing: 10) {
            // Document Type Badge
            HStack(spacing: 5) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text("MARKDOWN")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(TTZipTheme.bambooGreen.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            
            // File Name
            Text(fileName)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            
            if isEdited {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("Unsaved")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.orange)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.12))
                .clipShape(Capsule())
            }
            
            Spacer()
            
            // Document Stats
            HStack(spacing: 8) {
                Text("\(lineCount) lines")
                Text("•")
                Text("\(wordCount) words")
                Text("•")
                Text("\(characterCount) chars")
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            
            // Mode Segmented Switcher
            HStack(spacing: 2) {
                ForEach(MarkdownPreviewMode.allCases) { m in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            mode = m
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: m.icon)
                                .font(.system(size: 10, weight: .bold))
                            Text(m.rawValue)
                                .font(.system(size: 10.5, weight: mode == m ? .bold : .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(mode == m ? TTZipTheme.bambooGreen : Color.clear)
                        .foregroundStyle(mode == m ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            
            // Copy Markdown Button
            Button(action: { copyMarkdownToClipboard() }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Copy Raw Markdown")
            
            // Save Button
            if isSavedToastPresented {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("Saved")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(TTZipTheme.bambooGreen)
                .transition(.opacity)
            }
            
            if let url = fileURL, url.isFileURL {
                Button(action: { saveFile() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 10.5, weight: .bold))
                        Text("Save (⌘S)")
                            .font(.system(size: 10.5, weight: .bold))
                    }
                    .foregroundStyle(isEdited ? Color.white : TTZipTheme.bambooGreen)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(isEdited ? TTZipTheme.bambooGreen : TTZipTheme.bambooGreen.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: [.command])
                .help("Save changes to local file (⌘S)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Actions
    
    private func copyMarkdownToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdownContent, forType: .string)
    }
    
    private func saveFile() {
        guard let url = fileURL, url.isFileURL else { return }
        do {
            try markdownContent.write(to: url, atomically: true, encoding: .utf8)
            withAnimation {
                isEdited = false
                isSavedToastPresented = true
            }
            NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation {
                    isSavedToastPresented = false
                }
            }
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Native WKWebView Rich Markdown Renderer

public struct MarkdownNativeWKWebView: NSViewRepresentable {
    public let markdownText: String
    public let baseURL: URL?
    
    public init(markdownText: String, baseURL: URL? = nil) {
        self.markdownText = markdownText
        self.baseURL = baseURL
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        loadRenderedHTML(in: webView)
        return webView
    }
    
    public func updateNSView(_ webView: WKWebView, context: Context) {
        loadRenderedHTML(in: webView)
    }
    
    private func loadRenderedHTML(in webView: WKWebView) {
        let htmlBody = TTZipMarkdownParser.parseToHTML(markdown: markdownText)
        let fullHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                :root {
                    color-scheme: light dark;
                    --bg-color: #ffffff;
                    --text-color: #1d1d1f;
                    --heading-color: #111111;
                    --accent-color: #2ecc71;
                    --code-bg: rgba(128, 128, 128, 0.12);
                    --border-color: rgba(128, 128, 128, 0.22);
                    --blockquote-bg: rgba(46, 204, 113, 0.06);
                    --table-stripe: rgba(128, 128, 128, 0.04);
                    --link-color: #007aff;
                }
                @media (prefers-color-scheme: dark) {
                    :root {
                        --bg-color: #1e1e20;
                        --text-color: #e5e5ea;
                        --heading-color: #ffffff;
                        --accent-color: #30d158;
                        --code-bg: rgba(255, 255, 255, 0.10);
                        --border-color: rgba(255, 255, 255, 0.15);
                        --blockquote-bg: rgba(48, 209, 88, 0.08);
                        --table-stripe: rgba(255, 255, 255, 0.04);
                        --link-color: #0a84ff;
                    }
                }
                body {
                    background-color: var(--bg-color);
                    color: var(--text-color);
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", "Segoe UI", sans-serif;
                    font-size: 14px;
                    line-height: 1.65;
                    padding: 24px 36px;
                    margin: 0 auto;
                    max-width: 880px;
                    word-wrap: break-word;
                }
                h1, h2, h3, h4, h5, h6 {
                    color: var(--heading-color);
                    font-weight: 700;
                    margin-top: 1.4em;
                    margin-bottom: 0.6em;
                    line-height: 1.25;
                }
                h1 { font-size: 24px; border-bottom: 1px solid var(--border-color); padding-bottom: 0.3em; }
                h2 { font-size: 20px; border-bottom: 1px solid var(--border-color); padding-bottom: 0.25em; }
                h3 { font-size: 16px; }
                h4 { font-size: 14px; }
                p { margin-top: 0; margin-bottom: 1em; }
                a { color: var(--link-color); text-decoration: none; }
                a:hover { text-decoration: underline; }
                strong { font-weight: 700; color: var(--heading-color); }
                em { font-style: italic; }
                hr {
                    border: 0;
                    height: 1px;
                    background-color: var(--border-color);
                    margin: 24px 0;
                }
                blockquote {
                    margin: 1em 0;
                    padding: 8px 16px;
                    background-color: var(--blockquote-bg);
                    border-left: 4px solid var(--accent-color);
                    border-radius: 0 6px 6px 0;
                }
                blockquote p:last-child { margin-bottom: 0; }
                code {
                    font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
                    font-size: 12.5px;
                    background-color: var(--code-bg);
                    padding: 2px 6px;
                    border-radius: 4px;
                }
                pre {
                    background-color: var(--code-bg);
                    padding: 14px 16px;
                    border-radius: 8px;
                    overflow-x: auto;
                    border: 1px solid var(--border-color);
                }
                pre code {
                    background-color: transparent;
                    padding: 0;
                    font-size: 12.5px;
                    line-height: 1.5;
                }
                ul, ol {
                    padding-left: 24px;
                    margin-top: 0;
                    margin-bottom: 1em;
                }
                li { margin-bottom: 0.3em; }
                li.task-item {
                    list-style: none;
                    margin-left: -18px;
                }
                table {
                    border-collapse: collapse;
                    width: 100%;
                    margin: 1.2em 0;
                    border: 1px solid var(--border-color);
                    border-radius: 6px;
                    overflow: hidden;
                }
                th, td {
                    padding: 8px 12px;
                    border: 1px solid var(--border-color);
                    text-align: left;
                    font-size: 13px;
                }
                th {
                    background-color: var(--code-bg);
                    font-weight: 600;
                    color: var(--heading-color);
                }
                tr:nth-child(even) {
                    background-color: var(--table-stripe);
                }
                img {
                    max-width: 100%;
                    height: auto;
                    border-radius: 6px;
                    margin: 1em 0;
                }
            </style>
        </head>
        <body>
            \(htmlBody)
        </body>
        </html>
        """
        webView.loadHTMLString(fullHTML, baseURL: baseURL)
    }
    
    @MainActor
    public class Coordinator: NSObject, WKNavigationDelegate {
        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

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
