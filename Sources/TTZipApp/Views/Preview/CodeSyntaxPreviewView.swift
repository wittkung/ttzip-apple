// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore

/// Container view for syntax-highlighted code and text editing.
/// Supports large text files (>2MB) without read-only locking, utilizing non-contiguous layout and progressive highlighting.
public struct CodeTextEditorContainerView: View {
    public let initialText: String
    public let fileURL: URL?
    public let fileName: String
    
    @State private var editedText: String = ""
    @State private var isEdited: Bool = false
    @State private var isSavedToastPresented: Bool = false
    @State private var saveErrorMessage: String? = nil
    @State private var lineCount: Int = 1
    @State private var byteCount: Int64 = 0
    
    public init(initialText: String, fileURL: URL?, fileName: String) {
        self.initialText = initialText
        self.fileURL = fileURL
        self.fileName = fileName
        self._editedText = State(initialValue: initialText)
        self._byteCount = State(initialValue: Int64(initialText.utf8.count))
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 8) {
                // Language Tag
                HStack(spacing: 5) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                    Text(languageName)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(TTZipTheme.bambooGreen.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                
                // File Metrics (Size & Line Count)
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(fileSizeDescription) • \(lineCount) lines")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                
                // Unsaved indicator
                if isEdited {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text("Unsaved")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.orange)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
                }
                
                Spacer()
                
                // Saved Toast
                if isSavedToastPresented {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Saved to disk")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                
                // Save Error Notice
                if let errorMsg = saveErrorMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(errorMsg)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                
                // Save Button
                if let url = fileURL, url.isFileURL {
                    Button(action: { saveFile() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("Save (⌘S)")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(isEdited ? Color.white : TTZipTheme.bambooGreen)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(isEdited ? TTZipTheme.bambooGreen : TTZipTheme.bambooGreen.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("s", modifiers: [.command])
                    .help("Save changes to local file (⌘S)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03))
            
            Divider()
            
            CodeHighlightingEditorNSView(
                text: $editedText,
                fileName: fileName,
                onTextChange: { newText in
                    if newText != initialText {
                        isEdited = true
                    }
                    updateMetrics(for: newText)
                },
                onSaveShortcut: {
                    saveFile()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: initialText) {
            editedText = initialText
            isEdited = false
            updateMetrics(for: initialText)
        }
    }
    
    private var fileSizeDescription: String {
        ByteCountFormatterFlyweight.shared.string(fromByteCount: byteCount)
    }
    
    private func updateMetrics(for text: String) {
        byteCount = Int64(text.utf8.count)
        var count = 1
        for char in text {
            if char == "\n" {
                count += 1
            }
        }
        lineCount = count
    }
    
    private var languageName: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "Swift Code"
        case "kt", "kts": return "Kotlin Code"
        case "java": return "Java Source"
        case "py": return "Python Script"
        case "js", "jsx": return "JavaScript"
        case "ts", "tsx": return "TypeScript"
        case "c", "h": return "C Source"
        case "cpp", "hpp", "cc", "cxx", "m", "mm": return "C++ / ObjC"
        case "rs": return "Rust Source"
        case "go": return "Go Source"
        case "sh", "bash", "zsh": return "Shell Script"
        case "html", "htm": return "HTML Document"
        case "css", "scss", "less": return "CSS Stylesheet"
        case "json", "json5": return "JSON File"
        case "xml", "plist": return "XML / Plist"
        case "yaml", "yml": return "YAML Config"
        case "md", "markdown": return "Markdown Document"
        case "sql": return "SQL Script"
        default: return ext.isEmpty ? "Plain Text" : "\(ext.uppercased()) Text"
        }
    }
    
    private func saveFile() {
        guard let url = fileURL, url.isFileURL else { return }
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

/// High-performance NSViewRepresentable wrapper around NSTextView with TextKit non-contiguous layout and progressive streaming syntax highlighting.
public struct CodeHighlightingEditorNSView: NSViewRepresentable {
    @Binding public var text: String
    public let fileName: String
    public var onTextChange: ((String) -> Void)? = nil
    public var onSaveShortcut: (() -> Void)? = nil
    
    public init(
        text: Binding<String>,
        fileName: String,
        onTextChange: ((String) -> Void)? = nil,
        onSaveShortcut: (() -> Void)? = nil
    ) {
        self._text = text
        self.fileName = fileName
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
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        
        textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 14, height: 14)
        
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        
        textView.delegate = context.coordinator
        textView.onSaveShortcut = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSaveShortcut?()
        }
        context.coordinator.textView = textView
        
        // Populate initial text
        context.coordinator.isProgrammaticUpdate = true
        textStorage.beginEditing()
        let attrStr = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
        textStorage.setAttributedString(attrStr)
        textStorage.endEditing()
        context.coordinator.isProgrammaticUpdate = false
        
        context.coordinator.highlightSyntaxProgressive(in: textView, fileName: fileName)
        
        // Scroll notification observer for viewport-aware progressive re-coloring
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
        
        if storage.string != text {
            context.coordinator.isProgrammaticUpdate = true
            storage.beginEditing()
            let attrStr = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                    .foregroundColor: NSColor.labelColor
                ]
            )
            storage.setAttributedString(attrStr)
            storage.endEditing()
            context.coordinator.isProgrammaticUpdate = false
            context.coordinator.highlightSyntaxProgressive(in: textView, fileName: fileName)
        }
    }
    
    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeHighlightingEditorNSView
        weak var textView: LargeTextEditorTextView?
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
            
            currentHighlightTask?.cancel()
            debounceTask?.cancel()
            debounceTask = Task { @MainActor [weak self, weak tv] in
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled, let self = self, let textView = tv else { return }
                self.highlightSyntaxProgressive(in: textView, fileName: self.parent.fileName)
            }
        }
        
        @objc func handleScroll(_ notification: Notification) {
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
        
        public func highlightSyntaxProgressive(in tv: NSTextView, fileName: String) {
            guard let storage = tv.textStorage else { return }
            let currentLength = storage.length
            guard currentLength > 0 else { return }
            
            let snapshotText = storage.string
            let ext = (fileName as NSString).pathExtension.lowercased()
            let visibleRange = computeVisibleRange(in: tv)
            
            let commentColor = NSColor(red: 0.45, green: 0.60, blue: 0.40, alpha: 1.0)
            let stringColor = NSColor(red: 0.85, green: 0.55, blue: 0.40, alpha: 1.0)
            let keywordColor = NSColor(red: 0.35, green: 0.65, blue: 0.90, alpha: 1.0)
            let numberColor = NSColor(red: 0.70, green: 0.80, blue: 0.60, alpha: 1.0)
            let typeColor = NSColor(red: 0.30, green: 0.80, blue: 0.70, alpha: 1.0)
            let defaultColor = NSColor.labelColor
            let defaultFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let semiboldFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
            
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
                        
                        storage.beginEditing()
                        let fullRange = NSRange(location: 0, length: storage.length)
                        storage.setAttributes([
                            .font: defaultFont,
                            .foregroundColor: defaultColor
                        ], range: fullRange)
                        
                        for token in tokens {
                            guard token.range.location + token.range.length <= storage.length else { continue }
                            switch token.colorType {
                            case .comment:
                                storage.addAttribute(.foregroundColor, value: commentColor, range: token.range)
                            case .string:
                                storage.addAttribute(.foregroundColor, value: stringColor, range: token.range)
                            case .keyword:
                                storage.addAttribute(.foregroundColor, value: keywordColor, range: token.range)
                                storage.addAttribute(.font, value: semiboldFont, range: token.range)
                            case .number:
                                storage.addAttribute(.foregroundColor, value: numberColor, range: token.range)
                            case .type:
                                storage.addAttribute(.foregroundColor, value: typeColor, range: token.range)
                            }
                        }
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
                        
                        storage.beginEditing()
                        
                        if isFirstBatch {
                            let resetRange = NSIntersectionRange(visibleRange, NSRange(location: 0, length: storage.length))
                            if resetRange.length > 0 {
                                storage.setAttributes([
                                    .font: defaultFont,
                                    .foregroundColor: defaultColor
                                ], range: resetRange)
                            }
                            isFirstBatch = false
                        }
                        
                        for token in batch.spans {
                            guard token.range.location + token.range.length <= storage.length else { continue }
                            switch token.colorType {
                            case .comment:
                                storage.addAttribute(.foregroundColor, value: commentColor, range: token.range)
                            case .string:
                                storage.addAttribute(.foregroundColor, value: stringColor, range: token.range)
                            case .keyword:
                                storage.addAttribute(.foregroundColor, value: keywordColor, range: token.range)
                                storage.addAttribute(.font, value: semiboldFont, range: token.range)
                            case .number:
                                storage.addAttribute(.foregroundColor, value: numberColor, range: token.range)
                            case .type:
                                storage.addAttribute(.foregroundColor, value: typeColor, range: token.range)
                            }
                        }
                        storage.endEditing()
                    }
                    
                    await Task.yield()
                }
            }
        }
    }
}
