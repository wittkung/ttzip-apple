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

/// Page size options for Hex data viewer pagination.
public enum HexPageSizeOption: Int, CaseIterable, Identifiable {
    case oneKilobyte = 1024
    case twoKilobytes = 2048
    case fourKilobytes = 4096
    case eightKilobytes = 8192
    
    public var id: Int { rawValue }
    
    public var displayName: String {
        switch self {
        case .oneKilobyte: return "1 KB (64 lines)"
        case .twoKilobytes: return "2 KB (128 lines)"
        case .fourKilobytes: return "4 KB (256 lines)"
        case .eightKilobytes: return "8 KB (512 lines)"
        }
    }
}

/// Professional hex data and binary file previewer with pagination, three-column alignment, and copy tools.
public struct HexDataPreviewView: View {
    public let initialData: Data
    public let fileURL: URL?
    public let fileName: String
    
    @State private var totalFileSize: Int64 = 0
    @State private var pageSizeOption: HexPageSizeOption = .twoKilobytes
    @State private var currentPageIndex: Int = 0
    @State private var currentPageData: Data = Data()
    @State private var jumpOffsetInput: String = ""
    @State private var isJumpPopoverPresented: Bool = false
    @State private var copyToastMessage: String? = nil
    @State private var isToastVisible: Bool = false
    
    public init(data: Data = Data(), fileURL: URL? = nil, fileName: String = "") {
        self.initialData = data
        self.fileURL = fileURL
        self.fileName = fileName.isEmpty ? (fileURL?.lastPathComponent ?? "Binary Data") : fileName
    }
    
    private var pageSize: Int {
        pageSizeOption.rawValue
    }
    
    private var totalPages: Int {
        guard totalFileSize > 0 else { return 1 }
        return max(1, Int((totalFileSize + Int64(pageSize) - 1) / Int64(pageSize)))
    }
    
    private var currentStartOffset: Int64 {
        Int64(currentPageIndex * pageSize)
    }
    
    private var currentEndOffset: Int64 {
        min(totalFileSize, currentStartOffset + Int64(currentPageData.count))
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // 1. Top Control Bar
            topControlBar
            
            Divider()
            
            // 2. Hex Table Column Headers
            hexColumnHeader
            
            Divider()
            
            // 3. Main Hex Data Display Canvas
            ZStack {
                HexEditorNSView(
                    pageData: currentPageData,
                    startOffset: currentStartOffset
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Copy Notification Toast
                if isToastVisible, let msg = copyToastMessage {
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(TTZipTheme.bambooGreen)
                            Text(msg)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                    }
                }
            }
            
            Divider()
            
            // 4. Bottom Status and Pagination Bar
            bottomStatusBar
        }
        .background(Color(NSColor.textBackgroundColor))
        .task(id: fileURL) {
            loadInitialMetadata()
        }
        .task(id: currentPageIndex) {
            loadPageData()
        }
        .task(id: pageSizeOption) {
            currentPageIndex = 0
            loadPageData()
        }
    }
    
    // MARK: - Subviews
    
    private var topControlBar: some View {
        HStack(spacing: 10) {
            // File Type Badge
            HStack(spacing: 5) {
                Image(systemName: "memorychip.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text("HEX VIEWER")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(TTZipTheme.bambooGreen.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            
            // File Name
            Text(fileName)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            
            // Total Size Badge
            Text(ByteCountFormatterFlyweight.shared.string(fromByteCount: totalFileSize))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            
            Spacer()
            
            // Page Size Picker
            Menu {
                ForEach(HexPageSizeOption.allCases) { option in
                    Button(action: { pageSizeOption = option }) {
                        HStack {
                            Text(option.displayName)
                            if pageSizeOption == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10))
                    Text("Page: \(pageSizeOption.rawValue / 1024) KB")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            
            // Copy Actions Menu
            Menu {
                Button(action: { copyCurrentPageHex() }) {
                    Label("Copy Hex Bytes (Space Separated)", systemImage: "doc.on.doc")
                }
                Button(action: { copyCurrentPageContinuousHex() }) {
                    Label("Copy Continuous Hex String", systemImage: "number")
                }
                Button(action: { copyCurrentPageASCII() }) {
                    Label("Copy Decoded ASCII Text", systemImage: "text.alignleft")
                }
                Button(action: { copyCurrentPageCArray() }) {
                    Label("Copy as C Array (0x...)", systemImage: "curlybraces")
                }
                Divider()
                Button(action: { copyFullFormattedDump() }) {
                    Label("Copy Full Formatted Dump Table", systemImage: "tablecells")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                    Text("Copy")
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(TTZipTheme.bambooGreen.opacity(0.12))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var hexColumnHeader: some View {
        HStack(spacing: 0) {
            // Offset Column Header
            Text("Offset (h)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 8)
            
            // Hex Bytes Column Header (00 01 02 ... 0F)
            HStack(spacing: 6) {
                Text("00 01 02 03 04 05 06 07")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                Text(" ")
                    .font(.system(size: 11, design: .monospaced))
                
                Text("08 09 0A 0B 0C 0D 0E 0F")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 320, alignment: .leading)
            
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 8)
            
            // ASCII Column Header
            Text("Decoded Text")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4.5)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var bottomStatusBar: some View {
        HStack(spacing: 12) {
            // Current Offset Range
            HStack(spacing: 4) {
                Text("Range:")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(String(format: "0x%08X – 0x%08X", currentStartOffset, max(0, currentEndOffset - 1)))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            
            Spacer()
            
            // Jump To Offset Button
            Button(action: { isJumpPopoverPresented.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.to.line.compact")
                        .font(.system(size: 10))
                    Text("Jump (0x...)")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isJumpPopoverPresented, arrowEdge: .bottom) {
                jumpOffsetPopoverContent
            }
            
            // Pagination Controls
            HStack(spacing: 4) {
                // First Page
                Button(action: { currentPageIndex = 0 }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 9))
                }
                .disabled(currentPageIndex <= 0)
                .buttonStyle(.plain)
                .padding(4)
                
                // Previous Page
                Button(action: { if currentPageIndex > 0 { currentPageIndex -= 1 } }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                }
                .disabled(currentPageIndex <= 0)
                .buttonStyle(.plain)
                .padding(4)
                
                // Page Indicator
                Text("Page \(currentPageIndex + 1) of \(totalPages)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                
                // Next Page
                Button(action: { if currentPageIndex < totalPages - 1 { currentPageIndex += 1 } }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .disabled(currentPageIndex >= totalPages - 1)
                .buttonStyle(.plain)
                .padding(4)
                
                // Last Page
                Button(action: { currentPageIndex = max(0, totalPages - 1) }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 9))
                }
                .disabled(currentPageIndex >= totalPages - 1)
                .buttonStyle(.plain)
                .padding(4)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var jumpOffsetPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Jump to Offset")
                .font(.system(size: 12, weight: .bold))
            
            Text("Enter hex (e.g. 0x1000 or 1A0) or decimal byte offset:")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 8) {
                TextField("0x00000000", text: $jumpOffsetInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(width: 140)
                    .onSubmit { performJumpToOffset() }
                
                Button(action: { performJumpToOffset() }) {
                    Text("Jump")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(TTZipTheme.bambooGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
    
    // MARK: - Logic & Actions
    
    private func loadInitialMetadata() {
        if let url = fileURL, url.isFileURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
                ?? (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init))
                ?? Int64(initialData.count)
            self.totalFileSize = size
        } else {
            self.totalFileSize = Int64(initialData.count)
        }
        loadPageData()
    }
    
    private func loadPageData() {
        let offset = currentStartOffset
        let length = pageSize
        
        if let url = fileURL, url.isFileURL {
            Task {
                let chunk = await HexDataChunkLoaderActor.shared.loadChunk(from: url, offset: offset, length: length)
                await MainActor.run {
                    self.currentPageData = chunk
                }
            }
            return
        }
        
        // Fallback to in-memory slicing
        guard !initialData.isEmpty else {
            self.currentPageData = Data()
            return
        }
        let start = min(Int(offset), initialData.count)
        let end = min(start + length, initialData.count)
        self.currentPageData = initialData.subdata(in: start..<end)
    }
    
    private func performJumpToOffset() {
        isJumpPopoverPresented = false
        var clean = jumpOffsetInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsedOffset: Int64 = 0
        if clean.lowercased().hasPrefix("0x") {
            clean = String(clean.dropFirst(2))
            if let hexVal = Int64(clean, radix: 16) {
                parsedOffset = hexVal
            }
        } else if let decVal = Int64(clean, radix: 10) {
            parsedOffset = decVal
        } else if let hexVal = Int64(clean, radix: 16) {
            parsedOffset = hexVal
        }
        
        parsedOffset = max(0, min(parsedOffset, totalFileSize > 0 ? totalFileSize - 1 : 0))
        let targetPage = Int(parsedOffset / Int64(pageSize))
        if targetPage != currentPageIndex {
            currentPageIndex = min(targetPage, max(0, totalPages - 1))
        }
        jumpOffsetInput = ""
    }
    
    private func showCopyToast(_ message: String) {
        copyToastMessage = message
        withAnimation(.easeInOut(duration: 0.2)) {
            isToastVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.25)) {
                isToastVisible = false
            }
        }
    }
    
    private func copyToClipboard(_ string: String, message: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        showCopyToast(message)
    }
    
    private func copyCurrentPageHex() {
        let hexString = currentPageData.map { String(format: "%02X", $0) }.joined(separator: " ")
        copyToClipboard(hexString, message: "Copied \(currentPageData.count) Hex bytes to clipboard")
    }
    
    private func copyCurrentPageContinuousHex() {
        let hexString = currentPageData.map { String(format: "%02X", $0) }.joined()
        copyToClipboard(hexString, message: "Copied continuous Hex string")
    }
    
    private func copyCurrentPageASCII() {
        let asciiString = currentPageData.map { byte -> String in
            if byte >= 32 && byte <= 126 {
                return String(UnicodeScalar(byte))
            } else {
                return "."
            }
        }.joined()
        copyToClipboard(asciiString, message: "Copied ASCII decoded text")
    }
    
    private func copyCurrentPageCArray() {
        let hexList = currentPageData.map { String(format: "0x%02X", $0) }
        var result = "const unsigned char data[\(currentPageData.count)] = {\n"
        for i in stride(from: 0, to: hexList.count, by: 12) {
            let chunk = hexList[i..<min(i + 12, hexList.count)].joined(separator: ", ")
            result += "    " + chunk + (i + 12 < hexList.count ? ",\n" : "\n")
        }
        result += "};\n"
        copyToClipboard(result, message: "Copied as C array structure")
    }
    
    private func copyFullFormattedDump() {
        var dump = ""
        let count = currentPageData.count
        for lineStart in stride(from: 0, to: count, by: 16) {
            let offset = currentStartOffset + Int64(lineStart)
            let lineEnd = min(lineStart + 16, count)
            let chunk = currentPageData.subdata(in: lineStart..<lineEnd)
            
            let offsetStr = String(format: "%08X", offset)
            var hex1 = ""
            var hex2 = ""
            var ascii = ""
            
            for (idx, byte) in chunk.enumerated() {
                let hexByte = String(format: "%02X", byte)
                if idx < 8 {
                    hex1 += (hex1.isEmpty ? "" : " ") + hexByte
                } else {
                    hex2 += (hex2.isEmpty ? "" : " ") + hexByte
                }
                if byte >= 32 && byte <= 126 {
                    ascii.append(Character(UnicodeScalar(byte)))
                } else {
                    ascii.append(".")
                }
            }
            
            // Padding
            let hex1Padded = hex1.padding(toLength: 23, withPad: " ", startingAt: 0)
            let hex2Padded = hex2.padding(toLength: 23, withPad: " ", startingAt: 0)
            let asciiPadded = ascii.padding(toLength: 16, withPad: " ", startingAt: 0)
            
            dump += "\(offsetStr)  \(hex1Padded)  \(hex2Padded)  |\(asciiPadded)|\n"
        }
        copyToClipboard(dump, message: "Copied formatted hex dump table")
    }
}

// MARK: - Native High-Performance Selectable Hex NSTextView

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
        scrollView.hasHorizontalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        
        let textView = NSTextView()
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 14, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        
        if let container = textView.textContainer {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude)
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
            
            let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let boldMonoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            
            let offsetColor = NSColor(red: 0.20, green: 0.70, blue: 0.50, alpha: 1.0) // BambooGreen tint
            let separatorColor = NSColor.separatorColor
            let normalHexColor = NSColor.labelColor
            let zeroHexColor = NSColor.labelColor.withAlphaComponent(0.32)
            let highHexColor = NSColor(red: 0.75, green: 0.45, blue: 0.90, alpha: 1.0)
            let asciiPrintableColor = NSColor.labelColor
            let asciiDotColor = NSColor.secondaryLabelColor.withAlphaComponent(0.4)
            
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
                
                attrStr.append(NSAttributedString(string: "  ", attributes: [
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
