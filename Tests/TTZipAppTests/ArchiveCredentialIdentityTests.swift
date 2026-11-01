// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
import TTZipAppServices
@testable import TTZipAppViewModels
import TTZipCore

private final class RecordingArchiveCredentialStore: ArchiveScopedCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: (contentKey: String, password: String)] = [:]
    private var reads = 0

    var passwordReadCount: Int { lock.withLock { reads } }

    func password(logicalKey: String, contentKey: String) throws -> String? {
        lock.withLock {
            reads += 1
            guard let record = records[logicalKey], record.contentKey == contentKey else { return nil }
            return record.password
        }
    }

    func upsert(password: String, logicalKey: String, contentKey: String, label: String) throws {
        lock.withLock { records[logicalKey] = (contentKey, password) }
    }

    func remove(logicalKey: String) throws {
        lock.withLock { _ = records.removeValue(forKey: logicalKey) }
    }

    func remove(logicalKey: String, contentKey: String, ifPasswordMatches password: String) throws {
        lock.withLock {
            guard records[logicalKey]?.password == password,
                  records[logicalKey]?.contentKey == contentKey else { return }
            _ = records.removeValue(forKey: logicalKey)
        }
    }
}

@MainActor
private final class HeaderCredentialDriver: ArchivePasswordOperationsDriver {
    let acceptedPassword: String
    var submittedPasswords: [String?] = []
    var returnsPlaintextWithoutPassword = false

    init(acceptedPassword: String) {
        self.acceptedPassword = acceptedPassword
    }

    func inspectArchive(
        archivePath: String, password: String?, autoVaultUnlock: Bool
    ) async throws -> InspectResult {
        submittedPasswords.append(password)
        if password == nil && returnsPlaintextWithoutPassword {
            return InspectResult(
                archivePath: archivePath, format: "zip", entries: [],
                totalUncompressedBytes: 0, totalCompressedBytes: 0,
                unlockedPassword: nil
            )
        }
        guard let password else { throw ArchiveError.passwordRequired }
        guard password == acceptedPassword else {
            throw ArchiveError.wrongPassword(archivePath: archivePath)
        }
        return InspectResult(
            archivePath: archivePath,
            format: "zip",
            entries: [],
            totalUncompressedBytes: 0,
            totalCompressedBytes: 0,
            unlockedPassword: password
        )
    }

    func verifyEncryptedEntryPayload(
        archivePath: String, entryPath: String, password: String
    ) async throws -> Data? {
        throw ArchiveError.openFailed
    }

    func quickExtract(
        archivePath: String, destinationDir: String, password: String?,
        autoVaultUnlock: Bool, handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)?, token: CancellationToken?
    ) async throws -> ExtractResult {
        throw ArchiveError.openFailed
    }

    func extractEntries(
        archivePath: String, entryPaths: [String], destinationDir: String,
        password: String?, handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ExtractionOutcome {
        throw ArchiveError.openFailed
    }
}

final class ArchiveCredentialIdentityTests: XCTestCase {
    func testSameNameInDifferentDirectoriesAndReplacementDoNotShareIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first/archive.zip")
        let second = root.appendingPathComponent("second/archive.zip")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: first)
        try Data("first".utf8).write(to: second)

        let original = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: first.path))
        let other = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: second.path))
        XCTAssertNotEqual(original.logicalKey, other.logicalKey)
        XCTAssertNotEqual(original.key, other.key)
        let controller = ArchiveRememberedPasswordController(
            store: RecordingArchiveCredentialStore(), generation: ArchiveCredentialGeneration()
        )
        XCTAssertTrue(try controller.rememberVerified(
            "first fixture password", for: original,
            capturedGeneration: controller.operationGeneration(for: original)
        ))
        XCTAssertNil(try controller.password(for: other))

        try FileManager.default.removeItem(at: first)
        try Data("replacement".utf8).write(to: first)
        let replaced = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: first.path))
        XCTAssertEqual(original.logicalKey, replaced.logicalKey)
        XCTAssertNotEqual(original.key, replaced.key)
        XCTAssertNil(try controller.password(for: replaced))

        let moved = root.appendingPathComponent("first/renamed.zip")
        try FileManager.default.moveItem(at: first, to: moved)
        let movedIdentity = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: moved.path))
        XCTAssertNotEqual(replaced.logicalKey, movedIdentity.logicalKey)
        XCTAssertNotEqual(replaced.key, movedIdentity.key)
    }

    func testNumberedVolumesUseOneIdentityAndDetectMemberChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("archive.7z.001")
        let second = root.appendingPathComponent("archive.7z.002")
        try Data("volume one".utf8).write(to: first)
        try Data("volume two".utf8).write(to: second)

        let fromFirst = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: first.path))
        let fromSecond = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: second.path))
        XCTAssertEqual(fromFirst, fromSecond)

        try Data("changed second volume".utf8).write(to: second)
        let changed = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: first.path))
        XCTAssertEqual(fromFirst.logicalKey, changed.logicalKey)
        XCTAssertNotEqual(fromFirst.key, changed.key)
    }

    func testForgetGenerationRejectsResultsCapturedBeforeInvalidation() {
        let generation = ArchiveCredentialGeneration()
        let archiveKey = UUID().uuidString
        let captured = generation.snapshot(for: archiveKey)
        XCTAssertTrue(generation.isCurrent(captured, for: archiveKey))
        var storedPassword: String? = "existing"
        generation.invalidateAndPerform(for: archiveKey) { storedPassword = nil }
        XCTAssertFalse(generation.isCurrent(captured, for: archiveKey))
        XCTAssertTrue(generation.isCurrent(generation.snapshot(for: archiveKey), for: archiveKey))
        let staleResult = generation.performIfCurrent(captured, for: archiveKey) {
            storedPassword = "late result"
            return true
        }
        XCTAssertNil(staleResult)
        XCTAssertNil(storedPassword)
    }

    func testForgetPreventsLateVerifiedResultFromRepublishing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("fixture".utf8).write(to: file)
        let identity = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: file.path))
        let store = RecordingArchiveCredentialStore()
        let controller = ArchiveRememberedPasswordController(
            store: store, generation: ArchiveCredentialGeneration()
        )
        let oldGeneration = controller.operationGeneration(for: identity)

        try controller.forget(identity)
        XCTAssertFalse(try controller.rememberVerified(
            "late fixture password", for: identity, capturedGeneration: oldGeneration
        ))
        XCTAssertNil(try controller.password(for: identity))

        let newGeneration = controller.operationGeneration(for: identity)
        XCTAssertTrue(try controller.rememberVerified(
            "new fixture password", for: identity, capturedGeneration: newGeneration
        ))
        XCTAssertEqual(try controller.password(for: identity), "new fixture password")
    }

    func testChangedArchiveCannotPublishPasswordVerifiedForOldBytes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("original".utf8).write(to: file)
        let identity = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: file.path))
        let controller = ArchiveRememberedPasswordController(
            store: RecordingArchiveCredentialStore(), generation: ArchiveCredentialGeneration()
        )
        let generation = controller.operationGeneration(for: identity)
        try Data("changed archive bytes".utf8).write(to: file)

        XCTAssertThrowsError(try controller.rememberVerified(
            "fixture password", for: identity, capturedGeneration: generation
        )) { error in
            XCTAssertEqual(error as? ArchiveRememberedPasswordError, .sourceChanged)
        }
        let current = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: file.path))
        XCTAssertNil(try controller.password(for: current))
    }

    func testRejectedSavedCandidateDoesNotDeleteNewerCredential() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("fixture".utf8).write(to: file)
        let identity = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: file.path))
        let controller = ArchiveRememberedPasswordController(
            store: RecordingArchiveCredentialStore(), generation: ArchiveCredentialGeneration()
        )
        var generation = controller.operationGeneration(for: identity)
        XCTAssertTrue(try controller.rememberVerified("old", for: identity, capturedGeneration: generation))
        generation = controller.operationGeneration(for: identity)
        XCTAssertTrue(try controller.rememberVerified("new", for: identity, capturedGeneration: generation))

        try controller.rejectSavedCandidate("old", for: identity)
        XCTAssertEqual(try controller.password(for: identity), "new")
        try controller.rejectSavedCandidate("new", for: identity)
        XCTAssertNil(try controller.password(for: identity))
    }

    @MainActor
    func testNewWindowReadsScopedPasswordAndRejectsInvalidSavedCandidate() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            ArchivePasswordStore.shared.removePassword(for: file.path)
            try? FileManager.default.removeItem(at: file)
        }
        try Data("fixture".utf8).write(to: file)
        let identity = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: file.path))
        let controller = ArchiveRememberedPasswordController(
            store: RecordingArchiveCredentialStore(), generation: ArchiveCredentialGeneration()
        )
        XCTAssertTrue(try controller.rememberVerified(
            "saved fixture", for: identity,
            capturedGeneration: controller.operationGeneration(for: identity)
        ))

        let acceptedDriver = HeaderCredentialDriver(acceptedPassword: "saved fixture")
        let reopened = AppViewState(
            passwordDriver: acceptedDriver, archiveRememberedPasswordController: controller
        )
        let reopenedSuccessfully = await reopened.loadArchive(path: file.path)
        XCTAssertTrue(reopenedSuccessfully)
        XCTAssertEqual(acceptedDriver.submittedPasswords, [nil, "saved fixture"])
        XCTAssertEqual(reopened.explorerState.activePassword, "saved fixture")

        ArchivePasswordStore.shared.removePassword(for: file.path)
        let changedDriver = HeaderCredentialDriver(acceptedPassword: "new fixture")
        let changed = AppViewState(
            passwordDriver: changedDriver, archiveRememberedPasswordController: controller
        )
        let changedSuccessfully = await changed.loadArchive(path: file.path)
        XCTAssertFalse(changedSuccessfully)
        XCTAssertEqual(changedDriver.submittedPasswords, [nil, "saved fixture"])
        XCTAssertNil(try controller.password(for: identity))
        XCTAssertTrue(changed.overlayState.showPasswordPrompt)
    }

    func testForgetClearsEveryNumberedVolumeCacheEntry() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("archive.7z").path
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("archive.7z.001").path
        let first = base + ".001"
        let second = base + ".002"
        let cache = ArchivePasswordStore.shared
        defer {
            cache.removePassword(for: first)
            cache.removePassword(for: second)
            cache.removePassword(for: other)
        }
        cache.setPassword("first fixture", for: first)
        cache.setPassword("second fixture", for: second)
        cache.setPassword("unrelated fixture", for: other)

        cache.removePasswords(forLogicalArchiveAt: second)
        XCTAssertNil(cache.getPassword(for: first))
        XCTAssertNil(cache.getPassword(for: second))
        XCTAssertEqual(cache.getPassword(for: other), "unrelated fixture")
    }

    @MainActor
    func testRememberRequiresVerifiedEncryptedEvidence() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("fixture".utf8).write(to: file)
        let identity = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: file.path))
        let controller = ArchiveRememberedPasswordController(
            store: RecordingArchiveCredentialStore(), generation: ArchiveCredentialGeneration()
        )
        let state = AppViewState(archiveRememberedPasswordController: controller)
        state.stagePasswordPromptContext(archivePath: file.path, kind: .browse)
        let context = try XCTUnwrap(state.pendingPasswordContext)
        let generation = controller.operationGeneration(for: identity)

        state.passwordEvidenceState = .directoryBrowsableUnverified
        await state.rememberSubmittedPasswordIfVerified(
            "fixture password", context: context, identity: identity, generation: generation
        )
        XCTAssertNil(try controller.password(for: identity))

        state.passwordEvidenceState = .verified(.headerCatalog)
        await state.rememberSubmittedPasswordIfVerified(
            "fixture password", context: context, identity: identity, generation: generation
        )
        XCTAssertEqual(try controller.password(for: identity), "fixture password")
    }

    @MainActor
    func testQuickExtractResultCannotRememberPasswordForPlainArchive() async throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try Data("fixture".utf8).write(to: archive)
        let identity = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: archive.path))
        let controller = ArchiveRememberedPasswordController(
            store: RecordingArchiveCredentialStore(), generation: ArchiveCredentialGeneration()
        )
        let driver = HeaderCredentialDriver(acceptedPassword: "fixture password")
        driver.returnsPlaintextWithoutPassword = true
        let state = AppViewState(
            passwordDriver: driver, archiveRememberedPasswordController: controller
        )
        state.stagePasswordPromptContext(
            archivePath: archive.path,
            kind: .quickExtract(
                targetDir: nil, isSmartExtract: false,
                trashSourceAfterExtract: false, collisionHandling: nil
            )
        )
        let context = try XCTUnwrap(state.pendingPasswordContext)
        state.passwordEvidenceState = .verified(.fullArchive)

        await state.rememberSubmittedPasswordIfVerified(
            "fixture password", context: context, identity: identity,
            generation: controller.operationGeneration(for: identity)
        )

        XCTAssertNil(try controller.password(for: identity))
    }

    @MainActor
    func testForgetClearsActiveWindowAndProcessCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("archive.7z.001")
        let second = root.appendingPathComponent("archive.7z.002")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        let controller = ArchiveRememberedPasswordController(
            store: RecordingArchiveCredentialStore(), generation: ArchiveCredentialGeneration()
        )
        let state = AppViewState(archiveRememberedPasswordController: controller)
        state.explorerState.currentArchivePath = second.path
        state.explorerState.activePassword = "fixture password"
        state.passwordEvidenceState = .verified(.headerCatalog)
        ArchivePasswordStore.shared.setPassword("fixture password", for: first.path)
        ArchivePasswordStore.shared.setPassword("fixture password", for: second.path)
        defer {
            ArchivePasswordStore.shared.removePassword(for: first.path)
            ArchivePasswordStore.shared.removePassword(for: second.path)
        }

        let forgotten = await state.forgetArchivePassword(at: second.path)
        XCTAssertTrue(forgotten)
        XCTAssertNil(state.explorerState.activePassword)
        XCTAssertFalse(state.passwordEvidenceState.isCryptographicallyVerified)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: first.path))
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: second.path))
    }

    @MainActor
    func testForgetAfterArchiveRemovalDeletesHiddenScopedRecord() async throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: archive)
        let identity = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: archive.path))
        let store = RecordingArchiveCredentialStore()
        let controller = ArchiveRememberedPasswordController(
            store: store, generation: ArchiveCredentialGeneration()
        )
        try controller.rememberVerified(
            "fixture password", for: identity,
            capturedGeneration: controller.operationGeneration(for: identity)
        )
        try FileManager.default.removeItem(at: archive)

        let state = AppViewState(archiveRememberedPasswordController: controller)
        let forgotten = await state.forgetArchivePassword(at: archive.path)
        XCTAssertTrue(forgotten)
        XCTAssertNil(try store.password(logicalKey: identity.logicalKey, contentKey: identity.key))
    }

    @MainActor
    func testPlainArchiveDoesNotReadScopedVault() async throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try Data("fixture".utf8).write(to: archive)
        let store = RecordingArchiveCredentialStore()
        let driver = HeaderCredentialDriver(acceptedPassword: "unused")
        driver.returnsPlaintextWithoutPassword = true
        let state = AppViewState(
            passwordDriver: driver,
            archiveRememberedPasswordController: ArchiveRememberedPasswordController(
                store: store, generation: ArchiveCredentialGeneration()
            )
        )

        _ = await state.loadArchiveWithTicket(path: archive.path)
        XCTAssertEqual(store.passwordReadCount, 0)
    }

    @MainActor
    func testDisabledAutoUnlockDoesNotReadScopedVault() async throws {
        let setting = "TTZipAutoUnlockArchivesWithVault"
        let original = UserDefaults.standard.object(forKey: setting)
        UserDefaults.standard.set(false, forKey: setting)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: setting)
            } else {
                UserDefaults.standard.removeObject(forKey: setting)
            }
        }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try Data("fixture".utf8).write(to: archive)
        let store = RecordingArchiveCredentialStore()
        let state = AppViewState(
            passwordDriver: HeaderCredentialDriver(acceptedPassword: "fixture password"),
            archiveRememberedPasswordController: ArchiveRememberedPasswordController(
                store: store, generation: ArchiveCredentialGeneration()
            )
        )

        _ = await state.loadArchiveWithTicket(path: archive.path)
        XCTAssertEqual(store.passwordReadCount, 0)
    }
}
