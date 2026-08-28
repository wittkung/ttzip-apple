// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import Foundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class PasswordVaultViewModelTests: XCTestCase {
    
    override func setUp() async throws {
        try await super.setUp()
        PasswordVaultManager.shared.lockVault()
    }
    
    override func tearDown() async throws {
        PasswordVaultManager.shared.lockVault()
        try await super.tearDown()
    }
    
    func testInitialViewModelState() {
        let vm = PasswordVaultViewModel()
        XCTAssertFalse(vm.isUnlocked)
        XCTAssertEqual(vm.masterPasswordInput, "")
        XCTAssertEqual(vm.confirmMasterPasswordInput, "")
        XCTAssertEqual(vm.unlockErrorMessage, "")
        XCTAssertFalse(vm.isAddModalPresented)
        XCTAssertFalse(vm.isResetSheetPresented)
    }
    
    func testSetupFirstMasterPasswordAndUnlock() async {
        let vm = PasswordVaultViewModel()
        
        // Mismatched passwords should fail
        vm.masterPasswordInput = "MasterKey123"
        vm.confirmMasterPasswordInput = "DifferentKey"
        vm.setupFirstMasterPassword()
        XCTAssertFalse(vm.isUnlocked)
        XCTAssertEqual(vm.unlockErrorMessage, "Master passwords do not match. Please try again.")
        
        // Matching passwords should succeed
        vm.masterPasswordInput = "MasterKey123"
        vm.confirmMasterPasswordInput = "MasterKey123"
        vm.setupFirstMasterPassword()
        XCTAssertTrue(vm.isUnlocked)
        XCTAssertEqual(vm.unlockErrorMessage, "")
        XCTAssertTrue(vm.isMasterPasswordSet)
    }
    
    func testAddAndDeletePasswordVaultEntries() async {
        let vm = PasswordVaultViewModel()
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
        let vm = PasswordVaultViewModel()
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
        XCTAssertEqual(vm.unlockErrorMessage, "Incorrect master password. Please try again.")
        
        // Valid unlock
        vm.masterPasswordInput = "VaultPass123"
        let successUnlock = await vm.unlockVaultAsync()
        XCTAssertTrue(successUnlock)
        XCTAssertTrue(vm.isUnlocked)
        XCTAssertEqual(vm.unlockErrorMessage, "")
    }
    
    func testAutoUnlockArchivesToggle() {
        let vm = PasswordVaultViewModel()
        let original = vm.autoUnlockArchives
        
        vm.autoUnlockArchives = !original
        XCTAssertEqual(vm.autoUnlockArchives, !original)
        XCTAssertEqual(PasswordVaultManager.shared.autoUnlockArchives, !original)
        
        // Restore
        vm.autoUnlockArchives = original
    }
    
    func testSaveRecoveredPasswordToVault() {
        let vm = PasswordVaultViewModel()
        vm.masterPasswordInput = "VaultPass123"
        vm.confirmMasterPasswordInput = "VaultPass123"
        vm.setupFirstMasterPassword()
        
        let initialCount = vm.entries.count
        vm.saveRecoveredPasswordToVault(label: "Recovered RAR", password: "FoundKey123")
        
        XCTAssertEqual(vm.entries.count, initialCount + 1)
        XCTAssertTrue(vm.entries.contains { $0.label == "Recovered RAR" && $0.password == "FoundKey123" })
    }
}
