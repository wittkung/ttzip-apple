// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTKitDesign
import TTMediaKit

struct TTZipCodePreviewView: View {
    let fileName: String
    let fileURL: URL?
    let resourceContext: TTPreviewResourceContext

    private let fallbackText: String
    private let pasteboard: NSPasteboard?
    private let readingPreferences = TTTextReadingPreferenceStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isImmersiveFullscreen) private var isImmersiveFullscreen
    @Environment(\.previewBottomTrailingReservedWidth) private var reservedCornerWidth
    @Environment(\.textFloatingToolsStateOverride) private var floatingToolsStateOverride
    @Environment(\.mediaControlsVisibility) private var controlsVisibility
    @State private var session: SourceSession?
    @State private var isSavedToastPresented = false
    @State private var isCopiedToastPresented = false
    @State private var saveErrorMessage: String?
    @State private var showLineNumbers = true
    @State private var fontSize = TTZipCodeReadingTools.defaultFontSize
    @State private var isPointerInContainer = false
    @State private var isClusterHovered = false
    @State private var isClusterFocused = false
    @State private var isPopoverPresented = false
    @State private var interactionCoordinator = CodeReadingToolsInteractionCoordinator()
    @State private var focusCoordinator = TTZipCodeToolsFocusCoordinator()
    @State private var policyBox = SourcePolicyBox()
    @State private var lineCount = 1
    @State private var byteCount: Int64 = 0
    @State private var metricsTask: Task<Void, Never>?

    private struct FileIdentity: Hashable {
        let name: String
        let readableURL: URL?
        let origin: TTPreviewResourceOrigin
    }

    private struct SourceRevision: Hashable {
        let file: FileIdentity
        let fallbackText: String
    }

    private struct CallbackToken: Hashable {
        let sessionID: UUID
        let policyGeneration: Int
    }

    @MainActor
    private final class SourcePolicyBox {
        private(set) var fileName = ""
        private(set) var fileURL: URL?
        private(set) var resourceContext = TTPreviewResourceContext.inMemory(fileName: "")
        private(set) var policyGeneration = 0
        private(set) var hasSynced = false

        func sync(fileName: String, fileURL: URL?, resourceContext: TTPreviewResourceContext) {
            if hasSynced,
               self.fileName != fileName || self.fileURL != fileURL || self.resourceContext != resourceContext {
                policyGeneration &+= 1
            }
            self.fileName = fileName
            self.fileURL = fileURL
            self.resourceContext = resourceContext
            hasSynced = true
        }

        func token(for sessionID: UUID) -> CallbackToken {
            CallbackToken(sessionID: sessionID, policyGeneration: policyGeneration)
        }
    }

    private struct SourceSession {
        let id = UUID()
        let revision: SourceRevision
        let snapshot: TTZipCodeSourceSnapshot
        var text: String
        var baseline: String
        var enabledPolicyGeneration: Int?

        var isEdited: Bool { text != baseline }
    }

    init(
        text: String,
        fileURL: URL?,
        fileName: String,
        resourceContext: TTPreviewResourceContext,
        pasteboard: NSPasteboard? = nil
    ) {
        self.fileName = fileName
        self.fileURL = fileURL
        self.resourceContext = resourceContext
        self.pasteboard = pasteboard
        fallbackText = text
    }

    private var currentFileName: String {
        policyBox.hasSynced ? policyBox.fileName : fileName
    }

    private var currentFileURL: URL? {
        policyBox.hasSynced ? policyBox.fileURL : fileURL
    }

    private var currentResourceContext: TTPreviewResourceContext {
        policyBox.hasSynced ? policyBox.resourceContext : resourceContext
    }

    private var fileIdentity: FileIdentity {
        FileIdentity(name: currentFileName, readableURL: currentFileURL, origin: currentResourceContext.origin)
    }

    private var activeSession: SourceSession? {
        guard session?.revision.file == fileIdentity else { return nil }
        return session
    }

    private var sourceRevision: SourceRevision {
        SourceRevision(
            file: FileIdentity(name: fileName, readableURL: fileURL, origin: resourceContext.origin),
            fallbackText: fallbackText
        )
    }

    private var validatedSaveURL: URL? {
        guard let snapshot = activeSession?.snapshot, snapshot.saveBaseline != nil else { return nil }
        return currentResourceContext.validateInPlaceSaveTarget(
            expectedFileURL: currentFileURL,
            fileName: currentFileName,
            isTruncated: snapshot.isTruncated
        )
    }

    private var canEditSource: Bool { validatedSaveURL != nil }

    private var isEdited: Bool { activeSession?.isEdited == true }

    private func isEditable(for token: CallbackToken) -> Bool {
        guard let active = activeSession,
              policyBox.token(for: active.id) == token,
              active.enabledPolicyGeneration == token.policyGeneration else {
            return false
        }
        return canEditSource
    }

    private func editorText(for token: CallbackToken) -> Binding<String> {
        Binding(
            get: {
                guard let active = activeSession, active.id == token.sessionID else { return "" }
                return active.text
            },
            set: { newValue in
                guard isEditable(for: token) else { return }
                session?.text = newValue
            }
        )
    }

    private var floatingToolsState: TTTextFloatingToolsPresentationState {
        if let floatingToolsStateOverride { return floatingToolsStateOverride }
        if isPopoverPresented { return .popoverExpanded }
        if !isImmersiveFullscreen || isPointerInContainer || controlsVisibility?.isVisible == true
            || isClusterHovered || isClusterFocused || isEdited
            || isSavedToastPresented || isCopiedToastPresented || saveErrorMessage != nil {
            return .controlsVisible
        }
        return .quietReading
    }

    var body: some View {
        policyBox.sync(fileName: fileName, fileURL: fileURL, resourceContext: resourceContext)
        return GeometryReader { geometry in
            let palette = TTZipTextReadingAppearance.resolve(mode: readingPreferences.mode, isDarkAppearance: colorScheme == .dark)
            ZStack(alignment: .bottomTrailing) {
                if let active = activeSession {
                    let token = policyBox.token(for: active.id)
                    editor(session: active, token: token, palette: palette)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    readingTools(hostWidth: geometry.size.width, session: active, token: token)
                        .id(token)
                } else {
                    Color.clear
                }
            }
            .background(palette.containerBackgroundColor)
            .background(
                TTZipCodeWindowAccessor(
                    coordinator: interactionCoordinator,
                    isPopoverPresented: isPopoverPresented,
                    controlsVisibility: controlsVisibility,
                    onDismissPopover: { setPopoverPresented(false) }
                )
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onContinuousHover(perform: updatePointer)
        }
        .task(id: sourceRevision) { loadSource() }
        .onAppear {
            syncPopoverState()
            interactionCoordinator.handleAppear()
        }
        .onDisappear {
            controlsVisibility?.setKeyboardFocused(false)
            interactionCoordinator.handleDisappear()
            metricsTask?.cancel()
            metricsTask = nil
        }
    }

    private func editor(session: SourceSession, token: CallbackToken, palette: TTTextReadingPalette) -> some View {
        let editable = isEditable(for: token)
        let onEdit: ((String) -> Void)? = editable ? { recordEdit($0, for: token) } : nil
        let onSave: (() -> Void)? = editable ? { save(for: token) } : nil
        return CodeHighlightingEditorNSView(
            text: editorText(for: token),
            fileName: fileName,
            showLineNumbers: showLineNumbers,
            isEditable: editable,
            isSoftWrapEnabled: readingPreferences.isSoftWrapEnabled,
            readingPalette: palette,
            fontSize: fontSize,
            textContainerInset: isImmersiveFullscreen
                ? NSSize(width: 14, height: 28)
                : NSSize(width: 8, height: 10),
            totalSourceBytes: byteCount,
            sourceInspectDurationMs: session.snapshot.inspection.inspectDurationMs,
            onTextChange: onEdit,
            onSaveShortcut: onSave
        )
    }

    private func readingTools(hostWidth: CGFloat, session: SourceSession, token: CallbackToken) -> some View {
        let writable = canEditSource
        let editable = isEditable(for: token)
        let presentation = floatingToolsState
        return TTZipCodeReadingTools(
            fileName: fileName,
            lineCount: lineCount,
            byteCount: byteCount,
            isEdited: session.isEdited,
            isWritableFile: writable,
            isEditing: editable,
            encodingBadge: session.snapshot.inspection.encoding.displayBadge,
            isTruncatedForPreview: session.snapshot.isTruncated,
            isNonUTF8ReadOnly: !session.snapshot.inspection.encoding.allowsUTF8InPlaceSave && fileURL != nil,
            saveErrorMessage: saveErrorMessage,
            isSavedToastPresented: isSavedToastPresented,
            isCopiedToastPresented: isCopiedToastPresented,
            presentationState: presentation,
            bottomTrailingReservedWidth: reservedCornerWidth,
            availableHostWidth: hostWidth,
            showLineNumbers: $showLineNumbers,
            fontSize: $fontSize,
            isPopoverPresented: Binding(get: { presentation.isPopoverOpen }, set: { setPopoverPresented($0) }),
            readingBackgroundMode: Binding(
                get: { readingPreferences.mode }, set: { readingPreferences.mode = $0 }
            ),
            softWrapEnabled: Binding(
                get: { readingPreferences.isSoftWrapEnabled }, set: { readingPreferences.isSoftWrapEnabled = $0 }
            ),
            onEnableEditing: { enableEditing(for: token) },
            onCopy: copyToClipboard,
            onSave: { save(for: token) },
            onHoverChange: { hovered in withAnimation(.ttMicro) { isClusterHovered = hovered } },
            onFocusChange: setClusterFocused,
            focusCoordinator: focusCoordinator
        )
    }

    private func setClusterFocused(_ focused: Bool) {
        controlsVisibility?.setKeyboardFocused(focused)
        if isClusterFocused != focused {
            withAnimation(.ttMicro) { isClusterFocused = focused }
        }
    }

    private func updatePointer(_ phase: HoverPhase) {
        let isInside: Bool
        switch phase {
        case .active(let location):
            controlsVisibility?.recordMouseMove(at: location)
            isInside = true
        case .ended:
            controlsVisibility?.setHovered(false)
            isInside = false
        }
        if isPointerInContainer != isInside {
            withAnimation(.ttMicro) { isPointerInContainer = isInside }
        }
    }

    private func setPopoverPresented(_ presented: Bool, restoreFocus: Bool = true) {
        if !presented, restoreFocus, interactionCoordinator.isMounted {
            focusCoordinator.restoreTriggerFocusIfNeeded()
        }
        isPopoverPresented = presented
        syncPopoverState()
        interactionCoordinator.setPopoverPresented(presented)
    }

    private func syncPopoverState() {
        interactionCoordinator.syncState(
            isPopoverPresented: isPopoverPresented,
            controlsVisibility: controlsVisibility,
            onRequestDismissPopover: { setPopoverPresented(false) }
        )
    }

    private func loadSource() {
        guard !Task.isCancelled else { return }
        guard session?.revision != sourceRevision, activeSession?.isEdited != true else { return }
        let snapshot = TTZipCodeSourceSnapshot.load(
            fallbackText: fallbackText, fileURL: currentFileURL, context: currentResourceContext
        )
        guard !Task.isCancelled else { return }
        session = SourceSession(revision: sourceRevision, snapshot: snapshot,
                                text: snapshot.displayText, baseline: snapshot.saveBaseline ?? snapshot.displayText)
        saveErrorMessage = nil
        isSavedToastPresented = false
        setPopoverPresented(false, restoreFocus: false)
        scheduleMetrics(for: snapshot.displayText, totalBytes: snapshot.inspection.byteCount)
    }

    private func enableEditing(for token: CallbackToken) {
        guard canEditSource,
              let active = activeSession,
              policyBox.token(for: active.id) == token else { return }
        session?.enabledPolicyGeneration = token.policyGeneration
    }

    private func recordEdit(_ text: String, for token: CallbackToken) {
        guard isEditable(for: token) else { return }
        scheduleMetrics(for: text, totalBytes: encodedByteCount(for: text))
    }

    private func encodedByteCount(for text: String) -> Int64 {
        Int64(text.utf8.count + (activeSession?.snapshot.inspection.encoding == .utf8BOM ? 3 : 0))
    }

    private func scheduleMetrics(for text: String, totalBytes: Int64) {
        metricsTask?.cancel()
        byteCount = totalBytes
        metricsTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) { () -> Int? in
                guard !Task.isCancelled else { return nil }
                return Self.countLines(in: text)
            }
            let computedLines = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let computedLines else { return }
            lineCount = computedLines
        }
    }

    nonisolated private static func countLines(in text: String) -> Int {
        var lines = 1
        let counted: Bool? = text.utf8.withContiguousStorageIfAvailable { buffer in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count,
                  let match = memchr(base.advanced(by: offset), 0x0A, buffer.count - offset) {
                lines += 1
                offset = base.distance(to: match.assumingMemoryBound(to: UInt8.self)) + 1
            }
            return true
        }
        if counted == nil {
            for byte in text.utf8 where byte == 10 { lines += 1 }
        }
        return lines
    }

    private func copyToClipboard() {
        let pasteboard = pasteboard ?? .general
        pasteboard.clearContents()
        pasteboard.setString(activeSession?.text ?? "", forType: .string)
        withAnimation(.ttMicro) { isCopiedToastPresented = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.ttMicro) { isCopiedToastPresented = false }
        }
    }

    private func save(for token: CallbackToken) {
        guard let current = activeSession,
              isEditable(for: token) else { return }
        let payload = current.text
        guard current.isEdited, payload.utf8.count <= TTTextPreviewBytePolicy.maxInteractiveTextUTF8Bytes,
              let targetURL = validatedSaveURL else { return }
        do {
            _ = try TTControlledTextSaveTransaction.commit(
                payload: payload, expectedBaseline: current.baseline,
                encoding: current.snapshot.inspection.encoding, targetURL: targetURL, isCSV: false
            )
            session?.baseline = payload
            withAnimation(.ttMicro) {
                isSavedToastPresented = true
                saveErrorMessage = nil
            }
            scheduleMetrics(for: payload, totalBytes: encodedByteCount(for: payload))
            NotificationCenter.default.post(name: .ttMediaFileContentDidChange, object: targetURL)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.ttMicro) { isSavedToastPresented = false }
            }
        } catch {
            withAnimation(.ttMicro) { saveErrorMessage = error.localizedDescription }
        }
    }
}
