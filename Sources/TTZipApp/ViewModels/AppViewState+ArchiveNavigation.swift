// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
#if canImport(TTZipAppServices)
import TTZipAppServices
#endif

extension AppViewState {
    /// Captures the existing navigation/selection owners before a preview read suspends.
    package func captureArchiveEntryPreviewRequest(itemPath: String) -> ArchiveEntryPreviewRequest? {
        guard !isWindowClosing,
              let session = navigationState.activeTabSession,
              let itemURL = URL(string: itemPath),
              let entryPath = AcceptedArchiveDirectoryProjection.archiveSubpath(in: itemURL),
              !entryPath.isEmpty,
              AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(session.historyStack.current),
              itemURL.standardizedFileURL.path == session.historyStack.current.standardizedFileURL.path,
              selectionState.selectedDiskItem?.path == itemPath,
              selectionState.selectedDiskItem?.isDirectory == false,
              explorerState.acceptedArchiveProjection(for: session.id, archivePath: itemURL.path) != nil else { return nil }
        return ArchiveEntryPreviewRequest(
            windowID: windowID, sessionID: session.id, operationEpoch: operationEpoch,
            location: session.historyStack.current, archivePath: itemURL.path,
            itemPath: itemPath, entryPath: entryPath,
            selectedEntryID: selectionState.selectedEntryID
        )
    }

    package func isArchiveEntryPreviewRequestCurrent(_ request: ArchiveEntryPreviewRequest) -> Bool {
        !Task.isCancelled && !isWindowClosing && request.windowID == windowID
            && operationEpoch == request.operationEpoch
            && navigationState.activeSessionID == request.sessionID
            && navigationState.activeTabSession.map {
                WorkspaceHistoryStack.sameLocation($0.historyStack.current, request.location)
            } == true
            && WorkspaceHistoryStack.sameLocation(navigationState.currentDirectory, request.location)
            && selectionState.selectedDiskItem?.path == request.itemPath
            && selectionState.selectedEntryID == request.selectedEntryID
            && explorerState.acceptedArchiveProjection(
                for: request.sessionID, archivePath: request.archivePath
            ) != nil
    }

    /// The accepted catalog can identify encrypted payloads before a preview starts decoding.
    package func requiresPasswordForArchiveEntryPreview(_ request: ArchiveEntryPreviewRequest) -> Bool {
        guard isArchiveEntryPreviewRequestCurrent(request),
              let projection = explorerState.acceptedArchiveProjection(
                for: request.sessionID, archivePath: request.archivePath
              ),
              let entry = projection.entries.first(where: {
                ArchivePasswordProbePolicy.normalizeEntryPath($0.path)
                    == ArchivePasswordProbePolicy.normalizeEntryPath(request.entryPath)
              }),
              entry.isEncrypted else { return false }
        return ArchivePasswordStore.shared.getPassword(for: request.archivePath)?.isEmpty != false
    }

    internal func invalidateStaleAcceptedEntryPasswordPromptIfNeeded() {
        guard let context = pendingPasswordContext,
              case .acceptedEntry(let pendingRequest) = context.browseResumeIntent,
              !isArchiveEntryPreviewRequestCurrent(pendingRequest) else { return }
        invalidateBrowsePasswordOperationIfPending()
    }

    /// Only an accepted, current preview failure may stage the existing browse password owner.
    package func acceptArchiveEntryPreviewFailure(
        _ failure: ArchiveEntryPreviewFailure, request: ArchiveEntryPreviewRequest
    ) {
        guard isArchiveEntryPreviewRequestCurrent(request),
              case .archive(let error, let attemptedPassword) = failure,
              error.isPasswordRelated else { return }
        invalidateStaleAcceptedEntryPasswordPromptIfNeeded()
        guard pendingPasswordContext == nil else { return }
        stagePasswordPromptContext(
            archivePath: request.archivePath, kind: .browse, failedPassword: attemptedPassword
        )
        pendingPasswordContext?.browseResumeIntent = .acceptedEntry(request)
    }

    package func shouldRetryArchiveEntryPreview(
        _ request: ArchiveEntryPreviewRequest, notification: Notification
    ) -> Bool {
        guard isArchiveEntryPreviewRequestCurrent(request),
              let path = notification.object as? String,
              notification.userInfo?["previewEntryPath"] as? String == request.entryPath,
              URL(fileURLWithPath: path).standardizedFileURL.path
                == URL(fileURLWithPath: request.archivePath).standardizedFileURL.path else { return false }
        return notification.userInfo?["windowID"] as? UUID == windowID
    }

    /// Closing the archive leaves its virtual location instead of reopening the discarded snapshot.
    internal func leaveClosedArchiveLocation() {
        let location = navigationState.currentDirectory
        guard AcceptedArchiveDirectoryProjection.archiveSubpath(in: location) != nil else { return }
        navigationState.navigateTo(URL(fileURLWithPath: location.path).deletingLastPathComponent())
    }

    /// Refreshes through the same ticketed reader and keeps the accepted browsing location.
    public func refreshAcceptedArchive(at directoryURL: URL) async {
        guard let session = navigationState.activeTabSession,
              AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(directoryURL),
              AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(session.historyStack.current),
              session.historyStack.current.path == directoryURL.path,
              session.archivePath == directoryURL.path || explorerState.acceptedArchiveProjection(
                for: session.id, archivePath: directoryURL.path
              ) != nil else { return }
        let location = session.historyStack.current
        invalidateAcceptedArchiveResources(archivePath: location.path)
        _ = await loadArchiveWithTicket(
            path: location.path, restoringLocation: location
        )
    }

    /// A mutation invalidates this window's snapshots, not unrelated foreground work.
    public func archiveContentsDidChange(at archivePath: String) async {
        let canonicalPath = URL(fileURLWithPath: archivePath).standardizedFileURL.path
        if let session = navigationState.activeTabSession,
           AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(session.historyStack.current),
           session.historyStack.current.standardizedFileURL.path == canonicalPath,
           session.archivePath == canonicalPath || explorerState.acceptedArchiveProjection(
               for: session.id, archivePath: canonicalPath
           ) != nil {
            await refreshAcceptedArchive(at: session.historyStack.current)
        } else {
            explorerState.invalidateAcceptedArchiveProjections(archivePath: canonicalPath)
        }
    }

    /// Uses the session's committed location, even while currentDirectory is being restored.
    internal func restoreAcceptedArchiveAtCurrentLocation() {
        guard !isWindowClosing, let session = navigationState.activeTabSession else { return }
        let location = session.historyStack.current
        let restored = AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(location)
            && restoreAcceptedArchiveResources(
            for: session.id, archivePath: location.path
        )
        navigationState.setAcceptedArchiveContext(
            path: restored ? location.path : nil, forTab: session.id
        )
        if !restored {
            explorerState.currentArchivePath = nil
            explorerState.currentEntries = []
            explorerState.activePassword = nil
            passwordEvidenceState = .notEncrypted
            AppIntentDispatcher.shared.unregisterSession(id: windowID)
            reloadMissingArchiveProjection(at: location, sessionID: session.id)
        }
        pruneUnreachableArchiveResources()
    }

    /// An accepted virtual location remains an archive location after its snapshot expires.
    private func reloadMissingArchiveProjection(at location: URL, sessionID: UUID) {
        guard AcceptedArchiveDirectoryProjection.archiveSubpath(in: location) != nil else { return }
        let expectedEpoch = operationEpoch
        Task { @MainActor [weak self] in
            guard let self, !self.isWindowClosing,
                  self.operationEpoch == expectedEpoch,
                  self.navigationState.activeSessionID == sessionID,
                  self.navigationState.activeTabSession?.historyStack.current == location else { return }
            _ = await self.loadArchiveWithTicket(path: location.path, restoringLocation: location)
        }
    }

    /// Reachability is derived from existing navigation history, not a new cache policy.
    internal func pruneUnreachableArchiveResources() {
        var reachable: [UUID: Set<String>] = [:]
        for tab in navigationState.tabSessions {
            let locations = tab.historyStack.backStack + [tab.historyStack.current]
                + tab.historyStack.forwardStack
            reachable[tab.id] = Set(locations.filter(\.isFileURL).map {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path
            })
        }
        explorerState.pruneAcceptedArchiveProjections(reachablePaths: reachable)
    }
}
