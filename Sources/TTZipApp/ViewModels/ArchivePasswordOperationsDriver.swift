// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI
#if canImport(TTZipAppServices)
#endif

/// Pluggable archive operations driver enabling deterministic password verification and resumption tests.
public protocol ArchivePasswordOperationsDriver: Sendable {
    func inspectArchive(archivePath: String, password: String?, autoVaultUnlock: Bool) async throws -> InspectResult
    func verifyEncryptedEntryPayload(archivePath: String, entryPath: String, password: String) async throws -> Data?
    func quickExtract(archivePath: String, destinationDir: String, password: String?, autoVaultUnlock: Bool, handling: CollisionHandling, progress: (@Sendable (ArchiveProgress) -> Void)?, token: CancellationToken?) async throws -> ExtractResult
    func extractEntries(archivePath: String, entryPaths: [String], destinationDir: String, password: String?, handling: CollisionHandling, progress: (@Sendable (ArchiveProgress) -> Void)?) async throws -> ExtractionOutcome
}

/// Default production driver backed by `TTZipEngineFacade` and uncached Rust stream verification.
///
/// The driver is a query: it reads the shared password cache through the engine and reports
/// what it found, but it never publishes, restores or removes a shared credential. Committing
/// a credential to the shared cache is an authorization act owned by the caller that accepts
/// the result, in that caller's own acceptance block.
public struct DefaultArchivePasswordOperationsDriver: ArchivePasswordOperationsDriver {
    public static let shared = DefaultArchivePasswordOperationsDriver()

    /// Engine seam. Production always drives the shared facade; tests inject a facade that
    /// owns a controlled reader so the real call chain can be paused deterministically.
    internal let facade: TTZipEngineFacade

    public init() {
        self.facade = TTZipEngineFacade.shared
    }

    internal init(facade: TTZipEngineFacade) {
        self.facade = facade
    }

    public func inspectArchive(
        archivePath: String,
        password: String?,
        autoVaultUnlock: Bool
    ) async throws -> InspectResult {
        return try await facade.inspectArchive(
            archivePath: archivePath,
            password: password,
            autoVaultUnlock: autoVaultUnlock
        )
    }

    public func verifyEncryptedEntryPayload(
        archivePath: String,
        entryPath: String,
        password: String
    ) async throws -> Data? {
        let maxBudgetBytes = ArchivePasswordProbePolicy.maxProbeEntryBytes
        let normalizedTarget = ArchivePasswordProbePolicy.normalizeEntryPath(entryPath)
        guard !normalizedTarget.isEmpty else { return nil }

        return try await NativeComputeDispatcher.shared.dispatchCompute(qos: .userInitiated) {
            let entries: [UniFfiEntryMetadata]
            do {
                entries = try inspectArchiveEntries(archivePath: archivePath, password: password)
            } catch let error as TtZipError {
                throw Self.mapProbeUniFFIError(error, archivePath: archivePath)
            }

            guard let idx = entries.firstIndex(where: {
                !$0.isDirectory && ArchivePasswordProbePolicy.normalizeEntryPath($0.path) == normalizedTarget
            }) else {
                return nil
            }
            let entry = entries[idx]
            if entry.uncompressedSize == 0 {
                return nil
            }
            if entry.uncompressedSize > UInt64(maxBudgetBytes) {
                throw ArchiveError.engineFailure(
                    code: RustTTZipStatusCode.errOutOfMemory.rawValue,
                    message: "Entry uncompressed size \(entry.uncompressedSize) exceeds probe budget of \(maxBudgetBytes) bytes"
                )
            }

            do {
                let data = try extractSingleEntryStreamGuarded(
                    archivePath: archivePath,
                    entryIndex: UInt64(idx),
                    password: password,
                    maxPrecedingBudgetMb: 64
                )
                if Int64(data.count) > maxBudgetBytes {
                    throw ArchiveError.engineFailure(
                        code: RustTTZipStatusCode.errOutOfMemory.rawValue,
                        message: "Extracted probe stream (\(data.count) bytes) exceeds probe budget"
                    )
                }
                return data.isEmpty ? nil : data
            } catch let error as TtZipError {
                throw Self.mapProbeUniFFIError(error, archivePath: archivePath)
            }
        }
    }

    private static func mapProbeUniFFIError(_ error: TtZipError, archivePath: String) -> ArchiveError {
        let mapped = ArchiveError.from(uniffiError: error)
        if case .passwordRequired = mapped {
            return .wrongPassword(archivePath: archivePath)
        }
        return mapped
    }

    public func quickExtract(
        archivePath: String,
        destinationDir: String,
        password: String?,
        autoVaultUnlock: Bool,
        handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)?,
        token: CancellationToken?
    ) async throws -> ExtractResult {
        try await TTZipEngineFacade.shared.quickExtract(
            archivePath: archivePath,
            destinationDir: destinationDir,
            password: password,
            autoVaultUnlock: autoVaultUnlock,
            cachePasswordOnSuccess: false,
            handling: handling,
            progress: progress,
            token: token
        )
    }

    public func extractEntries(
        archivePath: String,
        entryPaths: [String],
        destinationDir: String,
        password: String?,
        handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ExtractionOutcome {
        try await TTZipEngineFacade.shared.extractEntries(
            archivePath: archivePath,
            entryPaths: entryPaths,
            destinationDir: destinationDir,
            password: password,
            handling: handling,
            progress: progress
        )
    }
}

/// Shared evidence rule for a plaintext catalog: listing is never credential verification.
/// This query selects a bounded encrypted payload and never writes the shared cache.
@MainActor
internal enum ArchivePlaintextCatalogPasswordVerifier {
    static func verify(
        archivePath: String,
        entries: [ArchiveEntry],
        password: String,
        driver: any ArchivePasswordOperationsDriver,
        maxProbeBytes: Int64 = ArchivePasswordProbePolicy.maxProbeEntryBytes
    ) async -> ArchivePasswordProbeOutcome {
        guard let probeEntry = ArchivePasswordProbePolicy.selectProbeEntry(from: entries, maxProbeBytes: maxProbeBytes) else {
            return .noAvailableEvidence
        }
        do {
            let decrypted = try await driver.verifyEncryptedEntryPayload(
                archivePath: archivePath,
                entryPath: probeEntry.path,
                password: password
            )
            guard let data = decrypted, !data.isEmpty, Int64(data.count) <= maxProbeBytes else {
                return .noAvailableEvidence
            }
            return .verified(.selectedEntries([probeEntry.path]))
        } catch {
            let classified = ArchivePasswordErrorClassifier.classify(error)
            if classified.category == .wrongPassword {
                return .wrongPassword(message: classified.message)
            }
            return .otherFailure(category: classified.category, message: classified.message)
        }
    }
}
