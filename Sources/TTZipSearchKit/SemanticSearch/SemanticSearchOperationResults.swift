// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

extension SemanticSearchEngine {
    nonisolated static func cancelledProgress(
        scopeId: String,
        processedFiles: UInt32 = 0,
        totalFiles: UInt32 = 0,
        indexGeneration: UInt64 = 0
    ) -> SemanticIndexProgress {
        SemanticIndexProgress(
            scopeId: scopeId,
            phase: .cancelled,
            processedFiles: processedFiles,
            totalFiles: totalFiles,
            indexedSegments: 0,
            indexGeneration: indexGeneration
        )
    }

    nonisolated static func emptySearchResponse(
        _ request: SemanticSearchRequest,
        isCancelled: Bool,
        degradedLexicalOnly: Bool = false,
        isEngineLinked: Bool = true,
        engineUnlinkedReason: String? = nil
    ) -> SemanticSearchResponse {
        SemanticSearchResponse(
            requestId: request.requestId,
            windowId: request.windowId,
            isCancelled: isCancelled,
            degradedLexicalOnly: degradedLexicalOnly,
            hits: [],
            isEngineLinked: isEngineLinked,
            engineUnlinkedReason: engineUnlinkedReason
        )
    }

    func setPredecessorWaitObserver(_ observer: (@Sendable (SemanticRetiringPredecessorWaitReceipt) -> Void)?) {
        predecessorWaitObserver = observer
    }

    /// Automatically indexes all registered authorized directory scopes whose indices were
    /// not yet built (e.g. scopes registered before the local GGUF model finished loading).
    @discardableResult
    public func backfillAuthorizedScopesIfNeeded() async -> [SemanticIndexProgress] {
        guard isPluginAdmittingWork, let seq = beginInFlightOperation() else { return [] }
        defer { endInFlightOperation(seq) }

        let authorizedScopes = scopeRecords.values
            .filter { $0.isAuthorized && $0.kind == .authorizedDirectory }
            .sorted { $0.scopeId < $1.scopeId }

        var results: [SemanticIndexProgress] = []
        for scope in authorizedScopes {
            guard isPluginAdmittingWork else { break }
            let existingProgress = await bridge.scopeProgress(scopeId: scope.scopeId)
            let alreadyIndexed = existingProgress?.phase == .completed
                && (existingProgress?.indexedSegments ?? 0) > 0
            if alreadyIndexed {
                if let existingProgress {
                    results.append(existingProgress)
                }
                continue
            }
            let progress = await performDeduplicatedDirectoryIndexing(scopeId: scope.scopeId)
            results.append(progress)
        }
        return results
    }

    /// Returns a summary of authorized scopes and total indexed segments across all authorized scopes.
    public func indexedCoverageSummary() async -> (authorizedScopeCount: Int, totalIndexedSegments: UInt32) {
        guard !isRuntimeDraining, let seq = beginInFlightOperation() else { return (0, 0) }
        defer { endInFlightOperation(seq) }

        let authorizedIds = scopeRecords.values.filter(\.isAuthorized).map(\.scopeId)
        var totalSegments: UInt32 = 0
        for scopeId in authorizedIds {
            if let prog = await bridge.scopeProgress(scopeId: scopeId) {
                totalSegments &+= prog.indexedSegments
            }
        }
        return (authorizedIds.count, totalSegments)
    }

    public func upsertArchiveEntries(
        scopeId: String,
        entries: [(entryPath: String, data: Data, mtimeNs: Int64)]
    ) async -> SemanticIndexProgress {
        let total = UInt32(entries.count)
        guard isPluginAdmittingWork, let seq = beginInFlightOperation() else {
            return Self.cancelledProgress(scopeId: scopeId, totalFiles: total)
        }
        defer { endInFlightOperation(seq) }
        hasDirtyBridgeSession = true
        let progress = await bridge.upsertArchiveEntries(scopeId: scopeId, entries: entries)
        return isPluginAdmittingWork
            ? progress
            : Self.cancelledProgress(scopeId: scopeId, totalFiles: total)
    }

    public func removeIndexedFile(scopeId: String, relativePath: String) async -> Bool {
        guard isPluginAdmittingWork, let seq = beginInFlightOperation() else { return false }
        defer { endInFlightOperation(seq) }
        hasDirtyBridgeSession = true
        let removed = await bridge.removeIndexedFile(scopeId: scopeId, relativePath: relativePath)
        return isPluginAdmittingWork && removed
    }
}

/// Internal diagnostic receipt emitted when an admitted indexing run suspends on prior retiring runs.
struct SemanticRetiringPredecessorWaitReceipt: Sendable, Equatable {
    let scopeId: String
    let waiterRunID: UUID
    let waiterAdmissionSequence: UInt64
    let priorRunIDs: [UUID]
    let priorAdmissionSequences: [UInt64]

    static func make(
        scopeId: String,
        waiterRunID: UUID,
        waiterSequence: UInt64,
        priorRuns: [SemanticTrackedIndexingRun]
    ) -> SemanticRetiringPredecessorWaitReceipt {
        SemanticRetiringPredecessorWaitReceipt(
            scopeId: scopeId,
            waiterRunID: waiterRunID,
            waiterAdmissionSequence: waiterSequence,
            priorRunIDs: priorRuns.map(\.runID),
            priorAdmissionSequences: priorRuns.map(\.admissionSequence)
        )
    }
}

enum SemanticModelReloadStateResolver {
    static func resolve(
        from bridgeState: SemanticModelInstallState,
        modelURL: URL?,
        requireExactChecksum: Bool,
        allowsNonExactModelRuntimeFallback: Bool
    ) -> (resolved: SemanticModelInstallState, overrideState: SemanticModelInstallState?) {
        switch bridgeState {
        case let .ready(descriptor):
            return (.ready(descriptor), nil)
        case _ where !requireExactChecksum && allowsNonExactModelRuntimeFallback && modelURL != nil:
            let state = SemanticModelInstallState.ready(SemanticModelDescriptor())
            return (state, state)
        case let .failed(reason), let .engineUnlinked(reason):
            let state = SemanticModelInstallState.failed(reason: reason)
            return (state, state)
        default:
            let state = SemanticModelInstallState.failed(
                reason: "Model runtime failed to transition to ready state."
            )
            return (state, state)
        }
    }
}
