// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

#if os(macOS)
import AppKit
import QuickLookUI
import SwiftUI

/// Native AppKit QLPreviewView bridging macOS system QuickLook engine for office documents and spreadsheets.
public struct QuickLookNativePreviewView: NSViewRepresentable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        preview.previewItem = url as QLPreviewItem
        preview.autoresizingMask = [.width, .height]
        return preview
    }

    public func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as QLPreviewItem
        }
    }
}
#endif
