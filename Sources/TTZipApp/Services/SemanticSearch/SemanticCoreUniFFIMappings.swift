// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

extension UniFFIRustSemanticCoreBridge {
    // MARK: - 1-to-1 UniFFI Type Mappings

    static func mapBackend(_ b: AppUniFFISemanticComputeBackend) -> SemanticComputeBackendKind {
        switch b {
        case .metal: return .metal
        case .cpuFallback: return .cpuFallback
        case .deterministicTestDouble: return .deterministicTestDouble
        }
    }

    static func mapModelState(_ s: AppUniFFISemanticModelState) -> SemanticModelInstallState {
        switch s {
        case .notInstalled:
            return .notInstalled
        case let .downloading(bytesDownloaded, totalBytes):
            return .downloading(bytesDownloaded: bytesDownloaded, totalBytes: totalBytes)
        case .verifying:
            return .verifying
        case let .ready(info):
            return .ready(
                SemanticModelDescriptor(
                    modelId: info.modelId,
                    modelRevision: info.modelRevision,
                    ggufFilename: info.ggufFilename,
                    expectedBytes: info.expectedBytes,
                    expectedSha256: info.expectedSha256,
                    llamaCppTag: info.llamaCppTag,
                    llamaCppCommit: info.llamaCppCommit,
                    modelFingerprint: info.modelFingerprint,
                    backend: mapBackend(info.backend)
                )
            )
        case let .failed(reason):
            return .failed(reason: reason)
        }
    }

    static func toUniFFIScopeKind(_ k: SemanticScopeKind) -> AppUniFFISemanticScopeKind {
        switch k {
        case .authorizedDirectory: return .authorizedDirectory
        case .openArchive: return .openArchive
        }
    }

    static func mapScopeKind(_ k: AppUniFFISemanticScopeKind) -> SemanticScopeKind {
        switch k {
        case .authorizedDirectory: return .authorizedDirectory
        case .openArchive: return .openArchive
        }
    }

    static func toUniFFIScope(
        _ d: SemanticScopeDescriptor
    ) -> AppUniFFISemanticScopeDescriptor {
        AppUniFFISemanticScopeDescriptor(
            scopeId: d.scopeId,
            kind: toUniFFIScopeKind(d.kind),
            rootPath: d.rootPath,
            displayName: d.displayName,
            isAuthorized: d.isAuthorized
        )
    }

    static func mapPhase(_ p: AppUniFFISemanticIngestPhase) -> SemanticIngestPhaseKind {
        switch p {
        case .idle: return .idle
        case .scanning: return .scanning
        case .chunkingAndEmbedding: return .chunkingAndEmbedding
        case .committing: return .committing
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .degradedLexicalOnly: return .degradedLexicalOnly
        case .failed: return .failed
        }
    }

    static func cancelledProgress(scopeId: String, totalFiles: UInt32 = 0) -> SemanticIndexProgress {
        SemanticIndexProgress(
            scopeId: scopeId,
            phase: .cancelled,
            processedFiles: 0,
            totalFiles: totalFiles,
            indexedSegments: 0,
            indexGeneration: 0,
            errorMessage: nil
        )
    }

    static func unlinkedProgress(scopeId: String, totalFiles: UInt32 = 0) -> SemanticIndexProgress {
        SemanticIndexProgress(
            scopeId: scopeId,
            phase: .engineUnlinked,
            processedFiles: 0,
            totalFiles: totalFiles,
            indexedSegments: 0,
            indexGeneration: 0,
            errorMessage: Self.unlinkedReasonMessage
        )
    }

    static func mapProgress(_ p: AppUniFFISemanticIndexProgress) -> SemanticIndexProgress {
        SemanticIndexProgress(
            scopeId: p.scopeId,
            phase: mapPhase(p.phase),
            processedFiles: p.processedFiles,
            totalFiles: p.totalFiles,
            indexedSegments: p.indexedSegments,
            indexGeneration: p.indexGeneration,
            errorMessage: p.errorMessage
        )
    }

    static func mapMatchKind(_ m: AppUniFFISemanticMatchKind) -> SemanticMatchKind {
        switch m {
        case .lexicalOnly: return .lexicalOnly
        case .pathSemantic: return .pathSemantic
        case .contentSemantic: return .contentSemantic
        case .hybridPathAndContent: return .hybridPathAndContent
        }
    }

    static func toUniFFISearchRequest(
        _ r: SemanticSearchRequest
    ) -> AppUniFFISemanticSearchRequest {
        AppUniFFISemanticSearchRequest(
            requestId: r.requestId,
            windowId: r.windowId,
            query: r.query,
            scopeIds: r.scopeIds,
            topK: r.topK,
            lexicalWeight: r.lexicalWeight,
            semanticWeight: r.semanticWeight
        )
    }

    static func mapSearchHit(_ h: AppUniFFISemanticSearchHit) -> SemanticSearchHit {
        SemanticSearchHit(
            scopeId: h.scopeId,
            sourceKind: mapScopeKind(h.sourceKind),
            containerOrRootPath: h.containerOrRootPath,
            displayPath: h.displayPath,
            archiveEntryPath: h.archiveEntryPath,
            snippet: h.snippet,
            lineStart: h.lineStart,
            lineEnd: h.lineEnd,
            matchKind: mapMatchKind(h.matchKind),
            lexicalScore: h.lexicalScore,
            semanticScore: h.semanticScore,
            combinedScore: h.combinedScore,
            indexGeneration: h.indexGeneration,
            modelFingerprint: h.modelFingerprint
        )
    }

    static func mapSearchResponse(
        _ r: AppUniFFISemanticSearchResponse
    ) -> SemanticSearchResponse {
        SemanticSearchResponse(
            requestId: r.requestId,
            windowId: r.windowId,
            isCancelled: r.isCancelled,
            degradedLexicalOnly: r.degradedLexicalOnly,
            hits: r.hits.map(mapSearchHit),
            isEngineLinked: true,
            engineUnlinkedReason: nil
        )
    }
}
