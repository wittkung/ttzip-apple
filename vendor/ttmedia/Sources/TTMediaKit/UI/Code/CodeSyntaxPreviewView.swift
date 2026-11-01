// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

public extension NSNotification.Name {
    /// Notification posted when a file is modified and saved within TTMediaKit editors.
    static let ttMediaFileContentDidChange = NSNotification.Name("TTMediaFileContentDidChangeNotification")
}

/// Container view for syntax-highlighted code and text editing.
/// Enforces a 2 MB interactive text preview budget, F4 source permission validation,
/// authentic file byte-count reporting, non-UTF-8 write-safety protection, and 3-state reading background synchronization.
public struct CodeTextEditorContainerView: View {
    /// Maximum UTF-8 byte budget for interactive text preview and in-place editing (2 MB).
    nonisolated public static let maxInteractiveTextUTF8Bytes: Int = 2 * 1024 * 1024

    /// Initial UTF-8 byte budget mounted synchronously for first-screen rendering (64 KB).
    nonisolated public static let initialMountUTF8Bytes: Int = 64 * 1024

    /// Incremental UTF-8 byte budget appended per scroll/search chunk step (128 KB).
    nonisolated public static let chunkStepUTF8Bytes: Int = 128 * 1024

    /// User-facing warning message displayed when a large text file is truncated to the 2 MB preview budget.
    @MainActor public static var truncationBannerMessage: String {
        TextAndDocumentPreviewLocalization.truncationBanner(budgetText: "2 MB")
    }

    public let initialText: String
    public let initialByteCount: Int64
    public let sourceEncoding: TTTextSourceEncoding
    public let sourceInspectDurationMs: Double
    public let previewDisplayText: String
    public let isTruncatedForPreview: Bool
    public let fileURL: URL?
    public let fileName: String
    public let isReadOnly: Bool
    public let resourceContext: TTPreviewResourceContext?
    public let syntaxModeOverride: TTTextSyntaxRenderMode?
    private var explicitReadingBackgroundMode: Binding<TTTextReadingBackgroundMode>?
    private var explicitSoftWrapEnabled: Binding<Bool>?
    private var explicitImmersiveToolbarPinned: Binding<Bool>?
    private var explicitFloatingToolsState: Binding<TTTextFloatingToolsPresentationState?>?
    private let externalOnSave: ((String) -> Void)?
    public var onPerformanceMetrics: ((TTTextPreviewPerformanceMetrics) -> Void)?

    private var sharedReadingPrefs = TTTextReadingPreferenceStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isImmersiveFullscreen) private var isImmersiveFullscreen
    @Environment(\.previewResourceContext) private var envResourceContext
    @Environment(\.previewBottomTrailingReservedWidth) private var envBottomTrailingReservedWidth
    @Environment(\.textFloatingToolsStateOverride) private var envFloatingToolsStateOverride
    @Environment(\.mediaControlsVisibility) private var sharedControlsVisibility
    @State private var editedText: String = ""
    @State private var isEdited: Bool = false
    @State private var isSavedToastPresented: Bool = false
    @State private var isCopiedToastPresented: Bool = false
    @State private var saveErrorMessage: String? = nil
    @State private var showLineNumbers: Bool = true
    @State private var fontSize: CGFloat = CodeFloatingReadingToolsOverlay.defaultFontSize
    @State private var isPointerInContainer: Bool = false
    @State private var isFloatingClusterHovered: Bool = false
    @State private var isFloatingClusterFocused: Bool = false
    @State private var isReadingToolsPopoverPresented: Bool = false
    @State private var interactionCoordinator = CodeReadingToolsInteractionCoordinator()
    @State private var lineCount: Int = 1
    @State private var byteCount: Int64 = 0
    @State private var runtimeEncodingOverride: TTTextSourceEncoding? = nil
    @State private var lastLoadedFileIdentity: String = ""
    @State private var metricsTask: Task<Void, Never>? = nil

    public init(
        initialText: String,
        fileURL: URL?,
        fileName: String,
        initialByteCount: Int64? = nil,
        isReadOnly: Bool = false,
        resourceContext: TTPreviewResourceContext? = nil,
        readingBackgroundMode: Binding<TTTextReadingBackgroundMode>? = nil,
        softWrapEnabled: Binding<Bool>? = nil,
        immersiveToolbarPinned: Binding<Bool>? = nil,
        floatingToolsState: Binding<TTTextFloatingToolsPresentationState?>? = nil,
        syntaxModeOverride: TTTextSyntaxRenderMode? = nil,
        onPerformanceMetrics: ((TTTextPreviewPerformanceMetrics) -> Void)? = nil,
        onSave: ((String) -> Void)? = nil
    ) {
        self.initialText = initialText
        self.fileURL = fileURL
        self.fileName = fileName
        self.isReadOnly = isReadOnly
        self.resourceContext = resourceContext
        self.explicitReadingBackgroundMode = readingBackgroundMode
        self.explicitSoftWrapEnabled = softWrapEnabled
        self.explicitImmersiveToolbarPinned = immersiveToolbarPinned
        self.explicitFloatingToolsState = floatingToolsState
        self.syntaxModeOverride = syntaxModeOverride
        self.onPerformanceMetrics = onPerformanceMetrics
        self.externalOnSave = onSave
        let readableForInspection = fileURL ?? resourceContext?.readableURL
        let inspection = TTTextSourceInspection.inspect(
            url: readableForInspection,
            fallbackText: initialText,
            explicitByteCount: initialByteCount
        )
        self.initialByteCount = inspection.byteCount
        self.sourceEncoding = inspection.encoding
        self.sourceInspectDurationMs = inspection.inspectDurationMs
        let (display, truncated) = Self.truncateForPreview(initialText)
        self.previewDisplayText = display
        self.isTruncatedForPreview = truncated
        self._editedText = State(initialValue: display)
        self._byteCount = State(initialValue: inspection.byteCount)
        let initialIdentity = "\(fileName)|\(fileURL?.path ?? resourceContext?.readableURL?.path ?? "")"
        self._lastLoadedFileIdentity = State(initialValue: initialIdentity)
    }

    @MainActor
    public var activeReadingBackgroundBinding: Binding<TTTextReadingBackgroundMode> {
        if let explicitReadingBackgroundMode {
            return explicitReadingBackgroundMode
        }
        return Binding(
            get: { sharedReadingPrefs.mode },
            set: { sharedReadingPrefs.mode = $0 }
        )
    }

    @MainActor
    public var activeReadingBackgroundMode: TTTextReadingBackgroundMode {
        activeReadingBackgroundBinding.wrappedValue
    }

    @MainActor
    public var activeSoftWrapBinding: Binding<Bool> {
        if let explicitSoftWrapEnabled {
            return explicitSoftWrapEnabled
        }
        return Binding(
            get: { sharedReadingPrefs.isSoftWrapEnabled },
            set: { sharedReadingPrefs.isSoftWrapEnabled = $0 }
        )
    }

    @MainActor
    public var activeSoftWrapEnabled: Bool {
        activeSoftWrapBinding.wrappedValue
    }

    @MainActor
    public var resolvedReadingPalette: TTTextReadingPalette {
        TTTextReadingPalette.resolve(
            mode: activeReadingBackgroundMode,
            isDarkAppearance: colorScheme == .dark
        )
    }

    public var resolvedSyntaxMode: TTTextSyntaxRenderMode {
        TTTextSyntaxRenderMode.resolve(fileName: fileName, overrideMode: syntaxModeOverride)
    }

    /// Safely truncates text to at most `maxUTF8Bytes` at a valid Unicode scalar boundary.
    nonisolated public static func truncateForPreview(
        _ text: String,
        maxUTF8Bytes: Int = maxInteractiveTextUTF8Bytes
    ) -> (displayText: String, isTruncated: Bool) {
        let result = TTSpreadsheetParser.truncateUTF8Prefix(text, maxBytes: maxUTF8Bytes)
        return (displayText: result.text, isTruncated: result.isTruncated)
    }

    /// Effective source encoding (incorporating environment readableURL inspection when `fileURL` was omitted by factory).
    public var effectiveSourceEncoding: TTTextSourceEncoding {
        runtimeEncodingOverride ?? sourceEncoding
    }

    /// Resolves the effective `TTPreviewResourceContext` from explicit initializer argument, SwiftUI environment, or fallback inspection.
    public var resolvedResourceContext: TTPreviewResourceContext {
        if let explicit = resourceContext {
            return isReadOnly ? explicit.forcingReadOnly() : explicit
        }
        if envResourceContext.origin != .unknown(readableURL: nil) {
            return isReadOnly ? envResourceContext.forcingReadOnly() : envResourceContext
        }
        guard let url = fileURL else {
            return .inMemory(fileName: fileName)
        }
        if TTPreviewResourceContext.isManagedPreviewStagingURL(url) {
            return TTPreviewResourceContext(
                origin: .diskFile(url: url.standardizedFileURL),
                displayFileName: fileName,
                allowsEditingWhenAuthorized: false,
                isPreviewTruncated: isTruncatedForPreview,
                isDerivedRepresentation: false
            )
        }
        return .diskFile(
            url: url,
            fileName: fileName,
            allowsEditing: !isReadOnly,
            isTruncated: isTruncatedForPreview
        )
    }

    /// Validated disk target URL for in-place saving, or `nil` when read-only, archive-staged, truncated, or non-UTF-8.
    public var validatedSaveURL: URL? {
        guard !isReadOnly,
              !isTruncatedForPreview,
              effectiveSourceEncoding.allowsUTF8InPlaceSave else {
            return nil
        }
        return resolvedResourceContext.validateInPlaceSaveTarget(
            expectedFileURL: fileURL,
            fileName: fileName,
            isTruncated: isTruncatedForPreview
        )
    }

    /// Whether this preview instance permits editing and in-place saving.
    public var canSaveInPlace: Bool {
        guard !isReadOnly, !isTruncatedForPreview, effectiveSourceEncoding.allowsUTF8InPlaceSave else {
            return false
        }
        if validatedSaveURL != nil {
            return true
        }
        return fileURL == nil && resourceContext == nil && envResourceContext.origin == .unknown(readableURL: nil) && externalOnSave != nil
    }

    /// Whether the underlying editor view should be editable.
    public var isEditorEditable: Bool {
        canSaveInPlace
    }

    /// Whether the file is read-only specifically because its source encoding is non-UTF-8.
    public var isNonUTF8ReadOnly: Bool {
        !effectiveSourceEncoding.allowsUTF8InPlaceSave && (fileURL != nil || resolvedResourceContext.readableURL != nil)
    }

    /// Resolves the 3-state floating reading tools presentation (`quietReading`, `controlsVisible`, `popoverExpanded`).
    /// Under the D3 Content-First ruling, no full-width header bar is ever inserted into the layout;
    /// the document viewport occupies 100% of the container in all three states.
    public static func resolveFloatingToolsState(
        explicitState: TTTextFloatingToolsPresentationState? = nil,
        isImmersiveFullscreen: Bool,
        isPointerInContainer: Bool = false,
        isClusterHovered: Bool = false,
        isClusterFocused: Bool = false,
        isPopoverPresented: Bool = false,
        isPinnedForTesting: Bool = false,
        hasUnsavedEdits: Bool = false,
        hasActiveToastOrError: Bool = false
    ) -> TTTextFloatingToolsPresentationState {
        if let explicitState {
            return explicitState
        }
        if isPopoverPresented {
            return .popoverExpanded
        }
        if !isImmersiveFullscreen {
            return .controlsVisible
        }
        if isPointerInContainer
            || isClusterHovered
            || isClusterFocused
            || isPinnedForTesting
            || hasUnsavedEdits
            || hasActiveToastOrError {
            return .controlsVisible
        }
        return .quietReading
    }

    /// Evaluates whether the floating reading tools cluster (`[ Aa ⎘ ]`) should be visible.
    public static func shouldShowReadingHeaderBar(
        isImmersiveFullscreen: Bool,
        isTopZoneHovered: Bool = false,
        isHeaderBarHovered: Bool = false,
        isHeaderBarFocused: Bool = false,
        isPinnedForTesting: Bool = false,
        hasUnsavedEdits: Bool = false,
        hasActiveToastOrError: Bool = false
    ) -> Bool {
        resolveFloatingToolsState(
            isImmersiveFullscreen: isImmersiveFullscreen,
            isPointerInContainer: isTopZoneHovered,
            isClusterHovered: isHeaderBarHovered,
            isClusterFocused: isHeaderBarFocused,
            isPinnedForTesting: isPinnedForTesting,
            hasUnsavedEdits: hasUnsavedEdits,
            hasActiveToastOrError: hasActiveToastOrError
        ).showsControlsCluster
    }

    /// Active 3-state floating tools presentation for this container.
    public var activeFloatingToolsState: TTTextFloatingToolsPresentationState {
        Self.resolveFloatingToolsState(
            explicitState: explicitFloatingToolsState?.wrappedValue ?? envFloatingToolsStateOverride,
            isImmersiveFullscreen: isImmersiveFullscreen,
            isPointerInContainer: isPointerInContainer || (sharedControlsVisibility?.isVisible == true),
            isClusterHovered: isFloatingClusterHovered,
            isClusterFocused: isFloatingClusterFocused,
            isPopoverPresented: isReadingToolsPopoverPresented,
            isPinnedForTesting: explicitImmersiveToolbarPinned?.wrappedValue ?? false,
            hasUnsavedEdits: isEditorEditable && isEdited,
            hasActiveToastOrError: isSavedToastPresented || isCopiedToastPresented || saveErrorMessage != nil
        )
    }

    /// Whether the floating reading tools cluster is currently visible in this container.
    public var isReadingHeaderBarVisible: Bool {
        activeFloatingToolsState.showsControlsCluster
    }

    public var body: some View {
        GeometryReader { geometry in
            let palette = resolvedReadingPalette
            let floatingState = activeFloatingToolsState
            let editorInset = isImmersiveFullscreen
                ? NSSize(width: 14.0, height: 28.0)
                : NSSize(width: 8.0, height: 10.0)
            ZStack(alignment: .bottomTrailing) {
                CodeHighlightingEditorNSView(
                    text: $editedText,
                    fileName: fileName,
                    showLineNumbers: showLineNumbers,
                    isEditable: isEditorEditable,
                    isSoftWrapEnabled: activeSoftWrapEnabled,
                    readingBackgroundMode: activeReadingBackgroundMode,
                    isDarkAppearance: colorScheme == .dark,
                    fontSize: fontSize,
                    textContainerInset: editorInset,
                    syntaxModeOverride: syntaxModeOverride,
                    totalSourceBytes: byteCount,
                    sourceInspectDurationMs: sourceInspectDurationMs,
                    onTextChange: isEditorEditable ? { newText in
                        guard isEditorEditable else { return }
                        let modified = newText != previewDisplayText
                        isEdited = modified
                        let overrideBytes: Int64? = modified
                            ? Int64(newText.utf8.count + (effectiveSourceEncoding == .utf8BOM ? 3 : 0))
                            : initialByteCount
                        scheduleMetricsUpdate(for: newText, totalBytesOverride: overrideBytes)
                    } : nil,
                    onSaveShortcut: isEditorEditable ? {
                        if isEditorEditable && isEdited {
                            _ = saveFile()
                        }
                    } : nil,
                    onPerformanceMetrics: onPerformanceMetrics
                )
                .frame(width: geometry.size.width, height: geometry.size.height)

                CodeFloatingReadingToolsOverlay(
                    fileName: fileName,
                    lineCount: lineCount,
                    byteCount: byteCount,
                    isEdited: isEditorEditable && isEdited,
                    isWritableFile: isEditorEditable,
                    isReadOnly: !isEditorEditable,
                    encodingBadge: effectiveSourceEncoding.displayBadge,
                    isTruncatedForPreview: isTruncatedForPreview,
                    isNonUTF8ReadOnly: isNonUTF8ReadOnly,
                    saveErrorMessage: saveErrorMessage,
                    isSavedToastPresented: isSavedToastPresented,
                    isCopiedToastPresented: isCopiedToastPresented,
                    presentationState: floatingState,
                    bottomTrailingReservedWidth: envBottomTrailingReservedWidth,
                    availableHostWidth: geometry.size.width,
                    showLineNumbers: $showLineNumbers,
                    fontSize: $fontSize,
                    isPopoverPresented: Binding(
                        get: { floatingState.isPopoverOpen },
                        set: { newValue in
                            setPopoverPresented(newValue)
                        }
                    ),
                    readingBackgroundMode: activeReadingBackgroundBinding,
                    softWrapEnabled: activeSoftWrapBinding,
                    onCopy: { copyToClipboard() },
                    onSave: {
                        if isEditorEditable && isEdited {
                            _ = saveFile()
                        }
                    },
                    onHoverChange: { hovering in
                        withAnimation(.ttMicro) {
                            isFloatingClusterHovered = hovering
                        }
                    },
                    onFocusChange: { focused in
                        withAnimation(.ttMicro) {
                            isFloatingClusterFocused = focused
                        }
                    }
                )
            }
            .background(palette.containerBackgroundColor)
            .background(
                CodeContainerWindowAccessor(
                    coordinator: interactionCoordinator,
                    isPopoverPresented: isReadingToolsPopoverPresented,
                    controlsVisibility: sharedControlsVisibility,
                    onDismissPopover: {
                        if let explicitFloatingToolsState {
                            explicitFloatingToolsState.wrappedValue = .controlsVisible
                        }
                        isReadingToolsPopoverPresented = false
                    }
                )
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    sharedControlsVisibility?.recordMouseMove(at: location)
                    if !isPointerInContainer {
                        withAnimation(.ttMicro) {
                            isPointerInContainer = true
                        }
                    }
                case .ended:
                    sharedControlsVisibility?.setHovered(false)
                    if isPointerInContainer {
                        withAnimation(.ttMicro) {
                            isPointerInContainer = false
                        }
                    }
                }
            }
        }
        .task(id: "\(fileName)|\(fileURL?.path ?? resolvedResourceContext.readableURL?.path ?? "")|\(initialByteCount)") {
            let currentIdentity = "\(fileName)|\(fileURL?.path ?? resolvedResourceContext.readableURL?.path ?? "")"
            let isSwitchingFiles = lastLoadedFileIdentity != currentIdentity
            if isSwitchingFiles {
                lastLoadedFileIdentity = currentIdentity
                editedText = previewDisplayText
                isEdited = false
                setPopoverPresented(false)
            } else if !isEdited {
                editedText = previewDisplayText
            }
            var resolvedBytes = initialByteCount
            if fileURL == nil, let envReadURL = resolvedResourceContext.readableURL {
                let envInspection = TTTextSourceInspection.inspect(url: envReadURL, fallbackText: initialText)
                resolvedBytes = envInspection.byteCount
                runtimeEncodingOverride = envInspection.encoding
            } else {
                runtimeEncodingOverride = nil
            }
            scheduleMetricsUpdate(
                for: editedText.isEmpty ? previewDisplayText : editedText,
                totalBytesOverride: resolvedBytes
            )
        }
        .onAppear {
            interactionCoordinator.syncState(
                isPopoverPresented: isReadingToolsPopoverPresented,
                controlsVisibility: sharedControlsVisibility,
                onRequestDismissPopover: {
                    if let explicitFloatingToolsState {
                        explicitFloatingToolsState.wrappedValue = .controlsVisible
                    }
                    isReadingToolsPopoverPresented = false
                }
            )
            interactionCoordinator.handleAppear()
        }
        .onDisappear {
            interactionCoordinator.handleDisappear()
            metricsTask?.cancel()
            metricsTask = nil
        }
    }

    private func setPopoverPresented(_ presented: Bool) {
        if let explicitFloatingToolsState {
            explicitFloatingToolsState.wrappedValue = presented ? .popoverExpanded : .controlsVisible
        }
        isReadingToolsPopoverPresented = presented
        interactionCoordinator.syncState(
            isPopoverPresented: presented,
            controlsVisibility: sharedControlsVisibility,
            onRequestDismissPopover: {
                if let explicitFloatingToolsState {
                    explicitFloatingToolsState.wrappedValue = .controlsVisible
                }
                isReadingToolsPopoverPresented = false
            }
        )
        interactionCoordinator.setPopoverPresented(presented)
    }

    // MARK: - Actions & Metrics

    private func scheduleMetricsUpdate(for text: String, totalBytesOverride: Int64?) {
        metricsTask?.cancel()
        let byteTotal = totalBytesOverride ?? Int64(text.utf8.count)
        byteCount = byteTotal
        metricsTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) { () -> Int? in
                guard !Task.isCancelled else { return nil }
                return Self.countLinesFast(in: text)
            }
            let computedLines = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let lines = computedLines else { return }
            self.lineCount = lines
        }
    }

    nonisolated internal static func countLinesFast(in text: String) -> Int {
        var lines = 1
        let handled: Bool? = text.utf8.withContiguousStorageIfAvailable { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return true }
            var offset = 0
            let total = buffer.count
            while offset < total {
                guard let found = memchr(base.advanced(by: offset), 0x0A, total - offset) else {
                    break
                }
                lines += 1
                let matched = found.assumingMemoryBound(to: UInt8.self)
                offset = base.distance(to: matched) + 1
            }
            return true
        }
        if handled == nil {
            for byte in text.utf8 where byte == 10 {
                lines += 1
            }
        }
        return lines
    }

    /// Copies the active preview text to the specified pasteboard and returns the copied string.
    @discardableResult
    public func copyPreviewToPasteboard(_ pasteboard: NSPasteboard = .general) -> String {
        let payload = (isEditorEditable && isEdited) ? editedText : previewDisplayText
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        return payload
    }

    private func copyToClipboard() {
        _ = copyPreviewToPasteboard(.general)
        withAnimation(.ttMicro) {
            isCopiedToastPresented = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.ttMicro) {
                isCopiedToastPresented = false
            }
        }
    }

    @discardableResult
    public func saveFile(contentOverride: String? = nil) -> Bool {
        guard canSaveInPlace,
              initialText.utf8.count <= Self.maxInteractiveTextUTF8Bytes else {
            return false
        }
        let payload = contentOverride ?? editedText
        guard payload.utf8.count <= Self.maxInteractiveTextUTF8Bytes else {
            return false
        }
        if let onSave = externalOnSave, fileURL == nil {
            onSave(payload)
            return true
        }
        guard isEdited || contentOverride != nil,
              let targetURL = validatedSaveURL else {
            return false
        }
        do {
            let outputData = Self.encodeForSave(payload: payload, encoding: sourceEncoding)
            try outputData.write(to: targetURL, options: .atomic)
            externalOnSave?(payload)
            withAnimation(.ttMicro) {
                isEdited = false
                isSavedToastPresented = true
                saveErrorMessage = nil
            }
            scheduleMetricsUpdate(for: payload, totalBytesOverride: Int64(outputData.count))
            NotificationCenter.default.post(name: .ttMediaFileContentDidChange, object: targetURL)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.0))
                withAnimation(.ttMicro) {
                    isSavedToastPresented = false
                }
            }
            return true
        } catch {
            withAnimation(.ttMicro) {
                saveErrorMessage = error.localizedDescription
            }
            return false
        }
    }

    nonisolated internal static func encodeForSave(payload: String, encoding: TTTextSourceEncoding) -> Data {
        var data = Data()
        if encoding == .utf8BOM {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(contentsOf: payload.utf8)
        return data
    }
}

// MARK: - Backward-Compatible Facade Alias

/// Backward-compatible typealias mapping `CodeSyntaxPreviewView` directly to `CodeTextEditorContainerView`.
public typealias CodeSyntaxPreviewView = CodeTextEditorContainerView

public extension CodeTextEditorContainerView {
    /// Backward-compatible convenience initializer matching previous adapter signature.
    init(
        content: String,
        fileURL: URL? = nil,
        fileName: String = "",
        initialByteCount: Int64? = nil,
        isReadOnly: Bool = false,
        resourceContext: TTPreviewResourceContext? = nil,
        onSave: ((String) -> Void)? = nil
    ) {
        self.init(
            initialText: content,
            fileURL: fileURL,
            fileName: fileName.isEmpty ? (fileURL?.lastPathComponent ?? "document.txt") : fileName,
            initialByteCount: initialByteCount,
            isReadOnly: isReadOnly,
            resourceContext: resourceContext,
            onSave: onSave
        )
    }
}
