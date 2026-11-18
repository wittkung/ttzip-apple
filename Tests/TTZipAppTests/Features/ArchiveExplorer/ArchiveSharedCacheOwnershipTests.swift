// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import TTZipUI
@testable import TTZipCore
@testable import TTZipApp

// MM48 — ownership of the shared password cache.
//
// Contract (products/ttzip/docs/twin/multiwindow-and-password-recovery.md §7):
//   * an inspection is a query: it may read the shared cache to pick a candidate and it keeps
//     the vault retry policy, but it must never publish, restore or remove a shared credential;
//   * the credential that worked is reported in `unlockedPassword`; the owner that accepts the
//     result commits it in its own acceptance block;
//   * a query that is in flight must not disturb a credential another owner committed while it
//     was running — neither by publishing its own candidate, nor by restoring an older one.
//
// The suites drive the real production chain: the real default driver, the real
// `TTZipEngineFacade` and the real host acceptance blocks. Only the archive reader and the
// password vault are injected, and the reader is paused at the shared
// `ArchiveHostAsyncBarrier` so the interleaving is deterministic: no sleeps, no timing races,
// every wait bounded, every barrier released.

@MainActor
final class ArchiveSharedCacheOwnershipTests: XCTestCase {
    // MARK: - Controlled environment

    /// Injected reader: succeeds only for the accepted passwords, and may pause at a barrier.
    private actor ControlledReader: ArchiveReading {
        private let acceptedPasswords: Set<String>
        private let failure: ArchiveError
        private let barrier: ArchiveHostAsyncBarrier?

        init(
            acceptedPasswords: Set<String>,
            failure: ArchiveError = .passwordRequired,
            barrier: ArchiveHostAsyncBarrier? = nil
        ) {
            self.acceptedPasswords = acceptedPasswords
            self.failure = failure
            self.barrier = barrier
        }

        func inspect(archivePath: String) async throws -> [ArchiveEntry] {
            try await inspect(archivePath: archivePath, password: nil, candidatePasswords: nil)
        }

        func inspect(archivePath: String, password: String?, candidatePasswords: [String]?) async throws -> [ArchiveEntry] {
            if let barrier {
                await barrier.suspendUntilReleased()
            }
            try Task.checkCancellation()
            guard let password, acceptedPasswords.contains(password) else {
                throw failure
            }
            return [ArchiveEntry(path: "entry.txt", uncompressedSize: 1, isDirectory: false)]
        }

        func inspectTree(archivePath: String, password: String?, candidatePasswords: [String]?) async throws -> ArchiveCompositeDirectory {
            XCTFail("The inspection facade must use the reader's inspection entry point")
            throw ArchiveError.openFailed
        }

        func probeEncryption(archivePath: String) async throws -> ArchiveEncryptionTier {
            XCTFail("A failed inspection must not guess encryption through another entry point")
            return .unsupported
        }
    }

    /// Injected vault: a fixed candidate list plus a usage counter.
    private final class ControlledVault: PasswordVaultManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [PasswordVaultEntry]
        private var usages: [UUID] = []

        var autoUnlockArchives: Bool { true }

        init(entries: [PasswordVaultEntry] = []) {
            self.entries = entries
        }

        func getEntries() -> [PasswordVaultEntry] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }

        func recordUsage(id: UUID) {
            lock.lock(); defer { lock.unlock() }
            usages.append(id)
        }

        var recordedUsages: [UUID] {
            lock.lock(); defer { lock.unlock() }
            return usages
        }
    }

    // MARK: - Fixtures

    /// A unique archive path per case. The shared cache is never cleared globally: every case
    /// removes only its own entry, so a case running in parallel is never disturbed.
    private func makeFixturePath() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm48-ownership-\(UUID().uuidString)")
        try Data([0x54, 0x54]).write(to: url, options: .withoutOverwriting)
        addTeardownBlock {
            ArchivePasswordStore.shared.removePassword(for: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url.path
    }

    private func makeDriver(
        acceptedPasswords: Set<String>,
        failure: ArchiveError = .passwordRequired,
        barrier: ArchiveHostAsyncBarrier? = nil,
        vault: ControlledVault = ControlledVault()
    ) -> (driver: DefaultArchivePasswordOperationsDriver, vault: ControlledVault) {
        let reader = ControlledReader(acceptedPasswords: acceptedPasswords, failure: failure, barrier: barrier)
        let facade = TTZipEngineFacade(reader: reader, passwordVault: vault)
        return (DefaultArchivePasswordOperationsDriver(facade: facade), vault)
    }

    // MARK: - The default driver is a query

    func testDefaultDriverQueryKeepsAConcurrentCommitWhenItSucceeds() async throws {
        let path = try makeFixturePath()
        let barrier = ArchiveHostAsyncBarrier()
        let (driver, _) = makeDriver(acceptedPasswords: ["query-pw"], barrier: barrier)

        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task.detached {
            do {
                let result = try await driver.inspectArchive(
                    archivePath: path,
                    password: "query-pw",
                    autoVaultUnlock: false
                )
                await receipt.store("ok:\(result.unlockedPassword ?? "nil")")
            } catch {
                await receipt.store("error")
            }
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))

        // Another owner commits a credential for the same path while the query is in flight.
        ArchivePasswordStore.shared.setPassword("owner-pw", for: path)
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The injected reader must reach the controlled barrier in budget")
        XCTAssertEqual(outcome, "ok:query-pw")
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: path),
            "owner-pw",
            "A successful query must not overwrite a credential another owner committed while it was running"
        )
    }

    func testDefaultDriverQueryKeepsAConcurrentCommitWhenThePasswordFails() async throws {
        let path = try makeFixturePath()
        let barrier = ArchiveHostAsyncBarrier()
        let (driver, vault) = makeDriver(acceptedPasswords: ["other-pw"], barrier: barrier)

        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task.detached {
            do {
                _ = try await driver.inspectArchive(
                    archivePath: path,
                    password: "query-pw",
                    autoVaultUnlock: false
                )
                await receipt.store("ok")
            } catch {
                await receipt.store("error")
            }
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))

        ArchivePasswordStore.shared.setPassword("owner-pw", for: path)
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The injected reader must reach the controlled barrier in budget")
        XCTAssertEqual(outcome, "error")
        XCTAssertEqual(vault.recordedUsages.count, 0, "An explicit credential owns its failure contract")
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: path),
            "owner-pw",
            "A failed query must not remove a credential another owner committed while it was running"
        )
    }

    func testDefaultDriverQueryKeepsAConcurrentCommitWhenTheInspectionFailsForAnotherReason() async throws {
        let path = try makeFixturePath()
        let barrier = ArchiveHostAsyncBarrier()
        let (driver, _) = makeDriver(
            acceptedPasswords: ["other-pw"],
            failure: .corruptHeader,
            barrier: barrier
        )

        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task.detached {
            do {
                _ = try await driver.inspectArchive(
                    archivePath: path,
                    password: "query-pw",
                    autoVaultUnlock: false
                )
                await receipt.store("ok")
            } catch {
                await receipt.store("error")
            }
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))

        ArchivePasswordStore.shared.setPassword("owner-pw", for: path)
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The injected reader must reach the controlled barrier in budget")
        XCTAssertEqual(outcome, "error")
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: path),
            "owner-pw",
            "A query that failed for a non-password reason must not remove another owner's credential"
        )
    }

    func testDefaultDriverQueryKeepsAConcurrentCommitWhenItIsCancelled() async throws {
        let path = try makeFixturePath()
        let barrier = ArchiveHostAsyncBarrier()
        let (driver, _) = makeDriver(acceptedPasswords: ["query-pw"], barrier: barrier)

        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task.detached {
            do {
                _ = try await driver.inspectArchive(
                    archivePath: path,
                    password: "query-pw",
                    autoVaultUnlock: false
                )
                await receipt.store("ok")
            } catch {
                await receipt.store("error")
            }
        }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))

        ArchivePasswordStore.shared.setPassword("owner-pw", for: path)
        task.cancel()
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The injected reader must reach the controlled barrier in budget")
        XCTAssertEqual(outcome, "error")
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: path),
            "owner-pw",
            "A cancelled query must not remove a credential another owner committed while it was running"
        )
    }

    func testDefaultDriverQueryDoesNotRestoreAnOlderCachedCandidateOverANewerCommit() async throws {
        let path = try makeFixturePath()
        // The cache holds an older credential that the query reads as its candidate.
        ArchivePasswordStore.shared.setPassword("old-pw", for: path)
        let barrier = ArchiveHostAsyncBarrier()
        let (driver, _) = makeDriver(acceptedPasswords: ["old-pw"], barrier: barrier)

        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task.detached {
            do {
                let result = try await driver.inspectArchive(
                    archivePath: path,
                    password: nil,
                    autoVaultUnlock: false
                )
                await receipt.store("ok:\(result.unlockedPassword ?? "nil")")
            } catch {
                await receipt.store("error")
            }
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))

        // Another owner commits a newer credential while the query is in flight.
        ArchivePasswordStore.shared.setPassword("new-pw", for: path)
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The injected reader must reach the controlled barrier in budget")
        XCTAssertEqual(outcome, "ok:old-pw")
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: path),
            "new-pw",
            "A query must not restore the candidate it read before its await over a newer commit"
        )
    }

    func testDefaultDriverQueryOnAnotherPathDoesNotDisturbTheCommittedPath() async throws {
        let inspectedPath = try makeFixturePath()
        let committedPath = try makeFixturePath()
        let barrier = ArchiveHostAsyncBarrier()
        let (driver, _) = makeDriver(acceptedPasswords: ["query-pw"], barrier: barrier)

        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task.detached {
            do {
                _ = try await driver.inspectArchive(
                    archivePath: inspectedPath,
                    password: "query-pw",
                    autoVaultUnlock: false
                )
                await receipt.store("ok")
            } catch {
                await receipt.store("error")
            }
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))

        ArchivePasswordStore.shared.setPassword("owner-pw", for: committedPath)
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The injected reader must reach the controlled barrier in budget")
        XCTAssertEqual(outcome, "ok")
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: committedPath),
            "owner-pw",
            "A query must not touch the shared cache of another path"
        )
        XCTAssertNil(
            ArchivePasswordStore.shared.getPassword(for: inspectedPath),
            "A query must not publish the credential it used"
        )
    }

    // MARK: - The normal open commits in its own acceptance block

    func testAbandonedNormalOpenNeitherPublishesNorReachesThePage() async throws {
        let path = try makeFixturePath()
        // An older credential is cached; the open request reads it as its candidate.
        ArchivePasswordStore.shared.setPassword("old-pw", for: path)
        let barrier = ArchiveHostAsyncBarrier()
        let (driver, _) = makeDriver(acceptedPasswords: ["old-pw"], barrier: barrier)
        let state = AppViewState(fileViewer: MockFileViewerHarness(), passwordDriver: driver)

        let receipt = ArchiveHostCompletionReceipt<Bool>()
        let task = Task { @MainActor in
            let loaded = await state.loadArchive(path: path)
            await receipt.store(loaded)
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))

        // The user navigates away: the open request loses its ticket.
        state.handleActiveBrowsingContextChange()
        // Another owner commits a newer credential for the same path.
        ArchivePasswordStore.shared.setPassword("new-pw", for: path)
        await barrier.release()

        let loaded = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The real reader must enter its controlled gate before cleanup")
        XCTAssertEqual(loaded, false, "An abandoned open request must not commit")
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: path),
            "new-pw",
            "An abandoned open request must not publish its candidate over a newer commit"
        )
        XCTAssertNil(
            state.explorerState.currentArchivePath,
            "An abandoned open request must not reach the page"
        )
    }

    func testAcceptedNormalOpenPublishesTheVerifiedCredential() async throws {
        let path = try makeFixturePath()
        let barrier = ArchiveHostAsyncBarrier()
        let (driver, _) = makeDriver(acceptedPasswords: ["open-pw"], barrier: barrier)
        let state = AppViewState(fileViewer: MockFileViewerHarness(), passwordDriver: driver)

        let receipt = ArchiveHostCompletionReceipt<Bool>()
        let task = Task { @MainActor in
            let loaded = await state.loadArchive(path: path, password: "open-pw")
            await receipt.store(loaded)
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))
        await barrier.release()

        let loaded = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The real reader must enter its controlled gate before cleanup")
        XCTAssertEqual(loaded, true, "An accepted open request must commit")
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: path),
            "open-pw",
            "The owner that accepted the open must publish the verified credential"
        )
    }

    // MARK: - The independent session commits in its own acceptance block

    func testIndependentSessionPublishesOnlyAfterItsOwnAcceptance() async throws {
        let path = try makeFixturePath()
        let barrier = ArchiveHostAsyncBarrier()
        let session = ArchiveSessionContext()
        session.facade = TTZipEngineFacade(
            reader: ControlledReader(acceptedPasswords: ["session-pw"], barrier: barrier),
            passwordVault: ControlledVault()
        )

        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task { @MainActor in
            do {
                try await session.loadArchive(path: path, password: "session-pw")
                await receipt.store("ok")
            } catch {
                await receipt.store("error")
            }
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))

        // The session is closed while the inspection is in flight.
        session.closeArchive()
        // Another owner commits a credential for the same path.
        ArchivePasswordStore.shared.setPassword("owner-pw", for: path)
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The injected reader must reach the controlled barrier in budget")
        XCTAssertEqual(outcome, "ok")
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: path),
            "owner-pw",
            "A closed session must not publish the credential of a discarded inspection"
        )
        XCTAssertNil(session.currentArchivePath, "A closed session must not restore its archive")
    }

    func testAcceptedIndependentSessionPublishesTheVerifiedCredential() async throws {
        let path = try makeFixturePath()
        let barrier = ArchiveHostAsyncBarrier()
        let session = ArchiveSessionContext()
        session.facade = TTZipEngineFacade(
            reader: ControlledReader(acceptedPasswords: ["session-pw"], barrier: barrier),
            passwordVault: ControlledVault()
        )

        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task { @MainActor in
            do {
                try await session.loadArchive(path: path, password: "session-pw")
                await receipt.store("ok")
            } catch {
                await receipt.store("error")
            }
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The injected reader must reach the controlled barrier in budget")
        XCTAssertEqual(outcome, "ok")
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: path),
            "session-pw",
            "The session that accepted the inspection must publish the credential"
        )
        XCTAssertEqual(session.currentArchivePath, path)
    }

    // MARK: - The hierarchy session publishes a discovered credential at its acceptance

    func testHierarchyPublishesADiscoveredCredentialAtItsAcceptance() async throws {
        let path = try makeFixturePath()
        let barrier = ArchiveHostAsyncBarrier()
        let vault = ControlledVault(entries: [PasswordVaultEntry(label: "Synthetic", password: "vault-pw")])
        let cache = ArchiveHierarchySessionCache(
            facade: TTZipEngineFacade(
                reader: ControlledReader(acceptedPasswords: ["vault-pw"], barrier: barrier),
                passwordVault: vault
            )
        )

        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task.detached {
            do {
                let session = try await cache.getOrFetchSession(for: path, password: nil, autoVaultUnlock: true)
                await receipt.store("ok:\(session.unlockedPassword ?? "nil")")
            } catch {
                await receipt.store("error")
            }
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The injected reader must reach the controlled barrier in budget")
        XCTAssertEqual(outcome, "ok:vault-pw")
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: path),
            "vault-pw",
            "An accepted hierarchy session must keep the credential it discovered reusable"
        )
    }

    func testHierarchyDoesNotPublishWhenItsGenerationIsInvalidated() async throws {
        let path = try makeFixturePath()
        let barrier = ArchiveHostAsyncBarrier()
        let vault = ControlledVault(entries: [PasswordVaultEntry(label: "Synthetic", password: "vault-pw")])
        let cache = ArchiveHierarchySessionCache(
            facade: TTZipEngineFacade(
                reader: ControlledReader(acceptedPasswords: ["vault-pw"], barrier: barrier),
                passwordVault: vault
            )
        )

        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task.detached {
            do {
                _ = try await cache.getOrFetchSession(for: path, password: nil, autoVaultUnlock: true)
                await receipt.store("ok")
            } catch {
                await receipt.store("error")
            }
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))

        // The path is invalidated while the fetch is in flight.
        await cache.invalidate(path: path)
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The injected reader must reach the controlled barrier in budget")
        XCTAssertNotNil(outcome)
        XCTAssertNil(
            ArchivePasswordStore.shared.getPassword(for: path),
            "An invalidated hierarchy fetch must not publish a credential"
        )
    }

    func testForgetLogicalKeyInvalidatesUncachedInFlightHierarchy() async throws {
        let path = try makeFixturePath()
        let barrier = ArchiveHostAsyncBarrier()
        let vault = ControlledVault(entries: [PasswordVaultEntry(label: "Synthetic", password: "vault-pw")])
        let cache = ArchiveHierarchySessionCache(
            facade: TTZipEngineFacade(
                reader: ControlledReader(acceptedPasswords: ["vault-pw"], barrier: barrier),
                passwordVault: vault
            )
        )
        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task.detached {
            do {
                _ = try await cache.getOrFetchSession(for: path, password: nil, autoVaultUnlock: true)
                await receipt.store("ok")
            } catch {
                await receipt.store("error")
            }
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))
        await cache.invalidate(logicalKey: ArchiveCredentialIdentity.logicalKey(for: path))
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended)
        XCTAssertNotNil(outcome)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: path))
        let cached = await cache.cachedSession(for: path)
        XCTAssertNil(cached)
    }

    func testForgetGenerationBlocksHierarchyPublishBeforeActorInvalidation() async throws {
        let path = try makeFixturePath()
        let logicalKey = ArchiveCredentialIdentity.logicalKey(for: path)
        let barrier = ArchiveHostAsyncBarrier()
        let vault = ControlledVault(entries: [PasswordVaultEntry(label: "Synthetic", password: "vault-pw")])
        let cache = ArchiveHierarchySessionCache(
            facade: TTZipEngineFacade(
                reader: ControlledReader(acceptedPasswords: ["vault-pw"], barrier: barrier),
                passwordVault: vault
            )
        )
        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task.detached {
            do {
                _ = try await cache.getOrFetchSession(for: path, password: nil, autoVaultUnlock: true)
                await receipt.store("ok")
            } catch {
                await receipt.store("error")
            }
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))
        ArchiveCredentialGeneration.shared.invalidate(logicalKey)
        ArchivePasswordStore.shared.removePasswords(forLogicalArchiveAt: path)
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended)
        XCTAssertNotNil(outcome)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: path))
        await cache.invalidate(logicalKey: logicalKey)
    }

    func testHierarchyDoesNotRepublishAnOldCachedCandidateOverANewerCommit() async throws {
        let path = try makeFixturePath()
        // The cache holds an older credential that the fetch reads as its candidate.
        ArchivePasswordStore.shared.setPassword("old-pw", for: path)
        let barrier = ArchiveHostAsyncBarrier()
        let cache = ArchiveHierarchySessionCache(
            facade: TTZipEngineFacade(
                reader: ControlledReader(acceptedPasswords: ["old-pw"], barrier: barrier),
                passwordVault: ControlledVault()
            )
        )

        let receipt = ArchiveHostCompletionReceipt<String>()
        let task = Task.detached {
            do {
                _ = try await cache.getOrFetchSession(for: path, password: nil, autoVaultUnlock: true)
                await receipt.store("ok")
            } catch {
                await receipt.store("error")
            }
        }
        defer { task.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))

        // Another owner commits a newer credential while the fetch is in flight.
        ArchivePasswordStore.shared.setPassword("new-pw", for: path)
        await barrier.release()

        let outcome = await receipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The injected reader must reach the controlled barrier in budget")
        XCTAssertEqual(outcome, "ok")
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: path),
            "new-pw",
            "The hierarchy must not restore the candidate it read before its await over a newer commit"
        )
    }

    func testHierarchyCoalescedWaitSharesTheAcceptedOutcome() async throws {
        let path = try makeFixturePath()
        let barrier = ArchiveHostAsyncBarrier()
        let vault = ControlledVault(entries: [PasswordVaultEntry(label: "Synthetic", password: "vault-pw")])
        let cache = ArchiveHierarchySessionCache(
            facade: TTZipEngineFacade(
                reader: ControlledReader(acceptedPasswords: ["vault-pw"], barrier: barrier),
                passwordVault: vault
            )
        )

        let firstReceipt = ArchiveHostCompletionReceipt<Result<ArchiveHierarchySession, Error>>()
        let first = Task.detached {
            do {
                let session = try await cache.getOrFetchSession(for: path, password: nil, autoVaultUnlock: true)
                await firstReceipt.store(.success(session))
            } catch { await firstReceipt.store(.failure(error)) }
        }
        defer { first.cancel() }

        let suspended = await barrier.waitUntilSuspended(timeout: .seconds(5))
        // The second request and both outcomes remain observed even if either fetch fails.
        let secondReceipt = ArchiveHostCompletionReceipt<Result<ArchiveHierarchySession, Error>>()
        let second = Task.detached {
            do {
                let session = try await cache.getOrFetchSession(for: path, password: nil, autoVaultUnlock: true)
                await secondReceipt.store(.success(session))
            } catch { await secondReceipt.store(.failure(error)) }
        }
        defer { second.cancel() }
        await barrier.release()
        let firstOutcome = await firstReceipt.waitForValue(timeout: .seconds(5))
        let secondOutcome = await secondReceipt.waitForValue(timeout: .seconds(5))
        XCTAssertTrue(suspended, "The injected reader must reach the controlled barrier in budget")
        let firstSession = try XCTUnwrap(firstOutcome, "First fetch did not complete within budget").get()
        let secondSession = try XCTUnwrap(secondOutcome, "Coalesced fetch did not complete within budget").get()
        XCTAssertEqual(firstSession.archivePath, secondSession.archivePath)
        XCTAssertEqual(firstSession.unlockedPassword, secondSession.unlockedPassword)
        XCTAssertEqual(
            ArchivePasswordStore.shared.getPassword(for: path),
            "vault-pw",
            "A coalesced wait must observe the same published credential as the accepted fetch"
        )
    }
}
