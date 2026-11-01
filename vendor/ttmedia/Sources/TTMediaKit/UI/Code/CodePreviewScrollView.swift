// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation

/// Snapshot of the reader's top-visible character position and active selection ranges prior to layout reflow.
public struct TTTextViewportAnchor: Equatable {
    public let characterIndex: Int
    public let intraLineOffsetY: CGFloat
    public let wasAtTop: Bool
    public let selectedRanges: [NSValue]
}

/// Repairs the document viewport after SwiftUI mounts or resizes an AppKit editor and synchronizes soft-wrap vs. horizontal-scroll geometry.
@MainActor
final class CodePreviewScrollView: NSScrollView {
    private var isSynchronizingDocument = false
    private var lastViewport = NSRect.null
    private var lastDocumentLength = -1
    private var lastSoftWrapState: Bool? = nil
    private var lastFontPointSize: CGFloat = -1
    private var lastInset: NSSize = .zero
    private var lastRulerWidth: CGFloat = -1
    weak var chunkCoordinator: CodeHighlightingEditorNSView.Coordinator?

    override func tile() {
        super.tile()
        synchronizeDocumentViewport()
    }

    override func layout() {
        super.layout()
        synchronizeDocumentViewport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeDocumentViewport()
    }

    func synchronizeDocumentViewport(force: Bool = false) {
        guard !isSynchronizingDocument,
              let textView = documentView as? NSTextView,
              contentSize.width > 0, contentSize.height > 0 else { return }
        let viewportBounds = NSRect(origin: contentView.bounds.origin, size: contentSize)
        let documentLength = textView.textStorage?.length ?? 0
        let isSoftWrap = textView.textContainer?.widthTracksTextView ?? true
        let fontPointSize = textView.font?.pointSize ?? 12.5
        let inset = textView.textContainerInset
        let rulerWidth = CodeRulerGeometry.reservedWidth(in: self)
        guard force || hasViewportStateChanged(
            viewportBounds: viewportBounds,
            documentLength: documentLength,
            isSoftWrap: isSoftWrap,
            fontPointSize: fontPointSize,
            inset: inset,
            rulerWidth: rulerWidth
        ) else { return }

        let resizeAnchor = captureResizeAnchorIfNeeded(
            force: force,
            viewportBounds: viewportBounds,
            isSoftWrap: isSoftWrap,
            textView: textView
        )
        recordViewportState(
            viewportBounds: viewportBounds,
            documentLength: documentLength,
            isSoftWrap: isSoftWrap,
            fontPointSize: fontPointSize,
            inset: inset,
            rulerWidth: rulerWidth
        )
        isSynchronizingDocument = true
        defer { isSynchronizingDocument = false }

        Self.applyViewportLayout(to: textView, in: self, isSoftWrap: isSoftWrap)
        if let resizeAnchor, let chunkCoordinator {
            chunkCoordinator.restoreViewportAnchor(
                resizeAnchor,
                in: textView,
                scrollView: self,
                isSoftWrapEnabled: isSoftWrap
            )
            lastViewport = NSRect(origin: contentView.bounds.origin, size: contentSize)
        }
        verticalRulerView?.needsDisplay = true
        textView.needsDisplay = true
    }

    private func hasViewportStateChanged(
        viewportBounds: NSRect,
        documentLength: Int,
        isSoftWrap: Bool,
        fontPointSize: CGFloat,
        inset: NSSize,
        rulerWidth: CGFloat
    ) -> Bool {
        if viewportBounds != lastViewport || documentLength != lastDocumentLength {
            return true
        }
        if isSoftWrap != lastSoftWrapState || inset != lastInset {
            return true
        }
        if abs(rulerWidth - lastRulerWidth) > 0.5 {
            return true
        }
        return abs(fontPointSize - lastFontPointSize) > 0.01
    }

    private func captureResizeAnchorIfNeeded(
        force: Bool,
        viewportBounds: NSRect,
        isSoftWrap: Bool,
        textView: NSTextView
    ) -> TTTextViewportAnchor? {
        guard !force,
              !lastViewport.isNull,
              abs(viewportBounds.width - lastViewport.width) > 0.5,
              isSoftWrap,
              viewportBounds.origin.y > 1.0 else {
            return nil
        }
        return chunkCoordinator?.captureViewportAnchor(in: textView, scrollView: self)
    }

    private func recordViewportState(
        viewportBounds: NSRect,
        documentLength: Int,
        isSoftWrap: Bool,
        fontPointSize: CGFloat,
        inset: NSSize,
        rulerWidth: CGFloat
    ) {
        lastViewport = viewportBounds
        lastDocumentLength = documentLength
        lastSoftWrapState = isSoftWrap
        lastFontPointSize = fontPointSize
        lastInset = inset
        lastRulerWidth = rulerWidth
    }

    static func applyViewportLayout(
        to textView: NSTextView,
        in scrollView: NSScrollView?,
        isSoftWrap: Bool
    ) {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        let inset = textView.textContainerInset
        let viewport = scrollView?.contentSize ?? textView.frame.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let usableWidth = CodeRulerGeometry.usableWidth(forViewportWidth: viewport.width, in: scrollView)

        configureContainerAndMinMaxSizes(
            textView: textView,
            container: container,
            viewport: viewport,
            usableWidth: usableWidth,
            inset: inset,
            isSoftWrap: isSoftWrap
        )
        ensureLayoutForViewport(
            textView: textView,
            scrollView: scrollView,
            manager: manager,
            container: container
        )
        measureAndUpdateFrameSize(
            textView: textView,
            scrollView: scrollView,
            manager: manager,
            container: container,
            viewport: viewport,
            usableWidth: usableWidth,
            inset: inset,
            isSoftWrap: isSoftWrap
        )
    }

    private static func configureContainerAndMinMaxSizes(
        textView: NSTextView,
        container: NSTextContainer,
        viewport: NSSize,
        usableWidth: CGFloat,
        inset: NSSize,
        isSoftWrap: Bool
    ) {
        textView.minSize = NSSize(width: usableWidth, height: viewport.height)
        if isSoftWrap {
            textView.maxSize = NSSize(width: usableWidth, height: CGFloat.greatestFiniteMagnitude)
            let targetWidth = max(1.0, usableWidth - inset.width * 2.0)
            if abs(container.containerSize.width - targetWidth) > 0.5 {
                container.containerSize = NSSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
            }
            if abs(textView.frame.width - usableWidth) > 0.5 || textView.frame.height < viewport.height {
                textView.setFrameSize(NSSize(width: usableWidth, height: max(viewport.height, textView.frame.height)))
            }
        } else {
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if container.containerSize.width < CGFloat.greatestFiniteMagnitude / 2.0 {
                container.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
        }
    }

    private static func ensureLayoutForViewport(
        textView: NSTextView,
        scrollView: NSScrollView?,
        manager: NSLayoutManager,
        container: NSTextContainer
    ) {
        let documentLength = textView.textStorage?.length ?? 0
        if documentLength <= 131_072 {
            manager.ensureLayout(for: container)
            return
        }
        let visibleBounds = scrollView?.contentView.bounds ?? textView.visibleRect
        let visibleInContainer = visibleBounds.offsetBy(
            dx: -textView.textContainerOrigin.x,
            dy: -textView.textContainerOrigin.y
        )
        manager.ensureLayout(forBoundingRect: visibleInContainer, in: container)
    }

    private static func measureAndUpdateFrameSize(
        textView: NSTextView,
        scrollView: NSScrollView?,
        manager: NSLayoutManager,
        container: NSTextContainer,
        viewport: NSSize,
        usableWidth: CGFloat,
        inset: NSSize,
        isSoftWrap: Bool
    ) {
        let used = manager.usedRect(for: container)
        let measuredWidth = isSoftWrap
            ? usableWidth
            : max(usableWidth, ceil(used.maxX + inset.width * 2.0))
        let measuredHeight = max(viewport.height, ceil(used.maxY + inset.height * 2.0))
        let measured = NSSize(width: measuredWidth, height: measuredHeight)
        if measured.width.isFinite && measured.height.isFinite && textView.frame.size != measured {
            textView.setFrameSize(measured)
        }
        if isSoftWrap, let clipView = scrollView?.contentView {
            // The ruler overlays the clip view, so the document's left edge must rest against the
            // ruler's right edge. Resetting the origin to 0 would slide the leading characters of
            // every line underneath the painted gutter.
            let restingX = CodeRulerGeometry.restingOriginX(in: scrollView)
            if abs(clipView.bounds.origin.x - restingX) > 0.5 {
                clipView.scroll(to: NSPoint(x: restingX, y: clipView.bounds.origin.y))
                scrollView?.reflectScrolledClipView(clipView)
            }
        }
    }
}

// MARK: - Coordinator Soft-Wrap, Viewport Anchor & Scroll Extension

extension CodeHighlightingEditorNSView.Coordinator {
    /// Applies soft-wrap or unwrapped horizontal-scroll layout to the live `NSTextView` and `NSScrollView`
    /// without mutating `NSTextStorage` characters, re-reading disk files, or re-running syntax tokenization.
    public func applySoftWrapConfiguration(
        isSoftWrapEnabled: Bool,
        to tv: NSTextView,
        scrollView: NSScrollView?,
        preserveAnchor: Bool = true
    ) {
        let activeScrollView = scrollView ?? tv.enclosingScrollView
        let anchor = preserveAnchor ? captureViewportAnchor(in: tv, scrollView: activeScrollView) : nil
        activeSoftWrapEnabled = isSoftWrapEnabled

        if let activeScrollView {
            activeScrollView.hasHorizontalScroller = !isSoftWrapEnabled
        }
        tv.isHorizontallyResizable = !isSoftWrapEnabled
        if let container = tv.textContainer {
            container.widthTracksTextView = isSoftWrapEnabled
            if isSoftWrapEnabled {
                let hostWidth = CodeRulerGeometry.usableWidth(
                    forViewportWidth: activeScrollView?.contentSize.width ?? tv.frame.width,
                    in: activeScrollView
                )
                if hostWidth > 0 {
                    let targetWidth = max(1.0, hostWidth - tv.textContainerInset.width * 2.0)
                    container.containerSize = NSSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
                }
            } else {
                container.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
        }

        if let previewScroll = activeScrollView as? CodePreviewScrollView {
            previewScroll.synchronizeDocumentViewport(force: true)
        } else {
            CodePreviewScrollView.applyViewportLayout(
                to: tv,
                in: activeScrollView,
                isSoftWrap: isSoftWrapEnabled
            )
        }

        if let anchor {
            restoreViewportAnchor(
                anchor,
                in: tv,
                scrollView: activeScrollView,
                isSoftWrapEnabled: isSoftWrapEnabled
            )
        }
        rulerView?.needsDisplay = true
        tv.needsDisplay = true
    }

    /// Captures the character index at the top of the visible viewport along with active selection ranges.
    public func captureViewportAnchor(
        in tv: NSTextView,
        scrollView: NSScrollView?
    ) -> TTTextViewportAnchor? {
        guard let layoutManager = tv.layoutManager,
              let textContainer = tv.textContainer,
              let storage = tv.textStorage else { return nil }
        let origin = scrollView?.contentView.bounds.origin ?? tv.visibleRect.origin
        let wasAtTop = origin.y <= 1.0
        guard storage.length > 0 else {
            return TTTextViewportAnchor(
                characterIndex: 0,
                intraLineOffsetY: 0.0,
                wasAtTop: true,
                selectedRanges: tv.selectedRanges
            )
        }
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else {
            return TTTextViewportAnchor(
                characterIndex: 0,
                intraLineOffsetY: 0.0,
                wasAtTop: wasAtTop,
                selectedRanges: tv.selectedRanges
            )
        }
        let probeY = max(0.0, origin.y - tv.textContainerOrigin.y + 2.0)
        let probePoint = NSPoint(x: 0.0, y: probeY)
        let rawGlyphIdx = layoutManager.glyphIndex(
            for: probePoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        let glyphIdx = max(0, min(glyphCount - 1, rawGlyphIdx))
        let charIdx = max(0, min(storage.length - 1, layoutManager.characterIndexForGlyph(at: glyphIdx)))
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        let intraOffsetY = max(0.0, probeY - lineRect.minY)
        return TTTextViewportAnchor(
            characterIndex: charIdx,
            intraLineOffsetY: intraOffsetY,
            wasAtTop: wasAtTop,
            selectedRanges: tv.selectedRanges
        )
    }

    /// Restores the reading viewport to the anchored character position after soft-wrap, resize, or font-size reflow.
    public func restoreViewportAnchor(
        _ anchor: TTTextViewportAnchor,
        in tv: NSTextView,
        scrollView: NSScrollView?,
        isSoftWrapEnabled: Bool
    ) {
        let storageLength = tv.textStorage?.length ?? 0
        restoreAnchoredSelectionIfNeeded(anchor.selectedRanges, in: tv, storageLength: storageLength)
        guard let activeScrollView = scrollView ?? tv.enclosingScrollView,
              let layoutManager = tv.layoutManager else { return }

        let newOrigin = computeAnchoredScrollOrigin(
            anchor: anchor,
            in: tv,
            scrollView: activeScrollView,
            layoutManager: layoutManager,
            storageLength: storageLength,
            isSoftWrapEnabled: isSoftWrapEnabled
        )
        if activeScrollView.contentView.bounds.origin != newOrigin {
            activeScrollView.contentView.scroll(to: newOrigin)
            activeScrollView.reflectScrolledClipView(activeScrollView.contentView)
        }
        rulerView?.needsDisplay = true
    }

    private func restoreAnchoredSelectionIfNeeded(
        _ selectedRanges: [NSValue],
        in tv: NSTextView,
        storageLength: Int
    ) {
        guard !tv.hasMarkedText(), tv.selectedRanges != selectedRanges else { return }
        let validRanges = selectedRanges.filter { val in
            let rng = val.rangeValue
            return rng.location != NSNotFound && NSMaxRange(rng) <= storageLength
        }
        if !validRanges.isEmpty {
            tv.selectedRanges = validRanges
        }
    }

    private func computeAnchoredScrollOrigin(
        anchor: TTTextViewportAnchor,
        in tv: NSTextView,
        scrollView: NSScrollView,
        layoutManager: NSLayoutManager,
        storageLength: Int,
        isSoftWrapEnabled: Bool
    ) -> NSPoint {
        if anchor.wasAtTop || storageLength == 0 {
            let restingX = CodeRulerGeometry.restingOriginX(in: scrollView)
            let targetX: CGFloat = isSoftWrapEnabled
                ? restingX
                : max(restingX, scrollView.contentView.bounds.origin.x)
            return NSPoint(x: targetX, y: 0.0)
        }
        let clampedChar = max(0, min(storageLength - 1, anchor.characterIndex))
        let glyphIdx = layoutManager.glyphIndexForCharacter(at: clampedChar)
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: glyphIdx, length: 1))
        let newLineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        let intraY = min(anchor.intraLineOffsetY, max(0.0, newLineRect.height - 2.0))
        let targetY = newLineRect.minY + tv.textContainerOrigin.y + intraY
        let maxScrollY = max(0.0, tv.frame.height - scrollView.contentSize.height)
        let clampedY = max(0.0, min(maxScrollY, targetY))
        let maxScrollX = max(0.0, tv.frame.width - scrollView.contentSize.width)
        // The ruler overlays the clip view, so the document's left edge rests at a negative origin.
        // Clamping to 0 would push the leading characters of every line under the painted gutter.
        let restingX = CodeRulerGeometry.restingOriginX(in: scrollView)
        let targetX: CGFloat = isSoftWrapEnabled
            ? restingX
            : max(restingX, min(maxScrollX, scrollView.contentView.bounds.origin.x))
        return NSPoint(x: targetX, y: clampedY)
    }

    @objc func handleScroll(_ notification: Notification) {
        rulerView?.needsDisplay = true
        if isPartiallyMounted, let tv = textView, let scrollView = tv.enclosingScrollView {
            let visibleRect = scrollView.contentView.bounds
            let preloadMargin = max(480.0, visibleRect.height * 1.5)
            if visibleRect.maxY + preloadMargin >= tv.bounds.height {
                _ = appendNextPreviewChunk()
            }
        }
        scrollDebounceTask?.cancel()
        let capturedGen = documentGeneration
        scrollDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  let self,
                  self.documentGeneration == capturedGen,
                  let tv = self.textView else { return }
            if tv.hasMarkedText() {
                self.needsHighlightAfterMarkedText = true
                return
            }
            if (tv.textStorage?.length ?? 0) > 128_000 {
                self.highlightSyntaxProgressive(in: tv, fileName: self.parent.fileName)
            }
        }
    }

    internal func computeVisibleRange(in tv: NSTextView) -> NSRange {
        guard let layoutManager = tv.layoutManager,
              let textContainer = tv.textContainer else {
            let total = tv.textStorage?.length ?? 0
            return NSRange(location: 0, length: min(total, 32_000))
        }

        let visibleRect = tv.visibleRect
        let containerOrigin = tv.textContainerOrigin
        let rectInContainer = visibleRect.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rectInContainer, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let totalLength = tv.textStorage?.length ?? 0
        guard totalLength > 0 else { return NSRange(location: 0, length: 0) }

        let effectiveLocation = glyphRange.length > 0 ? charRange.location : 0
        let effectiveLength = glyphRange.length > 0 ? charRange.length : min(totalLength, 32_000)

        let margin = 16_000
        let start = max(0, effectiveLocation - margin)
        let end = min(totalLength, effectiveLocation + effectiveLength + margin)
        return NSRange(location: start, length: max(0, end - start))
    }

    internal func emitPerformanceMetrics(for fileName: String, generation: UInt64) {
        guard generation == documentGeneration else { return }
        let totalBytes = parent.totalSourceBytes > 0 ? parent.totalSourceBytes : Int64(fullPreviewUTF8Count)
        let lineCount = rulerView?.indexedLineCount ?? max(1, fullPreviewText.components(separatedBy: .newlines).count)
        let metrics = TTTextPreviewPerformanceMetrics(
            fileName: fileName, syntaxMode: activeSyntaxMode, totalSourceBytes: totalBytes,
            mountedUTF8Bytes: mountedUTF8ByteCount, lineCount: lineCount,
            sourceInspectDurationMs: parent.sourceInspectDurationMs,
            initialMountDurationMs: latestInitialMountDurationMs,
            lineStartScanDurationMs: latestLineStartScanDurationMs,
            firstHighlightBatchDurationMs: latestFirstHighlightDurationMs, generation: generation
        )
        lastPerformanceMetrics = metrics
        parent.onPerformanceMetrics?(metrics)
    }
}

// MARK: - Source File Encoding Detection & Byte Inspection

/// Detected character encoding of a text/markdown source file on disk.
public enum TTTextSourceEncoding: String, Sendable, Equatable, Hashable, CaseIterable {
    case utf8 = "UTF-8"
    case utf8BOM = "UTF-8 BOM"
    case utf16LE = "UTF-16LE"
    case utf16BE = "UTF-16BE"
    case utf32LE = "UTF-32LE"
    case utf32BE = "UTF-32BE"
    case gb18030 = "GB18030"
    case shiftJIS = "Shift-JIS"
    case big5 = "Big5"
    case nonUTF8Legacy = "NON-UTF-8"

    nonisolated public var displayBadge: String { rawValue }

    /// Whether in-place UTF-8 saving is safe without silently altering the file's character encoding.
    nonisolated public var allowsUTF8InPlaceSave: Bool {
        self == .utf8 || self == .utf8BOM
    }
}

/// Result of inspecting a source file's raw byte size, character encoding, and inspection latency.
public struct TTTextSourceInspection: Sendable, Equatable {
    public let byteCount: Int64
    public let encoding: TTTextSourceEncoding
    public let inspectDurationMs: Double

    nonisolated public init(
        byteCount: Int64,
        encoding: TTTextSourceEncoding,
        inspectDurationMs: Double = 0
    ) {
        self.byteCount = byteCount
        self.encoding = encoding
        self.inspectDurationMs = inspectDurationMs
    }

    nonisolated public static func inspect(
        url: URL?,
        fallbackText: String,
        explicitByteCount: Int64? = nil
    ) -> TTTextSourceInspection {
        let start = CFAbsoluteTimeGetCurrent()
        guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            let bytes = explicitByteCount ?? Int64(fallbackText.utf8.count)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return TTTextSourceInspection(byteCount: bytes, encoding: .utf8, inspectDurationMs: elapsedMs)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let diskBytes = (attrs?[.size] as? NSNumber)?.int64Value
            ?? Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? fallbackText.utf8.count)
        let sample = readSampleBytes(from: url, maxBytes: 64 * 1024)
        let encoding = classifyEncoding(sample: sample)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        return TTTextSourceInspection(
            byteCount: explicitByteCount ?? diskBytes,
            encoding: encoding,
            inspectDurationMs: elapsedMs
        )
    }

    nonisolated private static func readSampleBytes(from url: URL, maxBytes: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maxBytes)) ?? Data()
    }

    nonisolated public static func classifyEncoding(sample: Data) -> TTTextSourceEncoding {
        if sample.isEmpty { return .utf8 }
        if let bomEncoding = detectBOM(in: sample) {
            return bomEncoding
        }
        if hasNullBytePattern(in: sample) {
            return detectNullPatternEncoding(in: sample)
        }
        let trimmedSample = trimIncompleteUTF8Suffix(sample)
        if String(data: trimmedSample, encoding: .utf8) != nil {
            return .utf8
        }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if String(data: sample, encoding: gb18030) != nil {
            return .gb18030
        }
        if String(data: sample, encoding: .shiftJIS) != nil {
            return .shiftJIS
        }
        let big5 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)
            )
        )
        if String(data: sample, encoding: big5) != nil {
            return .big5
        }
        return .nonUTF8Legacy
    }

    nonisolated private static func detectBOM(in data: Data) -> TTTextSourceEncoding? {
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LE }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BE }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LE }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BE }
        return nil
    }

    nonisolated private static func hasNullBytePattern(in data: Data) -> Bool {
        data.prefix(512).contains(0x00)
    }

    nonisolated private static func detectNullPatternEncoding(in data: Data) -> TTTextSourceEncoding {
        let slice = Array(data.prefix(64))
        guard slice.count >= 2 else { return .nonUTF8Legacy }
        var evenZeros = 0
        var oddZeros = 0
        for idx in 0..<slice.count {
            if slice[idx] == 0 {
                if idx.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
            }
        }
        if oddZeros > evenZeros { return .utf16LE }
        if evenZeros > oddZeros { return .utf16BE }
        return .nonUTF8Legacy
    }

    nonisolated private static func trimIncompleteUTF8Suffix(_ data: Data) -> Data {
        guard data.count >= 4 else { return data }
        var end = data.count
        var trailingContinues = 0
        while end > 0 && trailingContinues < 3 && (data[end - 1] & 0b1100_0000) == 0b1000_0000 {
            end -= 1
            trailingContinues += 1
        }
        guard end > 0, end < data.count else { return data }
        let lead = data[end - 1]
        let expectedLen: Int
        if (lead & 0b1110_0000) == 0b1100_0000 { expectedLen = 2 }
        else if (lead & 0b1111_0000) == 0b1110_0000 { expectedLen = 3 }
        else if (lead & 0b1111_1000) == 0b1111_0000 { expectedLen = 4 }
        else { return data }
        let actualLen = data.count - (end - 1)
        return actualLen < expectedLen ? data.prefix(end - 1) : data
    }
}
