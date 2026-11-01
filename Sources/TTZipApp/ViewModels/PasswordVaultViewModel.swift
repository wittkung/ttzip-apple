// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Observation
import TTZipCore
import LocalAuthentication
import TTZipUI
import TTZipPreviewKit

@Observable
@MainActor
public final class PasswordVaultViewModel {
    public var isUnlocked: Bool = false
    public var masterPasswordInput: String = ""
    public var confirmMasterPasswordInput: String = ""
    public var unlockErrorMessage: String = ""
    public var isUnlocking = false
    public var isBiometricAvailable = false
    public var isBiometricKeyMissing = false
    private var unlockTask: Task<Void, Never>?
    private var unlockGeneration = 0
    
    public var isResetSheetPresented: Bool = false
    public var newMasterPasswordInput: String = ""
    public var confirmNewMasterPasswordInput: String = ""
    public var resetErrorMessage: String = ""
    public var resetBackupLocation: URL?
    public var isResetBackupNoticePresented = false
    
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
    public var entryErrorMessage: String = ""
    
    public var manager: PasswordVaultManager
    
    public init(manager: PasswordVaultManager = .shared) {
        self.manager = manager
        refreshState()
        refreshBiometricAvailability()
    }
    
    public func refreshState() {
        self.isUnlocked = manager.isUnlocked
        if isUnlocked {
            self.entries = manager.getEntries()
        } else {
            self.entries = []
            self.visiblePasswordIDs = []
            self.copiedID = nil
        }
    }

    public func refreshBiometricAvailability() {
        let context = LAContext()
        isBiometricAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
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
            unlockErrorMessage = AppLocalizationState.shared.uiString(
                zh: "两次输入的主密码不一致。",
                en: "Master passwords do not match."
            )
            return
        }
        guard !masterPasswordInput.isEmpty else {
            unlockErrorMessage = AppLocalizationState.shared.uiString(
                zh: "主密码不能为空。",
                en: "Master password cannot be empty."
            )
            return
        }
        
        guard !manager.isMasterPasswordSet else { return }
        manager.setMasterPassword(masterPasswordInput)
        guard manager.isUnlocked else {
            unlockErrorMessage = AppLocalizationState.shared.uiString(zh: "无法创建钥匙库，请重试。", en: "Could not create the vault. Please try again.")
            return
        }
        isUnlocked = true
        unlockErrorMessage = ""
        masterPasswordInput = ""
        confirmMasterPasswordInput = ""
        refreshState()
    }
    
    public func unlockVault() {
        guard !isUnlocking, !masterPasswordInput.isEmpty else { return }
        unlockTask = Task { @MainActor [weak self] in
            _ = await self?.unlockVaultAsync()
        }
    }
    
    public func unlockVaultAsync() async -> Bool {
        guard !isUnlocking, !masterPasswordInput.isEmpty else { return false }
        let generation = unlockGeneration
        isUnlocking = true
        defer { if generation == unlockGeneration { isUnlocking = false } }
        let password = masterPasswordInput
        let mgr = self.manager
        
        let operation = Task.detached(priority: .userInitiated) {
            mgr.unlockVaultResult(with: password)
        }
        let result = await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
        if generation != unlockGeneration || withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
            return false
        }
        
        if result == .unlocked {
            self.isUnlocked = true
            self.unlockErrorMessage = ""
            self.masterPasswordInput = ""
            self.refreshState()
            self.isBiometricKeyMissing = false
        } else {
            let l10n = AppLocalizationState.shared
            switch result {
            case .invalidPassword:
                self.unlockErrorMessage = l10n.uiString(zh: "此钥匙库的主密码不匹配。请确认您打开的是原来的钥匙库。", en: "The master password does not match this vault. Check that you opened the intended vault.")
            case .configurationMissing:
                self.unlockErrorMessage = l10n.uiString(zh: "钥匙库配置缺失，现有数据未更改。", en: "The vault configuration is missing. Existing data was not changed.")
            case .vaultUnreadable:
                self.unlockErrorMessage = l10n.uiString(zh: "主密码已验证，但钥匙库文件无法读取。现有数据未更改。", en: "The master password was verified, but the vault file cannot be read. Existing data was not changed.")
            case .cancelled, .unlocked:
                self.unlockErrorMessage = ""
            }
        }
        return result == .unlocked
    }
    
    public func lockVault() {
        cancelPendingUnlock()
        manager.lockVault()
        isUnlocked = false
        masterPasswordInput = ""
        entries = []
    }

    public func cancelPendingUnlock() {
        let wasUnlocking = isUnlocking
        unlockGeneration &+= 1
        unlockTask?.cancel()
        unlockTask = nil
        isUnlocking = false
        if wasUnlocking && !isUnlocked {
            manager.lockVault()
        }
    }

    public func authenticateWithBiometrics() {
        guard !isUnlocking, !isBiometricKeyMissing else { return }
        guard isBiometricAvailable else {
            unlockErrorMessage = AppLocalizationState.shared.uiString(
                zh: "Touch ID 当前不可用，请使用主密码解锁。",
                en: "Touch ID is unavailable. Unlock with your master password."
            )
            return
        }
        isUnlocking = true
        unlockErrorMessage = ""
        let generation = unlockGeneration
        let manager = self.manager
        unlockTask = Task { @MainActor [weak self] in
            let operation = Task.detached(priority: .userInitiated) {
                manager.unlockWithBiometricsResult()
            }
            let result = await withTaskCancellationHandler {
                await operation.value
            } onCancel: {
                operation.cancel()
            }
            guard let self else { return }
            if generation != self.unlockGeneration || withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
                return
            }
            self.isUnlocking = false
            if result == .unlocked {
                self.isUnlocked = true
                self.refreshState()
                return
            }
            self.isBiometricKeyMissing = result == .keyMissing
            self.unlockErrorMessage = self.biometricMessage(for: result)
        }
    }

    private func biometricMessage(for result: VaultBiometricUnlockResult) -> String {
        let l10n = AppLocalizationState.shared
        switch result {
        case .unlocked: return ""
        case .cancelled: return ""
        case .keyMissing:
            return l10n.uiString(zh: "此设备尚无可用的 Touch ID 钥匙。请用主密码解锁一次以重新启用。", en: "No Touch ID key is available on this device. Unlock once with your master password to enable it again.")
        case .invalidKey, .vaultUnreadable:
            return l10n.uiString(zh: "Touch ID 钥匙无法打开现有钥匙库。请使用主密码；原始数据未更改。", en: "The Touch ID key cannot open this vault. Use your master password; the original data is unchanged.")
        case .unavailable:
            return l10n.uiString(zh: "Touch ID 当前不可用，请使用主密码解锁。", en: "Touch ID is unavailable. Unlock with your master password.")
        case .keyAccessFailed:
            return l10n.uiString(zh: "无法读取 Touch ID 钥匙，请使用主密码解锁。", en: "Could not read the Touch ID key. Unlock with your master password.")
        }
    }
    
    public func addEntry() {
        guard !newPassword.isEmpty else { return }
        let finalLabel = newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Password" : newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalCategory = newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "General" : newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let result = manager.addEntryVerified(label: finalLabel, password: newPassword, category: finalCategory)
        if case .saved = result {
            entryErrorMessage = ""
            refreshState()
            newLabel = ""
            newPassword = ""
            isAddModalPresented = false
        } else {
            entryErrorMessage = entryWriteErrorMessage
        }
    }
    
    public func deleteEntry(id: UUID) {
        let result = manager.removeEntryVerified(id: id)
        if result == .removed {
            entryErrorMessage = ""
            refreshState()
        } else if result != .notFound {
            entryErrorMessage = entryWriteErrorMessage
        }
    }

    private var entryWriteErrorMessage: String {
        AppLocalizationState.shared.uiString(
            zh: "钥匙库未能保存更改。请检查文件状态后重试；现有条目未更改。",
            en: "The vault could not save this change. Check the file and try again; existing entries were not changed."
        )
    }
    
    public func resetVault() {
        resetMasterPassword()
    }
    
    public func resetMasterPassword() {
        guard !newMasterPasswordInput.isEmpty,
              newMasterPasswordInput == confirmNewMasterPasswordInput else {
            resetErrorMessage = AppLocalizationState.shared.uiString(
                zh: "请确认两次输入的新主密码一致。",
                en: "Enter the same new master password twice."
            )
            return
        }
        do {
            let location = try manager.resetMasterPasswordPreservingEncryptedBackup(newMasterPasswordInput)
            resetBackupLocation = location
            resetErrorMessage = ""
            newMasterPasswordInput = ""
            confirmNewMasterPasswordInput = ""
            masterPasswordInput = ""
            unlockErrorMessage = ""
            isBiometricKeyMissing = false
            isResetSheetPresented = false
            isResetBackupNoticePresented = true
            refreshState()
        } catch VaultResetError.newVaultNotSaved(let backupDirectory) {
            resetBackupLocation = backupDirectory
            resetErrorMessage = AppLocalizationState.shared.uiString(
                zh: "新钥匙库未能保存。原加密文件已备份到：\(backupDirectory.path)",
                en: "The new vault could not be saved. The old encrypted files were backed up at: \(backupDirectory.path)"
            )
        } catch {
            resetErrorMessage = AppLocalizationState.shared.uiString(
                zh: "未能完成备份并重设；请保留现有文件后重试。",
                en: "Could not back up and reset the vault. Keep the existing files and try again."
            )
        }
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
            recoverErrorMessage = AppLocalizationState.shared.uiString(
                zh: "无法验证历史主密码，备份未恢复。",
                en: "Could not verify the previous master password. The backup was not restored."
            )
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
        let result = manager.addEntryVerified(label: label, password: password, category: category)
        if case .saved = result {
            entryErrorMessage = ""
            refreshState()
            isRecoverySheetPresented = false
        } else {
            entryErrorMessage = entryWriteErrorMessage
        }
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
