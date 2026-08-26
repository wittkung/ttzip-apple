// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore

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
        let scanMax = targetRange.location == NSNotFound 
            ? UInt32(text.utf16.count) 
            : UInt32(max(0, targetRange.location + targetRange.length))
        let rustSpans = TTZipCore.tokenizeSourceCode(
            text: text,
            fileExtension: ext,
            maxLength: scanMax
        )
        
        var results: [TokenSpan] = []
        for span in rustSpans {
            let nsRange = NSRange(location: Int(span.location), length: Int(span.length))
            let intersection = NSIntersectionRange(nsRange, targetRange)
            guard intersection.length > 0 else { continue }
            
            let colorType: ColorCategory = switch span.category {
            case "comment": .comment
            case "string": .string
            case "keyword": .keyword
            case "number": .number
            case "type": .type
            default: .keyword
            }
            results.append(TokenSpan(range: nsRange, colorType: colorType))
        }
        return results
    }
}
