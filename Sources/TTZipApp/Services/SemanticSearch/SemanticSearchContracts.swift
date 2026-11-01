// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Pinned EmbeddingGemma 2 GGUF & `llama.cpp` runtime constants shared across TTZip.
public enum PinnedSemanticModelConstants {
    public static let modelId = "google/embeddinggemma-2"
    public static let modelRevision = "914f7f8"
    public static let ggufRepo = "ggml-org/embeddinggemma-2-GGUF"
    public static let ggufRevision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"
    public static let ggufFilename = "embeddinggemma-2-Q8_0.gguf"
    public static let ggufSizeBytes: UInt64 = 309_855_456
    public static let ggufSha256 = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"
    public static let llamaCppTag = "b11461"
    public static let llamaCppCommit = "4d756bc72bf00a4aacf410ae15a2d315f3db400d"
    public static let llamaCppNoLogitsPatchSha256 = "33c8c4812a4307aef3f398e5ba622edcc54ef421054edd98ca0f71906b9a2d7e"
    public static let modelFingerprint: UInt64 = 0x914F_7F80_B114_6101
    public static let testDoubleModelFingerprint: UInt64 = 0x5445_5354_4442_4C01
    public static let ttEmbeddingMagic: UInt64 = 0x5454_454D_4231_0000
    public static let ttEmbeddingSchemaVersion2: UInt32 = 2
    public static let engineUnlinkedPrefix = "ENGINE_UNLINKED:"
    public static let pinnedDownloadURLString =
        "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/embeddinggemma-2-Q8_0.gguf"
    public static let displayTitle = "EmbeddingGemma 2 (300M Q8_0)"
    public static let maxRetryAttempts: Int = 2
    public static let pinnedGGUFFilename = ggufFilename
    public static let expectedGGUFSizeBytes = ggufSizeBytes
    public static let expectedGGUFSha256 = ggufSha256
}

/// Canonical model specification alias shared across TTZip semantic search and settings UI.
public enum SemanticModelSpec {
    public static let modelId = PinnedSemanticModelConstants.modelId
    public static let modelRevision = PinnedSemanticModelConstants.modelRevision
    public static let ggufRepo = PinnedSemanticModelConstants.ggufRepo
    public static let ggufRevision = PinnedSemanticModelConstants.ggufRevision
    public static let ggufFilename = PinnedSemanticModelConstants.ggufFilename
    public static let pinnedGGUFFilename = PinnedSemanticModelConstants.ggufFilename
    public static let ggufSizeBytes = PinnedSemanticModelConstants.ggufSizeBytes
    public static let expectedGGUFSizeBytes = PinnedSemanticModelConstants.ggufSizeBytes
    public static let ggufSha256 = PinnedSemanticModelConstants.ggufSha256
    public static let expectedGGUFSha256 = PinnedSemanticModelConstants.ggufSha256
    public static let llamaCppTag = PinnedSemanticModelConstants.llamaCppTag
    public static let llamaCppCommit = PinnedSemanticModelConstants.llamaCppCommit
    public static let llamaCppNoLogitsPatchSha256 = PinnedSemanticModelConstants.llamaCppNoLogitsPatchSha256
    public static let modelFingerprint = PinnedSemanticModelConstants.modelFingerprint
    public static let testDoubleModelFingerprint = PinnedSemanticModelConstants.testDoubleModelFingerprint
    public static let pinnedDownloadURLString = PinnedSemanticModelConstants.pinnedDownloadURLString
    public static let displayTitle = PinnedSemanticModelConstants.displayTitle
    public static let maxRetryAttempts = PinnedSemanticModelConstants.maxRetryAttempts
}

public enum SemanticSearchError: Error, Sendable, Equatable, LocalizedError {
    case modelNotInstalled
    case invalidModelFile(reason: String)
    case downloadFailed(reason: String)
    case downloadCancelled
    case runtimeLoadFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return "Semantic model is not installed."
        case .invalidModelFile(let reason):
            return "Invalid model file: \(reason)"
        case .downloadFailed(let reason):
            return "Model download failed: \(reason)"
        case .downloadCancelled:
            return "Model download was cancelled."
        case .runtimeLoadFailed(let reason):
            return "Runtime load failed: \(reason)"
        }
    }
}

/// Canonical prompt formatter for EmbeddingGemma 2 (`google/embeddinggemma-2`).
public enum SemanticPromptFormatter {
    public static func formatQueryPrompt(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return "task: search result | query: \(trimmed)"
    }

    public static func formatCodeQueryPrompt(_ cleanQuery: String) -> String {
        let trimmed = cleanQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return "task: code retrieval | query: \(trimmed)"
    }

    public static func formatDocumentPrompt(relativePath: String?, text: String) -> String {
        let cleanTitle = relativePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = cleanTitle.isEmpty ? "none" : cleanTitle
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "title: \(title) | text: \(cleanText)"
    }

    public static func stripCodeQueryPrefix(_ query: String) -> (isCodeQuery: Bool, cleanQuery: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("code:") {
            let clean = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            return (true, clean)
        }
        return (false, trimmed)
    }
}

public enum SemanticComputeBackendKind: String, Sendable, Equatable, Codable {
    case metal
    case cpuFallback
    case deterministicTestDouble
}

public struct SemanticModelDescriptor: Sendable, Equatable, Codable {
    public let modelId: String
    public let modelRevision: String
    public let ggufFilename: String
    public let expectedBytes: UInt64
    public let expectedSha256: String
    public let llamaCppTag: String
    public let llamaCppCommit: String
    public let modelFingerprint: UInt64
    public let backend: SemanticComputeBackendKind

    public init(
        modelId: String = PinnedSemanticModelConstants.modelId,
        modelRevision: String = PinnedSemanticModelConstants.modelRevision,
        ggufFilename: String = PinnedSemanticModelConstants.ggufFilename,
        expectedBytes: UInt64 = PinnedSemanticModelConstants.ggufSizeBytes,
        expectedSha256: String = PinnedSemanticModelConstants.ggufSha256,
        llamaCppTag: String = PinnedSemanticModelConstants.llamaCppTag,
        llamaCppCommit: String = PinnedSemanticModelConstants.llamaCppCommit,
        modelFingerprint: UInt64 = PinnedSemanticModelConstants.modelFingerprint,
        backend: SemanticComputeBackendKind = .metal
    ) {
        self.modelId = modelId
        self.modelRevision = modelRevision
        self.ggufFilename = ggufFilename
        self.expectedBytes = expectedBytes
        self.expectedSha256 = expectedSha256
        self.llamaCppTag = llamaCppTag
        self.llamaCppCommit = llamaCppCommit
        self.modelFingerprint = modelFingerprint
        self.backend = backend
    }
}

public enum SemanticModelInstallState: Sendable, Equatable {
    case notInstalled
    case downloading(Double)
    case verifying
    case ready(SemanticModelDescriptor)
    case engineUnlinked(reason: String)
    case failed(reason: String)

    /// Convenience factory for byte-count download progress.
    public static func downloading(bytesDownloaded: UInt64, totalBytes: UInt64) -> SemanticModelInstallState {
        guard totalBytes > 0 else { return .downloading(0.0) }
        let fraction = min(1.0, max(0.0, Double(bytesDownloaded) / Double(totalBytes)))
        return .downloading(fraction)
    }

    /// Fractional download progress (`0.0 ... 1.0`) when in `.downloading`, otherwise `nil`.
    public var progressFraction: Double? {
        guard case let .downloading(progress) = self else { return nil }
        return min(1.0, max(0.0, progress))
    }
}

public enum SemanticScopeKind: String, Sendable, Equatable, Codable {
    case authorizedDirectory
    case openArchive
}

public struct SemanticScopeDescriptor: Sendable, Equatable, Codable, Identifiable {
    public var id: String { scopeId }
    public let scopeId: String
    public let kind: SemanticScopeKind
    public let rootPath: String
    public let displayName: String
    public let isAuthorized: Bool

    public init(
        scopeId: String,
        kind: SemanticScopeKind,
        rootPath: String,
        displayName: String,
        isAuthorized: Bool = true
    ) {
        self.scopeId = scopeId
        self.kind = kind
        self.rootPath = rootPath
        self.displayName = displayName
        self.isAuthorized = isAuthorized
    }
}

public enum SemanticIngestPhaseKind: String, Sendable, Equatable, Codable {
    case idle
    case scanning
    case chunkingAndEmbedding
    case committing
    case completed
    case cancelled
    case degradedLexicalOnly
    case engineUnlinked
    case failed
}

public struct SemanticIndexProgress: Sendable, Equatable, Codable {
    public let scopeId: String
    public let phase: SemanticIngestPhaseKind
    public let processedFiles: UInt32
    public let totalFiles: UInt32
    public let indexedSegments: UInt32
    public let indexGeneration: UInt64
    public let errorMessage: String?

    public init(
        scopeId: String,
        phase: SemanticIngestPhaseKind,
        processedFiles: UInt32,
        totalFiles: UInt32,
        indexedSegments: UInt32,
        indexGeneration: UInt64,
        errorMessage: String? = nil
    ) {
        self.scopeId = scopeId
        self.phase = phase
        self.processedFiles = processedFiles
        self.totalFiles = totalFiles
        self.indexedSegments = indexedSegments
        self.indexGeneration = indexGeneration
        self.errorMessage = errorMessage
    }
}

public enum SemanticMatchKind: String, Sendable, Equatable, Codable {
    case lexicalOnly
    case pathSemantic
    case contentSemantic
    case hybridPathAndContent
}

public struct SemanticSearchRequest: Sendable, Equatable {
    public let requestId: UInt64
    public let windowId: String
    public let query: String
    public let scopeIds: [String]
    public let topK: UInt32
    public let lexicalWeight: Float
    public let semanticWeight: Float

    public init(
        requestId: UInt64,
        windowId: String,
        query: String,
        scopeIds: [String] = [],
        topK: UInt32 = 25,
        lexicalWeight: Float = 0.30,
        semanticWeight: Float = 0.70
    ) {
        self.requestId = requestId
        self.windowId = windowId
        self.query = query
        self.scopeIds = scopeIds
        self.topK = topK
        self.lexicalWeight = lexicalWeight
        self.semanticWeight = semanticWeight
    }
}

public struct SemanticSearchHit: Sendable, Equatable, Identifiable {
    public var id: String {
        "\(scopeId):\(displayPath):\(archiveEntryPath ?? ""):\(lineStart ?? 0)"
    }
    public let scopeId: String
    public let sourceKind: SemanticScopeKind
    public let containerOrRootPath: String
    public let displayPath: String
    public let archiveEntryPath: String?
    public let snippet: String?
    public let lineStart: UInt32?
    public let lineEnd: UInt32?
    public let matchKind: SemanticMatchKind
    public let lexicalScore: Float
    public let semanticScore: Float
    public let combinedScore: Float
    public let indexGeneration: UInt64
    public let modelFingerprint: UInt64

    public init(
        scopeId: String,
        sourceKind: SemanticScopeKind,
        containerOrRootPath: String,
        displayPath: String,
        archiveEntryPath: String? = nil,
        snippet: String? = nil,
        lineStart: UInt32? = nil,
        lineEnd: UInt32? = nil,
        matchKind: SemanticMatchKind,
        lexicalScore: Float,
        semanticScore: Float,
        combinedScore: Float,
        indexGeneration: UInt64,
        modelFingerprint: UInt64
    ) {
        self.scopeId = scopeId
        self.sourceKind = sourceKind
        self.containerOrRootPath = containerOrRootPath
        self.displayPath = displayPath
        self.archiveEntryPath = archiveEntryPath
        self.snippet = snippet
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.matchKind = matchKind
        self.lexicalScore = lexicalScore
        self.semanticScore = semanticScore
        self.combinedScore = combinedScore
        self.indexGeneration = indexGeneration
        self.modelFingerprint = modelFingerprint
    }

    /// Resolves the outer filesystem file path for `.authorizedDirectory` hits or outer archive container path for `.openArchive` hits.
    public var resolvedOuterFilePath: String {
        switch sourceKind {
        case .openArchive:
            return containerOrRootPath
        case .authorizedDirectory:
            return (containerOrRootPath as NSString).appendingPathComponent(displayPath)
        }
    }

    /// Maps a `SemanticSearchHit` to W1's `GlobalSearchResultItem` (`Models/GlobalSearchResultItem.swift`).
    /// Note: `lineStart` / `lineEnd` are rendered in `subtitle` for user context; `GlobalSearchResultItem`,
    /// `BrowserWindowRouter`, and `AppViewState` do not yet consume line numbers to scroll/jump inside file body previews.
    public func toGlobalSearchResultItem() -> GlobalSearchResultItem {
        let badge: String? = (matchKind == .lexicalOnly) ? nil : "AI"
        let lineSuffix: String = {
            if let s = lineStart, s > 0 {
                if let e = lineEnd, e >= s {
                    return " · L\(s)-L\(e)"
                }
                return " · L\(s)"
            }
            return ""
        }()
        let snippetSuffix: String = {
            guard let raw = snippet?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return ""
            }
            return " · \(raw)"
        }()

        switch sourceKind {
        case .authorizedDirectory:
            let fullPath = resolvedOuterFilePath
            let fileName = (displayPath as NSString).lastPathComponent
            return GlobalSearchResultItem(
                id: "semantic:dir:\(scopeId):\(displayPath):\(lineStart ?? 0)",
                title: fileName.isEmpty ? displayPath : fileName,
                subtitle: "\(displayPath)\(lineSuffix)\(snippetSuffix)",
                hitType: .archiveEntry,
                archivePath: nil,
                entrySubpath: nil,
                diskPath: fullPath,
                matchedLineStart: lineStart.map(Int.init),
                isDirectory: false,
                byteSize: 0,
                score: combinedScore,
                matchBadge: badge
            )
        case .openArchive:
            let entryPath = archiveEntryPath ?? displayPath
            let archiveName = (containerOrRootPath as NSString).lastPathComponent
            let entryName = (entryPath as NSString).lastPathComponent
            return GlobalSearchResultItem(
                id: "semantic:archive:\(scopeId):\(entryPath):\(lineStart ?? 0)",
                title: entryName.isEmpty ? entryPath : entryName,
                subtitle: "\(archiveName) → \(entryPath)\(lineSuffix)\(snippetSuffix)",
                hitType: .archiveEntry,
                archivePath: containerOrRootPath,
                entrySubpath: entryPath,
                diskPath: nil,
                matchedLineStart: lineStart.map(Int.init),
                isDirectory: false,
                byteSize: 0,
                score: combinedScore,
                matchBadge: badge
            )
        }
    }
}

public struct SemanticSearchResponse: Sendable, Equatable {
    public let requestId: UInt64
    public let windowId: String
    public let isCancelled: Bool
    public let degradedLexicalOnly: Bool
    public let isEngineLinked: Bool
    public let engineUnlinkedReason: String?
    public let hits: [SemanticSearchHit]

    public init(
        requestId: UInt64,
        windowId: String,
        isCancelled: Bool,
        degradedLexicalOnly: Bool,
        hits: [SemanticSearchHit],
        isEngineLinked: Bool = true,
        engineUnlinkedReason: String? = nil
    ) {
        self.requestId = requestId
        self.windowId = windowId
        self.isCancelled = isCancelled
        self.degradedLexicalOnly = degradedLexicalOnly
        self.hits = hits
        self.isEngineLinked = isEngineLinked
        self.engineUnlinkedReason = engineUnlinkedReason
    }
}

/// Request payload emitted when opening a search hit, preserving `archiveEntryPath` and `lineNumber`
/// so W1 (`BrowserWindowRouter`) opens the inner archive entry rather than only the outer archive.
public struct SemanticOpenRequest: Sendable, Equatable {
    public let scopeId: String
    public let sourceKind: SemanticScopeKind
    public let outerPath: String
    public let archiveEntryPath: String?
    public let lineNumber: UInt32?

    public init(
        scopeId: String,
        sourceKind: SemanticScopeKind,
        outerPath: String,
        archiveEntryPath: String?,
        lineNumber: UInt32?
    ) {
        self.scopeId = scopeId
        self.sourceKind = sourceKind
        self.outerPath = outerPath
        self.archiveEntryPath = archiveEntryPath
        self.lineNumber = lineNumber
    }
}

/// Interface v1 contract published for W1 (Global Search UI & Scope Auth) and H (Build/Packaging).
public protocol SemanticSearchEngineProtocol: Sendable {
    func modelState() async -> SemanticModelInstallState
    func registerScope(_ descriptor: SemanticScopeDescriptor) async -> Bool
    func revokeScope(scopeId: String) async -> Bool
    func startIndexing(scopeId: String) async -> SemanticIndexProgress
    func cancelIndexing(scopeId: String) async
    func indexProgress(scopeId: String) async -> SemanticIndexProgress?
    func upsertArchiveEntries(
        scopeId: String,
        entries: [(entryPath: String, data: Data, mtimeNs: Int64)]
    ) async -> SemanticIndexProgress
    func removeIndexedFile(scopeId: String, relativePath: String) async -> Bool
    func search(_ request: SemanticSearchRequest) async -> SemanticSearchResponse
    func cancelSearch(requestId: UInt64) async
    func buildOpenRequest(for hit: SemanticSearchHit) -> SemanticOpenRequest
    func indexedCoverageSummary() async -> (authorizedScopeCount: Int, totalIndexedSegments: UInt32)
    @discardableResult
    func shutdown() async -> Bool
}

public extension SemanticSearchEngineProtocol {
    func indexedCoverageSummary() async -> (authorizedScopeCount: Int, totalIndexedSegments: UInt32) {
        (0, 0)
    }
}

/// Thin bridge protocol forwarding Swift calls to Rust `UniFFISemanticSearchEngine` (`ttzip-semantic`).
/// Swift must never re-implement directory crawling, text chunking, `.ttvec` persistence, or hybrid scoring in production.
public protocol RustSemanticCoreBridging: Sendable {
    func prepareModelRuntime() async -> SemanticModelInstallState
    func modelState() async -> SemanticModelInstallState
    func registerScope(_ descriptor: SemanticScopeDescriptor) async -> Bool
    func revokeScope(scopeId: String) async -> Bool
    func startDirectoryIndexing(scopeId: String) async -> SemanticIndexProgress
    func cancelIndexing(scopeId: String) async
    func scopeProgress(scopeId: String) async -> SemanticIndexProgress?
    func upsertArchiveEntries(
        scopeId: String,
        entries: [(entryPath: String, data: Data, mtimeNs: Int64)]
    ) async -> SemanticIndexProgress
    func removeIndexedFile(scopeId: String, relativePath: String) async -> Bool
    func search(_ request: SemanticSearchRequest) async -> SemanticSearchResponse
    func cancelSearch(requestId: UInt64) async
    func buildOpenRequest(for hit: SemanticSearchHit) -> SemanticOpenRequest
    func resetEngine() async throws
    @discardableResult
    func shutdown() async -> Bool
}

public extension RustSemanticCoreBridging {
    func prepareModelRuntime() async -> SemanticModelInstallState { await modelState() }
    func resetEngine() async throws {}
}

public typealias SemanticCoreBridging = RustSemanticCoreBridging
