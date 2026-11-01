// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
#if canImport(TTZipAppServices)
import TTZipAppServices
#endif

public enum IntentDispatchResult: Sendable, Equatable {
    case success
    case rejected(reason: String)
    case queued
}

@MainActor
public final class AppIntentDispatcher {
    public static let shared = AppIntentDispatcher()

    private struct WeakStateBox {
        weak var state: AppViewState?
    }

    private weak var appViewState: AppViewState?
    private var statesByWindowID: [UUID: WeakStateBox] = [:]
    private var registeredSessions: [UUID: ArchiveSessionContext] = [:]
    
    private init() {}
    
    public func bind(state: AppViewState) {
        self.appViewState = state
        self.statesByWindowID[state.windowID] = WeakStateBox(state: state)
        BrowserWindowRegistry.shared.register(state)
        syncWindowArchiveSession(for: state)
    }

    public func unregister(windowID: UUID) {
        statesByWindowID.removeValue(forKey: windowID)
        registeredSessions.removeValue(forKey: windowID)
        if appViewState?.windowID == windowID {
            appViewState = BrowserWindowRegistry.shared.activeController as? AppViewState
        }
    }

    public func syncWindowArchiveSession(for state: AppViewState) {
        guard !state.isWindowClosing,
              BrowserWindowRegistry.shared.controller(for: state.windowID) != nil,
              let path = state.explorerState.currentArchivePath,
              !path.isEmpty else {
            registeredSessions.removeValue(forKey: state.windowID)
            return
        }
        let session = registeredSessions[state.windowID] ?? ArchiveSessionContext(
            id: state.windowID,
            initialURL: URL(fileURLWithPath: path)
        )
        session.currentArchivePath = path
        session.currentEntries = state.explorerState.currentEntries
        session.activePassword = state.explorerState.activePassword
        session.windowTitle = (path as NSString).lastPathComponent
        registeredSessions[state.windowID] = session
    }

    public var resolvedActiveState: AppViewState? {
        if let activeID = BrowserWindowRegistry.shared.activeWindowID,
           let state = statesByWindowID[activeID]?.state {
            return state
        }
        if let activeCtrl = BrowserWindowRegistry.shared.activeController as? AppViewState {
            return activeCtrl
        }
        return appViewState
    }

    public func registerSession(_ session: ArchiveSessionContext) {
        registeredSessions[session.id] = session
    }

    public func unregisterSession(id: UUID) {
        registeredSessions.removeValue(forKey: id)
    }

    public func activeSession(for path: String) -> ArchiveSessionContext? {
        let canonical = BrowserWindowRouter.canonicalFilePath(path) ?? path
        return registeredSessions.values.first {
            (BrowserWindowRouter.canonicalFilePath($0.currentArchivePath) ?? $0.currentArchivePath) == canonical
        }
    }

    public var allSessions: [ArchiveSessionContext] {
        Array(registeredSessions.values)
    }
    
    @discardableResult
    public func dispatch(_ envelope: AppIntentEnvelope, targetWindowID: UUID? = nil) -> IntentDispatchResult {
        let resolved: AppViewState? = {
            if let targetWindowID {
                return statesByWindowID[targetWindowID]?.state
                    ?? (BrowserWindowRegistry.shared.controller(for: targetWindowID) as? AppViewState)
            }
            return resolvedActiveState
        }()
        guard let state = resolved else {
            envelope.bookmarkSession?.invalidate()
            return .rejected(reason: "AppViewState is not bound to dispatcher")
        }

        // Bring application to foreground
        NSApplication.shared.activate(ignoringOtherApps: true)
        let bookmarkSession = envelope.bookmarkSession

        switch envelope.intent {
        case .openArchive(let url, let password):
            state.activeTab = .home
            state.openArchiveAsFolder(url: url, password: password, bookmarkSession: bookmarkSession)
            return .success

        case .navigateToDirectory(let url):
            defer { bookmarkSession?.invalidate() }
            if let bookmarkSession {
                for scopedURL in bookmarkSession.urls {
                    _ = RootFolderAccessManager.shared.persistBookmark(for: scopedURL)
                }
            }
            state.closeCurrentArchive()
            state.activeTab = .home
            state.currentDirectory = url
            state.selectedDiskItem = nil
            return .success

        case .switchTab(let tab):
            defer { bookmarkSession?.invalidate() }
            state.activeTab = tab
            return .success

        case .pickAndOpenArchive:
            defer { bookmarkSession?.invalidate() }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                state.openArchiveAsFolder(url: url)
            }
            return .success

        case .createArchive(let sourcePaths, let options):
            state.openCompressWorkspace(
                paths: sourcePaths,
                options: options,
                bookmarkSession: bookmarkSession
            )
            return .success

        case .extractArchive(let archivePaths, let options):
            dispatchExtraction(
                archivePaths: archivePaths,
                options: options,
                state: state,
                bookmarkSession: bookmarkSession
            )
            return .success

        case .inspectArchive(let archivePath):
            defer { bookmarkSession?.invalidate() }
            state.overlayState.inspectingArchivePath = archivePath
            state.overlayState.showArchiveInspectorModal = true
            return .success

        case .verifyIntegrity(let archivePath):
            defer { bookmarkSession?.invalidate() }
            state.overlayState.integrityArchivePath = archivePath
            state.overlayState.showArchiveIntegrityModal = true
            return .success

        case .autofillVaultPassword(let archivePath):
            Task {
                defer { bookmarkSession?.invalidate() }
                await state.loadArchive(path: archivePath, password: nil, bookmarkSession: bookmarkSession)
            }
            return .success

        case .promptPassword(let archivePath):
            defer { bookmarkSession?.invalidate() }
            state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)
            return .success

        case .addFilesToArchive(let archivePath, let sourcePaths, let destinationSubfolder):
            Task {
                defer { bookmarkSession?.invalidate() }
                do {
                    try await InPlaceMutationCoordinator.shared.appendFiles(
                        archivePath: archivePath,
                        sourceFilePaths: sourcePaths,
                        destinationVirtualFolder: destinationSubfolder,
                        password: state.activePassword
                    )
                    await state.loadArchive(path: archivePath, password: state.activePassword, bookmarkSession: bookmarkSession)
                } catch {
                    AppErrorReporter.shared.reportError(error, contextTitle: "Failed to Add Files to Archive")
                }
            }
            return .success

        case .deleteArchiveEntries(let archivePath, let entryPaths):
            Task {
                defer { bookmarkSession?.invalidate() }
                do {
                    try await InPlaceMutationCoordinator.shared.deleteEntries(
                        archivePath: archivePath,
                        entryPaths: entryPaths,
                        password: state.activePassword
                    )
                    await state.loadArchive(path: archivePath, password: state.activePassword, bookmarkSession: bookmarkSession)
                } catch {
                    AppErrorReporter.shared.reportError(error, contextTitle: "Failed to Delete Archive Entries")
                }
            }
            return .success

        case .openWithDefaultApp(let url):
            defer { bookmarkSession?.invalidate() }
            _ = state.openFileWithDefaultApp(url: url)
            return .success

        case .previewItem(let url):
            defer { bookmarkSession?.invalidate() }
            state.previewMediaFile(path: url.path)
            return .success

        case .quickPeek(let urls):
            defer { bookmarkSession?.invalidate() }
            if let first = urls.first {
                state.previewMediaFile(path: first.path)
            }
            return .success

        case .revealInFinder(let url):
            defer { bookmarkSession?.invalidate() }
            state.fileViewer.revealInFinder(at: url.path)
            return .success

        case .showAdbGuide:
            defer { bookmarkSession?.invalidate() }
            AndroidDeviceViewModel.shared.showAdbGuideSheet = true
            return .success
        }
    }

    @discardableResult
    public func dispatch(_ intent: AppIntent, from source: AppIntentSource) -> IntentDispatchResult {
        let envelope = AppIntentEnvelope(intent: intent, source: source)
        return dispatch(envelope)
    }

    /// Routes an extraction intent: a non-empty `targetEntrySubpaths` extracts only those entries,
    /// otherwise each archive is extracted whole. `forceKeepBoth` suppresses prompting in both cases.
    @discardableResult
    package func dispatchExtraction(
        archivePaths: [String],
        options: ExtractIntentOptions,
        state: AppViewState,
        bookmarkSession: ActiveBookmarkSession? = nil
    ) -> [Task<Void, Never>] {
        guard !archivePaths.isEmpty else {
            bookmarkSession?.invalidate()
            return []
        }
        let forcedHandling: CollisionHandling? = options.forceKeepBoth ? .policy(.keepBoth) : nil
        let subpaths = options.targetEntrySubpaths ?? []
        var remainingCount = archivePaths.count

        let finishTaskSession: @MainActor () -> Void = {
            remainingCount -= 1
            if remainingCount <= 0 {
                bookmarkSession?.invalidate()
            }
        }

        return archivePaths.map { path in
            if subpaths.isEmpty {
                return Task { @MainActor in
                    defer { finishTaskSession() }
                    await state.quickExtractArchive(
                        archivePath: path,
                        targetDir: options.destinationDirectory?.path,
                        password: options.password,
                        isSmartExtract: options.isSmartExtract,
                        trashSourceAfterExtract: options.deleteSourceAfterExtraction,
                        collisionHandling: forcedHandling
                    )
                }
            }
            let destination = options.destinationDirectory?.path ?? (path as NSString).deletingLastPathComponent
            return Task { @MainActor in
                defer { finishTaskSession() }
                await state.extractEntries(
                    archivePath: path,
                    entryPaths: subpaths,
                    destinationDir: destination,
                    password: options.password,
                    collisionHandling: forcedHandling
                )
            }
        }
    }
}

extension AppViewState {
    /// Selects a specific entry inside an archive in this window, loading the archive first if not already loaded,
    /// and discarding stale async loads when superseded by a newer search activation or window close.
    @discardableResult
    public func selectArchiveEntryInWindow(
        archivePath: String,
        entrySubpath: String,
        highlightLine: Int? = nil
    ) -> Task<Bool, Never> {
        guard !isWindowClosing else {
            return Task { false }
        }
        searchNavigationGeneration &+= 1
        let requestGen = searchNavigationGeneration
        let canonicalTarget = BrowserWindowRouter.canonicalFilePath(archivePath) ?? archivePath
        let canonicalCurrent = BrowserWindowRouter.canonicalFilePath(explorerState.currentArchivePath)
        let isAlreadyLoaded = canonicalCurrent == canonicalTarget
            && (!explorerState.currentEntries.isEmpty || explorerState.vfsSession != nil)

        if isAlreadyLoaded {
            let activeArchive = explorerState.currentArchivePath ?? archivePath
            selectArchiveEntry(path: entrySubpath, inArchive: activeArchive, highlightLine: highlightLine)
            AppIntentDispatcher.shared.syncWindowArchiveSession(for: self)
            return Task { true }
        }

        let archiveURL = URL(fileURLWithPath: archivePath)
        if navigationState.isCompressWorkspaceActive {
            navigationState.closeCompressWorkspaceTab()
        }
        navigationState.currentDirectory = archiveURL.deletingLastPathComponent()
        navigationState.activeTab = .home

        return Task { @MainActor [weak self] in
            guard let self, !self.isWindowClosing, self.searchNavigationGeneration == requestGen else {
                return false
            }
            let loaded = await self.loadArchive(path: archivePath)
            guard loaded,
                  !Task.isCancelled,
                  !self.isWindowClosing,
                  self.searchNavigationGeneration == requestGen,
                  BrowserWindowRouter.canonicalFilePath(self.explorerState.currentArchivePath) == canonicalTarget else {
                return false
            }
            let activeArchive = self.explorerState.currentArchivePath ?? archivePath
            self.selectArchiveEntry(path: entrySubpath, inArchive: activeArchive, highlightLine: highlightLine)
            AppIntentDispatcher.shared.syncWindowArchiveSession(for: self)
            return true
        }
    }

    public func extractArchiveInWindow(
        at url: URL,
        to destinationURL: URL?,
        password: String?,
        isSmartExtract: Bool,
        trashSourceAfterExtract: Bool,
        bookmarkSession: ActiveBookmarkSession?
    ) {
        _ = extractArchiveNonInteractive(
            at: url,
            to: destinationURL,
            password: password,
            isSmartExtract: isSmartExtract,
            trashSourceAfterExtract: trashSourceAfterExtract,
            collisionHandling: nil,
            bookmarkSession: bookmarkSession
        )
    }

    public func compressFilesInWindow(
        _ urls: [URL],
        to outputURL: URL?,
        format: ArchiveCompressionFormat,
        bookmarkSession: ActiveBookmarkSession?
    ) {
        _ = compressFiles(urls, to: outputURL, format: format, bookmarkSession: bookmarkSession)
    }

    public func openCompressWorkspaceInWindow(
        paths: [String],
        bookmarkSession: ActiveBookmarkSession?
    ) {
        openCompressWorkspace(paths: paths, bookmarkSession: bookmarkSession)
    }

    public func handleFocusedEncryptionPrompt(for archivePath: String) {
        stagePasswordPromptContext(archivePath: archivePath, kind: .browse)
    }

    /// Optional window-local geometry hook registered by `TTZipAppViews` so ViewModel-level inspector visibility
    /// transitions synchronously coordinate the target window's frame without importing `TTZipAppViews`.
    public static var windowInspectorVisibilityCoordinatorHook: (@MainActor (AppViewState, Bool) -> Void)?

    public func setInspectorVisibleInWindow(_ isVisible: Bool) {
        if let hook = Self.windowInspectorVisibilityCoordinatorHook {
            hook(self, isVisible)
        } else {
            navigationState.isInspectorVisible = isVisible
        }
    }

    public func restoreStandaloneOriginPreview(_ session: StandalonePlaybackSessionState) {
        if session.originArchivePath == nil,
           let originDir = session.originDirectoryURL,
           navigationState.currentDirectory != originDir {
            navigationState.currentDirectory = originDir
        }
        let targetItem = session.originSelectedItem ?? DiskItemInfo(url: session.item.url)
        selectionState.selectedDiskItem = targetItem
        selectionState.selectedDiskItems = [targetItem]
        setInspectorVisibleInWindow(true)
    }
}

private struct FocusedAppViewStateKey: FocusedValueKey {
    typealias Value = AppViewState
}

extension FocusedValues {
    public var appViewState: AppViewState? {
        get { self[FocusedAppViewStateKey.self] }
        set { self[FocusedAppViewStateKey.self] = newValue }
    }
}

@MainActor private var selectedEntryIDKey: UInt8 = 0

extension SelectionState {
    /// Active selected archive entry identifier within the archive table view.
    public var selectedEntryID: String? {
        get {
            objc_getAssociatedObject(self, &selectedEntryIDKey) as? String
        }
        set {
            objc_setAssociatedObject(self, &selectedEntryIDKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

