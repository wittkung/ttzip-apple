// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation
import TTKitCore
import TTZipCore
import TTZipUI
#if canImport(TTZipAppServices)
#endif

public typealias InspectResult = ArchiveInspectionResult

/// Preserves the complete successful reader result across password evidence classification.
struct ArchiveInspectionWithEvidence: Sendable {
    let result: InspectResult
    let verifiedPassword: String?
    let evidence: ArchivePasswordEvidenceState
    let isVaultUnlocked: Bool

    var entries: [ArchiveEntry] { result.entries }
    var treeNode: ArchiveCompositeDirectory { result.treeNode }
}

enum ArchiveBrowseResumeIntent: Sendable {
    case catalog
    case acceptedEntry(ArchiveEntryPreviewRequest)
}

/// Captures the original user operation that triggered an archive password prompt,
/// bound to a specific window, tab, and generational epoch.
public struct ArchivePasswordOperationContext: Identifiable, Sendable {
    var browseResumeIntent: ArchiveBrowseResumeIntent = .catalog
    public enum OperationKind: Sendable {
        case browse
        case quickExtract(
            targetDir: String?,
            isSmartExtract: Bool,
            trashSourceAfterExtract: Bool,
            collisionHandling: CollisionHandling?
        )
        case extractEntries(
            entryPaths: [String],
            destinationDir: String,
            collisionHandling: CollisionHandling?
        )
    }

    public let operationID: UUID
    public let windowID: UUID
    public let tabID: UUID?
    public let captureEpoch: UInt64
    public let archivePath: String
    public let browsingLocation: URL?
    public let kind: OperationKind
    public var failedPasswordFingerprints: Set<String>
    public var isResumingOrCompleted: Bool
    public var lastFailureCategory: ArchivePasswordFailureCategory?
    public var lastErrorMessage: String?

    public var id: UUID { operationID }

    public init(
        operationID: UUID = UUID(),
        windowID: UUID,
        tabID: UUID?,
        captureEpoch: UInt64,
        archivePath: String,
        kind: OperationKind,
        failedPasswordFingerprints: Set<String> = [],
        isResumingOrCompleted: Bool = false,
        lastFailureCategory: ArchivePasswordFailureCategory? = nil,
        lastErrorMessage: String? = nil,
        browsingLocation: URL? = nil
    ) {
        self.operationID = operationID
        self.windowID = windowID
        self.tabID = tabID
        self.captureEpoch = captureEpoch
        self.archivePath = archivePath
        self.browsingLocation = browsingLocation
        self.kind = kind
        self.failedPasswordFingerprints = failedPasswordFingerprints
        self.isResumingOrCompleted = isResumingOrCompleted
        self.lastFailureCategory = lastFailureCategory
        self.lastErrorMessage = lastErrorMessage
    }

    public static func fingerprint(for password: String) -> String {
        let digest = SHA256.hash(data: Data(password.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func hasFailedPassword(_ password: String) -> Bool {
        failedPasswordFingerprints.contains(Self.fingerprint(for: password))
    }

    public mutating func recordFailedPassword(_ password: String) {
        guard !password.isEmpty else { return }
        failedPasswordFingerprints.insert(Self.fingerprint(for: password))
    }
}

// MARK: - AppViewState Password Verification & Operation Resumption

extension AppViewState {
    /// Evicts a cached password from `ArchivePasswordStore.shared` only if it still equals `failedPassword`,
    /// preventing accidental removal of a valid credential updated concurrently by another window.
    public func evictCachedPasswordIfMatches(_ failedPassword: String?, for archivePath: String) {
        guard let failedPassword, !failedPassword.isEmpty else { return }
        if ArchivePasswordStore.shared.getPassword(for: archivePath) == failedPassword {
            ArchivePasswordStore.shared.removePassword(for: archivePath)
        }
        if explorerState.currentArchivePath == archivePath && explorerState.activePassword == failedPassword {
            explorerState.activePassword = nil
        }
    }

    /// Returns a candidate password from `ArchivePasswordStore` or `activePassword` only if it has not
    /// already failed in the current operation context.
    public func reusablePasswordCandidate(for archivePath: String, explicitPassword: String?) -> String? {
        if let explicitPassword, !explicitPassword.isEmpty {
            return explicitPassword
        }
        let stored = ArchivePasswordStore.shared.getPassword(for: archivePath)
            ?? (explorerState.currentArchivePath == archivePath ? explorerState.activePassword : nil)
        guard let candidate = stored, !candidate.isEmpty else { return nil }
        if let ctx = pendingPasswordContext,
           ctx.archivePath == archivePath,
           ctx.hasFailedPassword(candidate) {
            return nil
        }
        return candidate
    }

    /// Captures or updates the window-scoped `ArchivePasswordOperationContext` and presents `PasswordPromptSheetView`.
    public func stagePasswordPromptContext(
        archivePath: String,
        kind: ArchivePasswordOperationContext.OperationKind,
        failedPassword: String? = nil,
        errorMessage: String? = nil
    ) {
        guard !isWindowClosing else { return }
        if let failedPassword, !failedPassword.isEmpty {
            evictCachedPasswordIfMatches(failedPassword, for: archivePath)
        }
        var fingerprints = (pendingPasswordContext?.archivePath == archivePath)
            ? (pendingPasswordContext?.failedPasswordFingerprints ?? [])
            : []
        if let failedPassword, !failedPassword.isEmpty {
            fingerprints.insert(ArchivePasswordOperationContext.fingerprint(for: failedPassword))
        }
        passwordOperationEpoch &+= 1
        let context = ArchivePasswordOperationContext(
            windowID: windowID,
            tabID: navigationState.activeSessionID,
            captureEpoch: passwordOperationEpoch,
            archivePath: archivePath,
            kind: kind,
            failedPasswordFingerprints: fingerprints,
            isResumingOrCompleted: false,
            lastFailureCategory: failedPassword != nil ? .wrongPassword : nil,
            lastErrorMessage: errorMessage,
            browsingLocation: navigationState.activeTabSession?.historyStack.current
        )
        pendingPasswordContext = context
        overlayState.pendingEncryptedPath = archivePath
        overlayState.showPasswordPrompt = true
    }

    /// Verifies a candidate password against the smallest qualifying encrypted file entry (`0 < size <= maxProbeBytes`).
    public func verifyPlaintextCatalogPassword(
        archivePath: String,
        entries: [ArchiveEntry],
        password: String,
        maxProbeBytes: Int64 = ArchivePasswordProbePolicy.maxProbeEntryBytes
    ) async -> ArchivePasswordProbeOutcome {
        await ArchivePlaintextCatalogPasswordVerifier.verify(
            archivePath: archivePath, entries: entries, password: password,
            driver: passwordDriver, maxProbeBytes: maxProbeBytes
        )
    }

    /// Validates a user-submitted password against the captured `ArchivePasswordOperationContext`
    /// and resumes the original operation at most once.
    @discardableResult
    public func submitArchivePassword(
        _ candidate: String,
        remember: Bool = false
    ) async -> ArchivePasswordSubmissionResult {
        guard !isWindowClosing else { return .cancelledOrStale }
        if pendingPasswordContext == nil, let fallbackPath = overlayState.pendingEncryptedPath {
            stagePasswordPromptContext(archivePath: fallbackPath, kind: .browse)
        }
        guard var context = pendingPasswordContext else {
            return .cancelledOrStale
        }
        if context.isResumingOrCompleted {
            return .alreadyInFlight
        }
        let l10n = AppLocalizationState.shared
        guard !candidate.isEmpty else {
            let msg = l10n.t(ArchivePasswordLocaleKey.incorrectPassword)
            pendingPasswordContext?.lastFailureCategory = .wrongPassword
            pendingPasswordContext?.lastErrorMessage = msg
            return .wrongPassword(message: msg)
        }

        context.isResumingOrCompleted = true
        context.lastErrorMessage = nil
        pendingPasswordContext = context
        passwordEvidenceState = .candidate
        let capturedEpoch = context.captureEpoch
        let capturedOpID = context.operationID
        let credentialIdentity = remember
            ? ArchiveCredentialIdentity.resolve(archivePath: context.archivePath)
            : nil
        let credentialGeneration = credentialIdentity.flatMap {
            archiveRememberedPasswordController?.operationGeneration(for: $0)
        }

        do {
            try await executeCapturedPasswordOperation(context: context, candidate: candidate)
            guard isPasswordOperationStillCurrent(operationID: capturedOpID, epoch: capturedEpoch) else {
                return .cancelledOrStale
            }
            if remember {
                await rememberSubmittedPasswordIfVerified(
                    candidate,
                    context: context,
                    identity: credentialIdentity,
                    generation: credentialGeneration
                )
                guard isPasswordOperationStillCurrent(operationID: capturedOpID, epoch: capturedEpoch) else {
                    return .cancelledOrStale
                }
            }
            pendingPasswordContext = nil
            overlayState.showPasswordPrompt = false
            overlayState.pendingEncryptedPath = nil
            return .verifiedAndResumed
        } catch {
            guard isPasswordOperationStillCurrent(operationID: capturedOpID, epoch: capturedEpoch) else {
                return .cancelledOrStale
            }
            return handlePasswordSubmissionFailure(error, candidate: candidate, context: context)
        }
    }

    internal func isPasswordOperationStillCurrent(operationID: UUID, epoch: UInt64) -> Bool {
        !isWindowClosing
            && passwordOperationEpoch == epoch
            && pendingPasswordContext?.operationID == operationID
    }

    private func executeCapturedPasswordOperation(
        context: ArchivePasswordOperationContext,
        candidate: String
    ) async throws {
        switch context.kind {
        case .browse:
            try await verifyAndResumeBrowse(context: context, candidate: candidate)
        case .quickExtract(let targetDir, let isSmartExtract, let trashSourceAfterExtract, let collisionHandling):
            try await performVerifiedQuickExtract(
                archivePath: context.archivePath,
                targetDir: targetDir,
                explicitPassword: candidate,
                allowVaultFallback: false,
                isSmartExtract: isSmartExtract,
                trashSourceAfterExtract: trashSourceAfterExtract,
                collisionHandling: collisionHandling,
                operationID: context.operationID,
                epoch: context.captureEpoch
            )
        case .extractEntries(let entryPaths, let destinationDir, let collisionHandling):
            try await performVerifiedExtractEntries(
                archivePath: context.archivePath,
                entryPaths: entryPaths,
                destinationDir: destinationDir,
                explicitPassword: candidate,
                collisionHandling: collisionHandling,
                operationID: context.operationID,
                epoch: context.captureEpoch
            )
        }
    }

    private func verifyAndResumeBrowse(
        context: ArchivePasswordOperationContext,
        candidate: String
    ) async throws {
        if case .acceptedEntry(let request) = context.browseResumeIntent {
            try await verifyAndResumeAcceptedEntryPreview(context: context, request: request, candidate: candidate)
            return
        }
        let archivePath = context.archivePath
        let operationID = context.operationID
        let epoch = context.captureEpoch
        if let unauthInspect = try? await passwordDriver.inspectArchive(
            archivePath: archivePath,
            password: nil,
            autoVaultUnlock: false
        ) {
            guard Self.matchesArchiveInspection(unauthInspect, archivePath: archivePath) else {
                throw ArchiveError.engineFailure(code: -500, message: "Archive inspection source mismatch")
            }
            let outcome = await verifyPlaintextCatalogPassword(
                archivePath: archivePath,
                entries: unauthInspect.entries,
                password: candidate
            )
            guard isPasswordOperationStillCurrent(operationID: operationID, epoch: epoch) else { return }
            switch outcome {
            case .verified(let scope):
                applyVerifiedBrowseResult(
                    context: context,
                    inspection: unauthInspect,
                    verifiedPassword: candidate,
                    scope: scope
                )
            case .noAvailableEvidence:
                applyUnverifiedBrowsableCatalogResult(context: context, inspection: unauthInspect)
            case .wrongPassword:
                throw ArchiveError.wrongPassword(archivePath: archivePath)
            case .otherFailure(let category, let message):
                throw ArchivePasswordProbeFailure(category: category, message: message)
            }
            return
        }

        let res = try await passwordDriver.inspectArchive(
            archivePath: archivePath,
            password: candidate,
            autoVaultUnlock: false
        )
        guard isPasswordOperationStillCurrent(operationID: operationID, epoch: epoch) else { return }
        guard Self.matchesArchiveInspection(res, archivePath: archivePath) else {
            throw ArchiveError.engineFailure(code: -500, message: "Archive inspection source mismatch")
        }
        applyVerifiedBrowseResult(
            context: context,
            inspection: res,
            verifiedPassword: candidate,
            scope: .headerCatalog
        )
    }

    /// Abandons a pending browse password operation when the user navigates away.
    ///
    /// The prompt belongs to the page that raised it: leaving that page closes the prompt and
    /// drops the operation, so a late verification result can neither resume the operation nor
    /// write into the page the user navigated to. Extraction operations are not affected — an
    /// authorized extraction keeps running when the explorer navigates.
    ///
    /// Only the context and the overlay it owns are touched. The explorer state, the evidence
    /// state and the status message belong to the page the user navigated to and must not be
    /// rewritten here.
    internal func invalidateBrowsePasswordOperationIfPending() {
        guard let context = pendingPasswordContext, case .browse = context.kind else { return }
        passwordOperationEpoch &+= 1
        pendingPasswordContext = nil
        overlayState.showPasswordPrompt = false
        overlayState.pendingEncryptedPath = nil
    }

    /// Returns the captured tab session when a browse password result may still be committed.
    ///
    /// The result is accepted only while the operation is still current and the captured
    /// session is still the active one. A `nil` captured identity is never treated as the
    /// current tab, and the result of an abandoned operation is never committed into the
    /// background.
    private func committedBrowsePasswordTarget(for context: ArchivePasswordOperationContext) -> UUID? {
        guard isPasswordOperationStillCurrent(operationID: context.operationID, epoch: context.captureEpoch) else {
            return nil
        }
        guard let capturedTabID = context.tabID else { return nil }
        guard navigationState.activeSessionID == capturedTabID else { return nil }
        return capturedTabID
    }

    internal func applyUnverifiedBrowsableCatalogResult(
        context: ArchivePasswordOperationContext,
        inspection: InspectResult
    ) {
        guard !isWindowClosing else { return }
        guard let targetTabID = committedBrowsePasswordTarget(for: context) else { return }
        let archivePath = context.archivePath
        guard Self.matchesArchiveInspection(inspection, archivePath: archivePath) else { return }
        explorerState.installAcceptedArchiveProjection(
            AcceptedArchiveDirectoryProjection(inspection: inspection),
            evidence: .directoryBrowsableUnverified, for: targetTabID
        )
        passwordEvidenceState = .directoryBrowsableUnverified
        explorerState.currentArchivePath = archivePath
        explorerState.activePassword = nil
        explorerState.currentEntries = inspection.entries
        navigationState.setArchive(path: archivePath, forTab: targetTabID, restoringLocation: context.browsingLocation)
        pruneUnreachableArchiveResources()
        // MM49: the browse result never acquired a busy identity, so it must not release
        // one. It only publishes its own result text.
        taskState.statusMessage = AppLocalizationState.shared.t(ArchivePasswordLocaleKey.directoryBrowsableUnverifiedStatus)
        recordRecentArchive(url: URL(fileURLWithPath: archivePath))
        AppIntentDispatcher.shared.syncWindowArchiveSession(for: self)
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: archivePath)
    }

    internal func applyVerifiedBrowseResult(
        context: ArchivePasswordOperationContext,
        inspection: InspectResult,
        verifiedPassword: String,
        scope: ArchivePasswordVerificationScope
    ) {
        guard !isWindowClosing else { return }
        guard let targetTabID = committedBrowsePasswordTarget(for: context) else { return }
        let archivePath = context.archivePath
        guard Self.matchesArchiveInspection(inspection, archivePath: archivePath) else { return }
        explorerState.installAcceptedArchiveProjection(
            AcceptedArchiveDirectoryProjection(inspection: inspection),
            evidence: .verified(scope), for: targetTabID
        )
        ArchivePasswordStore.shared.setPassword(verifiedPassword, for: archivePath)
        passwordEvidenceState = .verified(scope)
        explorerState.currentArchivePath = archivePath
        explorerState.activePassword = verifiedPassword
        explorerState.currentEntries = inspection.entries
        navigationState.setArchive(path: archivePath, forTab: targetTabID, restoringLocation: context.browsingLocation)
        pruneUnreachableArchiveResources()
        // MM49: see `applyUnverifiedBrowsableCatalogResult` — no busy identity is released here.
        taskState.statusMessage = AppLocalizationState.shared.t(ArchivePasswordLocaleKey.passwordVerifiedStatus)
        recordRecentArchive(url: URL(fileURLWithPath: archivePath))
        AppIntentDispatcher.shared.syncWindowArchiveSession(for: self)
        prefetchArchiveEntries(path: archivePath, entries: inspection.entries, count: 16)
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: archivePath)
    }

    private func handlePasswordSubmissionFailure(
        _ error: Error,
        candidate: String,
        context: ArchivePasswordOperationContext
    ) -> ArchivePasswordSubmissionResult {
        evictCachedPasswordIfMatches(candidate, for: context.archivePath)
        let classified = ArchivePasswordErrorClassifier.classify(error)
        switch classified.category {
        case .wrongPassword:
            var updated = context
            updated.isResumingOrCompleted = false
            updated.recordFailedPassword(candidate)
            updated.lastFailureCategory = .wrongPassword
            updated.lastErrorMessage = classified.message
            pendingPasswordContext = updated
            if explorerState.currentArchivePath == context.archivePath && !explorerState.currentEntries.isEmpty {
                passwordEvidenceState = .directoryBrowsableUnverified
            } else {
                passwordEvidenceState = .notEncrypted
            }
            overlayState.pendingEncryptedPath = context.archivePath
            overlayState.showPasswordPrompt = true
            taskState.statusMessage = classified.message
            return .wrongPassword(message: classified.message)
        case .cancelled:
            pendingPasswordContext = nil
            overlayState.showPasswordPrompt = false
            overlayState.pendingEncryptedPath = nil
            return .cancelledOrStale
        default:
            pendingPasswordContext = nil
            overlayState.showPasswordPrompt = false
            overlayState.pendingEncryptedPath = nil
            taskState.statusMessage = classified.message
            AppErrorReporter.shared.reportError(error, contextTitle: classified.message)
            return .nonPasswordFailure(category: classified.category, message: classified.message)
        }
    }

    private func isOperationOrWindowActive(operationID: UUID?, epoch: UInt64?) -> Bool {
        if let operationID, let epoch {
            return isPasswordOperationStillCurrent(operationID: operationID, epoch: epoch)
        }
        return !isWindowClosing
    }

    private func tryExtractQuarantined(archiveURL: URL, destDir: String, password: String?, trashSource: Bool) async -> Bool {
        guard (password?.isEmpty ?? true), QuarantineWorkerClient.shared.shouldRouteToSandboxWorker(url: archiveURL) else { return false }
        guard await extractQuarantinedArchive(archiveURL: archiveURL, destinationDirectory: URL(fileURLWithPath: destDir)) else { return false }
        finalizeExtractedOutput(archiveURL: archiveURL, destDir: destDir, trashSourceAfterExtract: trashSource)
        return true
    }

    internal func performVerifiedQuickExtract(
        archivePath: String,
        targetDir: String?,
        explicitPassword: String?,
        allowVaultFallback: Bool,
        isSmartExtract: Bool,
        trashSourceAfterExtract: Bool,
        collisionHandling: CollisionHandling?,
        operationID: UUID? = nil,
        epoch: UInt64? = nil
    ) async throws {
        let archiveURL = URL(fileURLWithPath: archivePath)
        let credentialIdentity = ArchiveCredentialIdentity.resolve(archivePath: archivePath)
        let credentialGeneration = credentialIdentity.flatMap {
            archiveRememberedPasswordController?.operationGeneration(for: $0)
        }
        let archiveLease = RootFolderAccessManager.shared.acquireLease(for: archiveURL)
        defer { archiveLease?.release() }

        let archiveName = archiveURL.deletingPathExtension().lastPathComponent
        let parentDir = targetDir ?? archiveURL.deletingLastPathComponent().path
        let parentURL = URL(fileURLWithPath: parentDir)
        let destLease = RootFolderAccessManager.shared.acquireLease(for: parentURL)
        defer { destLease?.release() }

        let destDir = await resolveQuickExtractDestinationDir(
            archivePath: archivePath,
            archiveName: archiveName,
            parentURL: parentURL,
            explicitPassword: explicitPassword,
            isSmartExtract: isSmartExtract
        )

        let tracked = beginTrackedTask(statusMessage: "Extracting \(archiveName)...", canPause: true)
        defer { endTrackedTask(id: tracked.id, sheet: tracked.sheet, uiTask: tracked.uiTask, resetPauseState: true) }

        let handling = collisionHandling ?? resolveCollisionHandling(destinationDir: destDir)
        if await tryExtractQuarantined(archiveURL: archiveURL, destDir: destDir, password: explicitPassword, trashSource: trashSourceAfterExtract) {
            return
        }

        let res = try await passwordDriver.quickExtract(
            archivePath: archivePath,
            destinationDir: destDir,
            password: explicitPassword,
            autoVaultUnlock: allowVaultFallback,
            handling: handling,
            progress: { prog in tracked.sheet.ingest(progress: prog) },
            token: tracked.handle.uniffiToken
        )

        guard isOperationOrWindowActive(operationID: operationID, epoch: epoch) else { return }

        let hasEncryptedProof: Bool
        if let unlocked = res.unlockedPassword, !unlocked.isEmpty {
            hasEncryptedProof = await hasIndependentEncryptedProof(
                archivePath: archivePath, password: unlocked
            )
        } else {
            hasEncryptedProof = false
        }
        guard isOperationOrWindowActive(operationID: operationID, epoch: epoch) else { return }

        finalizeVerifiedQuickExtract(
            res,
            archivePath: archivePath,
            archiveURL: archiveURL,
            archiveName: archiveName,
            destDir: destDir,
            trashSourceAfterExtract: trashSourceAfterExtract,
            allowPasswordCache: hasEncryptedProof && isArchiveCredentialCurrent(
                credentialIdentity, generation: credentialGeneration
            )
        )
    }

    private func resolveQuickExtractDestinationDir(
        archivePath: String,
        archiveName: String,
        parentURL: URL,
        explicitPassword: String?,
        isSmartExtract: Bool
    ) async -> String {
        guard isSmartExtract else {
            return (parentURL.path as NSString).appendingPathComponent(archiveName)
        }
        let entries = (try? await passwordDriver.inspectArchive(
            archivePath: archivePath,
            password: explicitPassword,
            autoVaultUnlock: false
        ).entries) ?? []
        return SmartExtractResolver.resolve(
            entryPaths: entries.map(\.path),
            destinationParentURL: parentURL,
            archiveStemName: archiveName
        ).finalExtractionURL.path
    }

    private func finalizeVerifiedQuickExtract(
        _ res: ExtractResult,
        archivePath: String,
        archiveURL: URL,
        archiveName: String,
        destDir: String,
        trashSourceAfterExtract: Bool,
        allowPasswordCache: Bool
    ) {
        if allowPasswordCache, let verifiedPwd = res.unlockedPassword, !verifiedPwd.isEmpty {
            ArchivePasswordStore.shared.setPassword(verifiedPwd, for: archivePath)
            passwordEvidenceState = .verified(.fullArchive)
            if explorerState.currentArchivePath == archivePath {
                explorerState.activePassword = verifiedPwd
            }
        }
        if res.isVaultUnlocked, let unlockedPwd = res.unlockedPassword {
            self.taskState.statusMessage = "Extracted with vault password: \(archiveName)"
            if allowPasswordCache {
                ArchivePasswordStore.shared.setPassword(unlockedPwd, for: archivePath)
            }
        } else {
            self.taskState.statusMessage = "Extraction complete: \(archiveName)"
        }
        self.taskState.progressValue = 1.0
        self.taskState.taskStateName = "Idle"
        finalizeExtractedOutput(archiveURL: archiveURL, destDir: destDir, trashSourceAfterExtract: trashSourceAfterExtract)
    }

    private func finalizeExtractedOutput(archiveURL: URL, destDir: String, trashSourceAfterExtract: Bool) {
        self.fileViewer.revealInFinder(at: destDir)
        if trashSourceAfterExtract {
            try? FileManager.default.trashItem(at: archiveURL, resultingItemURL: nil)
        }
    }

    internal func performVerifiedExtractEntries(
        archivePath: String,
        entryPaths: [String],
        destinationDir: String,
        explicitPassword: String?,
        collisionHandling: CollisionHandling?,
        operationID: UUID? = nil,
        epoch: UInt64? = nil
    ) async throws {
        guard let firstEntry = entryPaths.first else { return }
        let credentialIdentity = ArchiveCredentialIdentity.resolve(archivePath: archivePath)
        let credentialGeneration = credentialIdentity.flatMap {
            archiveRememberedPasswordController?.operationGeneration(for: $0)
        }
        let archiveLease = RootFolderAccessManager.shared.acquireLease(for: URL(fileURLWithPath: archivePath))
        let destLease = RootFolderAccessManager.shared.acquireLease(for: URL(fileURLWithPath: destinationDir))
        defer {
            destLease?.release()
            archiveLease?.release()
        }

        let label = entryPaths.count == 1 ? (firstEntry as NSString).lastPathComponent : "\(entryPaths.count) items"
        let tracked = beginTrackedTask(statusMessage: "Extracting entry: \(label)...", canPause: false)
        defer { endTrackedTask(id: tracked.id, sheet: tracked.sheet, uiTask: tracked.uiTask, resetPauseState: false) }

        let handling = collisionHandling ?? resolveCollisionHandling(destinationDir: destinationDir)
        let outcome = try await passwordDriver.extractEntries(
            archivePath: archivePath,
            entryPaths: entryPaths,
            destinationDir: destinationDir,
            password: explicitPassword,
            handling: handling,
            progress: { prog in tracked.sheet.ingest(progress: prog) }
        )

        guard isOperationOrWindowActive(operationID: operationID, epoch: epoch) else { return }

        if outcome.status == .stopped {
            throw ArchiveError.extractionStopped
        }
        if outcome.status == .completedWithFailures {
            throw ArchiveError.partialExtractionFailure(outcome: outcome)
        }

        if isArchiveCredentialCurrent(credentialIdentity, generation: credentialGeneration),
           let verifiedPwd = explicitPassword, !verifiedPwd.isEmpty {
            ArchivePasswordStore.shared.setPassword(verifiedPwd, for: archivePath)
            passwordEvidenceState = .verified(.selectedEntries(Set(entryPaths)))
            if explorerState.currentArchivePath == archivePath {
                explorerState.activePassword = verifiedPwd
            }
        }
        finishEntryExtraction(outcome, label: label, entryPaths: entryPaths, destinationDir: destinationDir)
    }

    internal func inspectHeaderEncryptedArchive(
        path: String,
        explicitPassword: String?
    ) async throws -> ArchiveInspectionWithEvidence {
        if let explicitPassword, !explicitPassword.isEmpty {
            let res = try await passwordDriver.inspectArchive(
                archivePath: path,
                password: explicitPassword,
                autoVaultUnlock: false
            )
            return ArchiveInspectionWithEvidence(result: res, verifiedPassword: explicitPassword, evidence: .verified(.headerCatalog), isVaultUnlocked: false)
        }
        if let cached = reusablePasswordCandidate(for: path, explicitPassword: nil) {
            do {
                let res = try await passwordDriver.inspectArchive(
                    archivePath: path,
                    password: cached,
                    autoVaultUnlock: false
                )
                return ArchiveInspectionWithEvidence(result: res, verifiedPassword: cached, evidence: .verified(.headerCatalog), isVaultUnlocked: false)
            } catch {
                let classified = ArchivePasswordErrorClassifier.classify(error)
                if classified.category == .wrongPassword {
                    evictCachedPasswordIfMatches(cached, for: path)
                } else {
                    throw error
                }
            }
        }
        if self.passwordVault.autoUnlockArchives {
            let res = try await passwordDriver.inspectArchive(
                archivePath: path,
                password: nil,
                autoVaultUnlock: true
            )
            let isVaultUnlocked = (res.unlockedPassword != nil && !(res.unlockedPassword?.isEmpty ?? true))
            return ArchiveInspectionWithEvidence(result: res, verifiedPassword: res.unlockedPassword, evidence: .verified(.headerCatalog), isVaultUnlocked: isVaultUnlocked)
        }
        let res = try await passwordDriver.inspectArchive(
            archivePath: path,
            password: nil,
            autoVaultUnlock: false
        )
        return ArchiveInspectionWithEvidence(result: res, verifiedPassword: nil, evidence: .notEncrypted, isVaultUnlocked: false)
    }

    internal func inspectArchiveWithEvidence(
        path: String,
        explicitPassword: String?,
        unauthenticatedInspection: InspectResult? = nil
    ) async throws -> ArchiveInspectionWithEvidence {
        let unauthRes: InspectResult
        if let unauthenticatedInspection {
            unauthRes = unauthenticatedInspection
        } else {
            do {
                unauthRes = try await passwordDriver.inspectArchive(
                    archivePath: path,
                    password: nil,
                    autoVaultUnlock: false
                )
            } catch {
                let classified = ArchivePasswordErrorClassifier.classify(error)
                guard classified.category == .wrongPassword else {
                    throw error
                }
                return try await inspectHeaderEncryptedArchive(path: path, explicitPassword: explicitPassword)
            }
        }

        guard unauthRes.entries.contains(where: \.isEncrypted) else {
            return ArchiveInspectionWithEvidence(result: unauthRes, verifiedPassword: nil, evidence: .notEncrypted, isVaultUnlocked: false)
        }
        if let explicitPassword, !explicitPassword.isEmpty {
            let outcome = await verifyPlaintextCatalogPassword(
                archivePath: path,
                entries: unauthRes.entries,
                password: explicitPassword
            )
            switch outcome {
            case .verified(let scope):
                return ArchiveInspectionWithEvidence(result: unauthRes, verifiedPassword: explicitPassword, evidence: .verified(scope), isVaultUnlocked: false)
            case .noAvailableEvidence:
                return ArchiveInspectionWithEvidence(result: unauthRes, verifiedPassword: nil, evidence: .directoryBrowsableUnverified, isVaultUnlocked: false)
            case .wrongPassword:
                throw ArchiveError.wrongPassword(archivePath: path)
            case .otherFailure(let category, let message):
                throw ArchivePasswordProbeFailure(
                    category: category,
                    message: message
                )
            }
        }
        return ArchiveInspectionWithEvidence(result: unauthRes, verifiedPassword: nil, evidence: .directoryBrowsableUnverified, isVaultUnlocked: false)
    }
}

