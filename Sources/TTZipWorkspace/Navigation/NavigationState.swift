// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import TTZipUI

/// Window layout presentation mode for standard and immersive media focus states.
public enum WindowLayoutMode: Sendable, Hashable {
    case standard
    case mediaFocus
}

/// Navigation and routing state for one window.
@Observable
@MainActor
public final class NavigationState {
    public var activeTab: WorkspaceTab = .home
    public var isInspectorVisible: Bool = true
    public var isLeftSidebarVisible: Bool = true
    private var isNavigatingHistory: Bool = false

    /// Invoked when the active browsing context changes.
    ///
    /// The owning view state uses it to abandon foreground work that was bound to the page the
    /// user just left, so that a late result can never land on the page the user navigated to.
    @ObservationIgnored public var onActiveBrowsingContextChange: (@MainActor () -> Void)?
    @ObservationIgnored package var onSessionsRetired: (@MainActor ([UUID]) -> Void)?

    /// Suppresses the context-change callback while already committed state is applied.
    ///
    /// Committing an archive into the active tab writes its accepted virtual location. That is
    /// state the owner applies on purpose and not a navigation, so it must not invalidate the
    /// request that is committing it.
    @ObservationIgnored private var isApplyingCommittedState: Bool = false

    public var currentDirectory: URL {
        didSet {
            if !isNavigatingHistory, let active = activeTabSession, !active.kind.isCompressWorkspace {
                updateActiveURL(currentDirectory)
            }
            guard !isApplyingCommittedState else { return }
            onActiveBrowsingContextChange?()
        }
    }
    public var isOmnibarFocused: Bool = false
    public var layoutMode: WindowLayoutMode = .standard

    // MARK: - Multi-Directory Tab Session State (SSOT)
    public private(set) var tabSessions: [WorkspaceTabSession] {
        didSet {
            let liveIDs = Set(tabSessions.map(\.id))
            let retired = oldValue.map(\.id).filter { !liveIDs.contains($0) }
            if !retired.isEmpty { onSessionsRetired?(retired) }
        }
    }
    public private(set) var activeTabIndex: Int = 0
    public private(set) var activeSessionID: UUID {
        didSet {
            guard oldValue != self.activeSessionID else { return }
            onActiveBrowsingContextChange?()
        }
    }

    /// Read-only presentation projection; session mutations belong to navigation intents.
    public var directoryTabs: [DirectoryTabItem] {
        tabSessions.map { session in
            DirectoryTabItem(
                id: session.id,
                url: session.historyStack.current,
                customTitle: session.customTitle,
                isCompressWorkspace: session.kind.isCompressWorkspace,
                isStorageInspector: session.kind.isStorageInspector,
                history: session.historyStack.backStack + [session.historyStack.current] + session.historyStack.forwardStack.reversed(),
                historyIndex: session.historyStack.backStack.count
            )
        }
    }

    public var activeTabSession: WorkspaceTabSession? {
        tabSessions.first(where: { $0.id == activeSessionID })
    }

    public var activeDirectoryTab: DirectoryTabItem? {
        guard directoryTabs.indices.contains(activeTabIndex) else { return nil }
        return directoryTabs[activeTabIndex]
    }

    public var isCompressWorkspaceActive: Bool {
        activeTabSession?.kind.isCompressWorkspace == true
    }

    public var isStorageInspectorActive: Bool {
        activeTabSession?.kind.isStorageInspector == true || currentDirectory.absoluteString == "ttzip://storage-inspector"
    }

    @ObservationIgnored private let replacementDirectory: @MainActor () -> URL

    public init(
        initialDirectory: URL,
        replacementDirectory: @escaping @MainActor () -> URL
    ) {
        let initialSession = WorkspaceTabSession(url: initialDirectory)
        self.replacementDirectory = replacementDirectory
        self.currentDirectory = initialDirectory
        self.tabSessions = [initialSession]
        self.activeSessionID = initialSession.id
    }

    public func triggerOmnibarFocus() {
        self.isOmnibarFocused = true
    }

    public func toggleMediaFocusMode() {
        layoutMode = (layoutMode == .standard ? .mediaFocus : .standard)
    }

    public func setLayoutMode(_ mode: WindowLayoutMode) {
        self.layoutMode = mode
    }

    // MARK: - Tab Management Operations

    /// Shows a directory in a browsing session, replacing the active tool slot only if needed.
    public func showDirectory(at url: URL) {
        guard tabSessions.indices.contains(activeTabIndex) else { return }
        let targetURL = url.standardizedFileURL
        switch tabSessions[activeTabIndex].kind {
        case .compressWorkspace, .storageInspector:
            if let browsingIndex = tabSessions.firstIndex(where: { $0.kind.isDirectory || $0.kind.isArchive }) {
                switchToTab(at: browsingIndex)
            } else {
                let session = WorkspaceTabSession(url: targetURL)
                tabSessions[activeTabIndex] = session
                activeSessionID = session.id
            }
        case .directory, .archive:
            break
        }
        clearArchiveForActiveTab()
        activeTab = .home
        currentDirectory = targetURL
    }

    @discardableResult
    public func openTab(session: WorkspaceTabSession) -> UUID {
        tabSessions.append(session)
        activeTabIndex = tabSessions.count - 1
        activeSessionID = session.id
        if session.kind.isCompressWorkspace {
            activeTab = .compressWorkspace
        } else {
            activeTab = .home
            currentDirectory = session.historyStack.current
        }
        return session.id
    }

    @discardableResult
    public func openTab(url: URL? = nil) -> UUID {
        let targetURL = url ?? currentDirectory
        return openTab(session: WorkspaceTabSession(url: targetURL))
    }

    public func openNewTab(url: URL? = nil) {
        _ = openTab(url: url)
    }

    public func openCompressWorkspaceTab() {
        if let existing = tabSessions.first(where: { $0.kind.isCompressWorkspace }) {
            switchToTab(id: existing.id)
        } else {
            let session = WorkspaceTabSession(url: URL(string: "ttzip://compress-workspace")!, kind: .compressWorkspace, customTitle: nil)
            _ = openTab(session: session)
        }
        activeTab = .compressWorkspace
    }

    public func closeCompressWorkspaceTab() {
        if let existing = tabSessions.first(where: { $0.kind.isCompressWorkspace }) {
            closeTab(id: existing.id)
        }
    }

    public func openStorageInspectorTab() {
        let storageURL = URL(string: "ttzip://storage-inspector")!
        if let existing = tabSessions.first(where: { $0.kind.isStorageInspector }) {
            switchToTab(id: existing.id)
            currentDirectory = storageURL
        } else {
            let session = WorkspaceTabSession(url: storageURL, kind: .storageInspector, customTitle: nil)
            _ = openTab(session: session)
            currentDirectory = storageURL
        }
        activeTab = .home
    }

    public func closeStorageInspectorTab() {
        if let existing = tabSessions.first(where: { $0.kind.isStorageInspector }) {
            closeTab(id: existing.id)
        }
    }

    public func closeTab(id: UUID) {
        guard let index = tabSessions.firstIndex(where: { $0.id == id }) else { return }
        closeTab(at: index)
    }

    public func closeTab(at index: Int) {
        guard tabSessions.indices.contains(index) else { return }

        let closingSession = tabSessions[index]
        if tabSessions.count == 1 {
            if closingSession.kind.isCompressWorkspace || closingSession.kind.isStorageInspector || closingSession.kind.isArchive {
                let defaultURL = replacementDirectory()
                let defaultSession = WorkspaceTabSession(url: defaultURL)
                tabSessions[0] = defaultSession
                activeSessionID = defaultSession.id
                activeTabIndex = 0
                currentDirectory = defaultURL
                activeTab = .home
            }
            return
        }

        tabSessions.remove(at: index)
        if index < activeTabIndex {
            activeTabIndex -= 1
        } else if activeTabIndex >= tabSessions.count {
            activeTabIndex = max(0, tabSessions.count - 1)
        }

        if tabSessions.indices.contains(activeTabIndex), closingSession.id == activeSessionID {
            let active = tabSessions[activeTabIndex]
            activeSessionID = active.id
            if active.kind.isCompressWorkspace {
                activeTab = .compressWorkspace
            } else {
                activeTab = .home
                currentDirectory = active.historyStack.current
            }
        }
    }

    public func switchToTab(id: UUID) {
        guard let index = tabSessions.firstIndex(where: { $0.id == id }) else { return }
        switchToTab(at: index)
    }

    public func switchToTab(at index: Int) {
        guard tabSessions.indices.contains(index) else { return }
        activeTabIndex = index
        let session = tabSessions[index]
        activeSessionID = session.id
        if session.kind.isCompressWorkspace {
            activeTab = .compressWorkspace
        } else {
            activeTab = .home
            currentDirectory = session.historyStack.current
        }
    }

    public func selectTab(id: UUID) {
        switchToTab(id: id)
    }

    public func selectTab(at index: Int) {
        switchToTab(at: index)
    }

    public func selectNextTab() {
        guard !tabSessions.isEmpty else { return }
        let nextIndex = (activeTabIndex + 1) % tabSessions.count
        switchToTab(id: tabSessions[nextIndex].id)
    }

    public func selectPreviousTab() {
        guard !tabSessions.isEmpty else { return }
        let prevIndex = (activeTabIndex - 1 + tabSessions.count) % tabSessions.count
        switchToTab(id: tabSessions[prevIndex].id)
    }

    public func updateActiveURL(_ newURL: URL) {
        guard tabSessions.indices.contains(activeTabIndex) else { return }
        if tabSessions[activeTabIndex].historyStack.current != newURL {
            tabSessions[activeTabIndex].historyStack.push(newURL)
        }
    }

    public func updateActiveTabURL(_ newURL: URL) {
        updateActiveURL(newURL)
    }

    public func updateTabURL(id: UUID, newURL: URL) {
        guard let index = tabSessions.firstIndex(where: { $0.id == id }) else { return }
        if tabSessions[index].historyStack.current != newURL {
            tabSessions[index].historyStack.push(newURL)
            if activeSessionID == id {
                currentDirectory = newURL
            }
        }
    }

    public func setArchiveForActiveTab(path: String) {
        guard tabSessions.indices.contains(activeTabIndex) else { return }
        setArchive(path: path, forTab: tabSessions[activeTabIndex].id)
    }

    public func setArchive(path: String, forTab id: UUID, restoringLocation: URL? = nil) {
        guard let index = tabSessions.firstIndex(where: { $0.id == id }) else { return }
        let root = URL(fileURLWithPath: path).appending(queryItems: [URLQueryItem(name: "subpath", value: "")])
        let url = restoringLocation.flatMap {
            $0.isFileURL && $0.standardizedFileURL.path == root.standardizedFileURL.path ? $0 : nil
        } ?? root
        setAcceptedArchiveContext(path: path, forTab: id)
        tabSessions[index].historyStack.push(url)
        if activeSessionID == id {
            isApplyingCommittedState = true
            currentDirectory = url
            isApplyingCommittedState = false
        }
    }

    /// Restores presentation metadata without adding a second history entry.
    package func setAcceptedArchiveContext(path: String?, forTab id: UUID) {
        guard let index = tabSessions.firstIndex(where: { $0.id == id }) else { return }
        if let path {
            tabSessions[index].kind = .archive(path: path)
            tabSessions[index].customTitle = URL(fileURLWithPath: path).lastPathComponent
        } else if tabSessions[index].kind.isArchive {
            tabSessions[index].kind = .directory
            tabSessions[index].customTitle = nil
        }
    }

    public func clearArchiveForActiveTab() {
        guard tabSessions.indices.contains(activeTabIndex) else { return }
        clearArchive(forTab: tabSessions[activeTabIndex].id)
    }

    public func clearArchive(forTab id: UUID) {
        guard let index = tabSessions.firstIndex(where: { $0.id == id }) else { return }
        if tabSessions[index].kind.isArchive {
            tabSessions[index].kind = .directory
            tabSessions[index].customTitle = nil
        }
    }

    // MARK: - History Navigation Operations

    public var canGoBack: Bool {
        activeTabSession?.historyStack.canGoBack ?? false
    }

    public var canGoForward: Bool {
        activeTabSession?.historyStack.canGoForward ?? false
    }

    public var canGoUp: Bool {
        activeTabSession?.historyStack.canGoUp ?? false
    }

    public var backHistoryList: [URL] {
        guard let session = activeTabSession else { return [] }
        return session.historyStack.backList
    }

    public var forwardHistoryList: [URL] {
        guard let session = activeTabSession else { return [] }
        return session.historyStack.forwardList
    }

    public func navigateTo(_ targetURL: URL) {
        let canonical = WorkspaceHistoryStack.standardizedLocation(targetURL)
        guard tabSessions.indices.contains(activeTabIndex) else {
            currentDirectory = canonical
            return
        }
        tabSessions[activeTabIndex].historyStack.navigateToHistoryItem(canonical)
        isNavigatingHistory = true
        currentDirectory = canonical
        isNavigatingHistory = false
    }

    public func goBack() {
        guard tabSessions.indices.contains(activeTabIndex),
              let target = tabSessions[activeTabIndex].historyStack.goBack() else { return }
        isNavigatingHistory = true
        currentDirectory = target
        isNavigatingHistory = false
    }

    public func goForward() {
        guard tabSessions.indices.contains(activeTabIndex),
              let target = tabSessions[activeTabIndex].historyStack.goForward() else { return }
        isNavigatingHistory = true
        currentDirectory = target
        isNavigatingHistory = false
    }

    public func goUp() {
        guard tabSessions.indices.contains(activeTabIndex),
              let target = tabSessions[activeTabIndex].historyStack.goUp() else { return }
        isNavigatingHistory = true
        currentDirectory = target
        isNavigatingHistory = false
    }
}
