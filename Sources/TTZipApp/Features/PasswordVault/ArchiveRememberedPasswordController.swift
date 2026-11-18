// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// The vault implementation owns authentication and durability for scoped archive credentials.
public protocol ArchiveScopedCredentialStore: Sendable {
    func ensureUnlockedAsync() async throws
    func password(logicalKey: String, contentKey: String) throws -> String?
    func upsert(password: String, logicalKey: String, contentKey: String, label: String) throws
    func remove(logicalKey: String) throws
    func remove(logicalKey: String, contentKey: String, ifPasswordMatches password: String) throws
    func passwordAsync(logicalKey: String, contentKey: String) async throws -> String?
    func upsertAsync(password: String, logicalKey: String, contentKey: String, label: String) async throws
    func removeAsync(logicalKey: String) async throws
    func removeAsync(logicalKey: String, contentKey: String, ifPasswordMatches password: String) async throws
}

public extension ArchiveScopedCredentialStore {
    func ensureUnlockedAsync() async throws {}

    func passwordAsync(logicalKey: String, contentKey: String) async throws -> String? {
        try await ensureUnlockedAsync()
        return try password(logicalKey: logicalKey, contentKey: contentKey)
    }

    func upsertAsync(
        password: String, logicalKey: String, contentKey: String, label: String
    ) async throws {
        try await ensureUnlockedAsync()
        try upsert(password: password, logicalKey: logicalKey, contentKey: contentKey, label: label)
    }

    func removeAsync(logicalKey: String) async throws {
        try await ensureUnlockedAsync()
        try remove(logicalKey: logicalKey)
    }

    func removeAsync(
        logicalKey: String, contentKey: String, ifPasswordMatches password: String
    ) async throws {
        try await ensureUnlockedAsync()
        try remove(logicalKey: logicalKey, contentKey: contentKey, ifPasswordMatches: password)
    }
}

public enum ArchiveRememberedPasswordError: Error, Equatable, Sendable {
    case sourceChanged
}

/// Coordinates a user's explicit remember and forget decisions across windows.
public final class ArchiveRememberedPasswordController: @unchecked Sendable {
    private static let pendingForgetLock = NSLock()
    nonisolated(unsafe) private static var pendingForgottenLogicalKeys: Set<String> = []

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

    public func ensureUnlockedAsync() async throws {
        try await store.ensureUnlockedAsync()
    }

    public func password(for identity: ArchiveCredentialIdentity) throws -> String? {
        guard ArchiveCredentialIdentity.resolve(archivePath: identity.sourcePath) == identity else {
            throw ArchiveRememberedPasswordError.sourceChanged
        }
        while isPendingForgotten(identity.logicalKey) {
            let snapshot = generation.snapshot(for: identity.logicalKey)
            let reconciled = generation.performIfCurrent(snapshot, for: identity.logicalKey) { () -> Bool in
                guard isPendingForgotten(identity.logicalKey) else { return true }
                do {
                    try store.remove(logicalKey: identity.logicalKey)
                    clearPendingForgotten(identity.logicalKey)
                    return true
                } catch {
                    return false
                }
            }
            if let reconciled {
                if !reconciled {
                    return nil
                }
                break
            }
        }
        return try store.password(logicalKey: identity.logicalKey, contentKey: identity.key)
    }

    public func passwordAsync(for identity: ArchiveCredentialIdentity) async throws -> String? {
        guard ArchiveCredentialIdentity.resolve(archivePath: identity.sourcePath) == identity else {
            throw ArchiveRememberedPasswordError.sourceChanged
        }
        if isPendingForgotten(identity.logicalKey) {
            _ = try? await store.ensureUnlockedAsync()
            return try password(for: identity)
        }
        try await store.ensureUnlockedAsync()
        return try password(for: identity)
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
            clearPendingForgotten(identity.logicalKey)
            return true
        }
        return result ?? false
    }

    @discardableResult
    public func rememberVerifiedAsync(
        _ password: String,
        for identity: ArchiveCredentialIdentity,
        capturedGeneration: UInt64
    ) async throws -> Bool {
        try await store.ensureUnlockedAsync()
        return try rememberVerified(password, for: identity, capturedGeneration: capturedGeneration)
    }

    public func forget(_ identity: ArchiveCredentialIdentity) throws {
        try forget(logicalKey: identity.logicalKey)
    }

    public func forget(logicalKey: String) throws {
        try generation.invalidateAndPerform(for: logicalKey) {
            do {
                try store.remove(logicalKey: logicalKey)
                clearPendingForgotten(logicalKey)
            } catch {
                markPendingForgotten(logicalKey)
                throw error
            }
        }
    }

    public func forgetAsync(_ identity: ArchiveCredentialIdentity) async throws {
        try await forgetAsync(logicalKey: identity.logicalKey)
    }

    public func forgetAsync(logicalKey: String) async throws {
        do {
            try await store.ensureUnlockedAsync()
        } catch {
            generation.invalidateAndPerform(for: logicalKey) {
                markPendingForgotten(logicalKey)
            }
            throw error
        }
        try forget(logicalKey: logicalKey)
    }

    /// Drops an invalid saved candidate without deleting a newer credential from another window.
    public func rejectSavedCandidate(_ password: String, for identity: ArchiveCredentialIdentity) throws {
        try generation.invalidateAndPerform(for: identity.logicalKey) {
            try store.remove(logicalKey: identity.logicalKey, contentKey: identity.key, ifPasswordMatches: password)
        }
    }

    public func rejectSavedCandidateAsync(
        _ password: String,
        for identity: ArchiveCredentialIdentity
    ) async throws {
        do {
            try await store.ensureUnlockedAsync()
        } catch {
            generation.invalidateAndPerform(for: identity.logicalKey) {}
            throw error
        }
        try rejectSavedCandidate(password, for: identity)
    }

    private func markPendingForgotten(_ logicalKey: String) {
        Self.pendingForgetLock.withLock {
            _ = Self.pendingForgottenLogicalKeys.insert(logicalKey)
        }
    }

    private func clearPendingForgotten(_ logicalKey: String) {
        Self.pendingForgetLock.withLock {
            _ = Self.pendingForgottenLogicalKeys.remove(logicalKey)
        }
    }

    private func isPendingForgotten(_ logicalKey: String) -> Bool {
        Self.pendingForgetLock.withLock {
            Self.pendingForgottenLogicalKeys.contains(logicalKey)
        }
    }
}
