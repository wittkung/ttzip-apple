// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import Observation
import TTZipCore
import LocalAuthentication
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

@Observable
@MainActor
public final class PasswordVaultViewModel {
    public var isUnlocked: Bool = false
    public var masterPasswordInput: String = ""
    public var confirmMasterPasswordInput: String = ""
    public var unlockErrorMessage: String = ""
    
    public var isResetSheetPresented: Bool = false
    public var newMasterPasswordInput: String = ""
    
    public var isRecoverSheetPresented: Bool = false
    public var oldMasterPasswordInput: String = ""
    public var recoverErrorMessage: String = ""
    
    public var entries: [PasswordVaultEntry] = []
    public var isAddModalPresented: Bool = false
    
    public var newLabel: String = ""
    public var newPassword: String = ""
    public var newCategory: String = "General"
    public var copiedID: UUID? = nil
    public var visiblePasswordIDs: Set<UUID> = []
    
    public var manager: PasswordVaultManager
    
    public init(manager: PasswordVaultManager = .shared) {
        self.manager = manager
        refreshState()
    }
    
    public func refreshState() {
        self.isUnlocked = manager.isUnlocked
        if isUnlocked {
            self.entries = manager.getEntries()
        }
    }
    
    public var isMasterPasswordSet: Bool {
        manager.isMasterPasswordSet
    }
    
    public var hasBackupVault: Bool {
        manager.hasBackupVault
    }
    
    public var autoUnlockArchives: Bool {
        get { manager.autoUnlockArchives }
        set { manager.autoUnlockArchives = newValue }
    }
    
    public func setupFirstMasterPassword() {
        guard masterPasswordInput == confirmMasterPasswordInput else {
            unlockErrorMessage = "Master passwords do not match. Please try again."
            return
        }
        guard !masterPasswordInput.isEmpty else {
            unlockErrorMessage = "Master password cannot be empty."
            return
        }
        
        manager.setMasterPassword(masterPasswordInput)
        isUnlocked = true
        unlockErrorMessage = ""
        masterPasswordInput = ""
        confirmMasterPasswordInput = ""
        refreshState()
    }
    
    public func unlockVault() {
        guard !masterPasswordInput.isEmpty else { return }
        let password = masterPasswordInput
        let mgr = self.manager
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let success = await Task.detached(priority: .userInitiated) {
                return mgr.unlockVault(with: password)
            }.value
            
            if success {
                self.isUnlocked = true
                self.unlockErrorMessage = ""
                self.masterPasswordInput = ""
                self.refreshState()
            } else {
                self.unlockErrorMessage = "Incorrect master password. Please try again."
            }
        }
    }
    
    public func unlockVaultAsync() async -> Bool {
        guard !masterPasswordInput.isEmpty else { return false }
        let password = masterPasswordInput
        let mgr = self.manager
        
        let success = await Task.detached(priority: .userInitiated) {
            return mgr.unlockVault(with: password)
        }.value
        
        if success {
            self.isUnlocked = true
            self.unlockErrorMessage = ""
            self.masterPasswordInput = ""
            self.refreshState()
        } else {
            self.unlockErrorMessage = "Incorrect master password. Please try again."
        }
        return success
    }
    
    public func lockVault() {
        manager.lockVault()
        isUnlocked = false
        masterPasswordInput = ""
        entries = []
    }
    
    public func authenticateWithBiometrics() {
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Authenticate to unlock TTZip Password Vault") { success, _ in
                Task { @MainActor in
                    if success {
                        let ok = self.manager.unlockWithBiometrics()
                        if ok {
                            self.isUnlocked = true
                            self.unlockErrorMessage = ""
                            self.refreshState()
                        } else {
                            self.unlockErrorMessage = "Biometric authentication succeeded, but master password not found."
                        }
                    } else {
                        self.unlockErrorMessage = "Touch ID authentication failed."
                    }
                }
            }
        } else {
            unlockErrorMessage = "Touch ID is not supported or not enabled in System Settings."
        }
    }
    
    public func addEntry() {
        guard !newLabel.isEmpty, !newPassword.isEmpty else { return }
        let finalLabel = newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Password" : newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalCategory = newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "General" : newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        
        manager.addEntry(label: finalLabel, password: newPassword, category: finalCategory)
        refreshState()
        newLabel = ""
        newPassword = ""
        isAddModalPresented = false
    }
    
    public func deleteEntry(id: UUID) {
        manager.removeEntry(id: id)
        refreshState()
    }
    
    public func resetVault() {
        guard !newMasterPasswordInput.isEmpty else { return }
        manager.resetMasterPassword(newMasterPassword: newMasterPasswordInput)
        isUnlocked = true
        isResetSheetPresented = false
        newMasterPasswordInput = ""
        refreshState()
    }
    
    public func recoverVault() {
        guard !oldMasterPasswordInput.isEmpty else { return }
        let ok = manager.recoverBackupVault(withOriginalMasterPassword: oldMasterPasswordInput)
        if ok {
            isUnlocked = true
            isRecoverSheetPresented = false
            oldMasterPasswordInput = ""
            recoverErrorMessage = ""
            refreshState()
        } else {
            recoverErrorMessage = "Failed to verify previous master password."
        }
    }
    
    // MARK: - Multi-Core Parallel Password Recovery
    public var isRecoverySheetPresented: Bool = false
    public var recoveryArchivePath: String = ""
    public var customCandidatesInput: String = ""
    public var isRecoveringPassword: Bool = false
    public var recoveryResult: PasswordRecoveryResult? = nil
    public var recoveryStatusMessage: String = ""
    
    public func runParallelPasswordRecovery(archivePath: String, customCandidates: [String] = []) async {
        guard !archivePath.isEmpty else { return }
        isRecoveringPassword = true
        recoveryResult = nil
        recoveryStatusMessage = "Analyzing archive encryption and launching multi-core workers..."
        
        let vaultCandidates = manager.candidatePasswordsForAutoUnlock()
        var allCandidates = vaultCandidates
        for c in customCandidates {
            let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !allCandidates.contains(trimmed) {
                allCandidates.append(trimmed)
            }
        }
        
        if allCandidates.isEmpty {
            recoveryStatusMessage = "No password candidates available. Add words or save vault passwords."
            isRecoveringPassword = false
            return
        }
        
        let candidates = allCandidates
        let start = Date()
        
        // 1. Fast path: in-memory multi-core Rust recovery
        if let fastFound = PasswordRecoveryEngine.recoverFastInMemory(passwords: candidates, archivePath: archivePath) {
            let duration = max(0.001, Date().timeIntervalSince(start))
            let res = PasswordRecoveryResult(foundPassword: fastFound, totalAttempts: Int64(candidates.count), durationSeconds: duration)
            self.recoveryResult = res
            self.recoveryStatusMessage = "⚡️ Success! Found password: \(fastFound)"
            self.isRecoveringPassword = false
            return
        }
        
        // 2. Comprehensive parallel recovery engine
        let engine = PasswordRecoveryEngine()
        do {
            let res = try await engine.recoverPassword(archivePath: archivePath, dictionary: candidates)
            self.recoveryResult = res
            if let pwd = res.foundPassword {
                self.recoveryStatusMessage = "⚡️ Success! Found password: \(pwd)"
            } else {
                self.recoveryStatusMessage = "Recovery finished. Tested \(res.totalAttempts) candidates without match."
            }
        } catch {
            self.recoveryStatusMessage = "Recovery failed: \(error.localizedDescription)"
        }
        self.isRecoveringPassword = false
    }
    
    public func saveRecoveredPasswordToVault(label: String, password: String, category: String = "Recovered") {
        guard !password.isEmpty else { return }
        manager.addEntry(label: label, password: password, category: category)
        refreshState()
    }
}

extension PasswordVaultViewModel: StatefulTabViewModelProtocol {
    public func onTabActivated(payload: TabActivationPayload) {
        refreshState()
    }
    
    public func onTabDeactivated() {}
    
    public func onReceiveDynamicPayload(_ payload: TabActivationPayload) {
        onTabActivated(payload: payload)
    }
}
