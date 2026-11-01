// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Geometry and layout constants for synchronized hex preview canvas and header bar.
public enum HexMetrics: Sendable {
    /// Baseline offset column width (points) unifying header and text canvas.
    public static let offsetColumnWidth: CGFloat = 84.0
    /// Standard monospaced font size used across hex editor canvas and header bar.
    public static let fontSize: CGFloat = 12.0
    /// Horizontal inset margin for outer container alignment.
    public static let horizontalPadding: CGFloat = 14.0
}

/// Native high-performance selectable hex NSTextView with syntax coloring and column formatting.
public struct HexEditorNSView: NSViewRepresentable {
    public let pageData: Data
    public let startOffset: Int64
    
    public init(pageData: Data, startOffset: Int64) {
        self.pageData = pageData
        self.startOffset = startOffset
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
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
        textView.font = NSFont.monospacedSystemFont(ofSize: HexMetrics.fontSize, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: HexMetrics.horizontalPadding, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        
        if let container = textView.textContainer {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude)
            container.lineFragmentPadding = 0
        }
        
        context.coordinator.renderAttributedHexDump(data: pageData, startOffset: startOffset, in: textView)
        scrollView.documentView = textView
        return scrollView
    }
    
    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.renderAttributedHexDump(data: pageData, startOffset: startOffset, in: textView)
    }
    
    @MainActor
    public class Coordinator {
        private var lastRenderedSignature: String = ""
        
        public func renderAttributedHexDump(data: Data, startOffset: Int64, in textView: NSTextView) {
            let signature = "\(startOffset)_\(data.count)_\(data.prefix(32).hashValue)"
            guard signature != lastRenderedSignature else { return }
            lastRenderedSignature = signature
            
            let attrStr = NSMutableAttributedString()
            let count = data.count
            
            let monoFont = NSFont.monospacedSystemFont(ofSize: HexMetrics.fontSize, weight: .regular)
            let boldMonoFont = NSFont.monospacedSystemFont(ofSize: HexMetrics.fontSize, weight: .bold)
            
            let offsetColor = NSColor(red: 0.20, green: 0.70, blue: 0.50, alpha: 1.0)
            let separatorColor = NSColor.separatorColor
            let normalHexColor = NSColor.labelColor
            let zeroHexColor = NSColor.labelColor.withAlphaComponent(0.32)
            let highHexColor = NSColor(red: 0.75, green: 0.45, blue: 0.90, alpha: 1.0)
            let asciiPrintableColor = NSColor.labelColor
            let asciiDotColor = NSColor.secondaryLabelColor.withAlphaComponent(0.4)
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.tabStops = [
                NSTextTab(textAlignment: .left, location: HexMetrics.offsetColumnWidth, options: [:])
            ]
            
            for lineStart in stride(from: 0, to: count, by: 16) {
                let offset = startOffset + Int64(lineStart)
                let lineEnd = min(lineStart + 16, count)
                let lineSlice = data.subdata(in: lineStart..<lineEnd)
                
                // 1. Offset Column (e.g. 00000000)
                let offsetString = String(format: "%08X", offset)
                attrStr.append(NSAttributedString(string: offsetString, attributes: [
                    .font: boldMonoFont,
                    .foregroundColor: offsetColor
                ]))
                
                attrStr.append(NSAttributedString(string: "\t", attributes: [
                    .font: monoFont,
                    .foregroundColor: separatorColor
                ]))
                
                // 2. Hex Group 1 (8 bytes)
                var bytesWritten = 0
                for i in 0..<8 {
                    if i < lineSlice.count {
                        let byte = lineSlice[i]
                        let hexByte = String(format: "%02X", byte)
                        let color = (byte == 0) ? zeroHexColor : ((byte > 0x7F) ? highHexColor : normalHexColor)
                        attrStr.append(NSAttributedString(string: hexByte, attributes: [
                            .font: monoFont,
                            .foregroundColor: color
                        ]))
                    } else {
                        attrStr.append(NSAttributedString(string: "  ", attributes: [.font: monoFont]))
                    }
                    if i < 7 {
                        attrStr.append(NSAttributedString(string: " ", attributes: [.font: monoFont]))
                    }
                    bytesWritten += 1
                }
                
                // Middle gap
                attrStr.append(NSAttributedString(string: "   ", attributes: [.font: monoFont]))
                
                // 3. Hex Group 2 (8 bytes)
                for i in 8..<16 {
                    if i < lineSlice.count {
                        let byte = lineSlice[i]
                        let hexByte = String(format: "%02X", byte)
                        let color = (byte == 0) ? zeroHexColor : ((byte > 0x7F) ? highHexColor : normalHexColor)
                        attrStr.append(NSAttributedString(string: hexByte, attributes: [
                            .font: monoFont,
                            .foregroundColor: color
                        ]))
                    } else {
                        attrStr.append(NSAttributedString(string: "  ", attributes: [.font: monoFont]))
                    }
                    if i < 15 {
                        attrStr.append(NSAttributedString(string: " ", attributes: [.font: monoFont]))
                    }
                }
                
                // Spacer between Hex and ASCII
                attrStr.append(NSAttributedString(string: "   |", attributes: [
                    .font: monoFont,
                    .foregroundColor: separatorColor
                ]))
                
                // 4. ASCII Representation
                for i in 0..<16 {
                    if i < lineSlice.count {
                        let byte = lineSlice[i]
                        if byte >= 32 && byte <= 126 {
                            let charStr = String(UnicodeScalar(byte))
                            attrStr.append(NSAttributedString(string: charStr, attributes: [
                                .font: monoFont,
                                .foregroundColor: asciiPrintableColor
                            ]))
                        } else {
                            attrStr.append(NSAttributedString(string: "·", attributes: [
                                .font: monoFont,
                                .foregroundColor: asciiDotColor
                            ]))
                        }
                    } else {
                        attrStr.append(NSAttributedString(string: " ", attributes: [.font: monoFont]))
                    }
                }
                
                attrStr.append(NSAttributedString(string: "|\n", attributes: [
                    .font: monoFont,
                    .foregroundColor: separatorColor
                ]))
            }
            
            if attrStr.length > 0 {
                attrStr.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attrStr.length))
            }
            textView.textStorage?.setAttributedString(attrStr)
        }
    }
}

/// Dedicated background actor for asynchronous non-blocking hex page chunk loading.
public actor HexDataChunkLoaderActor {
    public static let shared = HexDataChunkLoaderActor()
    
    private init() {}
    
    public func loadChunk(from url: URL, offset: Int64, length: Int) -> Data {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return Data()
        }
        defer { try? fileHandle.close() }
        try? fileHandle.seek(toOffset: UInt64(max(0, offset)))
        return (try? fileHandle.read(upToCount: length)) ?? Data()
    }
}
