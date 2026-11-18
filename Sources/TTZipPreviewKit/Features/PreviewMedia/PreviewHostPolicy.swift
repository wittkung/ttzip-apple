// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit

/// Layout classification for the public preview host.
/// Distinguishes full-bleed media canvases (video/image/audio) from structured documents with their own top toolbars.
public enum PreviewHostLayoutClass: String, Sendable, Equatable {
    case canvasMedia
    case structuredDocument
}

extension TTMediaPreviewType {
    /// Determines whether the preview host should mount a full-bleed canvas HUD or a stacked non-occluding document header.
    public var hostLayoutClass: PreviewHostLayoutClass {
        switch self {
        case .video, .image, .audio:
            return .canvasMedia
        case .pdf, .pdfData, .text, .docxDocument, .epubBook, .ebook,
             .hexViewer, .markdown, .htmlWeb, .spreadsheetTable, .officeSpreadsheet,
             .officePresentation, .quickLook, .unsupported:
            return .structuredDocument
        }
    }

    /// Returns `true` when the preview component owns horizontal arrow keys (`←` / `→`) for internal pagination,
    /// scrubbing, or cursor movement, prohibiting outer file/column switchers from hijacking them.
    public var ownsHorizontalNavigationKeys: Bool {
        switch self {
        case .epubBook, .ebook, .video, .audio,
             .spreadsheetTable, .officeSpreadsheet,
             .pdf, .pdfData, .text, .markdown, .htmlWeb,
             .hexViewer, .docxDocument, .officePresentation:
            return true
        case .image, .quickLook, .unsupported:
            return false
        }
    }
}

/// Describes the usable content bounds and header geometry allocated by the outer preview host (Contract v1).
public struct TTPreviewHostContentGeometry: Sendable, Equatable {
    public static let contractVersion = "v1"
    public let layoutClass: PreviewHostLayoutClass
    public let hostHeaderHeight: CGFloat
    public let contentTopSafeInset: CGFloat
    public let availableSize: CGSize
    public let isStandalonePlaybackWindow: Bool

    public init(
        layoutClass: PreviewHostLayoutClass = .structuredDocument,
        hostHeaderHeight: CGFloat = 0,
        contentTopSafeInset: CGFloat = 0,
        availableSize: CGSize = .zero,
        isStandalonePlaybackWindow: Bool = false
    ) {
        self.layoutClass = layoutClass
        self.hostHeaderHeight = hostHeaderHeight
        self.contentTopSafeInset = contentTopSafeInset
        self.availableSize = availableSize
        self.isStandalonePlaybackWindow = isStandalonePlaybackWindow
    }
}

private struct TTPreviewHostContentGeometryKey: EnvironmentKey {
    static let defaultValue = TTPreviewHostContentGeometry()
}

extension EnvironmentValues {
    public var previewHostContentGeometry: TTPreviewHostContentGeometry {
        get { self[TTPreviewHostContentGeometryKey.self] }
        set { self[TTPreviewHostContentGeometryKey.self] = newValue }
    }
}

/// Policy evaluating whether horizontal arrow keys (`←` / `→`) belong to the active inner preview
/// (such as EPUB pagination, video seek, or text/table cursor) rather than outer file switching (Contract v1).
@MainActor
public enum TTPreviewHorizontalKeyPolicy {
    public static let contractVersion = "v1"

    private static let ebookAndDocumentExtensions: Set<String> = [
        "epub", "mobi", "azw", "azw3", "fb2",
        "pdf", "csv", "tsv", "xlsx", "xlsm", "ods", "numbers",
        "txt", "md", "markdown", "html", "htm", "xhtml",
        "json", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf", "log",
        "swift", "rs", "py", "js", "ts", "jsx", "tsx", "c", "cpp", "h", "hpp",
        "go", "java", "kt", "cs", "rb", "php", "sh", "zsh", "bash", "sql", "css",
        "docx", "pptx", "pages", "key"
    ]

    /// Determines whether the given preview type or file URL owns horizontal arrow keys internally.
    public static func ownsHorizontalArrowKeys(
        previewType: TTMediaPreviewType? = nil,
        url: URL? = nil,
        fileName: String = ""
    ) -> Bool {
        if let previewType {
            if case .unsupported(let msg) = previewType, msg == "Loading..." {
            } else {
                return previewType.ownsHorizontalNavigationKeys
            }
        }
        let candidateName = !fileName.isEmpty ? fileName : (url?.lastPathComponent ?? "")
        let ext = TTMediaCapabilityMatrix.cleanExtension(from: (candidateName as NSString).pathExtension)
        if ebookAndDocumentExtensions.contains(ext) {
            return true
        }
        if TTMediaCapabilityMatrix.videoExtensions.contains(ext) || TTMediaCapabilityMatrix.audioExtensions.contains(ext) {
            if let url, TTMediaCapabilityMatrix.ambiguousExtensions.contains(ext) {
                return TTMediaDetector.detectType(url: url).ownsHorizontalNavigationKeys
            }
            return true
        }
        return false
    }

    /// Returns `true` if `window`'s current first responder is an active text input or IME composition client.
    public static func isWindowTextInputActive(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let inputClient = responder as? NSTextInputClient, inputClient.hasMarkedText() {
            return true
        }
        return responder is NSTextView || responder is NSTextField
    }

    /// Evaluates whether the outer media browser or file switcher is allowed to intercept a horizontal arrow key.
    public static func shouldOuterBrowserInterceptHorizontalArrow(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        eventWindowNumber: Int? = nil,
        hostWindowNumber: Int? = nil,
        isAppKitTextInputActive: Bool = false,
        previewType: TTMediaPreviewType? = nil,
        url: URL? = nil,
        fileName: String = ""
    ) -> Bool {
        guard keyCode == 123 || keyCode == 124 else { return false }
        let cleanMods = modifiers.intersection(.deviceIndependentFlagsMask)
        if !cleanMods.intersection([.command, .option, .control, .shift]).isEmpty {
            return false
        }
        if let eventWindowNumber, let hostWindowNumber, eventWindowNumber != hostWindowNumber {
            return false
        }
        if isAppKitTextInputActive {
            return false
        }
        let query = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(
            windowNumber: eventWindowNumber ?? hostWindowNumber,
            keyCode: keyCode
        )
        if query.isTextInputActive || query.ownsHorizontalArrowKeys || query.isEventAlreadyHandled {
            return false
        }
        if ownsHorizontalArrowKeys(previewType: previewType, url: url, fileName: fileName) {
            return false
        }
        return true
    }
}

extension TTMediaDetector {
    /// Correctly distinguishes MPEG-TS video (`.canvasMedia`) from TypeScript `.ts` source code (`.structuredDocument`).
    nonisolated public static func inferHostLayoutClass(url: URL, fileName: String = "") -> PreviewHostLayoutClass {
        let fastType = fastTypeByExtension(url: url)
        switch fastType {
        case .video, .audio, .image:
            return .canvasMedia
        case .pdf, .pdfData, .text, .docxDocument, .epubBook, .ebook,
             .hexViewer, .markdown, .htmlWeb, .spreadsheetTable, .officeSpreadsheet,
             .officePresentation, .quickLook:
            return .structuredDocument
        case .unsupported:
            let candidateName = fileName.isEmpty ? url.lastPathComponent : fileName
            let ext = TTMediaCapabilityMatrix.cleanExtension(from: (candidateName as NSString).pathExtension)
            if TTMediaCapabilityMatrix.ambiguousExtensions.contains(ext) {
                return .structuredDocument
            }
            if TTMediaCapabilityMatrix.imageExtensions.contains(ext) && !TTMediaCapabilityMatrix.htmlWebExtensions.contains(ext) {
                return .canvasMedia
            }
            if TTMediaCapabilityMatrix.videoExtensions.contains(ext) || TTMediaCapabilityMatrix.audioExtensions.contains(ext) {
                let detected = detectType(url: url)
                return detected.hostLayoutClass
            }
            return .structuredDocument
        }
    }
}
