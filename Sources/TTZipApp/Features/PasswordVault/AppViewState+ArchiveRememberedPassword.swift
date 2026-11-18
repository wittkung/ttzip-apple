// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit

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
            try await controller.ensureUnlockedAsync()
            guard isPasswordOperationStillCurrent(
                operationID: context.operationID, epoch: context.captureEpoch
            ) else { return }
            if try await controller.rememberVerifiedAsync(
                password, for: identity, capturedGeneration: generation
            ) {
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
        let trimmedPath = archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            taskState.statusMessage = l10n.uiString(
                zh: "无法确认此压缩包或访问密码钥匙库",
                en: "Cannot identify this archive or access the password vault"
            )
            return false
        }
        let normalizedPath = URL(fileURLWithPath: trimmedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let logicalKey = ArchiveCredentialIdentity.logicalKey(for: trimmedPath)
        let volumePaths = ArchiveCredentialIdentity.resolve(archivePath: trimmedPath)?.volumePaths
            ?? [trimmedPath, normalizedPath]
        let allPaths = Set(volumePaths + [trimmedPath, normalizedPath])
        let hadSessionCredential = hasActiveSessionCredential(
            logicalKey: logicalKey, paths: allPaths
        )
        let entrySubpaths = collectSelectedSubpathsForEviction(logicalKey: logicalKey)

        ArchiveCredentialGeneration.shared.invalidateAndPerform(for: logicalKey) {}
        ArchivePasswordStore.shared.removePassword(for: trimmedPath)
        ArchivePasswordStore.shared.removePassword(for: normalizedPath)
        ArchivePasswordStore.shared.removePasswords(forLogicalArchiveAt: trimmedPath)

        await evictForgottenArchiveSessionsAndCaches(
            logicalKey: logicalKey,
            paths: allPaths,
            entrySubpaths: entrySubpaths
        )

        if let controller = archiveRememberedPasswordController {
            do {
                try await controller.forgetAsync(logicalKey: logicalKey)
            } catch {
                NotificationCenter.default.post(
                    name: NSNotification.Name("TTZipArchivePasswordForgotten"),
                    object: normalizedPath
                )
                taskState.statusMessage = archiveCredentialFailureMessage(error, saving: false)
                return hadSessionCredential
            }
        }

        NotificationCenter.default.post(
            name: NSNotification.Name("TTZipArchivePasswordForgotten"),
            object: normalizedPath
        )

        taskState.statusMessage = l10n.uiString(
            zh: "已忘记此压缩包密码；下次访问需要重新输入",
            en: "Archive password forgotten; enter it again next time"
        )
        return true
    }

    private func hasActiveSessionCredential(logicalKey: String, paths: Set<String>) -> Bool {
        for path in paths where ArchivePasswordStore.shared.getPassword(for: path)?.isEmpty == false {
            return true
        }
        let liveStates = BrowserWindowRegistry.shared.allControllers.compactMap { $0 as? AppViewState }
        let candidates = liveStates.contains(where: { $0 === self }) ? liveStates : (liveStates + [self])
        for state in candidates {
            let matchesArchive = state.explorerState.currentArchivePath.map {
                ArchiveCredentialIdentity.logicalKey(for: $0) == logicalKey
            } ?? false
            if matchesArchive, state.explorerState.activePassword?.isEmpty == false {
                return true
            }
        }
        return false
    }

    private func collectSelectedSubpathsForEviction(logicalKey: String) -> Set<String> {
        var subpaths: Set<String> = []
        let liveStates = BrowserWindowRegistry.shared.allControllers.compactMap { $0 as? AppViewState }
        let candidates = liveStates.contains(where: { $0 === self }) ? liveStates : (liveStates + [self])
        for state in candidates {
            let matchesArchive = state.explorerState.currentArchivePath.map {
                ArchiveCredentialIdentity.logicalKey(for: $0) == logicalKey
            } ?? false
            if matchesArchive, let selectedID = state.selectionState.selectedEntryID, !selectedID.isEmpty {
                subpaths.insert(selectedID)
            }
            if let sub = state.currentSelectedArchiveSubpath(
                for: logicalKey, matchesActiveArchive: matchesArchive
            ) {
                subpaths.insert(sub)
            }
        }
        return subpaths
    }

    private func evictForgottenArchiveSessionsAndCaches(
        logicalKey: String,
        paths: Set<String>,
        entrySubpaths: Set<String>
    ) async {
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
        for path in paths {
            clearArchiveVFSCache(path: path)
            let archiveId = TTZipArchiveVfsProvider.makeArchiveId(from: path)
            TTZipArchiveVfsProvider.shared.closeSession(archiveId: archiveId)
        }
        await PreviewLRUCacheManager.shared.evictArchiveEntries(
            logicalKey: logicalKey, archivePaths: paths, entrySubpaths: entrySubpaths
        )
        await ArchiveMediaCachePool.shared.purgeAll()
        await ArchiveHierarchySessionCache.shared.invalidate(logicalKey: logicalKey)
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
        let matchesActiveArchive = explorerState.currentArchivePath.map {
            ArchiveCredentialIdentity.logicalKey(for: $0) == logicalKey
        } ?? false
        if matchesActiveArchive {
            explorerState.activePassword = nil
            if passwordEvidenceState.isCryptographicallyVerified {
                passwordEvidenceState = explorerState.currentEntries.isEmpty
                    ? .notEncrypted : .directoryBrowsableUnverified
            }
        }
        evictForgottenArchiveSelectionIfNeeded(
            logicalKey: logicalKey,
            matchesActiveArchive: matchesActiveArchive
        )
    }

    private func evictForgottenArchiveSelectionIfNeeded(
        logicalKey: String,
        matchesActiveArchive: Bool
    ) {
        if overlayState.showImmersiveMediaBrowser {
            let mediaArchiveMatches = overlayState.immersiveMediaItem?.sourceArchivePath.map {
                ArchiveCredentialIdentity.logicalKey(for: $0) == logicalKey
            } ?? matchesActiveArchive
            if mediaArchiveMatches {
                closeImmersiveMedia()
            }
        }

        if let selectedSubpath = currentSelectedArchiveSubpath(for: logicalKey, matchesActiveArchive: matchesActiveArchive) {
            if matchesActiveArchive {
                let normalized = ArchivePasswordProbePolicy.normalizeEntryPath(selectedSubpath)
                let matchingEntry = explorerState.currentEntries.first {
                    ArchivePasswordProbePolicy.normalizeEntryPath($0.path) == normalized
                }
                if matchingEntry?.isEncrypted == true
                    || explorerState.currentEntries.isEmpty
                    || selectionState.selectedDiskItem?.isEncryptedLockItem == true {
                    clearInspectedFile()
                }
            } else {
                clearInspectedFile()
            }
        }
    }

    private func currentSelectedArchiveSubpath(
        for logicalKey: String,
        matchesActiveArchive: Bool
    ) -> String? {
        if matchesActiveArchive, let entryID = selectionState.selectedEntryID, !entryID.isEmpty {
            return entryID
        }
        guard let itemPath = selectionState.selectedDiskItem?.path,
              let url = URL(string: itemPath),
              let comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let sub = comp.queryItems?.first(where: { $0.name == "subpath" })?.value else {
            return nil
        }
        guard matchesActiveArchive || ArchiveCredentialIdentity.logicalKey(for: url.path) == logicalKey else {
            return nil
        }
        return sub
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

    internal func rejectRememberedCredentialAfterDirectExtractionFailure(
        _ savedCandidate: String,
        identity: ArchiveCredentialIdentity?
    ) async {
        guard let identity, let controller = archiveRememberedPasswordController else { return }
        try? await controller.rejectSavedCandidateAsync(savedCandidate, for: identity)
    }

    internal func commitRememberedCredentialFromDirectExtraction(
        _ savedPassword: String,
        archivePath: String,
        evidence: ArchivePasswordEvidenceState,
        identity: ArchiveCredentialIdentity?,
        generation: UInt64?,
        capturedEpoch: UInt64,
        capturedOperationID: UUID?
    ) {
        guard !Task.isCancelled,
              !isWindowClosing,
              passwordOperationEpoch == capturedEpoch,
              pendingPasswordContext?.operationID == capturedOperationID,
              !savedPassword.isEmpty,
              isArchiveCredentialCurrent(identity, generation: generation) else {
            return
        }
        ArchivePasswordStore.shared.setPassword(savedPassword, for: archivePath)
        passwordEvidenceState = evidence
        if explorerState.currentArchivePath == archivePath {
            explorerState.activePassword = savedPassword
        }
    }
}

/// Decorates an `ArchivePasswordOperationsDriver` so direct extraction entry points (`quickExtractArchive`
/// and `extractEntries`) resolve and verify archive-scoped remembered passwords without requiring a prior
/// browse operation.
@MainActor
internal struct RememberedPasswordExtractionDriver: ArchivePasswordOperationsDriver {
    let base: any ArchivePasswordOperationsDriver
    weak var viewState: AppViewState?

    func inspectArchive(
        archivePath: String, password: String?, autoVaultUnlock: Bool
    ) async throws -> InspectResult {
        try await base.inspectArchive(
            archivePath: archivePath, password: password, autoVaultUnlock: autoVaultUnlock
        )
    }

    func verifyEncryptedEntryPayload(
        archivePath: String, entryPath: String, password: String
    ) async throws -> Data? {
        try await base.verifyEncryptedEntryPayload(
            archivePath: archivePath, entryPath: entryPath, password: password
        )
    }

    func quickExtract(
        archivePath: String,
        destinationDir: String,
        password: String?,
        autoVaultUnlock: Bool,
        handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)?,
        token: CancellationToken?
    ) async throws -> ExtractResult {
        if let password, !password.isEmpty {
            return try await base.quickExtract(
                archivePath: archivePath, destinationDir: destinationDir, password: password,
                autoVaultUnlock: autoVaultUnlock, handling: handling, progress: progress, token: token
            )
        }
        do {
            return try await base.quickExtract(
                archivePath: archivePath, destinationDir: destinationDir, password: nil,
                autoVaultUnlock: autoVaultUnlock, handling: handling, progress: progress, token: token
            )
        } catch let initialError {
            return try await retryQuickExtractWithRememberedCredential(
                initialError: initialError, archivePath: archivePath, destinationDir: destinationDir,
                autoVaultUnlock: autoVaultUnlock, handling: handling, progress: progress, token: token
            )
        }
    }

    private func retryQuickExtractWithRememberedCredential(
        initialError: Error,
        archivePath: String,
        destinationDir: String,
        autoVaultUnlock: Bool,
        handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)?,
        token: CancellationToken?
    ) async throws -> ExtractResult {
        guard autoVaultUnlock,
              ArchivePasswordErrorClassifier.classify(initialError).category == .wrongPassword,
              let viewState else {
            throw initialError
        }
        let remembered = await viewState.readRememberedCredentialForDirectExtraction(archivePath: archivePath)
        guard let savedPassword = remembered.password, !savedPassword.isEmpty else {
            throw initialError
        }
        do {
            let res = try await base.quickExtract(
                archivePath: archivePath, destinationDir: destinationDir, password: savedPassword,
                autoVaultUnlock: false, handling: handling, progress: progress, token: token
            )
            // Credential publication is deferred to performVerifiedQuickExtract after
            // isOperationOrWindowActive and hasIndependentEncryptedProof succeed.
            return ExtractResult(
                archivePath: res.archivePath, destinationDir: res.destinationDir,
                durationSeconds: res.durationSeconds,
                unlockedPassword: res.unlockedPassword ?? savedPassword,
                isVaultUnlocked: true, outcome: res.outcome
            )
        } catch let retryError {
            if ArchivePasswordErrorClassifier.classify(retryError).category == .wrongPassword {
                await viewState.rejectRememberedCredentialAfterDirectExtractionFailure(
                    savedPassword, identity: remembered.identity
                )
            }
            throw retryError
        }
    }

    func extractEntries(
        archivePath: String,
        entryPaths: [String],
        destinationDir: String,
        password: String?,
        handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ExtractionOutcome {
        if let password, !password.isEmpty {
            return try await base.extractEntries(
                archivePath: archivePath, entryPaths: entryPaths, destinationDir: destinationDir,
                password: password, handling: handling, progress: progress
            )
        }
        do {
            return try await base.extractEntries(
                archivePath: archivePath, entryPaths: entryPaths, destinationDir: destinationDir,
                password: nil, handling: handling, progress: progress
            )
        } catch let initialError {
            return try await retryExtractEntriesWithRememberedCredential(
                initialError: initialError, archivePath: archivePath, entryPaths: entryPaths,
                destinationDir: destinationDir, handling: handling, progress: progress
            )
        }
    }

    private func retryExtractEntriesWithRememberedCredential(
        initialError: Error,
        archivePath: String,
        entryPaths: [String],
        destinationDir: String,
        handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ExtractionOutcome {
        guard ArchivePasswordErrorClassifier.classify(initialError).category == .wrongPassword,
              let viewState else {
            throw initialError
        }
        let capturedEpoch = viewState.passwordOperationEpoch
        let capturedOperationID = viewState.pendingPasswordContext?.operationID
        let remembered = await viewState.readRememberedCredentialForDirectExtraction(archivePath: archivePath)
        guard let savedPassword = remembered.password, !savedPassword.isEmpty else {
            throw initialError
        }
        do {
            let outcome = try await base.extractEntries(
                archivePath: archivePath, entryPaths: entryPaths, destinationDir: destinationDir,
                password: savedPassword, handling: handling, progress: progress
            )
            if outcome.status == .completed,
               !Task.isCancelled,
               !viewState.isWindowClosing,
               await viewState.hasIndependentEncryptedProof(archivePath: archivePath, password: savedPassword) {
                viewState.commitRememberedCredentialFromDirectExtraction(
                    savedPassword, archivePath: archivePath,
                    evidence: .verified(.selectedEntries(Set(entryPaths))),
                    identity: remembered.identity, generation: remembered.generation,
                    capturedEpoch: capturedEpoch, capturedOperationID: capturedOperationID
                )
            }
            return outcome
        } catch let retryError {
            if ArchivePasswordErrorClassifier.classify(retryError).category == .wrongPassword {
                await viewState.rejectRememberedCredentialAfterDirectExtractionFailure(
                    savedPassword, identity: remembered.identity
                )
            }
            throw retryError
        }
    }
}
