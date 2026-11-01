// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit

/// Custom NSTextView with keyboard shortcut routing, tab handling, chunked preview expansion, and non-contiguous layout.
public final class LargeTextEditorTextView: NSTextView {
    public var onSaveShortcut: (() -> Void)?
    public weak var chunkCoordinator: CodeHighlightingEditorNSView.Coordinator?
    private var markedCommitHookDepth: Int = 0

    /// Full preview text (capped at the 2 MB interactive preview budget), even when only a prefix is mounted in `textStorage`.
    public var fullPreviewText: String {
        chunkCoordinator?.fullPreviewText ?? self.string
    }

    /// Number of UTF-8 bytes currently mounted into `textStorage`.
    public var mountedUTF8ByteCount: Int {
        chunkCoordinator?.mountedUTF8ByteCount ?? self.string.utf8.count
    }

    /// Whether additional chunks of `fullPreviewText` remain unmounted beyond the current `textStorage`.
    public var isPartiallyMountedForViewport: Bool {
        chunkCoordinator?.isPartiallyMounted ?? false
    }

    /// Appends the next `128 KB` preview chunk into `textStorage` if unmounted text remains.
    @discardableResult
    public func loadNextPreviewChunk() -> Bool {
        chunkCoordinator?.appendNextPreviewChunk() ?? false
    }

    /// Ensures `textStorage` has mounted at least `targetUTF8Bytes` of `fullPreviewText`.
    @discardableResult
    public func ensureMountedThroughUTF8ByteOffset(_ targetUTF8Bytes: Int) -> Bool {
        chunkCoordinator?.ensureMounted(throughUTF8Bytes: targetUTF8Bytes) ?? false
    }

    /// Searches across the full 2 MB preview buffer, mounting any unmounted chunks up to the match before selecting and scrolling.
    @discardableResult
    public func searchInPreview(
        _ query: String,
        options: NSString.CompareOptions = [.caseInsensitive]
    ) -> NSRange? {
        guard !query.isEmpty else { return nil }
        let fullNSString = fullPreviewText as NSString
        let matchRange = fullNSString.range(of: query, options: options)
        guard matchRange.location != NSNotFound, matchRange.length > 0 else { return nil }

        let currentUTF16Len = textStorage?.length ?? (self.string as NSString).length
        let requiredUTF16End = NSMaxRange(matchRange)
        if requiredUTF16End > currentUTF16Len {
            let paddedUTF16End = min(fullNSString.length, requiredUTF16End + 4096)
            let requiredUTF8 = fullNSString.substring(to: paddedUTF16End).utf8.count
            let step = CodeHighlightingEditorNSView.chunkStepUTF8Bytes
            let alignedUTF8 = ((requiredUTF8 + step - 1) / step) * step
            _ = ensureMountedThroughUTF8ByteOffset(max(requiredUTF8, alignedUTF8))
        }

        if let layoutManager = self.layoutManager {
            layoutManager.ensureLayout(forCharacterRange: matchRange)
        }
        chunkCoordinator?.updateSearchHighlights(query: query, options: options, in: self)
        self.setSelectedRange(matchRange)
        self.scrollRangeToVisible(matchRange)
        return matchRange
    }

    public override func performFindPanelAction(_ sender: Any?) {
        mountForActiveFindPasteboardIfNeeded()
        super.performFindPanelAction(sender)
    }

    public override func performTextFinderAction(_ sender: Any?) {
        mountForActiveFindPasteboardIfNeeded()
        super.performTextFinderAction(sender)
    }

    private func mountForActiveFindPasteboardIfNeeded() {
        guard isPartiallyMountedForViewport else { return }
        if let findQuery = NSPasteboard(name: .find).string(forType: .string), !findQuery.isEmpty {
            _ = searchInPreview(findQuery)
        } else {
            _ = ensureMountedThroughUTF8ByteOffset(fullPreviewText.utf8.count)
        }
    }

    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isEditable && isPartiallyMountedForViewport {
            _ = ensureMountedThroughUTF8ByteOffset(fullPreviewText.utf8.count)
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isEditable && event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            if let onSave = onSaveShortcut {
                onSave()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func insertTab(_ sender: Any?) {
        if isEditable {
            insertText("    ", replacementRange: selectedRange())
        } else {
            super.insertTab(sender)
        }
    }

    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let wasMarked = hasMarkedText()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if hasMarkedText() {
            chunkCoordinator?.handleMarkedTextDidUpdate(in: self)
        } else if markedCommitHookDepth == 0, wasMarked {
            chunkCoordinator?.handleMarkedTextDidCommit(in: self)
        }
    }

    public override func unmarkText() {
        let wasMarked = hasMarkedText()
        markedCommitHookDepth += 1
        defer { markedCommitHookDepth -= 1 }
        super.unmarkText()
        if markedCommitHookDepth == 1, wasMarked, !hasMarkedText() {
            chunkCoordinator?.handleMarkedTextDidCommit(in: self)
        }
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        let wasMarked = hasMarkedText()
        markedCommitHookDepth += 1
        defer { markedCommitHookDepth -= 1 }
        super.insertText(string, replacementRange: replacementRange)
        if markedCommitHookDepth == 1, wasMarked, !hasMarkedText() {
            chunkCoordinator?.handleMarkedTextDidCommit(in: self)
        }
    }
}

/// Minimalist line number gutter view conforming to WSJ editorial and Zen typography standards.
/// Employs 10.5pt monospace font, right-alignment, adaptive digit width, and 3-state reading palette synchronization.
@MainActor
public final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    private var lineStartsTask: Task<Void, Never>?
    private var lineStartsGeneration: UInt64 = 0

    /// Active reading palette synchronized with `CodeHighlightingEditorNSView`.
    public var readingPalette: TTTextReadingPalette = .resolve(mode: .fluidTransparent, isDarkAppearance: true) {
        didSet {
            if readingPalette != oldValue {
                needsDisplay = true
            }
        }
    }

    /// Number of indexed lines in the currently mounted text storage.
    public var indexedLineCount: Int {
        max(1, lineStarts.count)
    }

    /// Duration in milliseconds of the most recent line-start offset scan.
    public private(set) var lastLineStartScanDurationMs: Double = 0

    private static let lineNumberFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let rightAlignedStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return style
    }()

    public init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clipsToBounds = true
        self.clientView = textView
        updateRuleThickness()
        updateTextViewInset()
    }

    public required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated deinit {
        lineStartsTask?.cancel()
    }

    public override var isFlipped: Bool { true }

    public func cancelPendingLineScan() {
        lineStartsGeneration &+= 1
        lineStartsTask?.cancel()
        lineStartsTask = nil
    }

    public func updateLineStarts(for text: String, onScanCompleted: ((Double, Int) -> Void)? = nil) {
        lineStartsGeneration &+= 1
        let capturedGeneration = lineStartsGeneration
        lineStartsTask?.cancel()
        lineStartsTask = nil

        let scanStart = CFAbsoluteTimeGetCurrent()
        if text.utf8.count <= 65_536 {
            self.lineStarts = Self.computeLineStarts(for: text, maxUTF8Bytes: .max)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - scanStart) * 1000.0
            self.lastLineStartScanDurationMs = elapsedMs
            updateRuleThickness()
            onScanCompleted?(elapsedMs, self.lineStarts.count)
            return
        }

        // Populate first-screen line starts immediately (< 0.1 ms), then finish full scan off MainActor.
        self.lineStarts = Self.computeLineStarts(for: text, maxUTF8Bytes: 32_768)
        let firstScreenElapsedMs = (CFAbsoluteTimeGetCurrent() - scanStart) * 1000.0
        self.lastLineStartScanDurationMs = firstScreenElapsedMs
        updateRuleThickness()

        lineStartsTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> [Int]? in
                guard !Task.isCancelled else { return nil }
                return Self.computeLineStarts(for: text, maxUTF8Bytes: .max)
            }
            let fullStarts = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  let self,
                  self.lineStartsGeneration == capturedGeneration,
                  let fullStarts else { return }
            let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - scanStart) * 1000.0
            self.lineStarts = fullStarts
            self.lastLineStartScanDurationMs = totalElapsedMs
            self.updateRuleThickness()
            self.needsDisplay = true
            onScanCompleted?(totalElapsedMs, fullStarts.count)
        }
    }

    nonisolated internal static func computeLineStarts(for text: String, maxUTF8Bytes: Int) -> [Int] {
        var starts: [Int] = [0]
        let utf8Count = min(text.utf8.count, maxUTF8Bytes)
        starts.reserveCapacity(max(16, utf8Count / 40))

        var utf16Index = 0
        var scannedBytes = 0
        for byte in text.utf8 {
            if scannedBytes >= maxUTF8Bytes { break }
            scannedBytes += 1
            if (scannedBytes & 0x3FFF) == 0 && Task.isCancelled {
                return starts
            }
            if byte == 0x0A {
                utf16Index += 1
                starts.append(utf16Index)
            } else if byte < 0x80 {
                utf16Index += 1
            } else if byte < 0xC0 {
                continue
            } else if byte < 0xF0 {
                utf16Index += 1
            } else {
                utf16Index += 2
            }
        }
        return starts
    }

    public func updateTextViewInset() {
        guard let tv = self.clientView as? NSTextView else { return }
        if tv.textContainerInset.width <= 0 || tv.textContainerInset.height <= 0 {
            tv.textContainerInset = NSSize(width: 8.0, height: 8.0)
        }
    }

    private func updateRuleThickness() {
        let digits = max(2, String(lineStarts.count).count)
        let required = max(36.0, CGFloat(digits) * 8.0 + 16.0)
        if abs(ruleThickness - required) > 0.5 {
            ruleThickness = required
        }
        updateTextViewInset()
    }

    /// Resolved placement of a logical source line number in the vertical ruler's coordinate space.
    public struct LogicalLineNumberPlacement: Equatable, Sendable {
        public let lineNumber: Int
        public let characterIndex: Int
        public let rectInRuler: NSRect
        public let visualFragmentCount: Int
    }

    public override func draw(_ dirtyRect: NSRect) {
        // AppKit may invalidate beyond the ruler; this painter owns only gutter pixels.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        readingPalette.nsGutterBackgroundColor.setFill()
        dirtyRect.fill()

        let separatorX = bounds.width - 0.5
        let separatorPath = NSBezierPath()
        separatorPath.move(to: NSPoint(x: separatorX, y: dirtyRect.minY))
        separatorPath.line(to: NSPoint(x: separatorX, y: dirtyRect.maxY))
        separatorPath.lineWidth = 0.5
        readingPalette.nsGutterBorderColor.setStroke()
        separatorPath.stroke()

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.lineNumberFont,
            .foregroundColor: readingPalette.nsGutterLabelColor,
            .paragraphStyle: Self.rightAlignedStyle
        ]

        let placements = visibleLogicalLineNumberPlacements(in: dirtyRect)
        for placement in placements {
            "\(placement.lineNumber)".draw(in: placement.rectInRuler, withAttributes: textAttrs)
        }
    }

    /// Computes the visible logical line number placements in ruler coordinates using live `NSLayoutManager` glyph fragments.
    /// Continuation fragments produced by soft-wrapping a logical line do not receive fabricated line numbers.
    public func visibleLogicalLineNumberPlacements(in targetRect: NSRect? = nil) -> [LogicalLineNumberPlacement] {
        guard let textView = self.clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return []
        }

        let clipRect = targetRect ?? bounds
        let storageLength = textView.textStorage?.length ?? 0
        if lineStarts.isEmpty || storageLength == 0 {
            let dummyRect = NSRect(x: 0, y: textView.textContainerOrigin.y, width: 10, height: 16)
            let rectInRuler = self.convert(dummyRect, from: textView)
            let labelRect = NSRect(x: 2, y: rectInRuler.origin.y + 1.0, width: max(0, bounds.width - 10), height: 16)
            return [
                LogicalLineNumberPlacement(
                    lineNumber: 1,
                    characterIndex: 0,
                    rectInRuler: labelRect,
                    visualFragmentCount: 1
                )
            ]
        }

        let convertedClip = self.convert(clipRect, to: textView)
        let baseVisible = textView.visibleRect
        let queryInTextView = targetRect != nil
            ? NSRect(
                x: baseVisible.minX,
                y: min(baseVisible.minY, convertedClip.minY),
                width: max(1.0, max(baseVisible.width, textView.bounds.width)),
                height: max(baseVisible.height, convertedClip.height)
            )
            : baseVisible
        let visibleInContainer = queryInTextView.offsetBy(
            dx: -textView.textContainerOrigin.x,
            dy: -textView.textContainerOrigin.y
        )
        layoutManager.ensureLayout(forBoundingRect: visibleInContainer, in: textContainer)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleInContainer, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let startLineIndex = findStartingLineIndex(for: charRange.location)

        return collectVisiblePlacements(
            from: startLineIndex,
            charRange: charRange,
            storageLength: storageLength,
            clipRect: clipRect,
            textView: textView,
            layoutManager: layoutManager
        )
    }

    private func findStartingLineIndex(for charLocation: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        var startLineIndex = 0
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= charLocation {
                startLineIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return startLineIndex
    }

    private func collectVisiblePlacements(
        from startLineIndex: Int,
        charRange: NSRange,
        storageLength: Int,
        clipRect: NSRect,
        textView: NSTextView,
        layoutManager: NSLayoutManager
    ) -> [LogicalLineNumberPlacement] {
        var placements: [LogicalLineNumberPlacement] = []
        for lineIdx in startLineIndex..<lineStarts.count {
            let charPos = lineStarts[lineIdx]
            if charPos >= storageLength || (charPos > NSMaxRange(charRange) && lineIdx > startLineIndex) {
                break
            }

            let glyphIdx = layoutManager.glyphIndexForCharacter(at: charPos)
            var firstFragmentGlyphRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: &firstFragmentGlyphRange)
            guard lineRect.height > 0 else { continue }
            let textRect = lineRect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            let rulerRect = self.convert(textRect, from: textView)

            if rulerRect.maxY < clipRect.minY { continue }
            if rulerRect.minY > clipRect.maxY { break }

            let nextLineStart = (lineIdx + 1 < lineStarts.count)
                ? min(storageLength, lineStarts[lineIdx + 1])
                : storageLength
            let lineCharLen = max(1, nextLineStart - charPos)
            let lineGlyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: charPos, length: lineCharLen),
                actualCharacterRange: nil
            )
            let fragCount = Self.countVisualFragments(
                in: lineGlyphRange,
                firstFragmentEnd: NSMaxRange(firstFragmentGlyphRange),
                layoutManager: layoutManager
            )
            let labelRect = NSRect(
                x: 2,
                y: rulerRect.origin.y + 1.0,
                width: max(0, bounds.width - 10),
                height: rulerRect.height
            )
            placements.append(
                LogicalLineNumberPlacement(
                    lineNumber: lineIdx + 1,
                    characterIndex: charPos,
                    rectInRuler: labelRect,
                    visualFragmentCount: fragCount
                )
            )
        }
        return placements
    }

    private static func countVisualFragments(
        in lineGlyphRange: NSRange,
        firstFragmentEnd: Int,
        layoutManager: NSLayoutManager
    ) -> Int {
        let glyphEnd = NSMaxRange(lineGlyphRange)
        guard firstFragmentEnd > lineGlyphRange.location, firstFragmentEnd < glyphEnd else {
            return 1
        }
        var count = 1
        var cursor = firstFragmentEnd
        while cursor < glyphEnd {
            var effRange = NSRange(location: 0, length: 0)
            _ = layoutManager.lineFragmentRect(forGlyphAt: cursor, effectiveRange: &effRange)
            count += 1
            let next = NSMaxRange(effRange)
            if next <= cursor { break }
            cursor = next
        }
        return count
    }
}
