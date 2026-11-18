// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

/// Fused match record combining lexical score and vector semantic dot product.
public typealias VfsHybridMatch = TTZipCore.VfsHybridMatch

/// Interface contract for VFS sessions supporting hybrid vector search.
public protocol VfsSemanticSearchable: Sendable {
    /// Executes hybrid lexical and vector semantic top-K search.
    func searchHybridTopK(
        query: String,
        queryVector: [Int8]?,
        limit: UInt32,
        lexicalWeight: Float,
        semanticWeight: Float
    ) throws -> [VfsHybridMatch]

    /// Executes semantic-only top-K search over pre-computed embeddings.
    func searchSemanticTopK(
        queryVector: [Int8],
        limit: UInt32
    ) throws -> [VfsPagedNode]

    /// Returns true if the active snapshot contains an embedded vector section.
    func hasVectorEmbeddings() -> Bool
}

public extension VfsSemanticSearchable {
    func searchHybridTopK(
        query: String,
        queryVector: [Int8]?,
        limit: UInt32 = 1000,
        lexicalWeight: Float = 0.6,
        semanticWeight: Float = 0.4
    ) throws -> [VfsHybridMatch] {
        try searchHybridTopK(
            query: query,
            queryVector: queryVector,
            limit: limit,
            lexicalWeight: lexicalWeight,
            semanticWeight: semanticWeight
        )
    }
}

// Zero-boilerplate conformance: TTZipCore.VfsSession satisfies all protocol requirements natively.
extension VfsSession: VfsSemanticSearchable {}
