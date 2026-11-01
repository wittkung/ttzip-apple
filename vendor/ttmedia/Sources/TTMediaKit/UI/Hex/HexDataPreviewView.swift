// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Professional hex data and binary file previewer with pagination, three-column alignment, and copy tools.
public struct HexDataPreviewView: View {
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

    @MainActor
    private var resolvedFileName: String {
        usesDefaultTitle ? TextAndDocumentPreviewLocalization.text(.hexDefaultTitle) : fileName
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
    
    public var body: some View {
        VStack(spacing: 0) {
            // 1. Top Responsive Control Bar
            HexTopControlBar(
                fileName: resolvedFileName,
                totalFileSize: totalFileSize,
                pageSizeOption: $pageSizeOption,
                onCopyHexBytes: {
                    copyFormattedData(
                        HexDataFormattingHelper.formatHexBytes(currentPageData),
                        label: TextAndDocumentPreviewLocalization.format(.hexCopiedBytesFormat, currentPageData.count)
                    )
                },
                onCopyContinuousHex: {
                    copyFormattedData(
                        HexDataFormattingHelper.formatContinuousHex(currentPageData),
                        label: TextAndDocumentPreviewLocalization.text(.hexCopiedContinuous)
                    )
                },
                onCopyASCII: {
                    copyFormattedData(
                        HexDataFormattingHelper.formatASCIIString(currentPageData),
                        label: TextAndDocumentPreviewLocalization.text(.hexCopiedASCII)
                    )
                },
                onCopyCArray: {
                    copyFormattedData(
                        HexDataFormattingHelper.formatCArray(currentPageData),
                        label: TextAndDocumentPreviewLocalization.text(.hexCopiedCArray)
                    )
                },
                onCopyFullDump: {
                    copyFormattedData(
                        HexDataFormattingHelper.formatFullDumpTable(currentPageData, startOffset: currentStartOffset),
                        label: TextAndDocumentPreviewLocalization.text(.hexCopiedFullDump)
                    )
                }
            )
            
            Divider()
            
            // 2. Main Hex Table Canvas with Synchronized Horizontal Scroll
            ZStack {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        HexColumnHeaderBar()
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
                    HexToastOverlay(message: msg)
                }
            }
            
            Divider()
            
            // 3. Bottom Responsive Status and Pagination Bar
            HexBottomStatusBar(
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
        .task(id: effectiveReadableURL) {
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
    
    @MainActor
    static func shouldAcceptLoadedChunk(
        isCancelled: Bool,
        expectedGeneration: UInt64,
        activeGeneration: UInt64,
        requestedURL: URL,
        currentURL: URL?,
        requestedOffset: Int64,
        currentOffset: Int64
    ) -> Bool {
        guard !isCancelled,
              expectedGeneration == activeGeneration,
              let currentURL,
              currentURL.standardizedFileURL.resolvingSymlinksInPath() == requestedURL.standardizedFileURL.resolvingSymlinksInPath(),
              requestedOffset == currentOffset else {
            return false
        }
        return true
    }
    
    private func loadInitialMetadata() {
        currentPageIndex = 0
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
                guard Self.shouldAcceptLoadedChunk(
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

/// Testable main-actor state machine coordinating paginated hex chunk loads and guarding against stale overwrites.
@MainActor
final class HexPageLoadCoordinator {
    typealias ChunkLoader = @Sendable (URL, Int64, Int) async -> Data

    private(set) var activeGeneration: UInt64 = 0
    private(set) var currentURL: URL?
    private(set) var currentOffset: Int64 = 0
    private(set) var currentPageData: Data = Data()
    private var pageLoadTask: Task<Void, Never>?
    private let chunkLoader: ChunkLoader

    init(
        chunkLoader: @escaping ChunkLoader = { url, offset, length in
            HexDataChunkLoaderActor.shared.loadChunk(from: url, offset: offset, length: length)
        }
    ) {
        self.chunkLoader = chunkLoader
    }

    @discardableResult
    func beginLoad(url: URL, offset: Int64, length: Int) -> UInt64 {
        pageLoadTask?.cancel()
        pageLoadTask = nil
        activeGeneration &+= 1
        currentURL = url
        currentOffset = offset
        let generation = activeGeneration
        let loader = chunkLoader
        pageLoadTask = Task { @MainActor [weak self] in
            let chunk = await loader(url, offset, length)
            guard let self else { return }
            self.applyLoadedChunkIfCurrent(
                chunk,
                generation: generation,
                url: url,
                offset: offset,
                isCancelled: Task.isCancelled
            )
        }
        return generation
    }

    @discardableResult
    func applyLoadedChunkIfCurrent(
        _ chunk: Data,
        generation: UInt64,
        url: URL,
        offset: Int64,
        isCancelled: Bool = false
    ) -> Bool {
        guard HexDataPreviewView.shouldAcceptLoadedChunk(
            isCancelled: isCancelled,
            expectedGeneration: generation,
            activeGeneration: activeGeneration,
            requestedURL: url,
            currentURL: currentURL,
            requestedOffset: offset,
            currentOffset: currentOffset
        ) else {
            return false
        }
        currentPageData = chunk
        return true
    }

    func waitForCurrentLoad() async {
        await pageLoadTask?.value
    }

    func cancel() {
        pageLoadTask?.cancel()
        pageLoadTask = nil
        activeGeneration &+= 1
    }
}
