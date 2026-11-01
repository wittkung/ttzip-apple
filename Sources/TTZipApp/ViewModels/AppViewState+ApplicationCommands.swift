// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import TTZipCore
import TTZipUI

// MARK: - Application Command Handling on AppViewState

extension AppViewState {
    /// Executes an application-level command dispatched from the macOS Dock menu or application menu bar.
    @MainActor
    public func handleApplicationCommand(_ command: ApplicationWindowCommand) {
        switch command {
        case .openNewWindow:
            _ = BrowserWindowRouter.shared.openNewWindow(with: navigationState.currentDirectory)

        case .presentNewSmartFolder(let initialScopeDirectory):
            navigationState.activeTab = .home
            overlayState.editingSmartFolderID = nil
            overlayState.smartFolderInitialScopeURL = initialScopeDirectory ?? effectiveDisplayDirectory
            overlayState.showSmartFolderModal = true

        case .openSmartFolder(let id):
            activateSmartFolder(id: id)

        case .focusFind(let initialQuery):
            navigationState.activeTab = .home
            if let q = initialQuery, !q.isEmpty {
                explorerState.searchQuery = q
            }
            overlayState.findFocusRequestGeneration &+= 1

        case .presentGoToFolder(let initialPath):
            navigationState.activeTab = .home
            overlayState.goToFolderInitialPath = initialPath ?? effectiveDisplayDirectory.path
            overlayState.showGoToFolderModal = true

        case .presentConnectToServer(let initialAddress):
            navigationState.activeTab = .home
            overlayState.connectToServerInitialAddress = initialAddress
            overlayState.showConnectToServerModal = true

        case .navigateToFavoriteLocation(let path, let bookmarkData, let healthState):
            handleNavigateToFavoriteLocation(
                path: path,
                bookmarkData: bookmarkData,
                healthState: healthState
            )

        case .openRecentItem(let item):
            handleOpenRecentLocationItem(item)
        }
    }

    // MARK: - Smart Folder Activation & Structured Criteria Consumption

    /// Activates a saved Smart Folder in the current browser window by ID, preserving full structured criteria.
    @MainActor
    public func activateSmartFolder(id: UUID, store: SmartFolderStore = .shared) {
        guard let record = store.record(for: id) else {
            let l10n = AppLocalizationState.shared
            taskState.statusMessage = l10n.uiString(
                zh: "未找到该智能文件夹，可能已被删除。",
                en: "The smart folder could not be found and may have been deleted."
            )
            return
        }
        activateSmartFolder(record: record, store: store)
    }

    /// Executes and displays a saved `SmartFolderRecord` (both `.directory` and `.fullDisk` scopes)
    /// as a live structured result view in the current browser window.
    @MainActor
    public func activateSmartFolder(record: SmartFolderRecord, store: SmartFolderStore = .shared) {
        overlayState.activeSmartFolderEvaluationTask?.cancel()
        overlayState.activeSmartFolderGeneration &+= 1
        let expectedGeneration = overlayState.activeSmartFolderGeneration

        navigationState.activeTab = .home
        overlayState.activeSmartFolderID = record.id
        overlayState.activeSmartFolderRecord = record
        overlayState.activeSmartFolderResult = SmartFolderEvaluationResult(
            recordID: record.id,
            items: [],
            phase: .loading,
            coverage: ExplorerSearchCoverageNote(scopeDescription: store.scopeDisplayDescription(for: record.scope)),
            isScopeUnauthorized: false,
            isCancelled: false
        )
        overlayState.isEvaluatingSmartFolder = true

        switch record.scope {
        case .directory(let dirPath, _):
            let dirURL = URL(fileURLWithPath: dirPath).standardizedFileURL
            if navigationState.currentDirectory.standardizedFileURL.path != dirURL.path || explorerState.currentArchivePath != nil {
                navigateToDirectory(dirURL)
            }
            // Never inject literal "*" for kind-only queries; keep searchQuery aligned with nameQuery only.
            explorerState.searchQuery = record.criteria.nameQuery

        case .fullDisk:
            break
        }

        let evaluationTask = Task { @MainActor [weak self] in
            let evaluation = await store.evaluate(record: record)
            guard let self,
                  !self.isWindowClosing,
                  self.overlayState.activeSmartFolderGeneration == expectedGeneration,
                  self.overlayState.activeSmartFolderID == record.id else {
                return
            }
            self.overlayState.activeSmartFolderResult = evaluation
            self.overlayState.isEvaluatingSmartFolder = false
        }
        overlayState.activeSmartFolderEvaluationTask = evaluationTask
    }

    /// Saves a new or edited Smart Folder and immediately activates its structured query in the window.
    @MainActor
    @discardableResult
    public func saveAndActivateSmartFolder(
        editingID: UUID?,
        name: String,
        criteria: SmartFolderCriteria,
        scope: SmartFolderSearchScope,
        store: SmartFolderStore = .shared,
        onDismiss: (() -> Void)? = nil
    ) throws -> SmartFolderRecord {
        let effectiveName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? criteria.effectiveScannerQuery
            : name
        let saved: SmartFolderRecord
        if let existingID = editingID {
            saved = try store.updateSmartFolder(
                id: existingID,
                name: effectiveName,
                criteria: criteria,
                scope: scope
            )
        } else {
            saved = try store.createSmartFolder(
                name: effectiveName,
                criteria: criteria,
                scope: scope
            )
        }
        onDismiss?()
        activateSmartFolder(record: saved, store: store)
        return saved
    }

    /// Re-evaluates the currently active Smart Folder against live filesystem state.
    @MainActor
    public func refreshActiveSmartFolder(store: SmartFolderStore = .shared) {
        guard let activeID = overlayState.activeSmartFolderID else { return }
        if let latest = store.record(for: activeID) {
            activateSmartFolder(record: latest, store: store)
        } else if let cached = overlayState.activeSmartFolderRecord {
            activateSmartFolder(record: cached, store: store)
        }
    }

    /// Closes the active Smart Folder result view and cancels any in-flight evaluation.
    @MainActor
    public func deactivateSmartFolder() {
        overlayState.activeSmartFolderEvaluationTask?.cancel()
        overlayState.activeSmartFolderEvaluationTask = nil
        overlayState.activeSmartFolderGeneration &+= 1
        overlayState.activeSmartFolderID = nil
        overlayState.activeSmartFolderRecord = nil
        overlayState.activeSmartFolderResult = nil
        overlayState.isEvaluatingSmartFolder = false
    }

    /// Waits for the currently active Smart Folder evaluation task to finish (used by deterministic integration tests).
    @MainActor
    public func waitForActiveSmartFolderEvaluation() async {
        if let task = overlayState.activeSmartFolderEvaluationTask {
            await task.value
        }
    }

    // MARK: - Favorite Location Navigation with Non-Destructive Health Check

    @MainActor
    private func handleNavigateToFavoriteLocation(
        path: String,
        bookmarkData: Data?,
        healthState: SidebarItemHealthState
    ) {
        if let bm = bookmarkData {
            RootFolderAccessManager.shared.registerSecurityScopedBookmark(bm, for: path)
        }

        let targetURL = URL(fileURLWithPath: path).standardizedFileURL
        let l10n = AppLocalizationState.shared

        // Probe without triggering cloud dataless downloads or deleting any files.
        let existsLocally = DatalessProtection.withMaterializationDisabled {
            var st = stat()
            return lstat(targetURL.path, &st) == 0
        }

        guard existsLocally else {
            switch healthState {
            case .unmountedVolume, .mounting:
                taskState.statusMessage = l10n.uiString(
                    zh: "外置卷或网络共享未挂载：\(targetURL.lastPathComponent)",
                    en: "External volume or network share is not mounted: \(targetURL.lastPathComponent)"
                )
            case .missing, .accessible, .datalessCloud, .warning:
                taskState.statusMessage = l10n.uiString(
                    zh: "常用位置不可用或已移动：\(targetURL.path)",
                    en: "Favorite location is unavailable or has moved: \(targetURL.path)"
                )
            }
            return
        }

        if !FileManager.default.isReadableFile(atPath: targetURL.path) {
            taskState.statusMessage = l10n.uiString(
                zh: "需要文件夹访问授权才能打开：\(targetURL.lastPathComponent)",
                en: "Folder access permission is required to open: \(targetURL.lastPathComponent)"
            )
            return
        }

        navigateToDirectory(targetURL)
    }

    // MARK: - Recent Location Item Navigation

    @MainActor
    private func handleOpenRecentLocationItem(_ item: RecentLocationItem) {
        if let bm = item.bookmarkData {
            RootFolderAccessManager.shared.registerSecurityScopedBookmark(bm, for: item.path)
        }

        let targetURL = URL(fileURLWithPath: item.path).standardizedFileURL
        let l10n = AppLocalizationState.shared

        let existsLocally = DatalessProtection.withMaterializationDisabled {
            var st = stat()
            return lstat(targetURL.path, &st) == 0
        }

        guard existsLocally else {
            taskState.statusMessage = l10n.uiString(
                zh: "最近使用的项目不存在或已移动：\(targetURL.lastPathComponent)",
                en: "Recent item no longer exists or has moved: \(targetURL.lastPathComponent)"
            )
            return
        }

        switch item.kind {
        case .directory:
            navigateToDirectory(targetURL)
        case .archive:
            navigationState.activeTab = .home
            openArchiveAsFolder(url: targetURL)
            RecentLocationsStore.shared.recordArchive(url: targetURL, bookmarkData: item.bookmarkData)
        }
    }
}

extension GoToFolderNavigationService {
    @MainActor
    @discardableResult
    public func submitAndNavigate(
        in viewModel: AppViewState,
        onDismiss: (() -> Void)? = nil
    ) async -> Result<GoToFolderResolvedTarget, GoToFolderValidationError> {
        await submit(baseDirectory: viewModel.effectiveDisplayDirectory) { [weak viewModel] target in
            guard let viewModel, !viewModel.isWindowClosing else { return }
            Self.commitTarget(target, in: viewModel)
            onDismiss?()
        }
    }

    @MainActor
    public func beginSubmitAndNavigate(
        in viewModel: AppViewState,
        onDismiss: (() -> Void)? = nil
    ) {
        beginSubmit(baseDirectory: viewModel.effectiveDisplayDirectory) { [weak viewModel] target in
            guard let viewModel, !viewModel.isWindowClosing else { return }
            Self.commitTarget(target, in: viewModel)
            onDismiss?()
        }
    }

    @MainActor
    private static func commitTarget(_ target: GoToFolderResolvedTarget, in viewModel: AppViewState) {
        switch target {
        case .directory(let dirURL):
            viewModel.navigateToDirectory(dirURL)
        case .archiveFile(let archiveURL):
            viewModel.openArchiveAsFolder(url: archiveURL)
            RecentLocationsStore.shared.recordArchive(url: archiveURL)
        case .plainFileReveal(let fileURL):
            viewModel.revealItemInWindow(fileURL)
        }
    }
}

extension ServerConnectionService {
    @MainActor
    @discardableResult
    public func connectAndNavigate(
        rawInput: String,
        defaultScheme: SupportedNetworkShareScheme = .smb,
        allowAuthenticationUI: Bool = true,
        in viewModel: AppViewState,
        onDismiss: (() -> Void)? = nil
    ) async -> Result<URL, ServerConnectionFailureReason> {
        await connect(
            rawInput: rawInput,
            defaultScheme: defaultScheme,
            allowAuthenticationUI: allowAuthenticationUI
        ) { [weak viewModel] mountPointURL in
            guard let viewModel, !viewModel.isWindowClosing else { return }
            viewModel.navigateToDirectory(mountPointURL)
            onDismiss?()
        }
    }

    @MainActor
    public func beginConnectAndNavigate(
        rawInput: String,
        defaultScheme: SupportedNetworkShareScheme = .smb,
        allowAuthenticationUI: Bool = true,
        in viewModel: AppViewState,
        onDismiss: (() -> Void)? = nil
    ) {
        beginConnect(
            rawInput: rawInput,
            defaultScheme: defaultScheme,
            allowAuthenticationUI: allowAuthenticationUI
        ) { [weak viewModel] mountPointURL in
            guard let viewModel, !viewModel.isWindowClosing else { return }
            viewModel.navigateToDirectory(mountPointURL)
            onDismiss?()
        }
    }
}
