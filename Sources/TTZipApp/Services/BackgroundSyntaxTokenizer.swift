// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

/// Syntax highlight token span passed from background tokenizer actor to main thread layout.
public struct TokenSpan: Sendable {
    public let range: NSRange
    public let colorType: ColorCategory
    
    public init(range: NSRange, colorType: ColorCategory) {
        self.range = range
        self.colorType = colorType
    }
}

public enum ColorCategory: Sendable {
    case comment
    case string
    case keyword
    case number
    case type
}

/// Actor executing background off-main-thread syntax tokenization without blocking the UI.
public actor BackgroundSyntaxTokenizer {
    public static let shared = BackgroundSyntaxTokenizer()
    
    private init() {}
    
    /// Tokenizes the target range in background without main thread regex compilation overhead.
    public func tokenize(text: String, ext: String, targetRange: NSRange) -> [TokenSpan] {
        guard let rules = PrecompiledSyntaxEngine.shared.rules(for: ext) else { return [] }
        var results: [TokenSpan] = []
        let nsText = text as NSString
        let scanRange = NSIntersectionRange(NSRange(location: 0, length: nsText.length), targetRange)
        guard scanRange.length > 0 else { return [] }
        
        if let reg = rules.commentRegex {
            for m in reg.matches(in: text, options: [], range: scanRange) {
                results.append(TokenSpan(range: m.range, colorType: .comment))
            }
        }
        if let reg = rules.stringRegex {
            for m in reg.matches(in: text, options: [], range: scanRange) {
                results.append(TokenSpan(range: m.range, colorType: .string))
            }
        }
        if let reg = rules.keywordRegex {
            for m in reg.matches(in: text, options: [], range: scanRange) {
                results.append(TokenSpan(range: m.range, colorType: .keyword))
            }
        }
        if let reg = rules.numberRegex {
            for m in reg.matches(in: text, options: [], range: scanRange) {
                results.append(TokenSpan(range: m.range, colorType: .number))
            }
        }
        if let reg = rules.typeRegex {
            for m in reg.matches(in: text, options: [], range: scanRange) {
                results.append(TokenSpan(range: m.range, colorType: .type))
            }
        }
        return results
    }
}
