// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import Observation
import TTZipCore

/// Initial navigation or archive seed staged for a newly created browser window.
public struct BrowserWindowLaunchSeed: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let initialDirectoryURL: URL?
    public let initialSelectedPath: String?
    public let initialArchiveURL: URL?
    public let initialPassword: String?
    public let initialArchiveEntrySubpath: String?
    public let initialHighlightLine: Int?

    public init(
        id: UUID = UUID(),
        initialDirectoryURL: URL? = nil,
        initialSelectedPath: String? = nil,
        initialArchiveURL: URL? = nil,
        initialPassword: String? = nil,
        initialArchiveEntrySubpath: String? = nil,
        initialHighlightLine: Int? = nil
    ) {
        self.id = id
        self.initialDirectoryURL = initialDirectoryURL
        self.initialSelectedPath = initialSelectedPath
        self.initialArchiveURL = initialArchiveURL
        self.initialPassword = initialPassword
        self.initialArchiveEntrySubpath = initialArchiveEntrySubpath
        self.initialHighlightLine = initialHighlightLine
    }
}

/// Protocol implemented by per-window `AppViewState` instances so `TTZipAppServices`
/// can route window lifecycle, commands, and external file requests without circular module imports.
@MainActor
public protocol BrowserWindowControlling: AnyObject {
    var windowID: UUID { get }
    var currentDirectoryURL: URL { get }
    var currentArchivePath: String? { get }
    var isBrowsingDefaultPristineState: Bool { get }
    var isShowingImmersiveMedia: Bool { get }
    var isWindowClosing: Bool { get }
    var selectedItemPath: String? { get }

    func applyLaunchSeed(_ seed: BrowserWindowLaunchSeed)
    func navigateToDirectory(_ url: URL)
    func revealItemInWindow(_ itemURL: URL)
    @discardableResult
    func receiveExternalFileInWindow(_ fileURL: URL) -> Task<Bool, Never>
    func openArchiveInWindow(at url: URL, password: String?, bookmarkSession: ActiveBookmarkSession?)
    @discardableResult
    func selectArchiveEntryInWindow(archivePath: String, entrySubpath: String, highlightLine: Int?) -> Task<Bool, Never>
    func extractArchiveInWindow(
        at url: URL,
        to destinationURL: URL?,
        password: String?,
        isSmartExtract: Bool,
        trashSourceAfterExtract: Bool,
        bookmarkSession: ActiveBookmarkSession?
    )
    func compressFilesInWindow(
        _ urls: [URL],
        to outputURL: URL?,
        format: ArchiveCompressionFormat,
        bookmarkSession: ActiveBookmarkSession?
    )
    func openCompressWorkspaceInWindow(paths: [String], bookmarkSession: ActiveBookmarkSession?)
    func handleFocusedEncryptionPrompt(for archivePath: String)
    func restoreStandaloneOriginPreview(_ session: StandalonePlaybackSessionState)
    func handleApplicationCommand(_ command: ApplicationWindowCommand)
    func prepareForWindowClose()
}

extension BrowserWindowControlling {
    public var isWindowClosing: Bool { false }
    public var selectedItemPath: String? { nil }
    public func handleApplicationCommand(_ command: ApplicationWindowCommand) {}
    @discardableResult
    public func receiveExternalFileInWindow(_ fileURL: URL) -> Task<Bool, Never> {
        revealItemInWindow(fileURL)
        return Task { true }
    }
}

/// Process-wide registry of live browser windows, focus order (MRU), launch seeds,
/// and single-stream media playback ownership.
@Observable
@MainActor
public final class BrowserWindowRegistry {
    public static let shared = BrowserWindowRegistry()

    private struct WeakControllerBox {
        weak var controller: (any BrowserWindowControlling)?
        weak var nsWindow: NSWindow?
    }

    private var entries: [UUID: WeakControllerBox] = [:]
    private var windowNumberToID: [Int: UUID] = [:]
    public private(set) var mruWindowIDs: [UUID] = []
    public private(set) var activeWindowID: UUID?
    public private(set) var playbackOwnerWindowID: UUID?
    public private(set) var pendingLaunchSeeds: [BrowserWindowLaunchSeed] = []
    /// Queued application commands awaiting registration of a newly created browser window when `windowCount == 0`.
    /// Each queued command is delivered at most once when the first valid controller registers.
    public private(set) var pendingWindowCommands: [ApplicationWindowCommand] = []

    public init() {}

    // MARK: - Launch Seeds & Deferred Window Commands

    public func enqueueLaunchSeed(_ seed: BrowserWindowLaunchSeed) {
        pendingLaunchSeeds.append(seed)
    }

    public func consumeNextLaunchSeed() -> BrowserWindowLaunchSeed? {
        guard !pendingLaunchSeeds.isEmpty else { return nil }
        return pendingLaunchSeeds.removeFirst()
    }

    /// Removes a specific unconsumed launch seed if no window creator consumed it.
    public func discardLaunchSeed(id: UUID) {
        pendingLaunchSeeds.removeAll { $0.id == id }
    }

    public func enqueuePendingWindowCommand(_ command: ApplicationWindowCommand) {
        pendingWindowCommands.append(command)
    }

    public func consumeAllPendingWindowCommands() -> [ApplicationWindowCommand] {
        guard !pendingWindowCommands.isEmpty else { return [] }
        let queued = pendingWindowCommands
        pendingWindowCommands.removeAll()
        return queued
    }

    // MARK: - Window Registration & Focus Tracking

    public func register(_ controller: any BrowserWindowControlling, nsWindow: NSWindow? = nil) {
        pruneDeallocatedEntries()
        guard !controller.isWindowClosing else { return }
        let id = controller.windowID
        let existingWindow = entries[id]?.nsWindow
        let resolvedWindow = nsWindow ?? existingWindow
        entries[id] = WeakControllerBox(controller: controller, nsWindow: resolvedWindow)
        if let resolvedWindow {
            windowNumberToID[resolvedWindow.windowNumber] = id
        }
        promoteInMRU(id)
        if activeWindowID == nil || resolvedWindow?.isKeyWindow == true || resolvedWindow?.isMainWindow == true {
            activeWindowID = id
        }
        let commands = consumeAllPendingWindowCommands()
        if !commands.isEmpty {
            activeWindowID = id
            for cmd in commands {
                controller.handleApplicationCommand(cmd)
            }
        }
    }

    public func bindNSWindow(_ nsWindow: NSWindow, for windowID: UUID) {
        pruneDeallocatedEntries()
        guard var box = entries[windowID], box.controller != nil else { return }
        if let prevWindow = box.nsWindow, prevWindow.windowNumber != nsWindow.windowNumber {
            windowNumberToID.removeValue(forKey: prevWindow.windowNumber)
        }
        box.nsWindow = nsWindow
        entries[windowID] = box
        windowNumberToID[nsWindow.windowNumber] = windowID
        if nsWindow.isKeyWindow || nsWindow.isMainWindow || activeWindowID == nil {
            activateWindow(id: windowID)
        }
    }

    public func activateWindow(id: UUID) {
        pruneDeallocatedEntries()
        guard entries[id]?.controller != nil else { return }
        activeWindowID = id
        promoteInMRU(id)
    }

    public func activateNSWindow(_ nsWindow: NSWindow) {
        pruneDeallocatedEntries()
        if let id = windowNumberToID[nsWindow.windowNumber], entries[id]?.controller != nil {
            activateWindow(id: id)
            return
        }
        for (id, box) in entries where box.nsWindow === nsWindow && box.controller != nil {
            windowNumberToID[nsWindow.windowNumber] = id
            activateWindow(id: id)
            return
        }
    }

    public func unregister(id: UUID) {
        if let box = entries.removeValue(forKey: id) {
            if let win = box.nsWindow {
                windowNumberToID.removeValue(forKey: win.windowNumber)
            }
        }
        windowNumberToID = windowNumberToID.filter { $0.value != id }
        mruWindowIDs.removeAll { $0 == id }
        if playbackOwnerWindowID == id {
            playbackOwnerWindowID = nil
        }
        StandalonePlaybackWindowManager.shared.notifyOriginBrowserWindowClosed(windowID: id)
        pruneDeallocatedEntries()
        if activeWindowID == id {
            activeWindowID = mruWindowIDs.first
        }
    }

    // MARK: - Queries

    public var windowCount: Int {
        pruneDeallocatedEntries()
        return entries.count
    }

    public var registeredWindowIDs: [UUID] {
        pruneDeallocatedEntries()
        return mruWindowIDs
    }

    public var allControllers: [any BrowserWindowControlling] {
        pruneDeallocatedEntries()
        return mruWindowIDs.compactMap { entries[$0]?.controller }
    }

    public func controller(for id: UUID) -> (any BrowserWindowControlling)? {
        pruneDeallocatedEntries()
        return entries[id]?.controller
    }

    public func controller(forWindowNumber windowNumber: Int) -> (any BrowserWindowControlling)? {
        pruneDeallocatedEntries()
        guard let id = windowNumberToID[windowNumber] else { return nil }
        return entries[id]?.controller
    }

    public func nsWindow(for id: UUID) -> NSWindow? {
        pruneDeallocatedEntries()
        return entries[id]?.nsWindow
    }

    /// Finds a live browser window in focus order; logical controllers alone cannot satisfy Dock recovery.
    public func restorableBrowserWindow(in applicationWindows: [NSWindow]) -> NSWindow? {
        pruneDeallocatedEntries()
        let liveWindows = Set(applicationWindows.map { ObjectIdentifier($0) })
        for id in mruWindowIDs {
            guard let box = entries[id],
                  let controller = box.controller,
                  !controller.isWindowClosing,
                  let window = box.nsWindow,
                  liveWindows.contains(ObjectIdentifier(window)),
                  window.canBecomeMain else { continue }
            return window
        }
        return nil
    }

    public var activeController: (any BrowserWindowControlling)? {
        pruneDeallocatedEntries()
        if let activeID = activeWindowID,
           let ctrl = entries[activeID]?.controller,
           !ctrl.isWindowClosing {
            return ctrl
        }
        if let keyWin = NSApplication.shared.keyWindow,
           let id = windowNumberToID[keyWin.windowNumber],
           let ctrl = entries[id]?.controller,
           !ctrl.isWindowClosing {
            activeWindowID = id
            promoteInMRU(id)
            return ctrl
        }
        for id in mruWindowIDs {
            if let ctrl = entries[id]?.controller, !ctrl.isWindowClosing {
                activeWindowID = id
                return ctrl
            }
        }
        return nil
    }

    // MARK: - Media Playback Ownership Isolation

    public func claimPlaybackOwnership(for windowID: UUID) {
        playbackOwnerWindowID = windowID
    }

    public func releasePlaybackOwnership(for windowID: UUID) {
        if playbackOwnerWindowID == windowID {
            playbackOwnerWindowID = nil
        }
    }

    /// Determines whether selection change or clear in `windowID` is allowed to stop global preview playback.
    public func shouldStopGlobalPlaybackOnSelectionChange(for windowID: UUID) -> Bool {
        if StandalonePlaybackWindowManager.shared.hasActivePlaybackSession {
            return false
        }
        pruneDeallocatedEntries()
        guard let owner = playbackOwnerWindowID else {
            return entries.count <= 1
        }
        return owner == windowID
    }

    /// Determines whether closing `windowID` should stop global preview playback.
    public func shouldStopGlobalPlaybackOnWindowClose(for windowID: UUID, isShowingImmersiveMedia: Bool) -> Bool {
        if StandalonePlaybackWindowManager.shared.hasActivePlaybackSession {
            return false
        }
        if isShowingImmersiveMedia {
            return true
        }
        return playbackOwnerWindowID == windowID
    }

    // MARK: - Internal Maintenance & Testing

    public func resetForTesting() {
        entries.removeAll()
        windowNumberToID.removeAll()
        mruWindowIDs.removeAll()
        activeWindowID = nil
        playbackOwnerWindowID = nil
        pendingLaunchSeeds.removeAll()
        pendingWindowCommands.removeAll()
    }

    private func promoteInMRU(_ id: UUID) {
        mruWindowIDs.removeAll { $0 == id }
        mruWindowIDs.insert(id, at: 0)
    }

    private func pruneDeallocatedEntries() {
        var deadIDs: [UUID] = []
        for (id, box) in entries where box.controller == nil {
            deadIDs.append(id)
        }
        guard !deadIDs.isEmpty else { return }
        let deadSet = Set(deadIDs)
        for id in deadSet {
            entries.removeValue(forKey: id)
            if playbackOwnerWindowID == id {
                playbackOwnerWindowID = nil
            }
        }
        windowNumberToID = windowNumberToID.filter { !deadSet.contains($0.value) }
        mruWindowIDs.removeAll { deadSet.contains($0) }
        if let active = activeWindowID, deadSet.contains(active) {
            activeWindowID = mruWindowIDs.first
        }
    }
}
