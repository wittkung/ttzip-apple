// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

// MARK: - Dedicated Attributed String Viewport

public struct DocxTextEditorNSView: NSViewRepresentable {
    public let attributedString: NSAttributedString
    public let fileURL: URL?

    public init(attributedString: NSAttributedString, fileURL: URL? = nil) {
        self.attributedString = attributedString
        self.fileURL = fileURL
    }

    public final class Coordinator {
        public private(set) var lastFileURL: URL?
        public private(set) var lastAttributedContent: NSAttributedString?

        public init(fileURL: URL?, attributedContent: NSAttributedString) {
            self.lastFileURL = fileURL
            self.lastAttributedContent = NSAttributedString(attributedString: attributedContent)
        }

        public func didChangeDocument(fileURL: URL?, attributedContent: NSAttributedString) -> Bool {
            if lastFileURL != fileURL {
                return true
            }
            guard let lastAttributedContent else { return true }
            return !lastAttributedContent.isEqual(to: attributedContent)
        }

        public func recordDocument(fileURL: URL?, attributedContent: NSAttributedString) {
            self.lastFileURL = fileURL
            self.lastAttributedContent = NSAttributedString(attributedString: attributedContent)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL, attributedContent: attributedString)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 32, height: 28)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        if let container = textView.textContainer {
            container.widthTracksTextView = true
            let initialWidth = scrollView.contentSize.width > 0
                ? scrollView.contentSize.width
                : CGFloat.greatestFiniteMagnitude
            container.containerSize = NSSize(width: initialWidth, height: .greatestFiniteMagnitude)
        }

        textView.textStorage?.setAttributedString(Self.normalizedAttributedContent(from: attributedString))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView.documentView = textView
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        applyUpdate(to: nsView, coordinator: context.coordinator)
    }

    public func applyUpdate(to nsView: NSScrollView, coordinator: Coordinator) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.autoresizingMask != [.width] {
            textView.autoresizingMask = [.width]
        }
        if coordinator.didChangeDocument(fileURL: fileURL, attributedContent: attributedString) {
            coordinator.recordDocument(fileURL: fileURL, attributedContent: attributedString)
            textView.textStorage?.setAttributedString(Self.normalizedAttributedContent(from: attributedString))
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            nsView.contentView.scroll(to: .zero)
            nsView.reflectScrolledClipView(nsView.contentView)
        }
    }

    private static func normalizedAttributedContent(from source: NSAttributedString) -> NSMutableAttributedString {
        let mutableAttrStr = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: mutableAttrStr.length)
        mutableAttrStr.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                mutableAttrStr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        return mutableAttrStr
    }
}
