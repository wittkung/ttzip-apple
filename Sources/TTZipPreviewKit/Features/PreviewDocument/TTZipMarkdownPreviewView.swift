// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit

struct TTZipMarkdownPreviewView: View {
    let initialMarkdown: String
    let initialByteCount: Int64
    let sourceEncoding: TTTextSourceEncoding
    let isTruncatedForPreview: Bool
    let fileURL: URL?
    let fileName: String
    let resourceContext: TTPreviewResourceContext
    private let isReadOnly: Bool
    private let explicitReadingPreferenceStore: TTTextReadingPreferenceStore?

    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: MarkdownPreviewMode
    @State private var markdownContent: String = ""
    @State private var isEdited: Bool = false
    @State private var isSavedToastPresented: Bool = false
    @State private var saveErrorMessage: String? = nil
    @State private var runtimeByteCountOverride: Int64? = nil
    @State private var savedBaselineContent: String? = nil
    @State private var baselineTracker: TTSavedBaselineTracker
    @State private var lastLoadedTaskIdentity: String = ""

    private static let validMarkdownExtensions: Set<String> = TTMediaCapabilityMatrix.markdownExtensions

    private var validatedSaveURL: URL? {
        guard !isReadOnly, !isTruncatedForPreview, sourceEncoding.allowsUTF8InPlaceSave else {
            return nil
        }
        return resourceContext.validateInPlaceSaveTarget(
            expectedFileURL: fileURL,
            fileName: fileName,
            allowedExtensions: Self.validMarkdownExtensions,
            isTruncated: isTruncatedForPreview
        )
    }

    var canSaveInPlace: Bool {
        validatedSaveURL != nil
    }

    private var isNonUTF8ReadOnly: Bool {
        !sourceEncoding.allowsUTF8InPlaceSave && fileURL != nil
    }

    var displayedByteCount: Int64 {
        if canSaveInPlace && isEdited {
            return Int64(markdownContent.utf8.count + (sourceEncoding == .utf8BOM ? 3 : 0))
        }
        return runtimeByteCountOverride ?? initialByteCount
    }

    init(
        initialMarkdown: String,
        fileURL: URL?,
        fileName: String,
        resourceContext: TTPreviewResourceContext,
        initialMode: MarkdownPreviewMode = .rich,
        readingPreferenceStore: TTTextReadingPreferenceStore? = nil
    ) {
        self.initialMarkdown = initialMarkdown
        self.fileURL = fileURL
        self.fileName = fileName
        self.resourceContext = resourceContext
        self.explicitReadingPreferenceStore = readingPreferenceStore
        self._mode = State(initialValue: initialMode)
        let isReadOnly = !resourceContext.isEditableInPlace
        self.isReadOnly = isReadOnly
        let inspection = TTTextSourceInspection.inspect(url: fileURL, fallbackText: initialMarkdown)
        self.initialByteCount = inspection.byteCount
        self.sourceEncoding = inspection.encoding
        let (display, truncated) = TTTextPreviewBytePolicy.truncateForPreview(initialMarkdown)
        self.isTruncatedForPreview = truncated
        self._baselineTracker = State(initialValue: TTSavedBaselineTracker(
            initialContent: display,
            fileURL: fileURL,
            allowsDiskBaselineLoad: !isReadOnly && !truncated && inspection.encoding.allowsUTF8InPlaceSave
        ))
        self._markdownContent = State(initialValue: display)
        self._lastLoadedTaskIdentity = State(initialValue: Self.documentIdentity(
            fileName: fileName, byteCount: inspection.byteCount, encoding: inspection.encoding,
            readableURL: fileURL, markdown: initialMarkdown
        ))
    }

    var currentSavedBaselineContent: String {
        baselineTracker.activeBaseline(
            hasContentOverride: true,
            stateBaseline: savedBaselineContent
        )
    }

    private var taskIdentityKey: String {
        Self.documentIdentity(
            fileName: fileName, byteCount: initialByteCount, encoding: sourceEncoding,
            readableURL: resourceContext.readableURL, markdown: initialMarkdown
        )
    }

    private static func documentIdentity(
        fileName: String,
        byteCount: Int64,
        encoding: TTTextSourceEncoding,
        readableURL: URL?,
        markdown: String
    ) -> String {
        "\(fileName)|\(byteCount)|\(encoding.rawValue)|\(readableURL?.path ?? "")|\(markdown.prefix(64))"
    }

    private var characterCount: Int { markdownContent.count }
    private var wordCount: Int { markdownContent.split { $0.isWhitespace || $0.isPunctuation }.count }
    private var lineCount: Int { markdownContent.components(separatedBy: "\n").count }

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width <= 560
            VStack(spacing: 0) {
                TTZipMarkdownPreviewToolbar(
                    isCompact: isCompact,
                    lineCount: lineCount,
                    wordCount: wordCount,
                    characterCount: characterCount,
                    byteCount: displayedByteCount,
                    encodingBadge: sourceEncoding.displayBadge,
                    isNativeWritableMarkdown: canSaveInPlace,
                    isEdited: canSaveInPlace && isEdited,
                    isSavedToastPresented: isSavedToastPresented,
                    mode: $mode,
                    onCopy: { copyMarkdownToClipboard() },
                    onSave: { _ = saveFile() }
                )

                if isTruncatedForPreview {
                    truncationWarningBanner
                } else if isNonUTF8ReadOnly {
                    encodingReadOnlyBanner
                }

                Divider()

                ZStack {
                    if mode == .rich {
                        TTZipMarkdownDocumentView(
                            markdown: markdownContent,
                            documentIdentity: taskIdentityKey
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        let readingPreferenceStore = explicitReadingPreferenceStore ?? .shared
                        CodeHighlightingEditorNSView(
                            text: $markdownContent,
                            fileName: fileName.isEmpty ? "document.md" : fileName,
                            showLineNumbers: true,
                            isEditable: canSaveInPlace,
                            isSoftWrapEnabled: readingPreferenceStore.isSoftWrapEnabled,
                            readingPalette: TTZipTextReadingAppearance.resolve(
                                mode: readingPreferenceStore.mode, isDarkAppearance: colorScheme == .dark
                            ),
                            onTextChange: canSaveInPlace ? { newText in
                                isEdited = (newText != currentSavedBaselineContent)
                            } : nil,
                            onSaveShortcut: canSaveInPlace ? { _ = saveFile() } : nil
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                if let errorMessage = saveErrorMessage {
                    Divider()
                    saveErrorBanner(errorMessage)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: taskIdentityKey) {
            reloadMarkdown()
        }
    }

    private func reloadMarkdown() {
        let currentIdentity = taskIdentityKey
        let didChangeDocument = lastLoadedTaskIdentity != currentIdentity
        guard didChangeDocument || !isEdited else { return }
        let (display, _) = TTTextPreviewBytePolicy.truncateForPreview(initialMarkdown)
        if didChangeDocument {
            lastLoadedTaskIdentity = currentIdentity
            isEdited = false
            saveErrorMessage = nil
            runtimeByteCountOverride = nil
        }
        markdownContent = display
        savedBaselineContent = nil
        baselineTracker.reset(
            initialContent: display,
            fileURL: fileURL,
            allowsDiskBaselineLoad: !isReadOnly
                && !isTruncatedForPreview && sourceEncoding.allowsUTF8InPlaceSave
        )
    }

    private var truncationWarningBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(TextAndDocumentPreviewLocalization.truncationBanner())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.12))
    }

    private var encodingReadOnlyBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.doc.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
            Text(TextAndDocumentPreviewLocalization.encodingReadOnlyBanner(encodingName: sourceEncoding.displayBadge))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
    }

    private func saveErrorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.red)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button {
                withAnimation {
                    saveErrorMessage = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.red.opacity(0.12))
    }

    private func copyMarkdownToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdownContent, forType: .string)
    }

    @discardableResult
    func saveFile(contentOverride: String? = nil) -> Bool {
        guard canSaveInPlace,
              let targetURL = validatedSaveURL else {
            return false
        }
        let payload = contentOverride ?? markdownContent
        guard payload.utf8.count <= TTTextPreviewBytePolicy.maxInteractiveTextUTF8Bytes else {
            return false
        }
        do {
            let activeEncoding = sourceEncoding
            let expectedBaseline = baselineTracker.activeBaseline(
                hasContentOverride: contentOverride != nil,
                stateBaseline: savedBaselineContent
            )
            _ = try TTControlledTextSaveTransaction.commit(
                payload: payload,
                expectedBaseline: expectedBaseline,
                encoding: activeEncoding,
                targetURL: targetURL,
                isCSV: false
            )
            baselineTracker.recordSave(payload)
            savedBaselineContent = payload
            if contentOverride != nil {
                markdownContent = payload
            }
            runtimeByteCountOverride = Int64(payload.utf8.count + (activeEncoding == .utf8BOM ? 3 : 0))
            withAnimation {
                isEdited = false
                isSavedToastPresented = true
                saveErrorMessage = nil
            }
            NotificationCenter.default.post(name: NSNotification.Name("TTMediaArchiveUnlockedRefreshNotification"), object: nil)
            NotificationCenter.default.post(name: .ttMediaFileContentDidChange, object: targetURL)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.0))
                withAnimation {
                    isSavedToastPresented = false
                }
            }
            return true
        } catch {
            saveErrorMessage = error.localizedDescription
            return false
        }
    }
}
