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
        usesCustomBridge: Bool
    ) -> (resolved: SemanticModelInstallState, overrideState: SemanticModelInstallState?) {
        switch bridgeState {
        case let .ready(descriptor):
            return (.ready(descriptor), nil)
        case _ where !requireExactChecksum && !usesCustomBridge && modelURL != nil:
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

/// Progress snapshot emitted during on-demand GGUF model download.
public struct LocalModelDownloadProgress: Sendable, Equatable {
    public let bytesReceived: Int64
    public let totalBytesExpected: Int64

    public var fractionCompleted: Double {
        guard totalBytesExpected > 0 else { return 0 }
        return min(1.0, max(0.0, Double(bytesReceived) / Double(totalBytesExpected)))
    }

    public init(bytesReceived: Int64, totalBytesExpected: Int64) {
        self.bytesReceived = bytesReceived
        self.totalBytesExpected = totalBytesExpected
    }
}

/// Transport contract for streaming the local GGUF model to a staging `.part` file.
public protocol LocalModelDownloadTransport: Sendable {
    func downloadModel(
        from url: URL,
        to destinationPartURL: URL,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) async -> Void
    ) async throws
}

/// Production `URLSession`-backed download transport streaming response bytes directly to disk.
public struct URLSessionLocalModelDownloadTransport: LocalModelDownloadTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func downloadModel(
        from url: URL,
        to destinationPartURL: URL,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) async -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SemanticSearchError.downloadFailed(reason: "HTTP status \(code)")
        }

        let fm = FileManager.default
        try fm.createDirectory(
            at: destinationPartURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destinationPartURL.path) {
            try fm.removeItem(at: destinationPartURL)
        }
        fm.createFile(atPath: destinationPartURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationPartURL)
        defer { try? handle.close() }

        let expectedTotal = http.expectedContentLength > 0
            ? http.expectedContentLength
            : Int64(SemanticModelSpec.expectedGGUFSizeBytes)
        try await streamBytes(
            from: asyncBytes,
            to: handle,
            expectedTotal: expectedTotal,
            onProgress: onProgress
        )
    }

    private func streamBytes(
        from asyncBytes: URLSession.AsyncBytes,
        to handle: FileHandle,
        expectedTotal: Int64,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) async -> Void
    ) async throws {
        let chunkCapacity = 256 * 1024
        var buffer = Data()
        buffer.reserveCapacity(chunkCapacity)
        var bytesReceived: Int64 = 0

        for try await byte in asyncBytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= chunkCapacity {
                try handle.write(contentsOf: buffer)
                bytesReceived += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await onProgress(
                    LocalModelDownloadProgress(
                        bytesReceived: bytesReceived,
                        totalBytesExpected: expectedTotal
                    )
                )
            }
        }
        try Task.checkCancellation()
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            bytesReceived += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: false)
        }
        try handle.synchronize()
        await onProgress(
            LocalModelDownloadProgress(
                bytesReceived: bytesReceived,
                totalBytesExpected: expectedTotal
            )
        )
    }
}
