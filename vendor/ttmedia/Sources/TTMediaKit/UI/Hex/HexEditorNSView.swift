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
    private let offsetColor: NSColor
    private let highByteColor: NSColor
    
    public init(
        pageData: Data,
        startOffset: Int64,
        offsetColor: NSColor = .secondaryLabelColor,
        highByteColor: NSColor = .labelColor
    ) {
        self.pageData = pageData
        self.startOffset = startOffset
        self.offsetColor = offsetColor
        self.highByteColor = highByteColor
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
        
        scrollView.documentView = textView
        context.coordinator.renderAttributedHexDump(
            data: pageData,
            startOffset: startOffset,
            offsetColor: offsetColor,
            highByteColor: highByteColor,
            in: textView
        )
        return scrollView
    }
    
    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.renderAttributedHexDump(
            data: pageData,
            startOffset: startOffset,
            offsetColor: offsetColor,
            highByteColor: highByteColor,
            in: textView
        )
    }
    
    @MainActor
    public class Coordinator {
        private struct RenderKey: Equatable {
            let contentSignature: String
            let offsetColor: NSColor
            let highByteColor: NSColor
        }

        private var lastRenderKey: RenderKey?
        
        private struct AttributedHexDumpBuilder {
            let offsetAttributes: [NSAttributedString.Key: Any]
            let separatorAttributes: [NSAttributedString.Key: Any]
            let plainMonoAttributes: [NSAttributedString.Key: Any]
            let normalHexAttributes: [NSAttributedString.Key: Any]
            let zeroHexAttributes: [NSAttributedString.Key: Any]
            let highHexAttributes: [NSAttributedString.Key: Any]
            let asciiPrintableAttributes: [NSAttributedString.Key: Any]
            let asciiDotAttributes: [NSAttributedString.Key: Any]
            let paragraphStyle: NSParagraphStyle

            init(offsetColor: NSColor, highByteColor: NSColor) {
                let monoFont = NSFont.monospacedSystemFont(ofSize: HexMetrics.fontSize, weight: .regular)
                let boldMonoFont = NSFont.monospacedSystemFont(ofSize: HexMetrics.fontSize, weight: .bold)

                offsetAttributes = [.font: boldMonoFont, .foregroundColor: offsetColor]
                separatorAttributes = [.font: monoFont, .foregroundColor: NSColor.separatorColor]
                plainMonoAttributes = [.font: monoFont]
                normalHexAttributes = [.font: monoFont, .foregroundColor: NSColor.labelColor]
                zeroHexAttributes = [.font: monoFont, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.32)]
                highHexAttributes = [.font: monoFont, .foregroundColor: highByteColor]
                asciiPrintableAttributes = [.font: monoFont, .foregroundColor: NSColor.labelColor]
                asciiDotAttributes = [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.4)]

                let style = NSMutableParagraphStyle()
                style.tabStops = [
                    NSTextTab(textAlignment: .left, location: HexMetrics.offsetColumnWidth, options: [:])
                ]
                paragraphStyle = style
            }

            func build(data: Data, startOffset: Int64) -> NSAttributedString {
                let output = NSMutableAttributedString()
                for lineStart in stride(from: 0, to: data.count, by: 16) {
                    let lineEnd = min(lineStart + 16, data.count)
                    let lineSlice = data.subdata(in: lineStart..<lineEnd)
                    appendLine(into: output, offset: startOffset + Int64(lineStart), lineSlice: lineSlice)
                }
                if output.length > 0 {
                    output.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: output.length))
                }
                return output
            }

            private func appendLine(into output: NSMutableAttributedString, offset: Int64, lineSlice: Data) {
                output.append(NSAttributedString(string: String(format: "%08X", offset), attributes: offsetAttributes))
                output.append(NSAttributedString(string: "\t", attributes: separatorAttributes))
                appendHexGroup(into: output, lineSlice: lineSlice, range: 0..<8)
                output.append(NSAttributedString(string: "   ", attributes: plainMonoAttributes))
                appendHexGroup(into: output, lineSlice: lineSlice, range: 8..<16)
                output.append(NSAttributedString(string: "   |", attributes: separatorAttributes))
                appendASCIIColumn(into: output, lineSlice: lineSlice)
                output.append(NSAttributedString(string: "|\n", attributes: separatorAttributes))
            }

            private func appendHexGroup(into output: NSMutableAttributedString, lineSlice: Data, range: Range<Int>) {
                for index in range {
                    if index < lineSlice.count {
                        let byte = lineSlice[index]
                        let attributes = hexAttributes(for: byte)
                        output.append(NSAttributedString(string: String(format: "%02X", byte), attributes: attributes))
                    } else {
                        output.append(NSAttributedString(string: "  ", attributes: plainMonoAttributes))
                    }
                    if index < range.upperBound - 1 {
                        output.append(NSAttributedString(string: " ", attributes: plainMonoAttributes))
                    }
                }
            }

            private func hexAttributes(for byte: UInt8) -> [NSAttributedString.Key: Any] {
                if byte == 0 {
                    return zeroHexAttributes
                }
                return byte > 0x7F ? highHexAttributes : normalHexAttributes
            }

            private func appendASCIIColumn(into output: NSMutableAttributedString, lineSlice: Data) {
                for index in 0..<16 {
                    guard index < lineSlice.count else {
                        output.append(NSAttributedString(string: " ", attributes: plainMonoAttributes))
                        continue
                    }
                    let byte = lineSlice[index]
                    if byte >= 32, byte <= 126 {
                        output.append(NSAttributedString(string: String(UnicodeScalar(byte)), attributes: asciiPrintableAttributes))
                    } else {
                        output.append(NSAttributedString(string: "·", attributes: asciiDotAttributes))
                    }
                }
            }
        }

        public func renderAttributedHexDump(
            data: Data,
            startOffset: Int64,
            offsetColor: NSColor = .secondaryLabelColor,
            highByteColor: NSColor = .labelColor,
            in textView: NSTextView
        ) {
            let renderKey = RenderKey(
                contentSignature: "\(startOffset)_\(data.count)_\(data.prefix(32).hashValue)",
                offsetColor: offsetColor,
                highByteColor: highByteColor
            )
            guard renderKey != lastRenderKey else { return }
            let contentChanged = renderKey.contentSignature != lastRenderKey?.contentSignature
            lastRenderKey = renderKey

            let builder = AttributedHexDumpBuilder(offsetColor: offsetColor, highByteColor: highByteColor)
            let attributedDump = builder.build(data: data, startOffset: startOffset)

            let selectedRanges = textView.selectedRanges
            textView.textStorage?.setAttributedString(attributedDump)
            guard contentChanged else {
                textView.selectedRanges = selectedRanges
                return
            }
            resetSelectionAndScroll(in: textView)
        }

        private func resetSelectionAndScroll(in textView: NSTextView) {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            guard let scrollView = textView.enclosingScrollView else { return }
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            var ancestor = scrollView.superview
            while let view = ancestor {
                if let outerScroll = view as? NSScrollView {
                    outerScroll.contentView.scroll(to: .zero)
                    outerScroll.reflectScrolledClipView(outerScroll.contentView)
                }
                ancestor = view.superview
            }
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
