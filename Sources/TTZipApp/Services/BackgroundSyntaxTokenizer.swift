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

/// Structured token batch yielded progressively to prevent main-thread layout locking on large files.
public struct TokenSpanBatch: Sendable {
    public let batchIndex: Int
    public let isPriorityViewport: Bool
    public let spans: [TokenSpan]
    
    public init(batchIndex: Int, isPriorityViewport: Bool, spans: [TokenSpan]) {
        self.batchIndex = batchIndex
        self.isPriorityViewport = isPriorityViewport
        self.spans = spans
    }
}

/// Actor executing background off-main-thread syntax tokenization with front-priority streaming & chunking.
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
        results.reserveCapacity(rustSpans.count)
        for span in rustSpans {
            let nsRange = NSRange(location: Int(span.location), length: Int(span.length))
            if targetRange.location != NSNotFound {
                let intersection = NSIntersectionRange(nsRange, targetRange)
                guard intersection.length > 0 else { continue }
            }
            
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
    
    /// Progressive streaming tokenizer: yields the priority range (e.g. viewport or head of text)
    /// immediately as batch 0, then streams the remaining spans in chunked batches.
    /// This guarantees immediate responsive visual feedback even for files with hundreds of thousands of lines.
    public func tokenizeStream(
        text: String,
        ext: String,
        priorityRange: NSRange? = nil,
        batchSize: Int = 2000
    ) -> AsyncStream<TokenSpanBatch> {
        AsyncStream { continuation in
            guard !text.isEmpty else {
                continuation.finish()
                return
            }
            
            let rustSpans = TTZipCore.tokenizeSourceCode(
                text: text,
                fileExtension: ext,
                maxLength: 0
            )
            
            guard !rustSpans.isEmpty else {
                continuation.finish()
                return
            }
            
            var allSpans: [TokenSpan] = []
            allSpans.reserveCapacity(rustSpans.count)
            
            for span in rustSpans {
                let nsRange = NSRange(location: Int(span.location), length: Int(span.length))
                let colorType: ColorCategory = switch span.category {
                case "comment": .comment
                case "string": .string
                case "keyword": .keyword
                case "number": .number
                case "type": .type
                default: .keyword
                }
                allSpans.append(TokenSpan(range: nsRange, colorType: colorType))
            }
            
            if let pRange = priorityRange, pRange.length > 0 {
                var prioritySpans: [TokenSpan] = []
                var remainingSpans: [TokenSpan] = []
                
                for token in allSpans {
                    let intersection = NSIntersectionRange(token.range, pRange)
                    if intersection.length > 0 {
                        prioritySpans.append(token)
                    } else {
                        remainingSpans.append(token)
                    }
                }
                
                if !prioritySpans.isEmpty {
                    continuation.yield(TokenSpanBatch(batchIndex: 0, isPriorityViewport: true, spans: prioritySpans))
                }
                
                var batchIndex = 1
                for chunkStart in stride(from: 0, to: remainingSpans.count, by: batchSize) {
                    let chunkEnd = min(chunkStart + batchSize, remainingSpans.count)
                    let batch = Array(remainingSpans[chunkStart..<chunkEnd])
                    continuation.yield(TokenSpanBatch(batchIndex: batchIndex, isPriorityViewport: false, spans: batch))
                    batchIndex += 1
                }
            } else {
                var batchIndex = 0
                for chunkStart in stride(from: 0, to: allSpans.count, by: batchSize) {
                    let chunkEnd = min(chunkStart + batchSize, allSpans.count)
                    let batch = Array(allSpans[chunkStart..<chunkEnd])
                    continuation.yield(TokenSpanBatch(batchIndex: batchIndex, isPriorityViewport: batchIndex == 0, spans: batch))
                    batchIndex += 1
                }
            }
            
            continuation.finish()
        }
    }
}
