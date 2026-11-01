// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI
#if canImport(TTZipAppServices)
import TTZipAppServices
#endif

extension AppViewState {
    internal func isArchiveCredentialCurrent(
        _ identity: ArchiveCredentialIdentity?, generation: UInt64?
    ) -> Bool {
        guard let controller = archiveRememberedPasswordController,
              let identity, let generation else { return true }
        return ArchiveCredentialIdentity.resolve(archivePath: identity.sourcePath) == identity
            && controller.operationGeneration(for: identity) == generation
    }

    internal func rememberSubmittedPasswordIfVerified(
        _ password: String,
        context: ArchivePasswordOperationContext,
        identity: ArchiveCredentialIdentity?,
        generation: UInt64?
    ) async {
        let l10n = AppLocalizationState.shared
        guard let controller = archiveRememberedPasswordController,
              let identity, let generation else {
            taskState.statusMessage = l10n.uiString(
                zh: "操作已完成，但无法确认压缩包身份，密码未保存",
                en: "Operation complete, but archive identity could not be confirmed; password was not saved"
            )
            return
        }

        let verified: Bool
        switch context.kind {
        case .browse:
            verified = passwordEvidenceState.isCryptographicallyVerified
        case .quickExtract, .extractEntries:
            verified = await hasIndependentEncryptedProof(
                archivePath: context.archivePath, password: password
            )
        }
        guard isPasswordOperationStillCurrent(
            operationID: context.operationID, epoch: context.captureEpoch
        ) else { return }
        guard verified else {
            taskState.statusMessage = l10n.uiString(
                zh: "操作已完成，但未验证加密内容，密码未保存",
                en: "Operation complete, but encrypted content was not verified; password was not saved"
            )
            return
        }

        do {
            if try controller.rememberVerified(password, for: identity, capturedGeneration: generation) {
                taskState.statusMessage = l10n.uiString(
                    zh: "已记住此压缩包密码", en: "Archive password remembered"
                )
            } else {
                taskState.statusMessage = l10n.uiString(
                    zh: "操作已完成，但密码已被忘记，未重新保存",
                    en: "Operation complete, but the forgotten password was not saved again"
                )
            }
        } catch {
            taskState.statusMessage = archiveCredentialFailureMessage(error, saving: true)
        }
    }

    internal func hasIndependentEncryptedProof(
        archivePath: String, password: String
    ) async -> Bool {
        do {
            let unauthenticated = try await passwordDriver.inspectArchive(
                archivePath: archivePath, password: nil, autoVaultUnlock: false
            )
            guard Self.matchesArchiveInspection(unauthenticated, archivePath: archivePath) else {
                return false
            }
            let outcome = await verifyPlaintextCatalogPassword(
                archivePath: archivePath, entries: unauthenticated.entries, password: password
            )
            if case .verified = outcome { return true }
            return false
        } catch {
            guard ArchivePasswordErrorClassifier.classify(error).category == .wrongPassword else {
                return false
            }
        }
        guard let authenticated = try? await passwordDriver.inspectArchive(
            archivePath: archivePath, password: password, autoVaultUnlock: false
        ) else { return false }
        return Self.matchesArchiveInspection(authenticated, archivePath: archivePath)
    }

    @discardableResult
    public func forgetArchivePassword(at archivePath: String) async -> Bool {
        let l10n = AppLocalizationState.shared
        guard let controller = archiveRememberedPasswordController,
              !archivePath.isEmpty else {
            taskState.statusMessage = l10n.uiString(
                zh: "无法确认此压缩包或访问密码钥匙库", en: "Cannot identify this archive or access the password vault"
            )
            return false
        }
        let logicalKey = ArchiveCredentialIdentity.logicalKey(for: archivePath)
        let volumePaths = ArchiveCredentialIdentity.resolve(archivePath: archivePath)?.volumePaths
            ?? [archivePath]

        do {
            try controller.forget(logicalKey: logicalKey)
        } catch {
            taskState.statusMessage = archiveCredentialFailureMessage(error, saving: false)
            return false
        }

        ArchivePasswordStore.shared.removePasswords(forLogicalArchiveAt: archivePath)
        let liveStates = BrowserWindowRegistry.shared.allControllers.compactMap { $0 as? AppViewState }
        for state in liveStates {
            state.clearForgottenArchiveSession(logicalKey: logicalKey)
        }
        if !liveStates.contains(where: { $0 === self }) {
            clearForgottenArchiveSession(logicalKey: logicalKey)
        }
        for session in AppIntentDispatcher.shared.allSessions {
            session.forgetPassword(forLogicalKey: logicalKey)
        }
        for path in volumePaths {
            clearArchiveVFSCache(path: path)
        }

        let cache = ArchiveHierarchySessionCache.shared
        await cache.invalidate(logicalKey: logicalKey)
        taskState.statusMessage = l10n.uiString(
            zh: "已忘记此压缩包密码；下次访问需要重新输入", en: "Archive password forgotten; enter it again next time"
        )
        return true
    }

    private func clearForgottenArchiveSession(logicalKey: String) {
        explorerState.invalidateAcceptedArchiveProjections(logicalKey: logicalKey)
        if let context = pendingPasswordContext,
           ArchiveCredentialIdentity.logicalKey(for: context.archivePath) == logicalKey {
            passwordOperationEpoch &+= 1
            pendingPasswordContext = nil
            overlayState.pendingEncryptedPath = nil
            overlayState.showPasswordPrompt = false
        }
        guard let path = explorerState.currentArchivePath,
              ArchiveCredentialIdentity.logicalKey(for: path) == logicalKey else { return }
        explorerState.activePassword = nil
        if passwordEvidenceState.isCryptographicallyVerified {
            passwordEvidenceState = explorerState.currentEntries.isEmpty
                ? .notEncrypted : .directoryBrowsableUnverified
        }
    }

    private func archiveCredentialFailureMessage(_ error: Error, saving: Bool) -> String {
        let l10n = AppLocalizationState.shared
        if let access = error as? ArchiveScopedVaultAccessError {
            switch access {
            case .authenticationCancelled:
                return l10n.uiString(zh: "已取消钥匙库验证", en: "Vault authentication cancelled")
            case .locked, .authenticationUnavailable, .authenticationFailed:
                return l10n.uiString(
                    zh: "请先解锁密码钥匙库再试", en: "Unlock the password vault and try again"
                )
            }
        }
        if let vault = error as? ArchiveVaultCredentialError, vault == .locked {
            return l10n.uiString(
                zh: "请先解锁密码钥匙库再试", en: "Unlock the password vault and try again"
            )
        }
        return saving
            ? l10n.uiString(
                zh: "操作已完成，但密码未能保存到钥匙库",
                en: "Operation complete, but the password could not be saved to the vault"
            )
            : l10n.uiString(
                zh: "无法从钥匙库删除此压缩包密码",
                en: "Could not remove this archive password from the vault"
            )
    }
}
