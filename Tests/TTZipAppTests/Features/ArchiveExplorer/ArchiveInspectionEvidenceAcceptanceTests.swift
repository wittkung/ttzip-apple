// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
import TTZipUI
@testable import TTZipCore
@testable import TTZipApp

/// Exercises real session acceptance, reusing the production plaintext-payload evidence rule.
@MainActor
final class ArchiveInspectionEvidenceAcceptanceTests: XCTestCase {
    private actor Reader: ArchiveReading {
        let entries: [ArchiveEntry]
        let headerPassword: String?
        let barrier: ArchiveHostAsyncBarrier?

        init(entries: [ArchiveEntry], headerPassword: String? = nil, barrier: ArchiveHostAsyncBarrier? = nil) {
            self.entries = entries
            self.headerPassword = headerPassword
            self.barrier = barrier
        }

        func inspect(archivePath: String) async throws -> [ArchiveEntry] {
            try await inspect(archivePath: archivePath, password: nil, candidatePasswords: [])
        }

        func inspect(archivePath: String, password: String?, candidatePasswords: [String]?) async throws -> [ArchiveEntry] {
            if let barrier { await barrier.suspendUntilReleased() }
            if let headerPassword, password != headerPassword { throw ArchiveError.passwordRequired }
            return entries
        }

        func inspectTree(archivePath: String, password: String?, candidatePasswords: [String]?) async throws -> ArchiveCompositeDirectory {
            throw ArchiveError.openFailed
        }

        func probeEncryption(archivePath: String) async throws -> ArchiveEncryptionTier { .none }
    }

    private final class Vault: PasswordVaultManaging, @unchecked Sendable {
        let entries: [PasswordVaultEntry]
        var autoUnlockArchives: Bool { true }
        init(_ entries: [PasswordVaultEntry] = []) { self.entries = entries }
        func getEntries() -> [PasswordVaultEntry] { entries }
        func recordUsage(id: UUID) {}
    }

    private func fixture(empty: Bool = false) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mm48-evidence-\(UUID().uuidString).zip")
        try (empty ? Data() : Data([0x50, 0x4b, 0, 0])).write(to: url)
        addTeardownBlock {
            ArchivePasswordStore.shared.removePassword(for: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url.path
    }

    private func encryptedEntry(size: Int64 = 1) -> ArchiveEntry {
        ArchiveEntry(path: "payload.txt", uncompressedSize: size, isDirectory: false, isEncrypted: true)
    }

    private enum ObservationFailure: Error { case missingEntry, missingCompletion }

    /// Capture both operations, release every gate, then publish failures or results.
    private func observeReleasedInspection<Value: Sendable>(
        barrier: ArchiveHostAsyncBarrier,
        operation: @escaping @MainActor () async throws -> Value,
        whileSuspended: @escaping @MainActor () async throws -> Void
    ) async throws -> Value {
        let receipt = ArchiveHostCompletionReceipt<Result<Value, Error>>()
        let task = Task { @MainActor in
            do { await receipt.store(.success(try await operation())) }
            catch { await receipt.store(.failure(error)) }
        }
        let entered = await barrier.waitUntilSuspended(timeout: .seconds(5))
        let actionReceipt = ArchiveHostCompletionReceipt<Result<Void, Error>>()
        let action = Task { @MainActor in
            guard entered else { await actionReceipt.store(.failure(ObservationFailure.missingEntry)); return }
            do { try await whileSuspended(); await actionReceipt.store(.success(())) }
            catch { await actionReceipt.store(.failure(error)) }
        }
        let actionOutcome = await actionReceipt.waitForValue(timeout: .seconds(5))
        await barrier.release()
        // Observe both completions after release, even when the overlapping operation threw.
        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        let settledAction = await actionReceipt.waitForValue(timeout: .seconds(5))
        task.cancel()
        action.cancel()
        XCTAssertTrue(entered, "The controlled reader must reach its gate within budget")
        guard entered else { throw ObservationFailure.missingEntry }
        guard let actionOutcome else { throw ObservationFailure.missingCompletion }
        guard settledAction != nil else { throw ObservationFailure.missingCompletion }
        try actionOutcome.get()
        guard let outcome else { throw ObservationFailure.missingCompletion }
        return try outcome.get()
    }

    func testRealEmptyFileListingDoesNotAuthorizeAnArbitraryPassword() async throws {
        let path = try fixture(empty: true)
        let session = ArchiveSessionContext()
        // The real ArchiveReader returns [] for a zero-byte file without testing the credential.
        try await session.loadArchive(path: path, password: "unverified")
        XCTAssertEqual(session.currentArchivePath, path)
        XCTAssertNil(session.activePassword)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: path))
    }

    func testReadableEncryptedCatalogRejectsWrongPayloadPassword() async throws {
        let path = try fixture()
        let session = ArchiveSessionContext()
        session.facade = TTZipEngineFacade(reader: Reader(entries: [encryptedEntry()]), passwordVault: Vault())
        let verifier = MockArchivePasswordDriver()
        verifier.verifyPayloadHandler = { path, _, _ in throw ArchiveError.wrongPassword(archivePath: path) }
        session.passwordVerificationDriver = verifier
        do {
            try await session.loadArchive(path: path, password: "wrong")
            XCTFail("Catalog success must not bypass the real payload-evidence boundary")
        } catch {}
        XCTAssertEqual(verifier.verifyPayloadCallCount, 1)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: path))
        XCTAssertNil(session.currentArchivePath)
    }

    func testReadableEncryptedCatalogCommitsOnlyAfterPayloadEvidence() async throws {
        let path = try fixture()
        let session = ArchiveSessionContext()
        session.facade = TTZipEngineFacade(reader: Reader(entries: [encryptedEntry()]), passwordVault: Vault())
        let verifier = MockArchivePasswordDriver()
        verifier.verifyPayloadHandler = { _, _, _ in Data([1]) }
        session.passwordVerificationDriver = verifier
        try await session.loadArchive(path: path, password: "verified")
        XCTAssertEqual(verifier.verifyPayloadCallCount, 1)
        XCTAssertEqual(session.activePassword, "verified")
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: path), "verified")
    }

    func testNoQualifyingPayloadKeepsCatalogBrowsableWithoutAuthorization() async throws {
        let path = try fixture()
        let session = ArchiveSessionContext()
        session.facade = TTZipEngineFacade(reader: Reader(entries: [encryptedEntry(size: 0)]), passwordVault: Vault())
        let verifier = MockArchivePasswordDriver()
        verifier.verifyPayloadHandler = { _, _, _ in XCTFail("No zero-size probe is permitted"); return Data([1]) }
        session.passwordVerificationDriver = verifier
        try await session.loadArchive(path: path, password: "unverified")
        XCTAssertEqual(session.currentArchivePath, path)
        XCTAssertEqual(verifier.verifyPayloadCallCount, 0)
        XCTAssertNil(session.activePassword)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: path))
    }

    func testHeaderUnlockRemainsAnAuthorizationWithoutPayloadProbe() async throws {
        let path = try fixture()
        let session = ArchiveSessionContext()
        session.facade = TTZipEngineFacade(
            reader: Reader(entries: [encryptedEntry()], headerPassword: "header"), passwordVault: Vault()
        )
        let verifier = MockArchivePasswordDriver()
        verifier.verifyPayloadHandler = { _, _, _ in XCTFail("A proven header unlock needs no payload probe"); return nil }
        session.passwordVerificationDriver = verifier
        try await session.loadArchive(path: path, password: "header")
        XCTAssertEqual(verifier.verifyPayloadCallCount, 0)
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: path), "header")
    }

    func testClosingDuringNewPayloadAwaitRejectsItsCredentialAndPage() async throws {
        let path = try fixture()
        let session = ArchiveSessionContext()
        session.facade = TTZipEngineFacade(reader: Reader(entries: [encryptedEntry()]), passwordVault: Vault())
        let barrier = ArchiveHostAsyncBarrier()
        let verifier = MockArchivePasswordDriver()
        verifier.verifyPayloadHandler = { _, _, _ in await barrier.suspendUntilReleased(); return Data([1]) }
        session.passwordVerificationDriver = verifier
        try await observeReleasedInspection(barrier: barrier, operation: {
            try await session.loadArchive(path: path, password: "late")
        }, whileSuspended: {
            session.closeArchive()
            ArchivePasswordStore.shared.setPassword("owner", for: path)
        })
        XCTAssertNil(session.currentArchivePath)
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: path), "owner")
    }

    func testImplicitCandidateIsNotRepublishedAfterAnotherOwnerCommits() async throws {
        let path = try fixture()
        ArchivePasswordStore.shared.setPassword("old", for: path)
        let session = ArchiveSessionContext()
        session.facade = TTZipEngineFacade(reader: Reader(entries: [encryptedEntry()]), passwordVault: Vault())
        let barrier = ArchiveHostAsyncBarrier()
        let selectedPassword = ArchiveHostCompletionReceipt<String>()
        let verifier = MockArchivePasswordDriver()
        verifier.verifyPayloadHandler = { _, _, password in
            await selectedPassword.store(password)
            await barrier.suspendUntilReleased()
            return Data([1])
        }
        session.passwordVerificationDriver = verifier
        try await observeReleasedInspection(barrier: barrier, operation: {
            try await session.loadArchive(path: path)
        }, whileSuspended: {
            ArchivePasswordStore.shared.setPassword("new-owner", for: path)
        })
        let selected = await selectedPassword.waitForValue(timeout: .seconds(5))
        XCTAssertEqual(selected, "old")
        XCTAssertEqual(session.activePassword, "old")
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: path), "new-owner")
    }

    func testNewerLoadDuringPayloadAwaitOwnsTheSessionCommit() async throws {
        let oldPath = try fixture()
        let newPath = try fixture()
        let session = ArchiveSessionContext()
        session.facade = TTZipEngineFacade(reader: Reader(entries: [encryptedEntry()]), passwordVault: Vault())
        let barrier = ArchiveHostAsyncBarrier()
        let verifier = MockArchivePasswordDriver()
        verifier.verifyPayloadHandler = { _, _, _ in await barrier.suspendUntilReleased(); return Data([1]) }
        session.passwordVerificationDriver = verifier
        try await observeReleasedInspection(barrier: barrier, operation: {
            try await session.loadArchive(path: oldPath, password: "old-request")
        }, whileSuspended: {
            try await session.loadArchive(path: newPath)
        })
        XCTAssertEqual(session.currentArchivePath, newPath)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: oldPath))
    }

    func testHierarchyVaultDiscoveryDoesNotOverrideAConcurrentOwner() async throws {
        let path = try fixture()
        let barrier = ArchiveHostAsyncBarrier()
        let cache = ArchiveHierarchySessionCache(facade: TTZipEngineFacade(
            reader: Reader(entries: [encryptedEntry()], headerPassword: "vault", barrier: barrier),
            passwordVault: Vault([PasswordVaultEntry(label: "Synthetic", password: "vault")])
        ))
        let loaded = try await observeReleasedInspection(barrier: barrier, operation: {
            try await cache.getOrFetchSession(for: path)
        }, whileSuspended: {
            ArchivePasswordStore.shared.setPassword("other-owner", for: path)
        })
        XCTAssertEqual(loaded.unlockedPassword, "vault")
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: path), "other-owner")
    }
}
