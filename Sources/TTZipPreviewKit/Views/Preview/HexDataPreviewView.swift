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
    
    private let minHexTableWidth: CGFloat = 620
    
    public var body: some View {
        VStack(spacing: 0) {
            // 1. Top Responsive Control Bar
            topControlBar
            
            Divider()
            
            // 2. Main Hex Table Canvas with Synchronized Horizontal Scroll
            ZStack {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        hexColumnHeader
                            .frame(minWidth: minHexTableWidth, alignment: .leading)
                        
                        Divider()
                        
                        HexEditorNSView(
                            pageData: currentPageData,
                            startOffset: currentStartOffset
                        )
                        .frame(minWidth: minHexTableWidth, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minWidth: minHexTableWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Copy Notification Toast Overlay
                if isToastVisible, let msg = copyToastMessage {
                    toastOverlay(message: msg)
                }
            }
            
            Divider()
            
            // 3. Bottom Responsive Status and Pagination Bar
            bottomStatusBar
        }
        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .clipped()
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
        ViewThatFits(in: .horizontal) {
            // Wide layout (>= 420pt)
            fullTopControlBar
            
            // Compact layout (~280pt - 420pt)
            compactTopControlBar
            
            // Minimal layout (200pt - 280pt)
            minimalTopControlBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var fullTopControlBar: some View {
        HStack(spacing: 10) {
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
            
            Text(fileName)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            
            Text(ByteCountFormatterFlyweight.shared.string(fromByteCount: totalFileSize))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            
            Spacer(minLength: 4)
            
            pageSizeMenu(compact: false)
            copyMenu(compact: false)
        }
    }
    
    private var compactTopControlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "memorychip.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text("HEX")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(TTZipTheme.bambooGreen.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            
            Text(fileName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer(minLength: 4)
            
            pageSizeMenu(compact: true)
            copyMenu(compact: false)
        }
    }
    
    private var minimalTopControlBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "memorychip.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TTZipTheme.bambooGreen)
                .padding(4)
                .background(TTZipTheme.bambooGreen.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            
            Text(fileName)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer(minLength: 2)
            
            pageSizeMenu(compact: true)
            copyMenu(compact: true)
        }
    }
    
    private func pageSizeMenu(compact: Bool) -> some View {
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
            HStack(spacing: 3) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9.5))
                Text(compact ? "\(pageSizeOption.rawValue / 1024)K" : "Page: \(pageSizeOption.rawValue / 1024) KB")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, compact ? 5 : 8)
            .padding(.vertical, 3.5)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
    }
    
    private func copyMenu(compact: Bool) -> some View {
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
            HStack(spacing: 3) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                if !compact {
                    Text("Copy")
                        .font(.system(size: 10.5, weight: .bold))
                }
            }
            .padding(.horizontal, compact ? 6 : 9)
            .padding(.vertical, 3.5)
            .background(TTZipTheme.bambooGreen.opacity(0.12))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
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
            
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4.5)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var bottomStatusBar: some View {
        ViewThatFits(in: .horizontal) {
            // Full status bar: includes full range, jump button, and complete pagination controls
            fullBottomStatusBar
            
            // Compact status bar: shortened range and pagination for medium widths
            compactBottomStatusBar
            
            // Minimal status bar: minimal jump icon and compact pagination for narrow widths (<= 200pt)
            minimalBottomStatusBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var fullBottomStatusBar: some View {
        HStack(spacing: 12) {
            offsetRangeView(compact: false)
            Spacer(minLength: 6)
            jumpButton(compact: false)
            fullPaginationControls
        }
    }
    
    private var compactBottomStatusBar: some View {
        HStack(spacing: 8) {
            offsetRangeView(compact: true)
            Spacer(minLength: 4)
            jumpButton(compact: true)
            compactPaginationControls
        }
    }
    
    private var minimalBottomStatusBar: some View {
        HStack(spacing: 6) {
            jumpButton(compact: true)
            Spacer(minLength: 4)
            compactPaginationControls
        }
    }
    
    private func offsetRangeView(compact: Bool) -> some View {
        HStack(spacing: 4) {
            if !compact {
                Text("Range:")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            Text(compact ? String(format: "0x%06X…", currentStartOffset) : String(format: "0x%08X – 0x%08X", currentStartOffset, max(0, currentEndOffset - 1)))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(TTZipTheme.bambooGreen)
        }
    }
    
    private func jumpButton(compact: Bool) -> some View {
        Button(action: { isJumpPopoverPresented.toggle() }) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.right.to.line.compact")
                    .font(.system(size: 10))
                if !compact {
                    Text("Jump (0x...)")
                        .font(.system(size: 10.5, weight: .medium))
                }
            }
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isJumpPopoverPresented, arrowEdge: .bottom) {
            jumpOffsetPopoverContent
        }
    }
    
    private var fullPaginationControls: some View {
        HStack(spacing: 4) {
            Button(action: { currentPageIndex = 0 }) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 9))
            }
            .disabled(currentPageIndex <= 0)
            .buttonStyle(.plain)
            .padding(4)
            
            Button(action: { if currentPageIndex > 0 { currentPageIndex -= 1 } }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
            }
            .disabled(currentPageIndex <= 0)
            .buttonStyle(.plain)
            .padding(4)
            
            Text("Page \(currentPageIndex + 1) of \(totalPages)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
            
            Button(action: { if currentPageIndex < totalPages - 1 { currentPageIndex += 1 } }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .disabled(currentPageIndex >= totalPages - 1)
            .buttonStyle(.plain)
            .padding(4)
            
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
    
    private var compactPaginationControls: some View {
        HStack(spacing: 2) {
            Button(action: { if currentPageIndex > 0 { currentPageIndex -= 1 } }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9.5, weight: .bold))
            }
            .disabled(currentPageIndex <= 0)
            .buttonStyle(.plain)
            .padding(3)
            
            Text("\(currentPageIndex + 1)/\(totalPages)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4)
            
            Button(action: { if currentPageIndex < totalPages - 1 { currentPageIndex += 1 } }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
            }
            .disabled(currentPageIndex >= totalPages - 1)
            .buttonStyle(.plain)
            .padding(3)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    
    private func toastOverlay(message: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text(message)
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
