// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AVKit
import PDFKit
import WebKit
import TTZipCore
import TTZipUI

private struct ImmersiveFullscreenKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    public var isImmersiveFullscreen: Bool {
        get { self[ImmersiveFullscreenKey.self] }
        set { self[ImmersiveFullscreenKey.self] = newValue }
    }
}

/// Media preview router and container view for native formats.
public struct MediaPreviewView: View {
    @Environment(\.isImmersiveFullscreen) private var envIsImmersiveFullscreen: Bool
    private var l10n = AppLocalizationState.shared
    public let isImmersiveFullscreen: Bool?
    let fileURL: URL?
    let fileName: String
    
    @State private var previewType: MediaPreviewType = .unsupported("Loading...")
    @State private var previewTask: Task<Void, Never>?
    @State private var isExtractingTemp = false
    @State private var isFullScreenActive = false
    @State private var isHovered = false
    
    public init(fileURL: URL?, fileName: String, isImmersiveFullscreen: Bool? = nil) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.isImmersiveFullscreen = isImmersiveFullscreen
        if let url = fileURL {
            _previewType = State(initialValue: MediaPreviewFactory.fastTypeByExtension(url: url))
        } else {
            _previewType = State(initialValue: .unsupported("Select a file from the explorer to preview"))
        }
    }
    
    private var effectiveIsImmersive: Bool {
        isImmersiveFullscreen ?? envIsImmersiveFullscreen
    }
    
    /// Sanitized file URL passed down to child preview views.
    /// Prevents passing disk file URLs for converted documents (such as DOCX converted to Markdown),
    /// which would otherwise allow destructive plain-text writeback to binary formats.
    private var effectiveFileURL: URL? {
        if let url = fileURL, MediaPreviewFactory.docxExtensions.contains(url.pathExtension.lowercased()) {
            return nil
        }
        switch previewType {
        case .markdown(_, let targetURL):
            return targetURL
        case .htmlWeb(_, let targetURL):
            return targetURL ?? fileURL
        default:
            return fileURL
        }
    }

    /// Determines whether the outer floating fullscreen capsule button should be displayed.
    /// Expanded to support images, PDFs, videos, web documents, Markdown, plain/code text,
    /// spreadsheets, audio, ebooks, and office documents.
    private var showsFloatingFullScreenButton: Bool {
        if effectiveIsImmersive { return false }
        switch previewType {
        case .image, .pdf, .pdfData, .video, .htmlWeb, .markdown, .text, .spreadsheetTable, .audio,
             .epubBook, .ebook, .docxDocument, .officeSpreadsheet, .officePresentation, .hexViewer:
            return true
        case .unsupported, .pluginView:
            return false
        }
    }
    
    private func toggleFullScreen() {
        isFullScreenActive.toggle()
        if let targetURL = effectiveFileURL ?? fileURL {
            let userInfo: [String: Any] = [
                "url": targetURL,
                "name": fileName
            ]
            NotificationCenter.default.post(
                name: NSNotification.Name("TTZipToggleMediaFocusNotification"),
                object: targetURL,
                userInfo: userInfo
            )
        } else {
            NotificationCenter.default.post(
                name: NSNotification.Name("TTZipToggleMediaFocusNotification"),
                object: nil
            )
        }
    }
    
    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            
            MediaPreviewFactory.makePreviewView(
                type: previewType,
                fileName: fileName,
                fileURL: effectiveFileURL,
                isFullScreenActive: effectiveIsImmersive || isFullScreenActive
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            if showsFloatingFullScreenButton {
                Button(action: { toggleFullScreen() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                        Text(l10n.t(L10n.Preview.fullScreen))
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .padding(12)
                .help("Toggle fullscreen preview (or double-click canvas)")
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: fileURL) {
            loadPreview()
        }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
        }
    }
    
    private var mediaIconName: String {
        return MediaPreviewFactory.iconName(for: fileName)
    }
    
    private func loadPreview() {
        previewTask?.cancel()
        guard let url = fileURL else {
            previewType = .unsupported("Select a file from the explorer to preview")
            return
        }
        let targetURL = url
        previewTask = Task { @MainActor in
            // 120ms debounce to prevent task avalanche during rapid navigation
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            
            let deepType = await MediaPreviewFactory.detectTypeAsync(url: targetURL)
            guard !Task.isCancelled else { return }
            
            if self.fileURL == targetURL {
                switch (self.previewType, deepType) {
                case (.video, .video), (.audio, .audio):
                    break
                default:
                    self.previewType = deepType
                }
            }
        }
    }

    nonisolated public static func readTextContent(from url: URL) -> String? {
        PreviewContentReader.readTextContent(from: url)
    }
    
    nonisolated public static func decodeText(data: Data) -> String? {
        PreviewContentReader.decodeText(data: data)
    }
}
