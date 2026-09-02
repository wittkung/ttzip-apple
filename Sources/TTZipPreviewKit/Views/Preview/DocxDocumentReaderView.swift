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

public struct DocxDocumentReaderView: View {
    public let attributedString: NSAttributedString?
    public let markdownContent: String?
    public let url: URL?
    
    public init(attributedString: NSAttributedString, url: URL? = nil) {
        self.attributedString = attributedString
        self.markdownContent = nil
        self.url = url
    }
    
    public init(markdownContent: String, url: URL? = nil) {
        self.attributedString = nil
        self.markdownContent = markdownContent
        self.url = url
    }
    
    public var body: some View {
        if let md = markdownContent, !md.isEmpty {
            MarkdownRichPreviewView(
                initialMarkdown: md,
                fileURL: url,
                fileName: url?.lastPathComponent ?? "Document.docx"
            )
        } else if let attrStr = attributedString {
            DocxTextEditorNSView(attributedString: attrStr)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Unable to render document content.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

public struct DocxTextEditorNSView: NSViewRepresentable {
    public let attributedString: NSAttributedString
    
    public init(attributedString: NSAttributedString) {
        self.attributedString = attributedString
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
        
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        }
        
        let mutableAttrStr = NSMutableAttributedString(attributedString: attributedString)
        let fullRange = NSRange(location: 0, length: mutableAttrStr.length)
        
        mutableAttrStr.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                mutableAttrStr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        
        textView.textStorage?.setAttributedString(mutableAttrStr)
        scrollView.documentView = textView
        return scrollView
    }
    
    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.attributedString() != attributedString {
            let mutableAttrStr = NSMutableAttributedString(attributedString: attributedString)
            let fullRange = NSRange(location: 0, length: mutableAttrStr.length)
            mutableAttrStr.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
                if value == nil {
                    mutableAttrStr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                }
            }
            textView.textStorage?.setAttributedString(mutableAttrStr)
        }
    }
}
