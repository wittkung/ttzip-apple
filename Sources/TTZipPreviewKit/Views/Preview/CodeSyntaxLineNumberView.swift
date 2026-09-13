// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit

/// Custom NSTextView with keyboard shortcut routing, tab handling, and non-contiguous layout.
final class LargeTextEditorTextView: NSTextView {
    var onSaveShortcut: (() -> Void)?
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            if let onSave = onSaveShortcut {
                onSave()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    
    override func insertTab(_ sender: Any?) {
        if isEditable {
            insertText("    ", replacementRange: selectedRange())
        } else {
            super.insertTab(sender)
        }
    }
}

/// Minimalist line number gutter view conforming to WSJ editorial and Zen typography standards.
/// Employs 10.5pt monospace tertiary label color font, right-alignment, and specular hairline separator.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    
    private static let lineNumberFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let rightAlignedStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return style
    }()
    
    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.clientView = textView
        updateRuleThickness()
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var isFlipped: Bool { true }
    
    func updateLineStarts(for text: String) {
        var starts: [Int] = [0]
        var utf16Index = 0
        for codeUnit in text.utf16 {
            utf16Index += 1
            if codeUnit == 10 { // UTF-16 code unit for '\n'
                starts.append(utf16Index)
            }
        }
        self.lineStarts = starts
        updateRuleThickness()
    }
    
    private func updateRuleThickness() {
        let digits = max(2, String(lineStarts.count).count)
        let required = max(34.0, CGFloat(digits) * 7.5 + 16.0)
        if abs(ruleThickness - required) > 0.5 {
            ruleThickness = required
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        // 1. Transparent Zen background allowing paper/charcoal material to shine through
        NSColor.clear.setFill()
        dirtyRect.fill()
        
        // 2. Specular hairline separator on the right edge
        let separatorX = bounds.width - 0.5
        let separatorPath = NSBezierPath()
        separatorPath.move(to: NSPoint(x: separatorX, y: dirtyRect.minY))
        separatorPath.line(to: NSPoint(x: separatorX, y: dirtyRect.maxY))
        separatorPath.lineWidth = 0.5
        NSColor.separatorColor.withAlphaComponent(0.2).setStroke()
        separatorPath.stroke()
        
        // 3. Draw line numbers for visible paragraphs
        guard let textView = self.clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }
        
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.lineNumberFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: Self.rightAlignedStyle
        ]
        
        if lineStarts.isEmpty || (lineStarts.count == 1 && textView.string.isEmpty) {
            let dummyRect = NSRect(x: 0, y: textView.textContainerOrigin.y, width: 10, height: 16)
            let rectInRuler = self.convert(dummyRect, from: textView)
            let labelRect = NSRect(x: 2, y: rectInRuler.origin.y + 1.0, width: bounds.width - 10, height: 16)
            "1".draw(in: labelRect, withAttributes: textAttrs)
            return
        }
        
        // Binary search to find starting line index within viewport
        var low = 0
        var high = lineStarts.count - 1
        var startLineIndex = 0
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= charRange.location {
                startLineIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        
        for lineIdx in startLineIndex..<lineStarts.count {
            let charPos = lineStarts[lineIdx]
            if charPos > NSMaxRange(charRange) && lineIdx > startLineIndex {
                break
            }
            
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: min(charPos, max(0, layoutManager.numberOfGlyphs - 1)))
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            guard lineRect.height > 0 else { continue }
            let textRect = lineRect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            let rulerRect = self.convert(textRect, from: textView)
            
            if rulerRect.maxY < dirtyRect.minY { continue }
            if rulerRect.minY > dirtyRect.maxY { break }
            
            let labelRect = NSRect(x: 2, y: rulerRect.origin.y + 1.0, width: bounds.width - 10, height: rulerRect.height)
            "\(lineIdx + 1)".draw(in: labelRect, withAttributes: textAttrs)
        }
    }
}
