// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

#if canImport(Darwin)
import Darwin
#endif

/// Coordinates background Apple Neural Engine (ANE) vector query encoding
/// and microkernel hybrid search dispatch with cooperative cancellation.
@MainActor
public final class SemanticSearchService {
    public let encoder: any SemanticQueryEncoding
    private var activeTask: Task<Void, Never>? = nil
    private var currentGeneration: UInt64 = 0

    public init(encoder: any SemanticQueryEncoding = CoreMLSemanticQueryEncoder()) {
        self.encoder = encoder
    }

    /// Requests the macOS kernel to reclaim dirty pages from the process malloc cache.
    public func relieveMemoryPressure() {
        #if canImport(Darwin)
        malloc_zone_pressure_relief(nil, 0)
        #endif
    }

    /// Cancels any in-flight query encoding and search execution cooperatively.
    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        relieveMemoryPressure()
    }

    /// Awaits completion of in-flight background query encoding.
    public func waitForActiveSearch() async {
        if let task = activeTask {
            _ = await task.value
        }
    }

    /// Dispatches a cooperative hybrid search task off the main thread.
    ///
    /// - Parameters:
    ///   - query: Cleaned user search term.
    ///   - generation: UI search generation token.
    ///   - session: Active VFS session conforming to `VfsSemanticSearchable`.
    ///   - limit: Maximum number of fused results to retrieve (default: 1000).
    ///   - lexicalWeight: Weight assigned to lexical scoring in RRF (default: 0.6).
    ///   - semanticWeight: Weight assigned to semantic vector scoring in RRF (default: 0.4).
    ///   - onResults: Completion callback delivered on `@MainActor` upon valid generation match.
    public func performHybridSearch(
        query: String,
        generation: UInt64,
        session: any VfsSemanticSearchable,
        limit: UInt32 = 1000,
        lexicalWeight: Float = 0.6,
        semanticWeight: Float = 0.4,
        onResults: @MainActor @Sendable @escaping ([VfsHybridMatch]) -> Void
    ) {
        cancel()
        self.currentGeneration = generation

        let encoder = self.encoder

        activeTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }

            // 1. Encode query vector on ANE in background
            let queryVector: [Int8]?
            do {
                queryVector = try await encoder.encode(query: query)
            } catch {
                // Graceful fallback: If model is not available or encoding fails, pure-lexical search is preserved
                return
            }

            guard !Task.isCancelled else { return }

            // 2. Call Rust microkernel SIMD dot product and RRF fusion
            let matches: [VfsHybridMatch]
            do {
                matches = try session.searchHybridTopK(
                    query: query,
                    queryVector: queryVector,
                    limit: limit,
                    lexicalWeight: lexicalWeight,
                    semanticWeight: semanticWeight
                )
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            // 3. Deliver results back on @MainActor, checking generation token
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard generation == self.currentGeneration else { return }
                self.activeTask = nil
                onResults(matches)
            }
        }
    }
}
