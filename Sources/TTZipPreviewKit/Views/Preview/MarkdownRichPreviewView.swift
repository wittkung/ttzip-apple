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

/// Preview mode for Markdown document viewing.
public enum MarkdownPreviewMode: String, CaseIterable, Identifiable {
    case rich = "Rich Preview"
    case source = "Source Code"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .rich: return "doc.richtext.fill"
        case .source: return "curlybraces"
        }
    }
}

/// Dual-mode Markdown viewer with rich typography rendering, source editing, and live sync.
public struct MarkdownRichPreviewView: View {
    public let initialMarkdown: String
    public let fileURL: URL?
    public let fileName: String
    public let isReadOnly: Bool
    
    @State private var mode: MarkdownPreviewMode = .rich
    @State private var markdownContent: String = ""
    @State private var isEdited: Bool = false
    @State private var isSavedToastPresented: Bool = false
    @State private var saveErrorMessage: String? = nil
    
    private static let validMarkdownExtensions: Set<String> = PreviewCapabilityMatrix.markdownExtensions
    
    /// Determines whether the document is a native, genuinely writable Markdown file on the local filesystem.
    /// Excludes read-only files, non-file URLs, and converted formats such as DOCX or RTF.
    private var isNativeWritableMarkdown: Bool {
        guard !isReadOnly else { return false }
        guard let url = fileURL, url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        guard Self.validMarkdownExtensions.contains(ext) else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: url.path)
    }
    
    public init(
        initialMarkdown: String,
        fileURL: URL? = nil,
        fileName: String = "",
        isReadOnly: Bool = false
    ) {
        self.initialMarkdown = initialMarkdown
        self.fileURL = fileURL
        self.fileName = fileName.isEmpty ? (fileURL?.lastPathComponent ?? "Markdown Document") : fileName
        self.isReadOnly = isReadOnly
        self._markdownContent = State(initialValue: initialMarkdown)
    }
    
    private var characterCount: Int { markdownContent.count }
    private var wordCount: Int { markdownContent.split { $0.isWhitespace || $0.isPunctuation }.count }
    private var lineCount: Int { markdownContent.components(separatedBy: "\n").count }
    
    public var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width <= 480
            VStack(spacing: 0) {
                // 1. Top Control & Mode Switcher Bar (Adaptive Compact vs Full)
                MarkdownPreviewToolbarView(
                    isCompact: isCompact,
                    fileName: fileName,
                    fileURL: fileURL,
                    lineCount: lineCount,
                    wordCount: wordCount,
                    characterCount: characterCount,
                    isNativeWritableMarkdown: isNativeWritableMarkdown,
                    isEdited: isEdited,
                    isSavedToastPresented: isSavedToastPresented,
                    mode: $mode,
                    onCopy: { copyMarkdownToClipboard() },
                    onSave: { saveFile() }
                )
                
                Divider()
                
                // 2. Main Content Canvas (Rich Preview vs Source Editor)
                ZStack {
                    if mode == .rich {
                        MarkdownNativeWKWebView(markdownText: markdownContent, baseURL: fileURL)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        CodeHighlightingEditorNSView(
                            text: $markdownContent,
                            fileName: fileName.isEmpty ? "document.md" : fileName,
                            onTextChange: { newText in
                                if isNativeWritableMarkdown && newText != initialMarkdown {
                                    isEdited = true
                                }
                            },
                            onSaveShortcut: isNativeWritableMarkdown ? { saveFile() } : nil
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: initialMarkdown) {
            markdownContent = initialMarkdown
            isEdited = false
        }
    }
    
    // MARK: - Actions
    
    private func copyMarkdownToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdownContent, forType: .string)
    }
    
    private func saveFile() {
        guard isNativeWritableMarkdown, let url = fileURL, url.isFileURL else { return }
        do {
            try markdownContent.write(to: url, atomically: true, encoding: .utf8)
            withAnimation {
                isEdited = false
                isSavedToastPresented = true
            }
            NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation {
                    isSavedToastPresented = false
                }
            }
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}
