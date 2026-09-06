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

/// Container view for syntax-highlighted code and text editing.
/// Supports large text files (>2MB) without read-only locking, utilizing non-contiguous layout and progressive highlighting.
public struct CodeTextEditorContainerView: View {
    public let initialText: String
    public let fileURL: URL?
    public let fileName: String
    
    @State private var editedText: String = ""
    @State private var isEdited: Bool = false
    @State private var isSavedToastPresented: Bool = false
    @State private var isCopiedToastPresented: Bool = false
    @State private var saveErrorMessage: String? = nil
    @State private var showLineNumbers: Bool = true
    @State private var lineCount: Int = 1
    @State private var byteCount: Int64 = 0
    
    public init(initialText: String, fileURL: URL?, fileName: String) {
        self.initialText = initialText
        self.fileURL = fileURL
        self.fileName = fileName
        self._editedText = State(initialValue: initialText)
        self._byteCount = State(initialValue: Int64(initialText.utf8.count))
    }
    
    private var isWritableFile: Bool {
        guard let url = fileURL, url.isFileURL else { return false }
        return FileManager.default.isWritableFile(atPath: url.path)
    }
    
    public var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width <= 480
            VStack(spacing: 0) {
                // Header Bar
                headerBar(isCompact: isCompact)
                
                Divider()
                
                CodeHighlightingEditorNSView(
                    text: $editedText,
                    fileName: fileName,
                    showLineNumbers: showLineNumbers,
                    onTextChange: { newText in
                        if newText != initialText {
                            isEdited = true
                        }
                        updateMetrics(for: newText)
                    },
                    onSaveShortcut: {
                        if isEdited {
                            saveFile()
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: initialText) {
            editedText = initialText
            isEdited = false
            updateMetrics(for: initialText)
        }
    }
    
    // MARK: - Header Bar & Subviews
    
    @ViewBuilder
    private func headerBar(isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 6 : 8) {
            // 1. Language Tag (Unbroken single line with concise name)
            languageBadge(isCompact: isCompact)
            
            // 2. File Metrics (Size & Line Count, shown in regular mode)
            if !isCompact {
                fileMetricsCard
            }
            
            // 3. Unsaved indicator
            if isEdited {
                unsavedBadge
            }
            
            Spacer()
            
            // 4. Notifications (Save Error / Saved Toast)
            if let errorMsg = saveErrorMessage {
                saveErrorNotice(errorMsg)
            } else if isSavedToastPresented {
                savedToastView
            }
            
            // 5. Line numbers toggle button
            lineNumbersToggleButton
            
            // 6. Copy code button
            copyButton
            
            // 7. Save Button (Strictly guarded by isEdited and isWritableFile)
            if isWritableFile && isEdited {
                saveButton(isCompact: isCompact)
            }
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }
    
    private func languageBadge(isCompact: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "curlybraces")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text(languageName(isCompact: isCompact))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(TTZipTheme.bambooGreen.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    private var fileMetricsCard: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(fileSizeDescription) • \(lineCount) lines")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    private var unsavedBadge: some View {
        headerBadge(icon: "circle.fill", text: "Unsaved", color: .orange, bgColor: Color.orange.opacity(0.12))
    }
    
    private var savedToastView: some View {
        headerBadge(icon: "checkmark.circle.fill", text: "Saved", color: TTZipTheme.bambooGreen, bgColor: TTZipTheme.bambooGreen.opacity(0.12))
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
    
    private func saveErrorNotice(_ errorMsg: String) -> some View {
        headerBadge(icon: "exclamationmark.circle.fill", text: errorMsg, color: .red, bgColor: Color.red.opacity(0.1))
    }
    
    private func headerBadge(icon: String, text: String, color: Color, bgColor: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 10.5, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(bgColor)
        .clipShape(Capsule())
    }
    
    private var lineNumbersToggleButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                showLineNumbers.toggle()
            }
        }) {
            Image(systemName: "list.number")
                .font(.system(size: 11, weight: showLineNumbers ? .bold : .regular))
                .foregroundStyle(showLineNumbers ? TTZipTheme.bambooGreen : Color.primary.opacity(0.75))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(showLineNumbers ? TTZipTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(showLineNumbers ? "Hide Line Numbers" : "Show Line Numbers")
    }
    
    private var copyButton: some View {
        Button(action: { copyToClipboard() }) {
            Image(systemName: isCopiedToastPresented ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(isCopiedToastPresented ? TTZipTheme.bambooGreen : Color.primary.opacity(0.75))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isCopiedToastPresented ? TTZipTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isCopiedToastPresented ? "Copied to clipboard" : "Copy Source Code")
    }
    
    @ViewBuilder
    private func saveButton(isCompact: Bool) -> some View {
        Button(action: { saveFile() }) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(isCompact ? "Save" : "Save (⌘S)")
                    .font(.system(size: isCompact ? 10.5 : 11, weight: .bold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, isCompact ? 8 : 10)
            .padding(.vertical, 4)
            .background(TTZipTheme.bambooGreen)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command])
        .help("Save changes to local file (⌘S)")
    }
    
    // MARK: - Helper Methods
    
    private var fileSizeDescription: String {
        ByteCountFormatterFlyweight.shared.string(fromByteCount: byteCount)
    }
    
    private func updateMetrics(for text: String) {
        byteCount = Int64(text.utf8.count)
        lineCount = text.utf8.reduce(into: 1) { count, byte in
            if byte == 10 { count += 1 }
        }
    }
    
    private static let extensionMap: [String: String] = [
        "swift": "Swift", "kt": "Kotlin", "kts": "Kotlin", "java": "Java",
        "py": "Python", "js": "JavaScript", "jsx": "JavaScript", "ts": "TypeScript",
        "tsx": "TypeScript", "c": "C", "h": "C", "rs": "Rust", "go": "Go",
        "sh": "Shell", "bash": "Shell", "zsh": "Shell", "html": "HTML", "htm": "HTML",
        "css": "CSS", "scss": "CSS", "less": "CSS", "json": "JSON", "json5": "JSON",
        "yaml": "YAML", "yml": "YAML", "md": "Markdown", "markdown": "Markdown", "sql": "SQL"
    ]
    
    private func languageName(isCompact: Bool) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let mapped = Self.extensionMap[ext] {
            return mapped
        }
        switch ext {
        case "cpp", "hpp", "cc", "cxx", "m", "mm":
            return isCompact ? "C++" : "C++ / ObjC"
        case "xml", "plist":
            return isCompact ? "XML" : "XML / Plist"
        default:
            return ext.isEmpty ? "Plain Text" : ext.uppercased()
        }
    }
    
    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(editedText, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            isCopiedToastPresented = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                isCopiedToastPresented = false
            }
        }
    }
    
    private func saveFile() {
        guard isEdited, let url = fileURL, url.isFileURL, isWritableFile else { return }
        do {
            try editedText.write(to: url, atomically: true, encoding: .utf8)
            withAnimation(.easeInOut(duration: 0.2)) {
                isEdited = false
                isSavedToastPresented = true
                saveErrorMessage = nil
            }
            updateMetrics(for: editedText)
            NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isSavedToastPresented = false
                }
            }
        } catch {
            withAnimation {
                saveErrorMessage = error.localizedDescription
            }
        }
    }
}

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
        textView.textContainerInset = NSSize(width: 14, height: 14)
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
        
        if storage.string != text {
            context.coordinator.isProgrammaticUpdate = true
            storage.beginEditing()
            storage.setAttributedString(Self.createAttributedString(from: text))
            storage.endEditing()
            context.coordinator.isProgrammaticUpdate = false
            context.coordinator.highlightSyntaxProgressive(in: textView, fileName: fileName)
            if let ruler = nsView.verticalRulerView as? LineNumberRulerView {
                ruler.updateLineStarts(for: text)
                ruler.needsDisplay = true
            }
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
