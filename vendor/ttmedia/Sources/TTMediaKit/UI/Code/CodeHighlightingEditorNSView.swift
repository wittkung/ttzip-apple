// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// High-performance NSViewRepresentable wrapper around NSTextView with TextKit non-contiguous layout,
/// 3-state reading background synchronization, plain-text vs. code syntax policy, and generation-guarded progressive highlighting.
public struct CodeHighlightingEditorNSView: NSViewRepresentable {
    /// Maximum UTF-8 byte budget for interactive text preview and in-place editing (2 MB).
    nonisolated public static let maxInteractiveTextUTF8Bytes: Int = CodeTextEditorContainerView.maxInteractiveTextUTF8Bytes

    /// Initial UTF-8 byte budget mounted synchronously for first-screen rendering (64 KB).
    nonisolated public static let initialMountUTF8Bytes: Int = CodeTextEditorContainerView.initialMountUTF8Bytes

    /// Incremental UTF-8 byte budget appended per scroll/search chunk step (128 KB).
    nonisolated public static let chunkStepUTF8Bytes: Int = CodeTextEditorContainerView.chunkStepUTF8Bytes

    @Binding public var text: String
    public var fileName: String
    public let showLineNumbers: Bool
    public let isEditable: Bool
    public var isSoftWrapEnabled: Bool
    public var readingBackgroundMode: TTTextReadingBackgroundMode
    public var isDarkAppearance: Bool
    public var fontSize: CGFloat
    public var textContainerInset: NSSize
    public var syntaxModeOverride: TTTextSyntaxRenderMode?
    public var totalSourceBytes: Int64
    public var sourceInspectDurationMs: Double
    public var onTextChange: ((String) -> Void)? = nil
    public var onSaveShortcut: (() -> Void)? = nil
    public var onPerformanceMetrics: ((TTTextPreviewPerformanceMetrics) -> Void)? = nil

    public var isTruncatedForPreview: Bool {
        text.utf8.count > Self.maxInteractiveTextUTF8Bytes
    }

    public var effectiveIsEditable: Bool {
        isEditable && !isTruncatedForPreview
    }

    public var resolvedReadingPalette: TTTextReadingPalette {
        TTTextReadingPalette.resolve(mode: readingBackgroundMode, isDarkAppearance: isDarkAppearance)
    }

    public var resolvedSyntaxMode: TTTextSyntaxRenderMode {
        TTTextSyntaxRenderMode.resolve(fileName: fileName, overrideMode: syntaxModeOverride)
    }

    /// Dedicated paragraph style providing comfortable 4.0pt line spacing.
    public static let codeParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4.0
        return style
    }()

    public static func createAttributedString(
        from text: String,
        foregroundColor: NSColor = NSColor(srgbRed: 0.925, green: 0.929, blue: 0.941, alpha: 1.0),
        fontSize: CGFloat = 12.5
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: foregroundColor,
                .paragraphStyle: codeParagraphStyle
            ]
        )
    }

    public init(
        text: Binding<String>,
        fileName: String,
        showLineNumbers: Bool = true,
        isEditable: Bool = false,
        isSoftWrapEnabled: Bool = TTTextReadingPreferenceStore.defaultSoftWrapEnabled,
        readingBackgroundMode: TTTextReadingBackgroundMode = .fluidTransparent,
        isDarkAppearance: Bool = true,
        fontSize: CGFloat = 12.5,
        textContainerInset: NSSize = NSSize(width: 8.0, height: 8.0),
        syntaxModeOverride: TTTextSyntaxRenderMode? = nil,
        totalSourceBytes: Int64 = 0,
        sourceInspectDurationMs: Double = 0,
        onTextChange: ((String) -> Void)? = nil,
        onSaveShortcut: (() -> Void)? = nil,
        onPerformanceMetrics: ((TTTextPreviewPerformanceMetrics) -> Void)? = nil
    ) {
        self._text = text
        self.fileName = fileName
        self.showLineNumbers = showLineNumbers
        self.isEditable = isEditable
        self.isSoftWrapEnabled = isSoftWrapEnabled
        self.readingBackgroundMode = readingBackgroundMode
        self.isDarkAppearance = isDarkAppearance
        self.fontSize = fontSize
        self.textContainerInset = textContainerInset
        self.syntaxModeOverride = syntaxModeOverride
        self.totalSourceBytes = totalSourceBytes
        self.sourceInspectDurationMs = sourceInspectDurationMs
        self.onTextChange = onTextChange
        self.onSaveShortcut = onSaveShortcut
        self.onPerformanceMetrics = onPerformanceMetrics
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        makeEditorScrollView(coordinator: context.coordinator)
    }

    internal func makeEditorScrollView(coordinator: Coordinator) -> NSScrollView {
        let palette = resolvedReadingPalette
        let scrollView = configureScrollView(palette: palette)
        let contentSize = scrollView.contentSize
        let (textStorage, textContainer) = makeNonContiguousTextSystem(contentSize: contentSize)
        coordinator.textStorageRef = textStorage

        let (displayString, truncated) = CodeTextEditorContainerView.truncateForPreview(text)
        let allowEditing = isEditable && !truncated

        let textView = configureTextView(
            contentSize: contentSize,
            textContainer: textContainer,
            allowEditing: allowEditing,
            palette: palette,
            coordinator: coordinator
        )
        coordinator.textView = textView

        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = showLineNumbers
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        ruler.readingPalette = palette
        scrollView.verticalRulerView = ruler
        coordinator.rulerView = ruler
        textView.textContainerInset = textContainerInset

        coordinator.applyReadingTheme(
            palette,
            to: textView,
            scrollView: scrollView,
            recolorStorage: false
        )
        coordinator.mountInitialPreview(
            displayString: displayString,
            in: textView,
            storage: textStorage,
            fileName: fileName
        )

        scrollView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.handleScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        scrollView.documentView = textView
        (scrollView as? CodePreviewScrollView)?.chunkCoordinator = coordinator
        coordinator.applySoftWrapConfiguration(
            isSoftWrapEnabled: isSoftWrapEnabled,
            to: textView,
            scrollView: scrollView,
            preserveAnchor: false
        )
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        applyUpdate(to: nsView, coordinator: context.coordinator)
    }

    public func applyUpdate(to nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.parent = self
        guard let textView = nsView.documentView as? LargeTextEditorTextView else { return }

        let (displayString, truncated) = CodeTextEditorContainerView.truncateForPreview(text)
        let allowEditing = isEditable && !truncated
        let currentPalette = resolvedReadingPalette

        textView.onSaveShortcut = allowEditing ? { [weak coordinator] in
            guard let coordinator, coordinator.parent.effectiveIsEditable else { return }
            coordinator.parent.onSaveShortcut?()
        } : nil

        if nsView.rulersVisible != showLineNumbers {
            nsView.rulersVisible = showLineNumbers
        }

        if textView.textContainerInset != textContainerInset {
            textView.textContainerInset = textContainerInset
        }

        if coordinator.shouldRemount(displayString: displayString, fileName: fileName) {
            coordinator.applyReadingTheme(
                currentPalette,
                to: textView,
                scrollView: nsView,
                recolorStorage: false
            )
            coordinator.applySoftWrapConfiguration(
                isSoftWrapEnabled: isSoftWrapEnabled,
                to: textView,
                scrollView: nsView,
                preserveAnchor: false
            )
            coordinator.mountInitialPreview(
                displayString: displayString,
                in: textView,
                fileName: fileName
            )
        } else {
            if coordinator.activeReadingPalette != currentPalette || abs(coordinator.activeFontSize - fontSize) > 0.05 {
                coordinator.applyReadingTheme(
                    currentPalette,
                    to: textView,
                    scrollView: nsView,
                    recolorStorage: true
                )
            }
            if coordinator.activeSoftWrapEnabled != isSoftWrapEnabled {
                coordinator.applySoftWrapConfiguration(
                    isSoftWrapEnabled: isSoftWrapEnabled,
                    to: textView,
                    scrollView: nsView,
                    preserveAnchor: true
                )
            }
        }

        if textView.isEditable != allowEditing {
            textView.isEditable = allowEditing
            textView.allowsUndo = allowEditing
        }
    }

    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPendingTasks()
    }

    private func configureScrollView(palette: TTTextReadingPalette) -> NSScrollView {
        let scrollView = CodePreviewScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !isSoftWrapEnabled
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = palette.drawsOpaqueBackground
        scrollView.backgroundColor = palette.nsCanvasBackgroundColor
        scrollView.contentView.drawsBackground = palette.drawsOpaqueBackground
        scrollView.contentView.backgroundColor = palette.nsCanvasBackgroundColor
        return scrollView
    }

    private func makeNonContiguousTextSystem(contentSize: NSSize) -> (NSTextStorage, NSTextContainer) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.backgroundLayoutEnabled = true
        textStorage.addLayoutManager(layoutManager)

        let initialContainerWidth = isSoftWrapEnabled
            ? (contentSize.width > 0 ? max(1.0, contentSize.width - textContainerInset.width * 2.0) : 0.0)
            : CGFloat.greatestFiniteMagnitude
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: initialContainerWidth > 0 ? initialContainerWidth : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = isSoftWrapEnabled
        layoutManager.addTextContainer(textContainer)
        return (textStorage, textContainer)
    }

    private func configureTextView(
        contentSize: NSSize,
        textContainer: NSTextContainer,
        allowEditing: Bool,
        palette: TTTextReadingPalette,
        coordinator: Coordinator
    ) -> LargeTextEditorTextView {
        let textView = LargeTextEditorTextView(
            frame: NSRect(origin: .zero, size: contentSize),
            textContainer: textContainer
        )
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = allowEditing
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = allowEditing
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.enabledTextCheckingTypes = 0

        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = palette.nsForegroundColor
        textView.backgroundColor = palette.nsCanvasBackgroundColor
        textView.drawsBackground = palette.drawsOpaqueBackground
        textView.insertionPointColor = palette.nsInsertionPointColor
        textView.selectedTextAttributes = [
            .backgroundColor: palette.nsSelectionBackgroundColor,
            .foregroundColor: palette.nsSelectionTextColor
        ]
        textView.textContainerInset = textContainerInset
        textView.defaultParagraphStyle = Self.codeParagraphStyle

        var typingAttrs = textView.typingAttributes
        typingAttrs[.paragraphStyle] = Self.codeParagraphStyle
        typingAttrs[.font] = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        typingAttrs[.foregroundColor] = palette.nsForegroundColor
        textView.typingAttributes = typingAttrs

        textView.isHorizontallyResizable = !isSoftWrapEnabled
        textView.isVerticallyResizable = true
        let initialMaxWidth = isSoftWrapEnabled && contentSize.width > 0
            ? contentSize.width
            : CGFloat.greatestFiniteMagnitude
        textView.maxSize = NSSize(width: initialMaxWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: max(0.0, contentSize.width), height: contentSize.height)

        textView.delegate = coordinator
        textView.chunkCoordinator = coordinator
        textView.onSaveShortcut = allowEditing ? { [weak coordinator] in
            guard let coordinator, coordinator.parent.effectiveIsEditable else { return }
            coordinator.parent.onSaveShortcut?()
        } : nil
        coordinator.textView = textView
        return textView
    }
}

// MARK: - Coordinator & Progressive Syntax Highlighting

extension CodeHighlightingEditorNSView {
    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeHighlightingEditorNSView
        var textStorageRef: NSTextStorage?
        weak var textView: LargeTextEditorTextView?
        weak var rulerView: LineNumberRulerView?
        var isProgrammaticUpdate: Bool = false

        public internal(set) var documentGeneration: UInt64 = 0
        internal var needsHighlightAfterMarkedText: Bool = false
        public internal(set) var activeReadingPalette: TTTextReadingPalette
        public internal(set) var activeSyntaxMode: TTTextSyntaxRenderMode
        public internal(set) var activeFontSize: CGFloat
        public internal(set) var activeSoftWrapEnabled: Bool
        public internal(set) var cachedTokenSpans: [TokenSpan] = []
        public internal(set) var searchMatchRanges: [NSRange] = []
        public internal(set) var activeSearchQuery: String = ""
        internal var activeSearchOptions: NSString.CompareOptions = [.caseInsensitive]
        public internal(set) var lastPerformanceMetrics: TTTextPreviewPerformanceMetrics?

        public private(set) var fullPreviewText: String = ""
        public private(set) var fullPreviewUTF8Count: Int = 0
        public private(set) var mountedUTF8ByteCount: Int = 0
        private var mountedEndUTF8Index: String.UTF8View.Index?
        private var fullPreviewPrefixSignature: String = ""
        internal var lastMountedFileName: String = ""

        internal var latestInitialMountDurationMs: Double = 0
        internal var latestLineStartScanDurationMs: Double = 0
        internal var latestFirstHighlightDurationMs: Double = 0

        public var isPartiallyMounted: Bool {
            mountedUTF8ByteCount < fullPreviewUTF8Count
        }

        internal private(set) var debounceTask: Task<Void, Never>?
        internal var scrollDebounceTask: Task<Void, Never>?
        internal private(set) var currentHighlightTask: Task<Void, Never>?

        init(_ parent: CodeHighlightingEditorNSView) {
            self.parent = parent
            self.activeReadingPalette = parent.resolvedReadingPalette
            self.activeSyntaxMode = parent.resolvedSyntaxMode
            self.activeFontSize = parent.fontSize
            self.activeSoftWrapEnabled = parent.isSoftWrapEnabled
            super.init()
        }

        nonisolated deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Cancels all in-flight highlighting, debounce, and line-index tasks and advances `documentGeneration`.
        public func cancelPendingTasks() {
            documentGeneration &+= 1
            needsHighlightAfterMarkedText = false
            currentHighlightTask?.cancel()
            currentHighlightTask = nil
            debounceTask?.cancel()
            debounceTask = nil
            scrollDebounceTask?.cancel()
            scrollDebounceTask = nil
            rulerView?.cancelPendingLineScan()
        }

        public func shouldRemount(displayString: String, fileName: String = "") -> Bool {
            let effectiveName = fileName.isEmpty ? parent.fileName : fileName
            if !lastMountedFileName.isEmpty && effectiveName != lastMountedFileName {
                return true
            }
            if parent.resolvedSyntaxMode != activeSyntaxMode {
                return true
            }
            guard displayString.utf8.count == fullPreviewUTF8Count,
                  String(displayString.prefix(128)) == fullPreviewPrefixSignature else {
                return true
            }
            return displayString != fullPreviewText
        }

        public func mountInitialPreview(
            displayString: String,
            in tv: LargeTextEditorTextView,
            storage: NSTextStorage? = nil,
            fileName: String
        ) {
            guard let activeStorage = storage ?? tv.textStorage ?? textStorageRef else { return }
            cancelPendingTasks()
            let capturedGeneration = documentGeneration
            let mountStart = CFAbsoluteTimeGetCurrent()

            textView = tv
            textStorageRef = activeStorage
            lastMountedFileName = fileName
            parent.fileName = fileName
            activeSyntaxMode = TTTextSyntaxRenderMode.resolve(
                fileName: fileName,
                overrideMode: parent.syntaxModeOverride
            )
            activeReadingPalette = parent.resolvedReadingPalette
            cachedTokenSpans = []
            searchMatchRanges = []
            activeSearchQuery = ""
            activeSearchOptions = [.caseInsensitive]

            fullPreviewText = displayString
            fullPreviewUTF8Count = displayString.utf8.count
            fullPreviewPrefixSignature = String(displayString.prefix(128))

            let (initialSlice, _) = TTSpreadsheetParser.truncateUTF8Prefix(
                displayString,
                maxBytes: CodeHighlightingEditorNSView.initialMountUTF8Bytes
            )
            let mountedBytes = initialSlice.utf8.count
            mountedUTF8ByteCount = mountedBytes
            mountedEndUTF8Index = displayString.utf8.index(
                displayString.utf8.startIndex,
                offsetBy: mountedBytes,
                limitedBy: displayString.utf8.endIndex
            ) ?? displayString.utf8.endIndex

            isProgrammaticUpdate = true
            activeStorage.beginEditing()
            activeStorage.setAttributedString(
                CodeHighlightingEditorNSView.createAttributedString(
                    from: initialSlice,
                    foregroundColor: activeReadingPalette.nsForegroundColor,
                    fontSize: parent.fontSize
                )
            )
            activeStorage.endEditing()
            isProgrammaticUpdate = false
            (tv.enclosingScrollView as? CodePreviewScrollView)?.synchronizeDocumentViewport(force: true)

            latestInitialMountDurationMs = (CFAbsoluteTimeGetCurrent() - mountStart) * 1000.0
            latestFirstHighlightDurationMs = 0.0

            rulerView?.readingPalette = activeReadingPalette
            rulerView?.updateLineStarts(for: initialSlice) { [weak self] scanMs, _ in
                guard let self, self.documentGeneration == capturedGeneration else { return }
                self.latestLineStartScanDurationMs = scanMs
                self.emitPerformanceMetrics(for: fileName, generation: capturedGeneration)
            }
            if let scanMs = rulerView?.lastLineStartScanDurationMs {
                latestLineStartScanDurationMs = scanMs
            }
            rulerView?.needsDisplay = true
            highlightSyntaxProgressive(in: tv, fileName: fileName)
        }

        @discardableResult
        public func appendNextPreviewChunk() -> Bool {
            ensureMounted(throughUTF8Bytes: mountedUTF8ByteCount + CodeHighlightingEditorNSView.chunkStepUTF8Bytes)
        }

        private func resolveNextChunkSlice(
            startUTF8Idx: String.UTF8View.Index,
            targetBytes: Int
        ) -> (slice: String, endIdx: String.UTF8View.Index, bytes: Int)? {
            let utf8 = fullPreviewText.utf8
            var endUTF8Idx = utf8.index(startUTF8Idx, offsetBy: targetBytes, limitedBy: utf8.endIndex) ?? utf8.endIndex
            while endUTF8Idx > startUTF8Idx
                && endUTF8Idx < utf8.endIndex
                && (utf8[endUTF8Idx] & 0b1100_0000) == 0b1000_0000 {
                endUTF8Idx = utf8.index(before: endUTF8Idx)
            }
            guard endUTF8Idx > startUTF8Idx else { return nil }
            let slice: String
            if let startScalar = startUTF8Idx.samePosition(in: fullPreviewText.unicodeScalars),
               let endScalar = endUTF8Idx.samePosition(in: fullPreviewText.unicodeScalars) {
                slice = String(fullPreviewText.unicodeScalars[startScalar..<endScalar])
            } else {
                slice = String(decoding: utf8[startUTF8Idx..<endUTF8Idx], as: UTF8.self)
            }
            guard !slice.isEmpty else { return nil }
            return (slice, endUTF8Idx, utf8.distance(from: startUTF8Idx, to: endUTF8Idx))
        }

        @discardableResult
        public func ensureMounted(throughUTF8Bytes targetUTF8Bytes: Int) -> Bool {
            guard isPartiallyMounted,
                  let tv = textView,
                  let storage = tv.textStorage ?? textStorageRef else { return false }

            let clampedTarget = min(fullPreviewUTF8Count, max(mountedUTF8ByteCount + 1, targetUTF8Bytes))
            guard clampedTarget > mountedUTF8ByteCount else { return false }

            let utf8 = fullPreviewText.utf8
            guard let startUTF8Idx = utf8.index(utf8.startIndex, offsetBy: mountedUTF8ByteCount, limitedBy: utf8.endIndex),
                  startUTF8Idx < utf8.endIndex else { return false }

            let deltaBytes = clampedTarget - mountedUTF8ByteCount
            guard let resolved = resolveNextChunkSlice(startUTF8Idx: startUTF8Idx, targetBytes: deltaBytes) else {
                return false
            }

            isProgrammaticUpdate = true
            storage.beginEditing()
            storage.append(
                CodeHighlightingEditorNSView.createAttributedString(
                    from: resolved.slice,
                    foregroundColor: activeReadingPalette.nsForegroundColor,
                    fontSize: parent.fontSize
                )
            )
            storage.endEditing()
            isProgrammaticUpdate = false
            (tv.enclosingScrollView as? CodePreviewScrollView)?.synchronizeDocumentViewport(force: true)

            mountedUTF8ByteCount += resolved.bytes
            mountedEndUTF8Index = resolved.endIdx

            rulerView?.updateLineStarts(for: storage.string)
            rulerView?.needsDisplay = true
            highlightSyntaxProgressive(in: tv, fileName: parent.fileName)
            return true
        }

        public func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  parent.effectiveIsEditable,
                  let tv = notification.object as? NSTextView else { return }
            let previousFullText = fullPreviewText
            synchronizeTextStateFromEditor(tv, forceNotifyBinding: true)
            let didMutateText = tv.string != previousFullText
            if didMutateText {
                currentHighlightTask?.cancel()
            }
            debounceTask?.cancel()
            if tv.hasMarkedText() {
                needsHighlightAfterMarkedText = true
                return
            }
            guard didMutateText else { return }
            let capturedGen = documentGeneration
            debounceTask = Task { @MainActor [weak self, weak tv] in
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled,
                      let self,
                      self.documentGeneration == capturedGen,
                      let textView = tv else { return }
                if textView.hasMarkedText() {
                    self.needsHighlightAfterMarkedText = true
                    return
                }
                self.highlightSyntaxProgressive(in: textView, fileName: self.parent.fileName)
            }
        }

        internal func synchronizeTextStateFromEditor(_ tv: NSTextView, forceNotifyBinding: Bool) {
            let newText = tv.string
            let didChangeFullText = fullPreviewText != newText
            let didChangeBinding = parent.text != newText
            fullPreviewText = newText
            fullPreviewUTF8Count = newText.utf8.count
            mountedUTF8ByteCount = fullPreviewUTF8Count
            mountedEndUTF8Index = newText.utf8.endIndex
            fullPreviewPrefixSignature = String(newText.prefix(128))
            if forceNotifyBinding || didChangeBinding || didChangeFullText {
                parent.text = newText
                parent.onTextChange?(newText)
            }
            if forceNotifyBinding || didChangeFullText {
                rulerView?.updateLineStarts(for: newText)
                rulerView?.needsDisplay = true
                (tv.enclosingScrollView as? CodePreviewScrollView)?.synchronizeDocumentViewport(force: true)
            }
            if tv.textContainerInset != parent.textContainerInset {
                tv.textContainerInset = parent.textContainerInset
            }
        }

        internal func cancelDebounceTask() {
            debounceTask?.cancel()
            debounceTask = nil
            scrollDebounceTask?.cancel()
            scrollDebounceTask = nil
        }

        public func highlightSyntaxProgressive(in tv: NSTextView, fileName: String) {
            guard self.textView == nil || self.textView === tv,
                  let storage = tv.textStorage,
                  self.textStorageRef == nil || self.textStorageRef === storage else { return }
            let currentLength = storage.length
            let mode = TTTextSyntaxRenderMode.resolve(
                fileName: fileName,
                overrideMode: parent.syntaxModeOverride
            )
            activeSyntaxMode = mode
            scrollDebounceTask?.cancel()
            scrollDebounceTask = nil
            currentHighlightTask?.cancel()
            currentHighlightTask = nil

            let capturedGen = documentGeneration
            guard currentLength > 0 else {
                cachedTokenSpans = []
                latestFirstHighlightDurationMs = 0.0
                emitPerformanceMetrics(for: fileName, generation: capturedGen)
                return
            }

            // Plain text policy: bypass code tokenizer for .txt/.log/plain files so URLs, quotes, and numbers are not miscolored.
            guard case .syntaxHighlighted(let ext) = mode else {
                cachedTokenSpans = []
                latestFirstHighlightDurationMs = 0.0
                if tv.hasMarkedText() {
                    needsHighlightAfterMarkedText = true
                    return
                }
                recolorStorageInPlace(storage, with: activeReadingPalette)
                emitPerformanceMetrics(for: fileName, generation: capturedGen)
                return
            }

            let snapshotText = storage.string
            let visibleRange = computeVisibleRange(in: tv)
            if currentLength < 128_000 {
                highlightSmallDocument(
                    in: tv, storage: storage, snapshotText: snapshotText,
                    ext: ext, length: currentLength, fileName: fileName, capturedGeneration: capturedGen
                )
            } else {
                highlightLargeDocumentStream(
                    in: tv, storage: storage, snapshotText: snapshotText,
                    ext: ext, visibleRange: visibleRange, fileName: fileName, capturedGeneration: capturedGen
                )
            }
        }

        private func highlightSmallDocument(
            in tv: NSTextView, storage: NSTextStorage, snapshotText: String,
            ext: String, length: Int, fileName: String, capturedGeneration: UInt64
        ) {
            let startTime = CFAbsoluteTimeGetCurrent()
            currentHighlightTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                let tokens = await BackgroundSyntaxTokenizer.shared.tokenize(
                    text: snapshotText, ext: ext, targetRange: NSRange(location: 0, length: length)
                )
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard !Task.isCancelled, self.documentGeneration == capturedGeneration,
                          self.textView == nil || self.textView === tv, tv.textStorage === storage,
                          self.textStorageRef == nil || self.textStorageRef === storage else { return }
                    if tv.hasMarkedText() { self.needsHighlightAfterMarkedText = true; return }
                    guard storage.string == snapshotText else { return }

                    self.cachedTokenSpans = tokens
                    self.latestFirstHighlightDurationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                    self.recolorStorageInPlace(storage, with: self.activeReadingPalette)
                    self.emitPerformanceMetrics(for: fileName, generation: capturedGeneration)
                }
            }
        }

        private func highlightLargeDocumentStream(
            in tv: NSTextView,
            storage: NSTextStorage,
            snapshotText: String,
            ext: String,
            visibleRange: NSRange,
            fileName: String,
            capturedGeneration: UInt64
        ) {
            let startTime = CFAbsoluteTimeGetCurrent()
            currentHighlightTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                let stream = await BackgroundSyntaxTokenizer.shared.tokenizeStream(
                    text: snapshotText,
                    ext: ext,
                    priorityRange: visibleRange,
                    batchSize: 2000
                )

                var isFirstBatch = true
                for await batch in stream {
                    guard !Task.isCancelled else { return }

                    let shouldBreak = await MainActor.run { () -> Bool in
                        guard !Task.isCancelled,
                              self.documentGeneration == capturedGeneration,
                              self.textView == nil || self.textView === tv,
                              tv.textStorage === storage,
                              self.textStorageRef == nil || self.textStorageRef === storage else {
                            return true
                        }
                        if tv.hasMarkedText() {
                            self.needsHighlightAfterMarkedText = true
                            return true
                        }
                        guard storage.string == snapshotText else {
                            return true
                        }

                        let palette = SyntaxPalette(readingPalette: self.activeReadingPalette, fontSize: self.parent.fontSize)
                        self.isProgrammaticUpdate = true
                        storage.beginEditing()
                        if isFirstBatch {
                            self.cachedTokenSpans.removeAll(keepingCapacity: true)
                            let fullStorageRange = NSRange(location: 0, length: storage.length)
                            if fullStorageRange.length > 0 {
                                storage.setAttributes([
                                    .font: palette.defaultFont,
                                    .foregroundColor: palette.defaultColor,
                                    .paragraphStyle: CodeHighlightingEditorNSView.codeParagraphStyle
                                ], range: fullStorageRange)
                            }
                            self.latestFirstHighlightDurationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                            isFirstBatch = false
                        }

                        self.cachedTokenSpans.append(contentsOf: batch.spans)
                        self.applyTokens(batch.spans, to: storage, palette: palette)
                        self.applySearchHighlightsToStorage(storage, palette: self.activeReadingPalette)
                        storage.endEditing()
                        self.isProgrammaticUpdate = false
                        if self.cachedTokenSpans.count == batch.spans.count {
                            self.emitPerformanceMetrics(for: fileName, generation: capturedGeneration)
                        }
                        return false
                    }
                    if shouldBreak { break }
                    await Task.yield()
                }
            }
        }
    }
}
