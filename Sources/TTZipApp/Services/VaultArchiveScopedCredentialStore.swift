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

    private func ensureUnlocked() throws {
        guard !manager.isUnlocked else { return }
        guard !PasswordVaultManager.isCLIProcess else {
            throw ArchiveScopedVaultAccessError.locked
        }
        switch manager.unlockWithBiometricsResult() {
        case .unlocked: return
        case .cancelled: throw ArchiveScopedVaultAccessError.authenticationCancelled
        case .unavailable: throw ArchiveScopedVaultAccessError.authenticationUnavailable
        case .keyMissing, .keyAccessFailed, .invalidKey, .vaultUnreadable:
            throw ArchiveScopedVaultAccessError.authenticationFailed
        }
    }
}
