// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

/// High-performance static precompiled syntax regular expression rule engine.
/// Eliminates runtime regex compilation and array sorting during interactive typing.
public final class PrecompiledSyntaxEngine: @unchecked Sendable {
    public static let shared = PrecompiledSyntaxEngine()
    
    public struct RuleSet: Sendable {
        public let commentRegex: NSRegularExpression?
        public let stringRegex: NSRegularExpression?
        public let keywordRegex: NSRegularExpression?
        public let numberRegex: NSRegularExpression?
        public let typeRegex: NSRegularExpression?
        public let caseSensitive: Bool
    }
    
    private let compiledCache: [String: RuleSet]
    
    private init() {
        var map: [String: RuleSet] = [:]
        let supportedExtensions = [
            "swift", "c", "cpp", "h", "hpp", "cc", "cxx",
            "java", "kt", "kts", "py", "js", "jsx", "ts", "tsx",
            "rs", "go", "sql", "sh", "bash", "zsh", "html", "htm",
            "css", "scss", "less", "json", "json5", "xml", "plist",
            "yaml", "yml", "md", "markdown"
        ]
        
        let stringPattern = "\"([^\"\\\\]|\\\\.)*\"|'([^'\\\\]|\\\\.)*'"
        let numberPattern = "\\b\\d+(\\.\\d+)?\\b|0x[0-9a-fA-F]+\\b"
        let staticStringRegex = try? NSRegularExpression(pattern: stringPattern, options: [])
        let staticNumberRegex = try? NSRegularExpression(pattern: numberPattern, options: [])
        
        for ext in supportedExtensions {
            let r = SyntaxLanguageRules.rules(forExtension: ext)
            let comment = try? NSRegularExpression(pattern: r.commentPattern, options: [])
            
            var kw: NSRegularExpression? = nil
            if !r.keywords.isEmpty {
                let sorted = r.keywords.sorted { $0.count > $1.count }.joined(separator: "|")
                let opts: NSRegularExpression.Options = r.caseSensitive ? [] : [.caseInsensitive]
                kw = try? NSRegularExpression(pattern: "\\b(\(sorted))\\b", options: opts)
            }
            
            var tp: NSRegularExpression? = nil
            if !r.types.isEmpty {
                let sorted = r.types.sorted { $0.count > $1.count }.joined(separator: "|")
                tp = try? NSRegularExpression(pattern: "\\b(\(sorted))\\b|@[a-zA-Z0-9_]+", options: [])
            }
            
            map[ext] = RuleSet(
                commentRegex: comment,
                stringRegex: staticStringRegex,
                keywordRegex: kw,
                numberRegex: staticNumberRegex,
                typeRegex: tp,
                caseSensitive: r.caseSensitive
            )
        }
        self.compiledCache = map
    }
    
    public func rules(for ext: String) -> RuleSet? {
        return compiledCache[ext.lowercased()]
    }
}
