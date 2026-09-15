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
                CodeSyntaxHeaderBar(
                    isCompact: isCompact,
                    fileName: fileName,
                    lineCount: lineCount,
                    byteCount: byteCount,
                    isEdited: isEdited,
                    isWritableFile: isWritableFile,
                    saveErrorMessage: saveErrorMessage,
                    isSavedToastPresented: isSavedToastPresented,
                    isCopiedToastPresented: isCopiedToastPresented,
                    showLineNumbers: $showLineNumbers,
                    onCopy: { copyToClipboard() },
                    onSave: {
                        if isEdited {
                            saveFile()
                        }
                    }
                )
                
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
    
    // MARK: - Actions & Metrics
    
    private func updateMetrics(for text: String) {
        byteCount = Int64(text.utf8.count)
        lineCount = text.utf8.reduce(into: 1) { count, byte in
            if byte == 10 { count += 1 }
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

// MARK: - Backward-Compatible Facade Alias

/// Backward-compatible typealias mapping `CodeSyntaxPreviewView` directly to `CodeTextEditorContainerView`.
public typealias CodeSyntaxPreviewView = CodeTextEditorContainerView

public extension CodeTextEditorContainerView {
    /// Backward-compatible convenience initializer matching previous adapter signature.
    init(
        content: String,
        fileURL: URL? = nil,
        fileName: String = "",
        onSave: ((String) -> Void)? = nil
    ) {
        self.init(
            initialText: content,
            fileURL: fileURL,
            fileName: fileName.isEmpty ? (fileURL?.lastPathComponent ?? "document.txt") : fileName
        )
    }
}
