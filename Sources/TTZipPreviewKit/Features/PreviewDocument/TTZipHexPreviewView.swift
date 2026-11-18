// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit
import TTZipUI

/// Professional hex data and binary file previewer with pagination, three-column alignment, and copy tools.
public struct TTZipHexPreviewView: View {
    public let initialData: Data
    public let fileURL: URL?
    public let fileName: String
    private let usesDefaultTitle: Bool

    @Environment(\.previewResourceContext) private var envResourceContext
    @State private var totalFileSize: Int64 = 0
    @State private var pageSizeOption: HexPageSizeOption = .twoKilobytes
    @State private var currentPageIndex: Int = 0
    @State private var currentPageData: Data = Data()
    @State private var jumpOffsetInput: String = ""
    @State private var isJumpPopoverPresented: Bool = false
    @State private var copyToastMessage: String? = nil
    @State private var isToastVisible: Bool = false
    @State private var pageLoadTask: Task<Void, Never>? = nil
    @State private var loadGeneration: UInt64 = 0

    public init(data: Data = Data(), fileURL: URL? = nil, fileName: String = "") {
        self.initialData = data
        self.fileURL = fileURL
        let urlName = fileURL?.lastPathComponent
        let hasExplicitName = !fileName.isEmpty || (urlName != nil && urlName?.isEmpty == false)
        self.usesDefaultTitle = !hasExplicitName
        self.fileName = fileName.isEmpty ? (urlName ?? "Binary Data") : fileName
    }

    private var effectiveReadableURL: URL? {
        fileURL ?? envResourceContext.readableURL
    }

    var taskIdentityKey: String {
        let prefixSig = initialData.prefix(32).base64EncodedString()
        return "\(effectiveReadableURL?.path ?? "")|\(fileName)|\(initialData.count)|\(prefixSig)"
    }

    @MainActor
    private var resolvedFileName: String {
        usesDefaultTitle ? TTZipMarkdownHexPreviewLocalization.text(.hexDefaultTitle) : fileName
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

    private let minHexTableWidth: CGFloat = 640
    private static let offsetAccentColor = NSColor(red: 0.20, green: 0.70, blue: 0.50, alpha: 1.0)
    private static let highByteAccentColor = NSColor(red: 0.75, green: 0.45, blue: 0.90, alpha: 1.0)

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Top Responsive Control Bar
            TTZipHexTopControlBar(
                fileName: resolvedFileName,
                totalFileSize: totalFileSize,
                pageSizeOption: $pageSizeOption,
                onCopyHexBytes: {
                    copyFormattedData(
                        HexDataFormattingHelper.formatHexBytes(currentPageData),
                        label: TTZipMarkdownHexPreviewLocalization.format(.hexCopiedBytesFormat, currentPageData.count)
                    )
                },
                onCopyContinuousHex: {
                    copyFormattedData(
                        HexDataFormattingHelper.formatContinuousHex(currentPageData),
                        label: TTZipMarkdownHexPreviewLocalization.text(.hexCopiedContinuous)
                    )
                },
                onCopyASCII: {
                    copyFormattedData(
                        HexDataFormattingHelper.formatASCIIString(currentPageData),
                        label: TTZipMarkdownHexPreviewLocalization.text(.hexCopiedASCII)
                    )
                },
                onCopyCArray: {
                    copyFormattedData(
                        HexDataFormattingHelper.formatCArray(currentPageData),
                        label: TTZipMarkdownHexPreviewLocalization.text(.hexCopiedCArray)
                    )
                },
                onCopyFullDump: {
                    copyFormattedData(
                        HexDataFormattingHelper.formatFullDumpTable(currentPageData, startOffset: currentStartOffset),
                        label: TTZipMarkdownHexPreviewLocalization.text(.hexCopiedFullDump)
                    )
                }
            )

            Divider()

            // 2. Main Hex Table Canvas with Synchronized Horizontal Scroll
            ZStack {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        TTZipHexColumnHeaderBar()
                            .frame(minWidth: minHexTableWidth, alignment: .leading)

                        Divider()

                        HexEditorNSView(
                            pageData: currentPageData,
                            startOffset: currentStartOffset,
                            offsetColor: Self.offsetAccentColor,
                            highByteColor: Self.highByteAccentColor
                        )
                        .frame(minWidth: minHexTableWidth, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minWidth: minHexTableWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .id(taskIdentityKey)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Copy Notification Toast Overlay
                if isToastVisible, let msg = copyToastMessage {
                    TTZipHexToastOverlay(message: msg)
                }
            }

            Divider()

            // 3. Bottom Responsive Status and Pagination Bar
            TTZipHexBottomStatusBar(
                startOffset: currentStartOffset,
                endOffset: currentEndOffset,
                isJumpPopoverPresented: $isJumpPopoverPresented,
                jumpOffsetInput: $jumpOffsetInput,
                currentPageIndex: $currentPageIndex,
                totalPages: totalPages,
                onJump: performJumpToOffset
            )
        }
        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .clipped()
        .task(id: taskIdentityKey) {
            loadInitialMetadata()
        }
        .task(id: currentPageIndex) {
            loadPageData()
        }
        .task(id: pageSizeOption) {
            currentPageIndex = 0
            loadPageData()
        }
        .onDisappear {
            pageLoadTask?.cancel()
            pageLoadTask = nil
            loadGeneration &+= 1
        }
    }

    // MARK: - Logic & Actions

    private func loadInitialMetadata() {
        currentPageIndex = 0
        isJumpPopoverPresented = false
        jumpOffsetInput = ""
        if let url = effectiveReadableURL, url.isFileURL {
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
        pageLoadTask?.cancel()
        pageLoadTask = nil
        loadGeneration &+= 1
        let generation = loadGeneration
        let offset = currentStartOffset
        let length = pageSize

        if let url = effectiveReadableURL, url.isFileURL {
            pageLoadTask = Task { @MainActor in
                let chunk = await HexDataChunkLoaderActor.shared.loadChunk(from: url, offset: offset, length: length)
                guard HexChunkAcceptance.accepts(
                    isCancelled: Task.isCancelled,
                    expectedGeneration: generation,
                    activeGeneration: loadGeneration,
                    requestedURL: url,
                    currentURL: effectiveReadableURL,
                    requestedOffset: offset,
                    currentOffset: currentStartOffset
                ) else {
                    return
                }
                self.currentPageData = chunk
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
        let parsedOffset = HexDataFormattingHelper.parseOffset(from: jumpOffsetInput, maxFileSize: totalFileSize)
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
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.0))
            withAnimation(.easeInOut(duration: 0.25)) {
                isToastVisible = false
            }
        }
    }

    private func copyFormattedData(_ string: String, label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        showCopyToast(label)
    }
}
