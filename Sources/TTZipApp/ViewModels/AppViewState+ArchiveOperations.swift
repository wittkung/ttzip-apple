// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit
#if canImport(TTZipAppServices)
#endif

extension AppViewState {
    /// Identity of a foreground archive-open request.
    ///
    /// The ticket binds the request to the tab session that started it and to the operation
    /// epoch that was current when it started. A late result may only commit while both are
    /// still current, which is what keeps the result of an abandoned request away from the
    /// page the user navigated to. The session identity alone cannot express that: a request
    /// that is abandoned and later resumed on the same session (T1 -> T2 -> T1) still has to
    /// stay rejected, and only the epoch tells the two apart.
    struct ArchiveOpenRequestTicket: Equatable {
        let epoch: UInt64
        let sessionID: UUID
    }

    public func openArchiveAsFolder(
        url: URL,
        password: String? = nil,
        bookmarkSession: ActiveBookmarkSession? = nil
    ) {
        _ = openArchive(at: url, password: password, bookmarkSession: bookmarkSession)
    }

    @discardableResult
    public func openArchive(
        at url: URL,
        password: String? = nil,
        bookmarkSession: ActiveBookmarkSession? = nil
    ) -> Task<Bool, Never> {
        if self.navigationState.isCompressWorkspaceActive {
            self.navigationState.closeCompressWorkspaceTab()
        }
        if FileManager.default.isReadableFile(atPath: url.path) {
            self.recordRecentArchive(url: url)
        }
        return Task { @MainActor [weak self] in
            defer { bookmarkSession?.invalidate() }
            guard let self else { return false }
            let ticket = await self.loadArchiveWithTicket(
                path: url.path,
                password: password,
                bookmarkSession: bookmarkSession
            )
            // The commit already happened inside the load. It is re-validated here because the
            // continuation of this task runs after the load returned, so the user may have
            // navigated away in between.
            guard let ticket, self.validateArchiveOpenRequest(ticket) else { return false }
            self.selectedDiskItem = DiskItemInfo(url: url)
            self.navigationState.activeTab = .home
            AppIntentDispatcher.shared.syncWindowArchiveSession(for: self)
            return true
        }
    }

    public func closeCurrentArchive(discardAcceptedResources: Bool = false) {
        if discardAcceptedResources {
            explorerState.discardAcceptedArchiveProjections(for: navigationState.activeSessionID)
        }
        self.operationEpoch &+= 1
        self.passwordOperationEpoch &+= 1
        self.searchNavigationGeneration &+= 1
        self.selectedArchiveHighlightLine = nil
        self.pendingPasswordContext = nil
        self.passwordEvidenceState = .notEncrypted
        self.overlayState.showPasswordPrompt = false
        self.overlayState.pendingEncryptedPath = nil
        self.explorerState.currentArchivePath = nil
        self.explorerState.activePassword = nil
        self.explorerState.currentEntries = []
        self.explorerState.searchQuery = ""
        self.selectionState.selectedEntryID = nil
        self.selectedDiskItem = nil
        // MM49: closing the archive abandons the foreground request only. Background
        // operations keep running and keep the window busy.
        self.taskState.invalidateArchiveRequest()
        self.taskState.statusMessage = ""
        self.navigationState.clearArchiveForActiveTab()
        if discardAcceptedResources { leaveClosedArchiveLocation() }
        AppIntentDispatcher.shared.unregisterSession(id: self.windowID)
    }

    public func selectArchiveEntry(
        path entryPath: String?,
        inArchive archivePath: String,
        highlightLine: Int? = nil
    ) {
        self.selectedArchiveHighlightLine = highlightLine
        guard let rawPath = entryPath, !rawPath.isEmpty else {
            self.selectionState.selectedEntryID = nil
            let archiveURL = URL(fileURLWithPath: archivePath)
            self.selectedDiskItem = DiskItemInfo(url: archiveURL)
            self.invalidateStaleAcceptedEntryPasswordPromptIfNeeded()
            return
        }

        let normalizedSubpath = ArchivePasswordProbePolicy.normalizeEntryPath(rawPath)
        let entry = self.explorerState.currentEntries.first(where: {
            ArchivePasswordProbePolicy.normalizeEntryPath($0.path) == normalizedSubpath
        })
        let canonicalEntryPath = entry?.path ?? normalizedSubpath
        self.selectionState.selectedEntryID = canonicalEntryPath

        guard let virtualURL = Self.makeArchiveEntryVirtualURL(
            archivePath: archivePath,
            entrySubpath: canonicalEntryPath
        ) else { return }

        let isDir = entry?.isDirectory ?? rawPath.hasSuffix("/")
        let sizeBytes = entry?.uncompressedSize ?? 0
        let filename = (canonicalEntryPath as NSString).lastPathComponent

        let sizeText = isDir ? "Folder" : ByteCountFormatterFlyweight.shared.string(fromByteCount: sizeBytes)
        let ext = (filename as NSString).pathExtension.lowercased()
        let kindText = isDir ? "Archive Folder" : (ext.isEmpty ? "File" : "\(ext.uppercased()) File")

        let virtualItem = DiskItemInfo(
            virtualName: filename,
            virtualURL: virtualURL,
            isDirectory: isDir,
            isArchive: false,
            sizeText: sizeText,
            rawSizeBytes: sizeBytes,
            kindText: kindText
        )
        self.selectedDiskItem = virtualItem
        self.selectionState.selectedDiskItems = [virtualItem]
        self.invalidateStaleAcceptedEntryPasswordPromptIfNeeded()
    }

    public static func makeArchiveEntryVirtualURL(archivePath: String, entrySubpath: String) -> URL? {
        let baseArchiveURL = URL(fileURLWithPath: archivePath)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?%")
        let encodedSubpath = entrySubpath.addingPercentEncoding(withAllowedCharacters: allowed) ?? entrySubpath
        return URL(string: baseArchiveURL.absoluteString + "?subpath=" + encodedSubpath)
    }

    public func previewMediaFile(path: String) {
        let url = URL(fileURLWithPath: path)
        let item = DiskItemInfo(url: url)
        self.openImmersiveMedia(for: item)
    }

    public func closeMediaPreview() {
        self.overlayState.showImmersiveMediaBrowser = false
        self.overlayState.immersiveMediaItem = nil
    }

    @discardableResult
    public func loadArchive(
        path: String,
        password: String? = nil,
        bookmarkSession: ActiveBookmarkSession? = nil
    ) async -> Bool {
        await loadArchiveWithTicket(
            path: path,
            password: password,
            bookmarkSession: bookmarkSession
        ) != nil
    }

    /// Loads an archive into the tab session that owns the request.
    ///
    /// Returns the ticket that authorized the commit, or `nil` when the request did not commit:
    /// the inspection failed, the window closed, or the user navigated away while the request
    /// was in flight. Ticket validation and the commit share one synchronous block, so a late
    /// success, failure or password prompt can never be written to a page the request no
    /// longer owns.
    ///
    /// The request lifecycle is split by responsibility: `beginArchiveOpenRequest` establishes
    /// the request and the resources its inspection needs, `acceptArchiveOpenSuccess` commits a
    /// successful inspection, and `acceptArchiveOpenFailure` presents a failed one.
    @discardableResult
    internal func loadArchiveWithTicket(
        path: String,
        password: String? = nil,
        bookmarkSession: ActiveBookmarkSession? = nil,
        restoringLocation: URL? = nil
    ) async -> ArchiveOpenRequestTicket? {
        defer { bookmarkSession?.invalidate() }

        guard let request = await self.beginArchiveOpenRequest(path: path) else { return nil }
        defer { request.lease?.release() }

        // The credential identity and generation are captured before the inspection suspends, so
        // a credential that is changed or forgotten while the request is in flight invalidates
        // that request.
        let credentialIdentity = ArchiveCredentialIdentity.resolve(archivePath: path)
        let credentialGeneration = credentialIdentity.flatMap {
            archiveRememberedPasswordController?.operationGeneration(for: $0)
        }

        let candidatePassword = reusablePasswordCandidate(for: path, explicitPassword: password)
        let probe = await self.probeArchiveCredentialRequirement(
            path: path, candidatePassword: candidatePassword
        )

        guard self.isArchiveCredentialStillCurrent(
            path: path, identity: credentialIdentity, generation: credentialGeneration
        ) else { return nil }

        let remembered = await self.readRememberedArchiveCredential(
            path: path,
            identity: credentialIdentity,
            mayReadSavedCredential: probe.mayReadSavedCredential
        )
        let resolvedPassword = candidatePassword ?? remembered.password

        self.taskState.statusMessage = "Loading archive..."
        self.taskState.beginArchiveRequest(epoch: request.ticket.epoch)

        do {
            let inspection = try await self.inspectArchiveForLoad(
                path: path,
                candidatePassword: resolvedPassword,
                headerNeedsPassword: probe.headerNeedsPassword,
                unauthenticatedInspection: probe.unauthenticatedInspection
            )
            guard Self.matchesArchiveInspection(inspection.result, archivePath: path) else {
                throw ArchiveError.engineFailure(code: -500, message: "Archive inspection source mismatch")
            }
            guard self.isArchiveCredentialStillCurrent(
                path: path, identity: credentialIdentity, generation: credentialGeneration
            ) else { return nil }
            return self.acceptArchiveOpenSuccess(
                ticket: request.ticket,
                path: path,
                inspection: inspection,
                restoringLocation: restoringLocation
            )
        } catch {
            guard self.isArchiveCredentialStillCurrent(
                path: path, identity: credentialIdentity, generation: credentialGeneration
            ) else { return nil }
            return self.presentArchiveOpenFailure(
                ticket: request.ticket,
                path: path,
                error: error,
                candidatePassword: resolvedPassword,
                explicitPassword: password,
                savedCandidate: remembered.password,
                vaultReadFailed: remembered.vaultReadFailed,
                identity: credentialIdentity
            )
        }
    }

    /// Determines what the archive needs before it can be inspected.
    ///
    /// The probe only runs when no reusable candidate password exists and the vault may unlock
    /// archives on its own. A successful probe yields the unauthenticated inspection that the
    /// later inspection can reuse; a failed probe tells the caller that the archive header
    /// itself demands a password.
    private func probeArchiveCredentialRequirement(
        path: String,
        candidatePassword: String?
    ) async -> (unauthenticatedInspection: InspectResult?, headerNeedsPassword: Bool, mayReadSavedCredential: Bool) {
        guard candidatePassword == nil, passwordVault.autoUnlockArchives else {
            return (nil, false, false)
        }
        do {
            let preflight = try await passwordDriver.inspectArchive(
                archivePath: path, password: nil, autoVaultUnlock: false
            )
            guard Self.matchesArchiveInspection(preflight, archivePath: path) else {
                return (nil, false, false)
            }
            return (preflight, false, preflight.entries.contains(where: \.isEncrypted))
        } catch {
            let headerNeedsPassword = ArchivePasswordErrorClassifier.classify(error).category == .wrongPassword
            return (nil, headerNeedsPassword, headerNeedsPassword)
        }
    }

    /// Reads the remembered credential of the archive when the inspection says one is needed.
    ///
    /// The controller is read live, so a credential that was forgotten while the request was in
    /// flight is not resurrected. A failed vault read is reported instead of being passed off as
    /// "there is no remembered credential".
    private func readRememberedArchiveCredential(
        path: String,
        identity: ArchiveCredentialIdentity?,
        mayReadSavedCredential: Bool
    ) async -> (password: String?, vaultReadFailed: Bool) {
        guard mayReadSavedCredential, let identity else { return (nil, false) }
        guard let controller = self.archiveRememberedPasswordController else { return (nil, false) }
        do {
            let saved = try controller.password(for: identity)
            guard let saved, !saved.isEmpty,
                  !(pendingPasswordContext?.archivePath == path
                    && pendingPasswordContext?.hasFailedPassword(saved) == true) else {
                return (nil, false)
            }
            return (saved, false)
        } catch {
            return (nil, true)
        }
    }

    /// Reports whether the remembered credential of the archive is still the one the request started with.
    ///
    /// The controller is read live: a request that started before a credential was changed or
    /// forgotten must not continue with the credential it started with. A request without a
    /// remembered credential stays valid, because there is nothing that could have changed.
    private func isArchiveCredentialStillCurrent(
        path: String,
        identity: ArchiveCredentialIdentity?,
        generation: UInt64?
    ) -> Bool {
        guard let identity, let generation,
              let controller = self.archiveRememberedPasswordController else { return true }
        return ArchiveCredentialIdentity.resolve(archivePath: path) == identity
            && controller.operationGeneration(for: identity) == generation
    }

    /// Inspects the archive for the load, taking the header path for encrypted archives.
    private func inspectArchiveForLoad(
        path: String,
        candidatePassword: String?,
        headerNeedsPassword: Bool,
        unauthenticatedInspection: InspectResult?
    ) async throws -> ArchiveInspectionWithEvidence {
        if headerNeedsPassword {
            return try await inspectHeaderEncryptedArchive(
                path: path, explicitPassword: candidatePassword
            )
        }
        return try await inspectArchiveWithEvidence(
            path: path, explicitPassword: candidatePassword,
            unauthenticatedInspection: unauthenticatedInspection
        )
    }

    /// Rejects an invalid remembered credential and presents the failed inspection.
    ///
    /// The rejection runs before the failure is presented, so a wrong saved password is dropped
    /// from the vault before the user is asked for a new one.
    private func presentArchiveOpenFailure(
        ticket: ArchiveOpenRequestTicket,
        path: String,
        error: Error,
        candidatePassword: String?,
        explicitPassword: String?,
        savedCandidate: String?,
        vaultReadFailed: Bool,
        identity: ArchiveCredentialIdentity?
    ) -> ArchiveOpenRequestTicket? {
        var vaultRemovalFailed = false
        if let savedCandidate,
           ArchivePasswordErrorClassifier.classify(error).category == .wrongPassword,
           let identity,
           let controller = self.archiveRememberedPasswordController {
            do {
                try controller.rejectSavedCandidate(savedCandidate, for: identity)
            } catch {
                vaultRemovalFailed = true
            }
        }
        let result = self.acceptArchiveOpenFailure(
            ticket: ticket,
            path: path,
            error: error,
            candidatePassword: candidatePassword,
            explicitPassword: explicitPassword
        )
        self.applyArchiveOpenFailureStatus(
            ticket: ticket,
            vaultRemovalFailed: vaultRemovalFailed,
            vaultReadFailed: vaultReadFailed
        )
        return result
    }

    /// Reports a vault problem the user has to resolve by hand.
    ///
    /// The status is only written while the request still owns the page, so a stale failure never
    /// overwrites the message of the page the user navigated to.
    private func applyArchiveOpenFailureStatus(
        ticket: ArchiveOpenRequestTicket,
        vaultRemovalFailed: Bool,
        vaultReadFailed: Bool
    ) {
        let requestStillOwnsPage = !Task.isCancelled && !isWindowClosing
            && operationEpoch == ticket.epoch
            && navigationState.activeSessionID == ticket.sessionID
        guard requestStillOwnsPage else { return }
        if vaultRemovalFailed {
            taskState.statusMessage = AppLocalizationState.shared.uiString(
                zh: "已保存的密码无效，且无法从钥匙库删除；请手动输入",
                en: "Saved password is invalid and could not be removed from the vault; enter it manually"
            )
        } else if vaultReadFailed {
            taskState.statusMessage = AppLocalizationState.shared.uiString(
                zh: "无法读取钥匙库密码；请手动输入",
                en: "Could not read the vault password; enter it manually"
            )
        }
    }

    /// Establishes the foreground archive-open request and the resources its inspection needs.
    ///
    /// The request identity is captured before the first suspension point, and the resources
    /// (root folder access and the security-scoped lease) are acquired here, so a navigation
    /// during the acquisition already invalidates the request before any inspection starts.
    /// The lease is handed to the caller, which owns its release.
    private func beginArchiveOpenRequest(
        path: String
    ) async -> (ticket: ArchiveOpenRequestTicket, lease: SecurityScopeLease?)? {
        // 1. Establish request identity BEFORE any async suspension point
        self.operationEpoch &+= 1
        let ticket = ArchiveOpenRequestTicket(
            epoch: self.operationEpoch,
            sessionID: self.navigationState.activeSessionID
        )

        let archiveURL = URL(fileURLWithPath: path)
        if !FileManager.default.isReadableFile(atPath: path) {
            _ = await RootFolderAccessManager.shared.requestRootAccess(
                suggestedURL: archiveURL.deletingLastPathComponent()
            )
        }

        let lease = RootFolderAccessManager.shared.acquireLease(for: archiveURL)
        guard self.validateArchiveOpenRequest(ticket) else {
            lease?.release()
            return nil
        }
        return (ticket, lease)
    }

    /// Accepts a successful inspection for the request that owns the foreground.
    ///
    /// Validation and commit share one synchronous block: the ticket is checked immediately
    /// before the state is written, so a result of an abandoned request can never reach the
    /// page the user navigated to.
    private func acceptArchiveOpenSuccess(
        ticket: ArchiveOpenRequestTicket,
        path: String,
        inspection: ArchiveInspectionWithEvidence,
        restoringLocation: URL?
    ) -> ArchiveOpenRequestTicket? {
        guard self.validateArchiveOpenRequest(ticket) else { return nil }

        self.explorerState.installAcceptedArchiveProjection(
            AcceptedArchiveDirectoryProjection(inspection: inspection.result),
            evidence: inspection.evidence, for: ticket.sessionID
        )
        if let verifiedPassword = inspection.verifiedPassword, !verifiedPassword.isEmpty {
            ArchivePasswordStore.shared.setPassword(verifiedPassword, for: path)
        }

        self.explorerState.currentArchivePath = path
        self.explorerState.activePassword = inspection.verifiedPassword
        self.explorerState.currentEntries = inspection.entries
        self.passwordEvidenceState = inspection.evidence
        self.navigationState.activeTab = .home
        // The archive is committed into the session that started the request, never into
        // whichever session happens to be active when the inspection returns.
        self.navigationState.setArchive(
            path: path, forTab: ticket.sessionID, restoringLocation: restoringLocation
        )
        pruneUnreachableArchiveResources()
        // MM49: the request releases the foreground only while it still owns it.
        self.taskState.endArchiveRequest(ifOwnedBy: ticket.epoch)

        if inspection.isVaultUnlocked {
            self.taskState.statusMessage = "Unlocked with vault password (\(inspection.entries.count) entries)"
        } else if inspection.evidence == .directoryBrowsableUnverified {
            self.taskState.statusMessage = ArchivePasswordLocaleKey.directoryBrowsableUnverifiedStatus.localized()
        } else if inspection.verifiedPassword != nil {
            self.taskState.statusMessage = ArchivePasswordLocaleKey.passwordVerifiedStatus.localized()
        } else {
            self.taskState.statusMessage = "Loaded \(inspection.entries.count) entries"
        }

        self.recordRecentArchive(url: URL(fileURLWithPath: path))
        AppIntentDispatcher.shared.syncWindowArchiveSession(for: self)
        self.prefetchArchiveEntries(path: path, entries: inspection.entries, count: 16)
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: path)
        return ticket
    }

    /// Accepts a failed inspection for the request that owns the foreground and presents it.
    ///
    /// A stale failure is dropped together with its presentation: a password prompt of an
    /// abandoned request must not be staged for the page the user navigated to.
    private func acceptArchiveOpenFailure(
        ticket: ArchiveOpenRequestTicket,
        path: String,
        error: Error,
        candidatePassword: String?,
        explicitPassword: String?
    ) -> ArchiveOpenRequestTicket? {
        guard self.validateArchiveOpenRequest(ticket) else { return nil }

        // MM49: the request releases the foreground only while it still owns it.
        self.taskState.endArchiveRequest(ifOwnedBy: ticket.epoch)
        let classified = ArchivePasswordErrorClassifier.classify(error)

        guard classified.category != .wrongPassword else {
            stagePasswordPromptContext(
                archivePath: path,
                kind: .browse,
                failedPassword: candidatePassword,
                errorMessage: (explicitPassword != nil && !(explicitPassword?.isEmpty ?? true)) ? classified.message : nil
            )
            self.taskState.statusMessage = "Archive is password-protected"
            return nil
        }

        self.taskState.statusMessage = classified.message
        AppErrorReporter.shared.reportError(error, contextTitle: "Archive Inspection Failed")
        return nil
    }

    /// Validates that the archive-open request still owns the foreground.
    ///
    /// The check covers cancellation, window close, the operation epoch and the owning tab
    /// session. A request that lost the foreground also releases the shared loading state it
    /// owned, so a rejected request leaves no spinner behind and never clears the spinner of
    /// a newer request or of an unrelated flow.
    private func validateArchiveOpenRequest(_ ticket: ArchiveOpenRequestTicket) -> Bool {
        guard !Task.isCancelled,
              !isWindowClosing,
              operationEpoch == ticket.epoch,
              navigationState.activeSessionID == ticket.sessionID else {
            releaseArchiveRequestLoadingState(ifOwnedBy: ticket.epoch)
            return false
        }
        return true
    }

    /// Releases the shared loading state when the given archive request still owns it.
    private func releaseArchiveRequestLoadingState(ifOwnedBy epoch: UInt64) {
        // MM49: only the owner releases the foreground; the release of a request that lost the
        // foreground leaves the current owner untouched.
        guard taskState.endArchiveRequest(ifOwnedBy: epoch) else { return }
        taskState.statusMessage = ""
    }

    /// Abandons the foreground archive request when the user navigates to another page.
    ///
    /// Navigating away from the page that started an archive open invalidates that request:
    /// its late success, failure or password prompt must never reach the new active page.
    internal func handleActiveBrowsingContextChange() {
        reconcileAcceptedArchiveResources()
        invalidateActiveArchiveWork()
        restoreAcceptedArchiveAtCurrentLocation()
    }

    internal func invalidateActiveArchiveWork() {
        operationEpoch &+= 1
        // Navigation invalidates only the browse prompt that belonged to the abandoned page.
        invalidateBrowsePasswordOperationIfPending()
        guard taskState.archiveRequestOwnerEpoch != nil else { return }
        // Navigation invalidates the foreground identity only; background work remains busy.
        taskState.invalidateArchiveRequest()
        taskState.statusMessage = ""
    }

    public func prefetchArchiveEntries(path: String, entries: [ArchiveEntry], count: Int = 16) {
        guard !entries.isEmpty else { return }
        let targetEntries = entries
            .lazy
            .filter { !$0.isDirectory && $0.uncompressedSize > 0 && $0.uncompressedSize <= 50 * 1024 * 1024 }
            .prefix(count)
            .map { $0.path }
        guard !targetEntries.isEmpty else { return }

        Task(priority: .utility) {
            let pwd = ArchivePasswordStore.shared.getPassword(for: path)
            for entryPath in targetEntries {
                guard !Task.isCancelled else { break }
                _ = try? await ArchiveSelectiveExtractor.shared.extractSingleEntryData(
                    archivePath: path,
                    entryPath: entryPath,
                    password: pwd
                )
            }
        }
    }

    public func prefetchVisibleWindow(path: String, startIndex: Int, count: Int = 32) {
        let entries = self.explorerState.currentEntries
        guard !entries.isEmpty, startIndex >= 0, startIndex < entries.count else { return }
        let endIndex = min(startIndex + count, entries.count)
        let slice = Array(entries[startIndex..<endIndex])
        prefetchArchiveEntries(path: path, entries: slice, count: count)
    }

    public func clearArchiveVFSCache(path: String) {
        VFSLz4CachePool.shared.clearSession(sessionId: path)
    }

    public func cancelPasswordPrompt() {
        self.passwordOperationEpoch &+= 1
        self.pendingPasswordContext = nil
        self.overlayState.showPasswordPrompt = false
        self.overlayState.pendingEncryptedPath = nil
        if self.explorerState.currentEntries.isEmpty {
            self.explorerState.currentArchivePath = nil
            self.explorerState.activePassword = nil
            self.passwordEvidenceState = .notEncrypted
            self.taskState.statusMessage = ArchivePasswordLocaleKey.operationCancelled.localized()
        } else {
            self.passwordEvidenceState = .directoryBrowsableUnverified
        }
    }

    public func reset() {
        explorerState.discardAcceptedArchiveProjections(for: navigationState.activeSessionID)
        if let path = self.explorerState.currentArchivePath {
            VFSLz4CachePool.shared.clearSession(sessionId: path)
        }
        self.operationEpoch &+= 1
        self.passwordOperationEpoch &+= 1
        self.searchNavigationGeneration &+= 1
        self.selectedArchiveHighlightLine = nil
        self.pendingPasswordContext = nil
        self.passwordEvidenceState = .notEncrypted
        self.overlayState.showPasswordPrompt = false
        self.overlayState.pendingEncryptedPath = nil
        self.explorerState.currentArchivePath = nil
        self.explorerState.activePassword = nil
        self.explorerState.currentEntries = []
        self.navigationState.clearArchiveForActiveTab()
        AppIntentDispatcher.shared.unregisterSession(id: self.windowID)
        self.taskState.invalidateArchiveRequest()
        self.taskState.statusMessage = "Ready"
        self.navigationState.activeTab = .home
        leaveClosedArchiveLocation()
    }

    /// Pure source-identity comparison; does not read the filesystem or credentials.
    internal static func matchesArchiveInspection(_ result: InspectResult, archivePath: String) -> Bool {
        URL(fileURLWithPath: result.archivePath).standardizedFileURL.path
            == URL(fileURLWithPath: archivePath).standardizedFileURL.path
    }

    /// Must also be called by root after a session retirement that does not change currentDirectory.
    internal func reconcileAcceptedArchiveResources() {
        explorerState.retainAcceptedArchiveProjections(
            for: Set(navigationState.tabSessions.map(\.id))
        )
    }

    /// Called at explicit close/retirement intent boundaries; ordinary navigation does not retire history.
    internal func retireAcceptedArchiveResources(for sessionID: UUID) {
        explorerState.discardAcceptedArchiveProjections(for: sessionID)
    }

    /// Activates an already accepted resource after root has restored that session's location.
    /// No reader, global credential lookup, navigation write or fallback is performed here.
    internal func restoreAcceptedArchiveResources(for sessionID: UUID, archivePath: String) -> Bool {
        guard !isWindowClosing, navigationState.activeSessionID == sessionID,
              let projection = explorerState.acceptedArchiveProjection(
                for: sessionID, archivePath: archivePath
              ),
              let evidence = explorerState.acceptedArchiveEvidence(
                for: sessionID, archivePath: archivePath
              ) else { return false }
        explorerState.currentArchivePath = projection.archivePath
        explorerState.currentEntries = projection.entries
        // The projection carries no credential; extraction uses its existing verification boundary.
        explorerState.activePassword = nil
        passwordEvidenceState = evidence
        AppIntentDispatcher.shared.syncWindowArchiveSession(for: self)
        return true
    }

    /// Refresh/mutation must invalidate foreground work before releasing accepted snapshots.
    /// Caller then uses the existing ticketed inspection route, never a scanner fallback reader.
    internal func invalidateAcceptedArchiveResources(archivePath: String) {
        invalidateActiveArchiveWork()
        explorerState.invalidateAcceptedArchiveProjections(archivePath: archivePath)
        if let current = explorerState.currentArchivePath,
           URL(fileURLWithPath: current).standardizedFileURL.path
            == URL(fileURLWithPath: archivePath).standardizedFileURL.path {
            explorerState.currentEntries = []
            explorerState.activePassword = nil
            passwordEvidenceState = .notEncrypted
            selectionState.clear()
            AppIntentDispatcher.shared.unregisterSession(id: windowID)
        }
        NotificationCenter.default.post(
            name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: archivePath
        )
    }
}
