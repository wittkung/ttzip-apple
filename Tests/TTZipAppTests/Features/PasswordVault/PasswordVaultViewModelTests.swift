// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class PasswordVaultViewModelTests: XCTestCase {
    private var testDirectory: URL!
    private var manager: PasswordVaultManager!

    override func setUp() async throws {
        try await super.setUp()
        testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ttzip-vault-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        manager = PasswordVaultManager(
            vaultURL: testDirectory.appendingPathComponent("vault.enc"),
            configURL: testDirectory.appendingPathComponent("config.json"),
            backupURL: testDirectory.appendingPathComponent("backup.enc")
        )
    }

    override func tearDown() async throws {
        manager.lockVault()
        try FileManager.default.removeItem(at: testDirectory)
        manager = nil
        try await super.tearDown()
    }
    
    func testInitialViewModelState() {
        let vm = PasswordVaultViewModel(manager: manager)
        XCTAssertFalse(vm.isUnlocked)
        XCTAssertEqual(vm.masterPasswordInput, "")
        XCTAssertEqual(vm.confirmMasterPasswordInput, "")
        XCTAssertEqual(vm.unlockErrorMessage, "")
        XCTAssertFalse(vm.isAddModalPresented)
        XCTAssertFalse(vm.isResetSheetPresented)
    }
    
    func testSetupFirstMasterPasswordAndUnlock() async {
        let vm = PasswordVaultViewModel(manager: manager)
        
        // Mismatched passwords should fail
        vm.masterPasswordInput = "MasterKey123"
        vm.confirmMasterPasswordInput = "DifferentKey"
        vm.setupFirstMasterPassword()
        XCTAssertFalse(vm.isUnlocked)
        XCTAssertFalse(vm.unlockErrorMessage.isEmpty)
        
        // Matching passwords should succeed
        vm.masterPasswordInput = "MasterKey123"
        vm.confirmMasterPasswordInput = "MasterKey123"
        vm.setupFirstMasterPassword()
        XCTAssertTrue(vm.isUnlocked)
        XCTAssertEqual(vm.unlockErrorMessage, "")
        XCTAssertTrue(vm.isMasterPasswordSet)
    }
    
    func testAddAndDeletePasswordVaultEntries() async {
        let vm = PasswordVaultViewModel(manager: manager)
        vm.masterPasswordInput = "MasterKey123"
        vm.confirmMasterPasswordInput = "MasterKey123"
        vm.setupFirstMasterPassword()
        
        let initialCount = vm.entries.count
        
        // Add entry
        vm.newLabel = "Work Archive"
        vm.newPassword = "ArchiveSecret99"
        vm.newCategory = "Work"
        vm.addEntry()
        
        XCTAssertEqual(vm.entries.count, initialCount + 1)
        guard let added = vm.entries.first(where: { $0.label == "Work Archive" }) else {
            XCTFail("Added entry must exist in ViewModel entries")
            return
        }
        XCTAssertEqual(added.password, "ArchiveSecret99")
        XCTAssertEqual(added.category, "Work")
        XCTAssertEqual(vm.newLabel, "")
        XCTAssertEqual(vm.newPassword, "")
        
        // Delete entry
        vm.deleteEntry(id: added.id)
        XCTAssertFalse(vm.entries.contains { $0.id == added.id })
    }
    
    func testLockAndUnlockVaultAsync() async {
        let vm = PasswordVaultViewModel(manager: manager)
        vm.masterPasswordInput = "VaultPass123"
        vm.confirmMasterPasswordInput = "VaultPass123"
        vm.setupFirstMasterPassword()
        XCTAssertTrue(vm.isUnlocked)
        
        // Lock
        vm.lockVault()
        XCTAssertFalse(vm.isUnlocked)
        XCTAssertTrue(vm.entries.isEmpty)
        
        // Invalid unlock
        vm.masterPasswordInput = "WrongPassword"
        let failedUnlock = await vm.unlockVaultAsync()
        XCTAssertFalse(failedUnlock)
        XCTAssertFalse(vm.isUnlocked)
        XCTAssertTrue(vm.unlockErrorMessage.contains("主密码不匹配") || vm.unlockErrorMessage.contains("does not match"))
        
        // Valid unlock
        vm.masterPasswordInput = "VaultPass123"
        let successUnlock = await vm.unlockVaultAsync()
        XCTAssertTrue(successUnlock)
        XCTAssertTrue(vm.isUnlocked)
        XCTAssertEqual(vm.unlockErrorMessage, "")
    }

    func testExternalLockClearsCachedEntriesFromViewModel() {
        let vm = PasswordVaultViewModel(manager: manager)
        vm.masterPasswordInput = "TaskOwnedMasterPassword@2026"
        vm.confirmMasterPasswordInput = vm.masterPasswordInput
        vm.setupFirstMasterPassword()
        vm.newLabel = "test archive"
        vm.newPassword = "task-owned-secret"
        vm.addEntry()
        XCTAssertEqual(vm.entries.count, 1)

        manager.lockVault()
        vm.refreshState()
        XCTAssertFalse(vm.isUnlocked)
        XCTAssertTrue(vm.entries.isEmpty)
    }

    func testFailedEntryWriteRetainsInputAndExistingEntries() throws {
        let vm = PasswordVaultViewModel(manager: manager)
        vm.masterPasswordInput = "TaskOwnedMasterPassword@2026"
        vm.confirmMasterPasswordInput = vm.masterPasswordInput
        vm.setupFirstMasterPassword()
        vm.newLabel = "existing"
        vm.newPassword = "task-owned-secret"
        vm.addEntry()
        let originalEntries = vm.entries
        let vaultURL = testDirectory.appendingPathComponent("vault.enc")
        let externalData = Data("external change for test".utf8)
        try externalData.write(to: vaultURL, options: .atomic)

        vm.isAddModalPresented = true
        vm.newLabel = "unsaved"
        vm.newPassword = "task-owned-new-secret"
        vm.addEntry()
        XCTAssertTrue(vm.isAddModalPresented)
        XCTAssertEqual(vm.newLabel, "unsaved")
        XCTAssertEqual(vm.newPassword, "task-owned-new-secret")
        XCTAssertFalse(vm.entryErrorMessage.isEmpty)
        XCTAssertEqual(vm.entries.map(\.id), originalEntries.map(\.id))
        XCTAssertEqual(try Data(contentsOf: vaultURL), externalData)

        vm.deleteEntry(id: originalEntries[0].id)
        XCTAssertEqual(vm.entries.map(\.id), originalEntries.map(\.id))
        XCTAssertFalse(vm.entryErrorMessage.isEmpty)
    }

    func testCancelPendingUnlockClearsBusyState() {
        let vm = PasswordVaultViewModel(manager: manager)
        manager.setMasterPassword("TaskOwnedMasterPassword@2026")
        vm.isUnlocking = true
        vm.cancelPendingUnlock()
        XCTAssertFalse(vm.isUnlocking)
        XCTAssertFalse(manager.isUnlocked)
    }

    func testCancelPendingUnlockOnVaultExitInvalidatesBiometricContextAndBlocksLateUnlock() async throws {
        let vm = PasswordVaultViewModel(manager: manager)
        vm.masterPasswordInput = "TaskOwnedMasterPassword@2026"
        vm.confirmMasterPasswordInput = vm.masterPasswordInput
        vm.setupFirstMasterPassword()
        vm.newLabel = "Work Archive"
        vm.newPassword = "task-owned-secret"
        vm.addEntry()
        let keyData = try XCTUnwrap(manager.activeDerivedVaultKey).withUnsafeBytes { Data($0) }
        vm.lockVault()
        XCTAssertFalse(vm.isUnlocked)

        let mockContext = ViewModelMockBiometricContext()
        let readEntered = expectation(description: "Biometric key read entered")
        let readReturned = expectation(description: "Biometric key read returned")
        let releaseRead = DispatchSemaphore(value: 0)

        manager.makeBiometricContext = { mockContext }
        manager.biometricKeyReaderOverride = { _ in
            readEntered.fulfill()
            _ = releaseRead.wait(timeout: .now() + 5)
            defer { readReturned.fulfill() }
            return .success(keyData)
        }

        vm.isBiometricAvailable = true
        vm.authenticateWithBiometrics()
        XCTAssertTrue(vm.isUnlocking)

        await fulfillment(of: [readEntered], timeout: 5.0)
        XCTAssertEqual(mockContext.invalidateCallCount, 0)

        vm.cancelPendingUnlock()
        XCTAssertFalse(vm.isUnlocking)
        XCTAssertEqual(mockContext.invalidateCallCount, 1)
        XCTAssertFalse(vm.isUnlocked)
        XCTAssertFalse(manager.isUnlocked)

        releaseRead.signal()
        await fulfillment(of: [readReturned], timeout: 5.0)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(manager.isUnlocked)
        XCTAssertTrue(manager.getEntries().isEmpty)
        XCTAssertFalse(vm.isUnlocked)
        XCTAssertFalse(vm.isUnlocking)
        XCTAssertTrue(vm.entries.isEmpty)
    }

    func testResetRequiresConfirmationAndPreservesEncryptedBackup() throws {
        let vm = PasswordVaultViewModel(manager: manager)
        vm.masterPasswordInput = "OldTaskOwnedMaster@2026"
        vm.confirmMasterPasswordInput = vm.masterPasswordInput
        vm.setupFirstMasterPassword()
        vm.newLabel = "old entry"
        vm.newPassword = "task-owned-secret"
        vm.addEntry()
        vm.lockVault()

        vm.newMasterPasswordInput = "NewTaskOwnedMaster@2026"
        vm.confirmNewMasterPasswordInput = "different"
        vm.resetMasterPassword()
        XCTAssertFalse(vm.isResetBackupNoticePresented)
        XCTAssertFalse(vm.resetErrorMessage.isEmpty)

        vm.confirmNewMasterPasswordInput = vm.newMasterPasswordInput
        vm.resetMasterPassword()
        XCTAssertTrue(vm.isResetBackupNoticePresented)
        XCTAssertTrue(vm.isUnlocked)
        XCTAssertTrue(vm.entries.isEmpty)
        let backup = try XCTUnwrap(vm.resetBackupLocation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("vault.enc").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("config.json").path))
    }
    
    func testAutoUnlockArchivesToggle() {
        let vm = PasswordVaultViewModel(manager: manager)
        let original = vm.autoUnlockArchives
        XCTAssertEqual(vm.autoUnlockArchives, original)
    }
    
    func testSaveRecoveredPasswordToVault() {
        let vm = PasswordVaultViewModel(manager: manager)
        vm.masterPasswordInput = "VaultPass123"
        vm.confirmMasterPasswordInput = "VaultPass123"
        vm.setupFirstMasterPassword()
        
        let initialCount = vm.entries.count
        vm.saveRecoveredPasswordToVault(label: "Recovered RAR", password: "FoundKey123")
        
        XCTAssertEqual(vm.entries.count, initialCount + 1)
        XCTAssertTrue(vm.entries.contains { $0.label == "Recovered RAR" && $0.password == "FoundKey123" })
    }

    func testTouchIDAvailableAndBootstrapsVaultOnInitialSetupAndEmptyVault() async throws {
        let vm = PasswordVaultViewModel(manager: manager)
        vm.isBiometricAvailable = true
        XCTAssertFalse(vm.isMasterPasswordSet)
        XCTAssertTrue(vm.canUseBiometricUnlock)

        let unlockedExpectation = expectation(description: "Biometric bootstrap completed")
        manager.biometricKeyReaderOverride = { _ in
            defer { unlockedExpectation.fulfill() }
            return .missing
        }
        manager.biometricPolicyEvaluatorOverride = { _, _ in .success(()) }

        vm.authenticateWithBiometrics()
        await fulfillment(of: [unlockedExpectation], timeout: 5.0)
        for _ in 0..<40 where vm.isUnlocking {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(vm.isUnlocked)
        XCTAssertTrue(vm.isMasterPasswordSet)
        XCTAssertFalse(vm.isBiometricKeyMissing)
        XCTAssertEqual(vm.unlockErrorMessage, "")

        vm.newLabel = "TouchID Entry"
        vm.newPassword = "TouchIDPassword123"
        vm.addEntry()
        XCTAssertEqual(vm.entries.count, 1)
    }
}

private final class ViewModelMockBiometricContext: BiometricAuthenticationContextProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _localizedReason = ""
    private var _invalidateCallCount = 0

    var localizedReason: String {
        get { lock.withLock { _localizedReason } }
        set { lock.withLock { _localizedReason = newValue } }
    }

    var invalidateCallCount: Int {
        lock.withLock { _invalidateCallCount }
    }

    func invalidate() {
        lock.withLock { _invalidateCallCount += 1 }
    }
}

