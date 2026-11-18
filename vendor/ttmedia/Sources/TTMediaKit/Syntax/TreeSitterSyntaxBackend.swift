// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaDemux

/// Production Tree-sitter syntax highlighting backend bridging `SyntaxEngine` over C-ABI,
/// with automatic fallback to `BackgroundSyntaxTokenizer.defaultLexer` for unsupported extensions
/// or inputs exceeding the interactive AST UTF-16/UTF-8 bounds.
public struct TreeSitterSyntaxBackend: SyntaxTokenizingBackend, Sendable {
    /// Maximum UTF-16 code units tokenized via full-AST Tree-sitter pass before falling back to
    /// the chunked native lexer.
    public static let maxASTUTF16Length: Int = 131_072

    /// Maximum UTF-8 byte length accepted by `ttmedia_syntax_tokenize`.
    public static let maxASTUTF8ByteLength: Int = 4 * 1024 * 1024

    public static let supportedExtensions: Set<String> = [
        "rs", "swift", "c", "h", "cpp", "cc", "cxx", "hpp", "hxx",
        "py", "pyw", "js", "jsx", "mjs", "cjs", "ts", "tsx",
        "json", "jsonc", "md", "markdown", "html", "htm", "css"
    ]

    public init() {}

    public static func isSupportedExtension(_ fileExtension: String) -> Bool {
        let clean = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        return supportedExtensions.contains(clean)
    }

    public static func canTokenizeWithAST(text: String, fileExtension: String, requestedMaxLength: Int = 0) -> Bool {
        guard isSupportedExtension(fileExtension) else { return false }
        let totalUTF16 = text.utf16.count
        let effectiveUTF16 = (requestedMaxLength > 0 && requestedMaxLength < totalUTF16) ? requestedMaxLength : totalUTF16
        guard effectiveUTF16 > 0, effectiveUTF16 <= maxASTUTF16Length, totalUTF16 <= maxASTUTF16Length else {
            return false
        }
        return text.utf8.count <= maxASTUTF8ByteLength
    }

    public func tokenize(text: String, fileExtension: String, maxLength: Int) -> [TokenSpan] {
        guard !text.isEmpty, !Task.isCancelled else { return [] }
        let utf16 = text.utf16
        let totalUTF16 = utf16.count
        let requestedLimit = (maxLength > 0 && maxLength < totalUTF16) ? maxLength : totalUTF16
        let limit = min(requestedLimit, BackgroundSyntaxTokenizer.maxSyntaxHighlightUTF16Length)
        guard limit > 0 else { return [] }

        let cleanExt = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        guard Self.isSupportedExtension(cleanExt),
              totalUTF16 <= Self.maxASTUTF16Length,
              limit <= Self.maxASTUTF16Length else {
            return BackgroundSyntaxTokenizer.defaultLexer(text: text, ext: fileExtension, maxLength: limit)
        }

        let sliceLimit = Self.alignedSliceLimit(in: text, utf16Count: totalUTF16, requestedLimit: limit)
        let sourceSlice: String
        if sliceLimit < totalUTF16,
           let endUTF16Index = utf16.index(utf16.startIndex, offsetBy: sliceLimit, limitedBy: utf16.endIndex),
           let scalarEnd = endUTF16Index.samePosition(in: text) {
            sourceSlice = String(text[..<scalarEnd])
        } else {
            sourceSlice = text
        }

        guard let initialSpans = Self.runASTTokenize(
            sourceSlice: sourceSlice,
            cleanExt: cleanExt,
            startLimit: limit,
            maxEndLimit: sliceLimit
        ) else {
            return BackgroundSyntaxTokenizer.defaultLexer(text: text, ext: fileExtension, maxLength: limit)
        }

        if sliceLimit < totalUTF16,
           initialSpans.contains(where: { NSMaxRange($0.range) >= sliceLimit }),
           let fullSpans = Self.runASTTokenize(
               sourceSlice: text,
               cleanExt: cleanExt,
               startLimit: limit,
               maxEndLimit: totalUTF16
           ) {
            return fullSpans
        }
        return initialSpans
    }

    private static func alignedSliceLimit(in text: String, utf16Count: Int, requestedLimit: Int) -> Int {
        guard requestedLimit < utf16Count else { return utf16Count }
        let utf16 = text.utf16
        guard var idx = utf16.index(utf16.startIndex, offsetBy: requestedLimit, limitedBy: utf16.endIndex) else {
            return utf16Count
        }
        var current = requestedLimit
        while idx < utf16.endIndex {
            if utf16[idx] == 0x000A {
                break
            }
            idx = utf16.index(after: idx)
            current += 1
        }
        while idx < utf16.endIndex && idx.samePosition(in: text) == nil {
            idx = utf16.index(after: idx)
            current += 1
        }
        return min(current, utf16Count)
    }

    private static func runASTTokenize(
        sourceSlice: String,
        cleanExt: String,
        startLimit: Int,
        maxEndLimit: Int
    ) -> [TokenSpan]? {
        let utf8Bytes = Array(sourceSlice.utf8)
        guard utf8Bytes.count <= Self.maxASTUTF8ByteLength else {
            return nil
        }

        var spansPtr: UnsafeMutablePointer<TTMediaSyntaxTokenSpan>?
        var spanCount: Int = 0
        let status = utf8Bytes.withUnsafeBufferPointer { buffer -> Int32 in
            cleanExt.withCString { extPtr in
                ttmedia_syntax_tokenize(
                    buffer.baseAddress,
                    buffer.count,
                    extPtr,
                    &spansPtr,
                    &spanCount
                )
            }
        }
        defer {
            ttmedia_syntax_tokens_free(spansPtr, spanCount)
        }

        guard status == 0 else {
            return nil
        }
        guard let basePtr = spansPtr, spanCount > 0, !Task.isCancelled else {
            return []
        }

        let rawBuffer = UnsafeBufferPointer(start: basePtr, count: spanCount)
        var spans: [TokenSpan] = []
        spans.reserveCapacity(spanCount)
        for raw in rawBuffer {
            guard let category = Self.mapCategory(raw.category) else { continue }
            let loc = Int(raw.utf16_location)
            let len = Int(raw.utf16_length)
            guard loc >= 0, len > 0, loc < startLimit, loc + len <= maxEndLimit else { continue }
            spans.append(TokenSpan(range: NSRange(location: loc, length: len), colorType: category))
        }
        return spans
    }

    private static func mapCategory(_ code: UInt8) -> ColorCategory? {
        switch code {
        case 0: return .comment
        case 1: return .string
        case 2: return .keyword
        case 3: return .number
        case 4: return .type
        default: return nil
        }
    }
}
