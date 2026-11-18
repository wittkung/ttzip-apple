// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public enum HexChunkAcceptance {
    @MainActor
    public static func accepts(
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
        guard HexChunkAcceptance.accepts(
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
