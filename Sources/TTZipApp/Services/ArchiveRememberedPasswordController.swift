// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// The vault implementation owns authentication and durability for scoped archive credentials.
public protocol ArchiveScopedCredentialStore: Sendable {
    func password(logicalKey: String, contentKey: String) throws -> String?
    func upsert(password: String, logicalKey: String, contentKey: String, label: String) throws
    func remove(logicalKey: String) throws
    func remove(logicalKey: String, contentKey: String, ifPasswordMatches password: String) throws
}

public enum ArchiveRememberedPasswordError: Error, Equatable, Sendable {
    case sourceChanged
}

/// Coordinates a user's explicit remember and forget decisions across windows.
public final class ArchiveRememberedPasswordController: @unchecked Sendable {
    private let store: any ArchiveScopedCredentialStore
    private let generation: ArchiveCredentialGeneration

    public init(
        store: any ArchiveScopedCredentialStore,
        generation: ArchiveCredentialGeneration = .shared
    ) {
        self.store = store
        self.generation = generation
    }

    public func operationGeneration(for identity: ArchiveCredentialIdentity) -> UInt64 {
        generation.snapshot(for: identity.logicalKey)
    }

    public func password(for identity: ArchiveCredentialIdentity) throws -> String? {
        guard ArchiveCredentialIdentity.resolve(archivePath: identity.sourcePath) == identity else {
            throw ArchiveRememberedPasswordError.sourceChanged
        }
        return try store.password(logicalKey: identity.logicalKey, contentKey: identity.key)
    }

    /// The caller supplies a credential only after actual encrypted-content verification.
    /// `false` means Forget overtook the verification before it could publish.
    @discardableResult
    public func rememberVerified(
        _ password: String,
        for identity: ArchiveCredentialIdentity,
        capturedGeneration: UInt64
    ) throws -> Bool {
        let label = URL(fileURLWithPath: identity.sourcePath).lastPathComponent
        let result = try generation.performIfCurrent(capturedGeneration, for: identity.logicalKey) {
            guard ArchiveCredentialIdentity.resolve(archivePath: identity.sourcePath) == identity else {
                throw ArchiveRememberedPasswordError.sourceChanged
            }
            try store.upsert(
                password: password,
                logicalKey: identity.logicalKey,
                contentKey: identity.key,
                label: label
            )
            return true
        }
        return result ?? false
    }

    public func forget(_ identity: ArchiveCredentialIdentity) throws {
        try forget(logicalKey: identity.logicalKey)
    }

    public func forget(logicalKey: String) throws {
        try generation.invalidateAndPerform(for: logicalKey) {
            try store.remove(logicalKey: logicalKey)
        }
    }

    /// Drops an invalid saved candidate without deleting a newer credential from another window.
    public func rejectSavedCandidate(_ password: String, for identity: ArchiveCredentialIdentity) throws {
        try generation.invalidateAndPerform(for: identity.logicalKey) {
            try store.remove(logicalKey: identity.logicalKey, contentKey: identity.key, ifPasswordMatches: password)
        }
    }
}
