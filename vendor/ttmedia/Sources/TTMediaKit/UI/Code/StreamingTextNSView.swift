// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// High-performance NSViewRepresentable wrapper around NSTextView for streaming or log output display.
/// Synchronizes with `TTTextReadingPreferenceStore` (`.black`, `.white`, `.fluidTransparent`) and adapts foreground contrast in `.fluidTransparent` mode.
public struct StreamingTextNSView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    private var readingPrefs = TTTextReadingPreferenceStore.shared

    public let text: String
    public let readingBackgroundMode: TTTextReadingBackgroundMode?
    public let isDarkAppearanceOverride: Bool?
    public let isSoftWrapEnabledOverride: Bool?

    public init(
        text: String,
        readingBackgroundMode: TTTextReadingBackgroundMode? = nil,
        isDarkAppearanceOverride: Bool? = nil,
        isSoftWrapEnabledOverride: Bool? = nil
    ) {
        self.text = text
        self.readingBackgroundMode = readingBackgroundMode
        self.isDarkAppearanceOverride = isDarkAppearanceOverride
        self.isSoftWrapEnabledOverride = isSoftWrapEnabledOverride
    }

    @MainActor
    public var resolvedSoftWrapEnabled: Bool {
        isSoftWrapEnabledOverride ?? readingPrefs.isSoftWrapEnabled
    }

    @MainActor
    public var resolvedReadingPalette: TTTextReadingPalette {
        let mode = readingBackgroundMode ?? readingPrefs.mode
        let isDark = isDarkAppearanceOverride ?? (colorScheme == .dark)
        return TTTextReadingPalette.resolve(mode: mode, isDarkAppearance: isDark)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let isSoftWrap = resolvedSoftWrapEnabled
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !isSoftWrap
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isHorizontallyResizable = !isSoftWrap
        textView.textContainer?.widthTracksTextView = isSoftWrap
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.layoutManager?.backgroundLayoutEnabled = true
        textView.string = text

        Self.applyPalette(resolvedReadingPalette, to: textView, scrollView: scrollView)
        scrollView.documentView = textView
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        let isSoftWrap = resolvedSoftWrapEnabled
        let savedSelection = textView.selectedRanges
        if textView.string != text {
            textView.string = text
        }
        nsView.hasHorizontalScroller = !isSoftWrap
        textView.isHorizontallyResizable = !isSoftWrap
        textView.textContainer?.widthTracksTextView = isSoftWrap
        Self.applyPalette(resolvedReadingPalette, to: textView, scrollView: nsView)
        if textView.string == text {
            textView.selectedRanges = savedSelection
        }
    }

    @MainActor
    public static func applyPalette(
        _ palette: TTTextReadingPalette,
        to textView: NSTextView,
        scrollView: NSScrollView?
    ) {
        if let scrollView {
            scrollView.drawsBackground = palette.drawsOpaqueBackground
            scrollView.backgroundColor = palette.nsCanvasBackgroundColor
            scrollView.contentView.drawsBackground = palette.drawsOpaqueBackground
            scrollView.contentView.backgroundColor = palette.nsCanvasBackgroundColor
        }
        textView.drawsBackground = palette.drawsOpaqueBackground
        textView.backgroundColor = palette.nsCanvasBackgroundColor
        textView.textColor = palette.nsForegroundColor
        textView.insertionPointColor = palette.nsInsertionPointColor
        textView.selectedTextAttributes = [
            .backgroundColor: palette.nsSelectionBackgroundColor,
            .foregroundColor: palette.nsSelectionTextColor
        ]
    }
}
