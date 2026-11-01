// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit

/// Syntax highlight token span passed from background tokenizer actor to main thread layout.
public struct TokenSpan: Sendable, Equatable {
    public let range: NSRange
    public let colorType: ColorCategory
    
    public init(range: NSRange, colorType: ColorCategory) {
        self.range = range
        self.colorType = colorType
    }
}

/// Syntactic category of a highlight token.
public enum ColorCategory: Sendable, Equatable {
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

/// Protocol allowing customizable plug-in syntax highlighting engines.
public protocol SyntaxTokenizingBackend: Sendable {
    func tokenize(text: String, fileExtension: String, maxLength: Int) -> [TokenSpan]
}

/// Actor executing background off-main-thread syntax tokenization with front-priority streaming & chunking.
public actor BackgroundSyntaxTokenizer {
    public static let shared = BackgroundSyntaxTokenizer()

    /// Maximum UTF-16 code units highlighted per document to bound background CPU and memory.
    public static let maxSyntaxHighlightUTF16Length: Int = 2 * 1024 * 1024

    /// Chunk size (in UTF-16 code units) for incremental lexing without whole-file array allocation.
    private static let streamChunkUTF16Length: Int = 131_072

    private typealias LexerConfig = SyntaxLanguageVocabulary.LexerConfig

    private var customBackend: (any SyntaxTokenizingBackend)?

    public init(backend: (any SyntaxTokenizingBackend)? = nil) {
        self.customBackend = backend
    }

    public func setBackend(_ backend: (any SyntaxTokenizingBackend)?) {
        self.customBackend = backend
    }

    /// Tokenizes the target range in background without main thread regex compilation overhead.
    public func tokenize(text: String, ext: String, targetRange: NSRange) -> [TokenSpan] {
        guard !text.isEmpty, !Task.isCancelled else { return [] }
        let totalCount = text.utf16.count
        let rawMax = targetRange.location == NSNotFound
            ? totalCount
            : max(0, targetRange.location + targetRange.length)
        let scanMax = min(totalCount, min(rawMax, Self.maxSyntaxHighlightUTF16Length))
        guard scanMax > 0 else { return [] }

        let allTokens: [TokenSpan]
        if let backend = customBackend {
            allTokens = backend.tokenize(text: text, fileExtension: ext, maxLength: scanMax)
        } else {
            allTokens = Self.defaultLexer(text: text, ext: ext, maxLength: scanMax)
        }
        guard !Task.isCancelled else { return [] }

        if targetRange.location == NSNotFound {
            return allTokens
        }

        var results: [TokenSpan] = []
        results.reserveCapacity(allTokens.count)
        for token in allTokens where NSIntersectionRange(token.range, targetRange).length > 0 {
            results.append(token)
        }
        return results
    }

    /// Progressive streaming tokenizer: yields the priority range (e.g. viewport or head of text)
    /// immediately as batch 0 by lexing only the priority prefix first, then streams remaining spans in chunked batches.
    public func tokenizeStream(
        text: String,
        ext: String,
        priorityRange: NSRange? = nil,
        batchSize: Int = 2000
    ) -> AsyncStream<TokenSpanBatch> {
        let backend = self.customBackend
        let safeBatchSize = max(1, batchSize)
        return AsyncStream(TokenSpanBatch.self, bufferingPolicy: .unbounded) { continuation in
            let workerTask = Task.detached(priority: .userInitiated) {
                await Self.runTokenizeStreamWorker(
                    text: text,
                    ext: ext,
                    priorityRange: priorityRange,
                    batchSize: safeBatchSize,
                    backend: backend,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in
                workerTask.cancel()
            }
        }
    }

    // MARK: - Streaming Worker

    private static func runTokenizeStreamWorker(
        text: String,
        ext: String,
        priorityRange: NSRange?,
        batchSize: Int,
        backend: (any SyntaxTokenizingBackend)?,
        continuation: AsyncStream<TokenSpanBatch>.Continuation
    ) async {
        guard !text.isEmpty, !Task.isCancelled else {
            continuation.finish()
            return
        }

        if let backend {
            await streamWithCustomBackend(
                text: text,
                ext: ext,
                priorityRange: priorityRange,
                batchSize: batchSize,
                backend: backend,
                continuation: continuation
            )
            return
        }

        await streamWithNativeLexer(
            text: text,
            ext: ext,
            priorityRange: priorityRange,
            batchSize: batchSize,
            continuation: continuation
        )
    }

    private static func streamWithCustomBackend(
        text: String,
        ext: String,
        priorityRange: NSRange?,
        batchSize: Int,
        backend: any SyntaxTokenizingBackend,
        continuation: AsyncStream<TokenSpanBatch>.Continuation
    ) async {
        let totalUTF16 = text.utf16.count
        let effectiveLimit = min(totalUTF16, maxSyntaxHighlightUTF16Length)
        var nextBatchIndex = 0

        if let pRange = priorityRange, pRange.length > 0 {
            let pEnd = min(effectiveLimit, max(0, pRange.location + pRange.length))
            let priorityLimit = min(effectiveLimit, max(pEnd, 16_384))
            let prefixTokens = backend.tokenize(text: text, fileExtension: ext, maxLength: priorityLimit)
            guard !Task.isCancelled else { continuation.finish(); return }

            let prioritySpans = prefixTokens.filter { NSIntersectionRange($0.range, pRange).length > 0 }
            if !prioritySpans.isEmpty {
                let res = continuation.yield(TokenSpanBatch(batchIndex: 0, isPriorityViewport: true, spans: prioritySpans))
                if case .terminated = res { return }
                nextBatchIndex = 1
                await Task.yield()
            }
            guard !Task.isCancelled else { continuation.finish(); return }

            let fullTokens = priorityLimit < effectiveLimit
                ? backend.tokenize(text: text, fileExtension: ext, maxLength: effectiveLimit)
                : prefixTokens
            guard !Task.isCancelled else { continuation.finish(); return }

            let remaining = fullTokens.filter { NSIntersectionRange($0.range, pRange).length == 0 }
            await yieldBatches(remaining, startBatchIndex: nextBatchIndex, batchSize: batchSize, firstIsPriority: false, continuation: continuation)
        } else {
            let allTokens = backend.tokenize(text: text, fileExtension: ext, maxLength: effectiveLimit)
            guard !Task.isCancelled else { continuation.finish(); return }
            await yieldBatches(allTokens, startBatchIndex: 0, batchSize: batchSize, firstIsPriority: true, continuation: continuation)
        }
        continuation.finish()
    }

    private enum LexerCarryState: Equatable, Sendable {
        case normal
        case lineComment
        case blockComment
        case htmlComment
        case stringLiteral(quote: UInt16, isEscaped: Bool)
    }

    private static func streamWithNativeLexer(
        text: String,
        ext: String,
        priorityRange: NSRange?,
        batchSize: Int,
        continuation: AsyncStream<TokenSpanBatch>.Continuation
    ) async {
        let utf16 = text.utf16
        let effectiveLimit = min(utf16.count, maxSyntaxHighlightUTF16Length)
        guard effectiveLimit > 0 else { continuation.finish(); return }

        let config = LexerConfig(ext: ext, leadingText: String(text.prefix(128)))
        var cursorIdx = utf16.startIndex
        var cursorOffset = 0
        var nextBatchIndex = 0
        var carryState: LexerCarryState = .normal
        var pendingSpans: [TokenSpan] = []

        if let pRange = priorityRange, pRange.length > 0 {
            let keepGoing = await emitPriorityPrefixIfNeeded(
                utf16: utf16,
                effectiveLimit: effectiveLimit,
                pRange: pRange,
                config: config,
                cursorIdx: &cursorIdx,
                cursorOffset: &cursorOffset,
                nextBatchIndex: &nextBatchIndex,
                carryState: &carryState,
                pendingSpans: &pendingSpans,
                continuation: continuation
            )
            guard keepGoing else { return }
        }

        while cursorOffset < effectiveLimit && !Task.isCancelled {
            let stepTarget = (cursorOffset == 0) ? min(16_384, effectiveLimit) : streamChunkUTF16Length
            let (sliceEndIdx, sliceLen) = advanceNewlineAligned(
                in: utf16,
                from: cursorIdx,
                currentOffset: cursorOffset,
                targetLength: stepTarget,
                maxTotalOffset: effectiveLimit
            )
            guard sliceLen > 0 else { break }

            let chars = Array(utf16[cursorIdx..<sliceEndIdx])
            let (chunkSpans, nextState) = lexUTF16Buffer(chars, baseOffset: cursorOffset, config: config, initialState: carryState)
            guard !Task.isCancelled else { continuation.finish(); return }

            carryState = nextState
            cursorIdx = sliceEndIdx
            cursorOffset += sliceLen
            appendMergingContiguous(&pendingSpans, chunkSpans)

            let keepGoing = await drainReadyBatches(
                pendingSpans: &pendingSpans,
                batchSize: batchSize,
                nextBatchIndex: &nextBatchIndex,
                hasPriorityRange: priorityRange != nil,
                continuation: continuation
            )
            guard keepGoing else { return }
        }

        if !pendingSpans.isEmpty && !Task.isCancelled {
            await yieldBatches(
                pendingSpans,
                startBatchIndex: nextBatchIndex,
                batchSize: batchSize,
                firstIsPriority: (nextBatchIndex == 0 && priorityRange == nil),
                continuation: continuation
            )
        }
        continuation.finish()
    }

    private static func emitPriorityPrefixIfNeeded(
        utf16: String.UTF16View,
        effectiveLimit: Int,
        pRange: NSRange,
        config: LexerConfig,
        cursorIdx: inout String.UTF16View.Index,
        cursorOffset: inout Int,
        nextBatchIndex: inout Int,
        carryState: inout LexerCarryState,
        pendingSpans: inout [TokenSpan],
        continuation: AsyncStream<TokenSpanBatch>.Continuation
    ) async -> Bool {
        let pEnd = min(effectiveLimit, max(0, pRange.location + pRange.length))
        let priorityTarget = min(effectiveLimit, max(pEnd, 16_384))
        let (sliceEndIdx, sliceLen) = advanceNewlineAligned(
            in: utf16,
            from: cursorIdx,
            currentOffset: 0,
            targetLength: priorityTarget,
            maxTotalOffset: effectiveLimit
        )
        let chars = Array(utf16[cursorIdx..<sliceEndIdx])
        cursorIdx = sliceEndIdx
        cursorOffset = sliceLen

        let (initialSpans, nextState) = lexUTF16Buffer(chars, baseOffset: 0, config: config, initialState: carryState)
        carryState = nextState
        guard !Task.isCancelled else {
            continuation.finish()
            return false
        }

        var prioritySpans: [TokenSpan] = []
        for span in initialSpans {
            if NSIntersectionRange(span.range, pRange).length > 0 {
                prioritySpans.append(span)
            } else {
                pendingSpans.append(span)
            }
        }

        guard !prioritySpans.isEmpty else { return true }
        let res = continuation.yield(TokenSpanBatch(batchIndex: 0, isPriorityViewport: true, spans: prioritySpans))
        if case .terminated = res { return false }
        nextBatchIndex = 1
        await Task.yield()
        return true
    }

    private static func drainReadyBatches(
        pendingSpans: inout [TokenSpan],
        batchSize: Int,
        nextBatchIndex: inout Int,
        hasPriorityRange: Bool,
        continuation: AsyncStream<TokenSpanBatch>.Continuation
    ) async -> Bool {
        while pendingSpans.count >= batchSize && !Task.isCancelled {
            let batch = Array(pendingSpans.prefix(batchSize))
            pendingSpans.removeFirst(batchSize)
            let isPriority = (nextBatchIndex == 0 && !hasPriorityRange)
            let res = continuation.yield(TokenSpanBatch(batchIndex: nextBatchIndex, isPriorityViewport: isPriority, spans: batch))
            if case .terminated = res { return false }
            nextBatchIndex += 1
            await Task.yield()
        }
        return true
    }

    private static func yieldBatches(
        _ spans: [TokenSpan],
        startBatchIndex: Int,
        batchSize: Int,
        firstIsPriority: Bool,
        continuation: AsyncStream<TokenSpanBatch>.Continuation
    ) async {
        var batchIndex = startBatchIndex
        for chunkStart in stride(from: 0, to: spans.count, by: batchSize) {
            guard !Task.isCancelled else { return }
            let chunkEnd = min(chunkStart + batchSize, spans.count)
            let batch = Array(spans[chunkStart..<chunkEnd])
            let isPriority = firstIsPriority && chunkStart == 0
            let res = continuation.yield(TokenSpanBatch(batchIndex: batchIndex, isPriorityViewport: isPriority, spans: batch))
            if case .terminated = res { return }
            batchIndex += 1
            await Task.yield()
        }
    }

    private static func advanceNewlineAligned(
        in utf16: String.UTF16View,
        from startIdx: String.UTF16View.Index,
        currentOffset: Int,
        targetLength: Int,
        maxTotalOffset: Int
    ) -> (endIndex: String.UTF16View.Index, length: Int) {
        let remaining = max(0, maxTotalOffset - currentOffset)
        guard remaining > 0 else { return (startIdx, 0) }
        let baseAdvance = min(targetLength, remaining)
        var idx = utf16.index(startIdx, offsetBy: baseAdvance, limitedBy: utf16.endIndex) ?? utf16.endIndex
        var length = baseAdvance
        let extraCap = min(1024, remaining - baseAdvance)
        var extra = 0
        var lastUnit: UInt16 = (idx > startIdx) ? utf16[utf16.index(before: idx)] : 0
        while extra < extraCap && idx < utf16.endIndex {
            let unit = utf16[idx]
            idx = utf16.index(after: idx)
            length += 1
            extra += 1
            lastUnit = unit
            if unit == 10 { return (idx, length) }
        }
        while length < remaining && idx < utf16.endIndex && isUnsafeBoundaryUnit(lastUnit) {
            lastUnit = utf16[idx]
            idx = utf16.index(after: idx)
            length += 1
        }
        return (idx, length)
    }

    private static func isUnsafeBoundaryUnit(_ u: UInt16) -> Bool {
        if isIdentifierBody(u) { return true }
        return u == 47 || u == 42 || u == 92 || u == 60 || u == 33 || u == 45 || u == 46
    }

    private static func appendMergingContiguous(_ target: inout [TokenSpan], _ incoming: [TokenSpan]) {
        guard !incoming.isEmpty else { return }
        var startIndex = 0
        if let last = target.last, let first = incoming.first,
           last.colorType == first.colorType,
           last.range.location + last.range.length == first.range.location {
            target[target.count - 1] = TokenSpan(
                range: NSRange(location: last.range.location, length: last.range.length + first.range.length),
                colorType: last.colorType
            )
            startIndex = 1
        }
        if startIndex < incoming.count {
            target.append(contentsOf: incoming[startIndex...])
        }
    }

    // MARK: - Native High-Speed Lexer

    static func defaultLexer(text: String, ext: String, maxLength: Int = 0) -> [TokenSpan] {
        guard !Task.isCancelled else { return [] }
        let utf16 = text.utf16
        let totalCount = utf16.count
        let requestedLimit = (maxLength > 0 && maxLength < totalCount) ? maxLength : totalCount
        let limit = min(requestedLimit, maxSyntaxHighlightUTF16Length)
        guard limit > 0 else { return [] }

        let config = LexerConfig(ext: ext, leadingText: String(text.prefix(128)))
        let chars = (limit == totalCount) ? Array(utf16) : Array(utf16.prefix(limit))
        return lexUTF16Buffer(chars, baseOffset: 0, config: config, initialState: .normal).spans
    }

    private static func lexUTF16Buffer(
        _ chars: [UInt16],
        baseOffset: Int,
        config: LexerConfig,
        initialState: LexerCarryState = .normal
    ) -> (spans: [TokenSpan], endState: LexerCarryState) {
        let limit = chars.count
        guard limit > 0 else { return ([], initialState) }
        var spans: [TokenSpan] = []
        spans.reserveCapacity(min(limit / 8, 8_192))

        var i = 0
        var state = initialState
        if state != .normal,
           let carried = resumeCarriedState(chars, at: &i, limit: limit, baseOffset: baseOffset, state: &state) {
            spans.append(carried)
        }

        var lastCancelCheck = i
        while i < limit {
            if i - lastCancelCheck >= 4096 {
                if Task.isCancelled { return ([], state) }
                lastCancelCheck = i
            }
            if let commentOrString = scanCommentOrString(chars, at: &i, limit: limit, baseOffset: baseOffset, isHashComment: config.isHashComment, state: &state) {
                spans.append(commentOrString)
                continue
            }
            if let numberOrIdent = scanNumberOrIdentifier(chars, at: &i, limit: limit, baseOffset: baseOffset, config: config) {
                spans.append(numberOrIdent)
                continue
            }
            i += 1
        }
        return (spans, state)
    }

    private static func resumeCarriedState(
        _ chars: [UInt16], at i: inout Int, limit: Int, baseOffset: Int, state: inout LexerCarryState
    ) -> TokenSpan? {
        switch state {
        case .normal:
            return nil
        case .lineComment:
            return continueLineComment(chars, start: 0, at: &i, limit: limit, baseOffset: baseOffset, state: &state)
        case .blockComment:
            return continueBlockComment(chars, start: 0, at: &i, limit: limit, baseOffset: baseOffset, state: &state)
        case .htmlComment:
            return continueHTMLComment(chars, start: 0, at: &i, limit: limit, baseOffset: baseOffset, state: &state)
        case .stringLiteral(let quote, let isEscaped):
            return continueStringLiteral(chars, start: 0, at: &i, limit: limit, baseOffset: baseOffset, quote: quote, initialEscaped: isEscaped, state: &state)
        }
    }

    private static func scanCommentOrString(
        _ chars: [UInt16], at i: inout Int, limit: Int, baseOffset: Int, isHashComment: Bool, state: inout LexerCarryState
    ) -> TokenSpan? {
        let c = chars[i]
        if let lineComment = scanLineComment(chars, at: &i, limit: limit, baseOffset: baseOffset, isHashComment: isHashComment, state: &state) {
            return lineComment
        }
        if let blockComment = scanBlockComment(chars, at: &i, limit: limit, baseOffset: baseOffset, state: &state) {
            return blockComment
        }
        if c == 34 || c == 39 || c == 96 {
            let start = i
            i += 1
            return continueStringLiteral(chars, start: start, at: &i, limit: limit, baseOffset: baseOffset, quote: c, initialEscaped: false, state: &state)
        }
        return nil
    }

    private static func scanLineComment(
        _ chars: [UInt16], at i: inout Int, limit: Int, baseOffset: Int, isHashComment: Bool, state: inout LexerCarryState
    ) -> TokenSpan? {
        let c = chars[i]
        let isSlashSlash = (c == 47 && i + 1 < limit && chars[i + 1] == 47)
        let isHash = (isHashComment && c == 35)
        guard isSlashSlash || isHash else { return nil }
        let start = i
        i += isSlashSlash ? 2 : 1
        return continueLineComment(chars, start: start, at: &i, limit: limit, baseOffset: baseOffset, state: &state)
    }

    private static func continueLineComment(
        _ chars: [UInt16], start: Int, at i: inout Int, limit: Int, baseOffset: Int, state: inout LexerCarryState
    ) -> TokenSpan? {
        while i < limit && chars[i] != 10 { i += 1 }
        state = (i < limit) ? .normal : .lineComment
        guard i > start else { return nil }
        return TokenSpan(range: NSRange(location: baseOffset + start, length: i - start), colorType: .comment)
    }

    private static func scanBlockComment(
        _ chars: [UInt16], at i: inout Int, limit: Int, baseOffset: Int, state: inout LexerCarryState
    ) -> TokenSpan? {
        let c = chars[i]
        if c == 47 && i + 1 < limit && chars[i + 1] == 42 {
            let start = i
            i += 2
            return continueBlockComment(chars, start: start, at: &i, limit: limit, baseOffset: baseOffset, state: &state)
        }
        if isHTMLCommentStart(chars, at: i, limit: limit) {
            let start = i
            i += 4
            return continueHTMLComment(chars, start: start, at: &i, limit: limit, baseOffset: baseOffset, state: &state)
        }
        return nil
    }

    private static func continueBlockComment(
        _ chars: [UInt16], start: Int, at i: inout Int, limit: Int, baseOffset: Int, state: inout LexerCarryState
    ) -> TokenSpan? {
        var closed = false
        while i + 1 < limit {
            if chars[i] == 42 && chars[i + 1] == 47 {
                i += 2
                closed = true
                break
            }
            i += 1
        }
        if !closed {
            i = limit
            state = .blockComment
        } else {
            state = .normal
        }
        guard i > start else { return nil }
        return TokenSpan(range: NSRange(location: baseOffset + start, length: i - start), colorType: .comment)
    }

    private static func continueHTMLComment(
        _ chars: [UInt16], start: Int, at i: inout Int, limit: Int, baseOffset: Int, state: inout LexerCarryState
    ) -> TokenSpan? {
        var closed = false
        while i + 2 < limit {
            if isHTMLCommentEnd(chars, at: i) {
                i += 3
                closed = true
                break
            }
            i += 1
        }
        if !closed {
            i = limit
            state = .htmlComment
        } else {
            state = .normal
        }
        guard i > start else { return nil }
        return TokenSpan(range: NSRange(location: baseOffset + start, length: i - start), colorType: .comment)
    }

    private static func isHTMLCommentStart(_ chars: [UInt16], at i: Int, limit: Int) -> Bool {
        guard i + 3 < limit, chars[i] == 60, chars[i + 1] == 33 else { return false }
        return chars[i + 2] == 45 && chars[i + 3] == 45
    }

    private static func isHTMLCommentEnd(_ chars: [UInt16], at i: Int) -> Bool {
        guard chars[i] == 45, chars[i + 1] == 45 else { return false }
        return chars[i + 2] == 62
    }

    private static func continueStringLiteral(
        _ chars: [UInt16], start: Int, at i: inout Int, limit: Int, baseOffset: Int, quote: UInt16, initialEscaped: Bool, state: inout LexerCarryState
    ) -> TokenSpan? {
        var escaped = initialEscaped
        var closed = false
        while i < limit {
            let sc = chars[i]
            if escaped {
                escaped = false
            } else if sc == 92 {
                escaped = true
            } else if sc == quote {
                i += 1
                closed = true
                break
            }
            i += 1
        }
        state = closed ? .normal : .stringLiteral(quote: quote, isEscaped: escaped)
        guard i > start else { return nil }
        return TokenSpan(range: NSRange(location: baseOffset + start, length: i - start), colorType: .string)
    }

    private static func scanNumberOrIdentifier(
        _ chars: [UInt16], at i: inout Int, limit: Int, baseOffset: Int, config: LexerConfig
    ) -> TokenSpan? {
        let c = chars[i]
        if config.isShellFamily, c == 36,
           let shellParam = SyntaxLanguageVocabulary.scanShellParameter(chars, at: &i, limit: limit, baseOffset: baseOffset) {
            return shellParam
        }
        if isNumberStart(chars, at: i, limit: limit) {
            let start = i
            i += 1
            while i < limit && isNumberBody(chars[i]) { i += 1 }
            return TokenSpan(range: NSRange(location: baseOffset + start, length: i - start), colorType: .number)
        }
        if isIdentifierStart(c) {
            let start = i
            i += 1
            while i < limit && isIdentifierBody(chars[i]) { i += 1 }
            return classifyIdentifier(chars, start: start, end: i, firstChar: c, baseOffset: baseOffset, config: config)
        }
        return nil
    }

    private static func isNumberStart(_ chars: [UInt16], at i: Int, limit: Int) -> Bool {
        let c = chars[i]
        if isASCIIDigit(c) { return true }
        return c == 46 && i + 1 < limit && isASCIIDigit(chars[i + 1])
    }

    private static func isASCIIDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isASCIIUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
    private static func isASCIILower(_ c: UInt16) -> Bool { c >= 97 && c <= 122 }

    private static func isNumberBody(_ nc: UInt16) -> Bool {
        if isASCIIDigit(nc) { return true }
        if (nc >= 97 && nc <= 102) || (nc >= 65 && nc <= 70) { return true }
        return nc == 120 || nc == 98 || nc == 46 || nc == 95
    }

    private static func isIdentifierStart(_ c: UInt16) -> Bool {
        if isASCIIUpper(c) || isASCIILower(c) { return true }
        return c == 95 || c == 36 || c == 64
    }

    private static func isIdentifierBody(_ ic: UInt16) -> Bool {
        if isASCIIUpper(ic) || isASCIILower(ic) || isASCIIDigit(ic) { return true }
        return ic == 95 || ic == 36
    }

    private static func classifyIdentifier(
        _ chars: [UInt16], start: Int, end: Int, firstChar: UInt16, baseOffset: Int, config: LexerConfig
    ) -> TokenSpan? {
        let range = NSRange(location: baseOffset + start, length: end - start)
        let word = String(decoding: chars[start..<end], as: UTF16.self)
        if config.builtInTypes.contains(word) { return TokenSpan(range: range, colorType: .type) }
        if config.keywords.contains(word) { return TokenSpan(range: range, colorType: .keyword) }
        if isASCIIUpper(firstChar) { return TokenSpan(range: range, colorType: .type) }
        return nil
    }
}
