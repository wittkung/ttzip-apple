// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// High-performance NSViewRepresentable wrapper around NSTextView with TextKit non-contiguous layout and progressive streaming syntax highlighting.
public struct CodeHighlightingEditorNSView: NSViewRepresentable {
    @Binding public var text: String
    public let fileName: String
    public let showLineNumbers: Bool
    public var onTextChange: ((String) -> Void)? = nil
    public var onSaveShortcut: (() -> Void)? = nil
    
    /// Dedicated paragraph style providing WSJ/Zen comfortable 4.0pt line spacing.
    public static let codeParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4.0
        return style
    }()
    
    public static func createAttributedString(from text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: codeParagraphStyle
            ]
        )
    }
    
    public init(
        text: Binding<String>,
        fileName: String,
        showLineNumbers: Bool = true,
        onTextChange: ((String) -> Void)? = nil,
        onSaveShortcut: (() -> Void)? = nil
    ) {
        self._text = text
        self.fileName = fileName
        self.showLineNumbers = showLineNumbers
        self.onTextChange = onTextChange
        self.onSaveShortcut = onSaveShortcut
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        
        let contentSize = scrollView.contentSize
        
        // TextKit Layout Architecture with Non-Contiguous Background Layout
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.backgroundLayoutEnabled = true
        textStorage.addLayoutManager(layoutManager)
        
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.addTextContainer(textContainer)
        
        let textView = LargeTextEditorTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.enabledTextCheckingTypes = 0
        
        textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        let digits = max(2, String(text.split(separator: "\n", omittingEmptySubsequences: false).count).count)
        let initialGutterWidth = showLineNumbers ? max(36.0, CGFloat(digits) * 8.0 + 16.0) : 0
        textView.textContainerInset = NSSize(width: showLineNumbers ? (initialGutterWidth + 12.0) : 14.0, height: 14.0)
        textView.defaultParagraphStyle = Self.codeParagraphStyle
        
        var typingAttrs = textView.typingAttributes
        typingAttrs[.paragraphStyle] = Self.codeParagraphStyle
        typingAttrs[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        typingAttrs[.foregroundColor] = NSColor.labelColor
        textView.typingAttributes = typingAttrs
        
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        
        textView.delegate = context.coordinator
        textView.onSaveShortcut = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSaveShortcut?()
        }
        context.coordinator.textView = textView
        
        // Setup Line Number Gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = showLineNumbers
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        ruler.updateLineStarts(for: text)
        scrollView.verticalRulerView = ruler
        context.coordinator.rulerView = ruler
        
        // Populate initial text with 4.0 line spacing paragraph style
        context.coordinator.isProgrammaticUpdate = true
        textStorage.beginEditing()
        textStorage.setAttributedString(Self.createAttributedString(from: text))
        textStorage.endEditing()
        context.coordinator.isProgrammaticUpdate = false
        
        context.coordinator.highlightSyntaxProgressive(in: textView, fileName: fileName)
        
        // Scroll notification observer for viewport-aware progressive re-coloring and ruler redraw
        scrollView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        
        scrollView.documentView = textView
        return scrollView
    }
    
    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? LargeTextEditorTextView,
              let storage = textView.textStorage else { return }
        
        textView.onSaveShortcut = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSaveShortcut?()
        }
        
        if nsView.rulersVisible != showLineNumbers {
            nsView.rulersVisible = showLineNumbers
        }
        
        let ruler = nsView.verticalRulerView as? LineNumberRulerView
        if storage.string != text {
            context.coordinator.isProgrammaticUpdate = true
            storage.beginEditing()
            storage.setAttributedString(Self.createAttributedString(from: text))
            storage.endEditing()
            context.coordinator.isProgrammaticUpdate = false
            context.coordinator.highlightSyntaxProgressive(in: textView, fileName: fileName)
            if let ruler = ruler {
                ruler.updateLineStarts(for: text)
                ruler.needsDisplay = true
            }
        }
        
        let leftInset: CGFloat = showLineNumbers ? ((ruler?.ruleThickness ?? 36.0) + 12.0) : 14.0
        if textView.textContainerInset.width != leftInset {
            textView.textContainerInset = NSSize(width: leftInset, height: 14.0)
        }
    }
    
    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeHighlightingEditorNSView
        weak var textView: LargeTextEditorTextView?
        weak var rulerView: LineNumberRulerView?
        var isProgrammaticUpdate: Bool = false
        
        private var debounceTask: Task<Void, Never>?
        private var scrollDebounceTask: Task<Void, Never>?
        private var currentHighlightTask: Task<Void, Never>?
        
        init(_ parent: CodeHighlightingEditorNSView) {
            self.parent = parent
            super.init()
        }
        
        nonisolated deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        public func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, let tv = notification.object as? NSTextView else { return }
            let newText = tv.string
            parent.text = newText
            parent.onTextChange?(newText)
            
            rulerView?.updateLineStarts(for: newText)
            rulerView?.needsDisplay = true
            
            currentHighlightTask?.cancel()
            debounceTask?.cancel()
            debounceTask = Task { @MainActor [weak self, weak tv] in
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled, let self = self, let textView = tv else { return }
                self.highlightSyntaxProgressive(in: textView, fileName: self.parent.fileName)
            }
        }
        
        @objc func handleScroll(_ notification: Notification) {
            rulerView?.needsDisplay = true
            scrollDebounceTask?.cancel()
            scrollDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self = self, let tv = self.textView else { return }
                if (tv.textStorage?.length ?? 0) > 128_000 {
                    self.highlightSyntaxProgressive(in: tv, fileName: self.parent.fileName)
                }
            }
        }
        
        private func computeVisibleRange(in tv: NSTextView) -> NSRange {
            guard let layoutManager = tv.layoutManager,
                  let textContainer = tv.textContainer,
                  let scrollView = tv.enclosingScrollView else {
                let total = tv.textStorage?.length ?? 0
                return NSRange(location: 0, length: min(total, 32_000))
            }
            
            let visibleRect = scrollView.contentView.bounds
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            
            let margin = 16_000
            let start = max(0, charRange.location - margin)
            let end = min(tv.textStorage?.length ?? 0, charRange.location + charRange.length + margin)
            return NSRange(location: start, length: max(0, end - start))
        }
        
        @MainActor
        private struct SyntaxPalette {
            let comment = NSColor(red: 0.45, green: 0.60, blue: 0.40, alpha: 1.0)
            let string = NSColor(red: 0.85, green: 0.55, blue: 0.40, alpha: 1.0)
            let keyword = NSColor(red: 0.35, green: 0.65, blue: 0.90, alpha: 1.0)
            let number = NSColor(red: 0.70, green: 0.80, blue: 0.60, alpha: 1.0)
            let type = NSColor(red: 0.30, green: 0.80, blue: 0.70, alpha: 1.0)
            let defaultColor = NSColor.labelColor
            let defaultFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let semiboldFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
            
            static let shared = SyntaxPalette()
        }
        
        private func applyTokens(_ tokens: [TokenSpan], to storage: NSTextStorage, palette: SyntaxPalette) {
            for token in tokens {
                guard token.range.location + token.range.length <= storage.length else { continue }
                switch token.colorType {
                case .comment:
                    storage.addAttribute(.foregroundColor, value: palette.comment, range: token.range)
                case .string:
                    storage.addAttribute(.foregroundColor, value: palette.string, range: token.range)
                case .keyword:
                    storage.addAttribute(.foregroundColor, value: palette.keyword, range: token.range)
                    storage.addAttribute(.font, value: palette.semiboldFont, range: token.range)
                case .number:
                    storage.addAttribute(.foregroundColor, value: palette.number, range: token.range)
                case .type:
                    storage.addAttribute(.foregroundColor, value: palette.type, range: token.range)
                }
            }
        }
        
        public func highlightSyntaxProgressive(in tv: NSTextView, fileName: String) {
            guard let storage = tv.textStorage else { return }
            let currentLength = storage.length
            guard currentLength > 0 else { return }
            
            let snapshotText = storage.string
            let ext = (fileName as NSString).pathExtension.lowercased()
            let visibleRange = computeVisibleRange(in: tv)
            
            // Fast path for small documents (<128KB)
            if currentLength < 128_000 {
                currentHighlightTask?.cancel()
                currentHighlightTask = Task {
                    let tokens = await BackgroundSyntaxTokenizer.shared.tokenize(
                        text: snapshotText,
                        ext: ext,
                        targetRange: NSRange(location: 0, length: currentLength)
                    )
                    guard !Task.isCancelled else { return }
                    
                    await MainActor.run {
                        guard !Task.isCancelled,
                              tv.textStorage === storage,
                              storage.string == snapshotText else { return }
                        
                        let palette = SyntaxPalette.shared
                        storage.beginEditing()
                        let fullRange = NSRange(location: 0, length: storage.length)
                        storage.setAttributes([
                            .font: palette.defaultFont,
                            .foregroundColor: palette.defaultColor,
                            .paragraphStyle: CodeHighlightingEditorNSView.codeParagraphStyle
                        ], range: fullRange)
                        
                        self.applyTokens(tokens, to: storage, palette: palette)
                        storage.endEditing()
                    }
                }
                return
            }
            
            // Progressive streaming batch path for large documents (>128KB, up to tens of MBs)
            currentHighlightTask?.cancel()
            currentHighlightTask = Task {
                let stream = await BackgroundSyntaxTokenizer.shared.tokenizeStream(
                    text: snapshotText,
                    ext: ext,
                    priorityRange: visibleRange,
                    batchSize: 2000
                )
                
                var isFirstBatch = true
                for await batch in stream {
                    guard !Task.isCancelled else { return }
                    
                    await MainActor.run {
                        guard !Task.isCancelled,
                              tv.textStorage === storage,
                              storage.string == snapshotText else { return }
                        
                        let palette = SyntaxPalette.shared
                        storage.beginEditing()
                        if isFirstBatch {
                            let resetRange = NSIntersectionRange(visibleRange, NSRange(location: 0, length: storage.length))
                            if resetRange.length > 0 {
                                storage.setAttributes([
                                    .font: palette.defaultFont,
                                    .foregroundColor: palette.defaultColor,
                                    .paragraphStyle: CodeHighlightingEditorNSView.codeParagraphStyle
                                ], range: resetRange)
                            }
                            isFirstBatch = false
                        }
                        
                        self.applyTokens(batch.spans, to: storage, palette: palette)
                        storage.endEditing()
                    }
                    
                    await Task.yield()
                }
            }
        }
    }
}
