// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

public enum ArchiveScopedVaultAccessError: Error, Sendable, Equatable {
    case locked
    case authenticationCancelled
    case authenticationUnavailable
    case authenticationFailed
}

/// Uses the existing encrypted vault and its authentication policy for archive-only entries.
public struct VaultArchiveScopedCredentialStore: ArchiveScopedCredentialStore {
    private let manager: PasswordVaultManager

    public init(manager: PasswordVaultManager = .shared) {
        self.manager = manager
    }

    public func password(logicalKey: String, contentKey: String) throws -> String? {
        try ensureUnlocked()
        return try manager.archivePassword(logicalKey: logicalKey, contentKey: contentKey)
    }

    public func upsert(password: String, logicalKey: String, contentKey: String, label: String) throws {
        try ensureUnlocked()
        try manager.upsertArchivePassword(
            password, logicalKey: logicalKey, contentKey: contentKey, label: label
        )
    }

    public func remove(logicalKey: String) throws {
        try ensureUnlocked()
        try manager.removeArchivePassword(logicalKey: logicalKey)
    }

    public func remove(
        logicalKey: String, contentKey: String, ifPasswordMatches password: String
    ) throws {
        try ensureUnlocked()
        try manager.removeArchivePassword(
            logicalKey: logicalKey, contentKey: contentKey, ifPasswordMatches: password
        )
    }

    /// Satisfies `ArchiveScopedCredentialStore` async credential lookup, unlocking with biometrics off the main thread when needed.
    public func passwordAsync(logicalKey: String, contentKey: String) async throws -> String? {
        try await ensureUnlockedAsync()
        return try manager.archivePassword(logicalKey: logicalKey, contentKey: contentKey)
    }

    /// Satisfies `ArchiveScopedCredentialStore` async credential upsert, unlocking with biometrics off the main thread when needed.
    public func upsertAsync(
        password: String, logicalKey: String, contentKey: String, label: String
    ) async throws {
        try await ensureUnlockedAsync()
        try manager.upsertArchivePassword(
            password, logicalKey: logicalKey, contentKey: contentKey, label: label
        )
    }

    /// Satisfies `ArchiveScopedCredentialStore` async credential removal, unlocking with biometrics off the main thread when needed.
    public func removeAsync(logicalKey: String) async throws {
        try await ensureUnlockedAsync()
        try manager.removeArchivePassword(logicalKey: logicalKey)
    }

    /// Satisfies `ArchiveScopedCredentialStore` async conditional credential removal, unlocking with biometrics off the main thread when needed.
    public func removeAsync(
        logicalKey: String, contentKey: String, ifPasswordMatches password: String
    ) async throws {
        try await ensureUnlockedAsync()
        try manager.removeArchivePassword(
            logicalKey: logicalKey, contentKey: contentKey, ifPasswordMatches: password
        )
    }

    public func ensureUnlockedAsync() async throws {
        guard !manager.isUnlocked else { return }
        if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
            manager.cancelPendingBiometricAuthentication()
            throw ArchiveScopedVaultAccessError.authenticationCancelled
        }
        guard !PasswordVaultManager.isCLIProcess || manager.hasBiometricTestOverrides else {
            throw ArchiveScopedVaultAccessError.locked
        }
        try Self.validateUnlockResult(await manager.unlockWithBiometricsAsyncResult())
    }

    private func ensureUnlocked() throws {
        guard !manager.isUnlocked else { return }
        if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
            manager.cancelPendingBiometricAuthentication()
            throw ArchiveScopedVaultAccessError.authenticationCancelled
        }
        guard !Thread.isMainThread,
              !PasswordVaultManager.isCLIProcess || manager.hasBiometricTestOverrides else {
            throw ArchiveScopedVaultAccessError.locked
        }
        try Self.validateUnlockResult(manager.unlockWithBiometricsResult())
    }

    private static func validateUnlockResult(_ result: VaultBiometricUnlockResult) throws {
        switch result {
        case .unlocked: return
        case .cancelled: throw ArchiveScopedVaultAccessError.authenticationCancelled
        case .unavailable: throw ArchiveScopedVaultAccessError.authenticationUnavailable
        case .keyMissing, .keyAccessFailed, .invalidKey, .vaultUnreadable:
            throw ArchiveScopedVaultAccessError.authenticationFailed
        }
    }
}
