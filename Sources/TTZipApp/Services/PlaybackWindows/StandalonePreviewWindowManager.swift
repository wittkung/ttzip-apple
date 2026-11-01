// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import TTMediaKit
import TTZipPreviewKit

/// Owns independent non-video preview windows and their exact resource consumers.
@MainActor
public final class StandalonePreviewWindowManager: NSObject, NSWindowDelegate {
    public static let shared = StandalonePreviewWindowManager()
    public private(set) var createdWindowCount = 0
    public private(set) var windowPresentationRequestCount = 0
    public var activeWindowCount: Int { sessions.count }
    public var pendingOpenCount: Int { requests.count }
    public var onWillCommitAcquiredLeaseHook: (@MainActor () async -> Void)?
    /// Controlled host window factory for test assembly without skipping production window requests.
    public var windowFactory: (@MainActor (ImmersiveMediaItem, UUID?) -> NSWindow)?
    /// Controlled window presentation handler for test isolation without foreground GUI activation.
    public var windowPresentationHandler: (@MainActor (NSWindow, ImmersiveMediaItem, UUID?) -> Void)?

    private struct Key: Hashable {
        let originWindowID: UUID?
        let identity: String
    }
    private struct Request {
        let id: UUID
        let task: Task<Bool, Never>
    }
    private final class Session {
        let item: ImmersiveMediaItem
        let resources: StandalonePreviewResources
        var window: NSWindow?
        init(item: ImmersiveMediaItem, resources: StandalonePreviewResources) {
            self.item = item
            self.resources = resources
        }
    }
    private var sessions: [Key: Session] = [:]
    private var requests: [Key: Request] = [:]

    public override init() { super.init() }

    /// Coalesces equal requests while preserving independent files and origin windows.
    @discardableResult
    public func open(
        item: ImmersiveMediaItem,
        originWindowID: UUID?,
        resourceContext: TTPreviewResourceContext? = nil,
        createAppKitWindow: Bool = true,
        cacheManager: PreviewLRUCacheManager = .shared
    ) async -> Bool {
        let item = effectiveItem(item, resourceContext: resourceContext)
        guard !StandalonePlaybackWindowManager.isVideoItem(item), !Task.isCancelled else { return false }
        let key = key(for: item, originWindowID: originWindowID)
        if let session = sessions[key] {
            if createAppKitWindow { present(session, key: key) }
            return true
        }
        if let pending = requests[key] {
            let opened = await pending.task.value
            if opened, createAppKitWindow, let session = sessions[key] { present(session, key: key) }
            return opened
        }
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.acquireAndOpen(item, key: key, requestID: requestID,
                                             createWindow: createAppKitWindow, cacheManager: cacheManager)
        }
        requests[key] = Request(id: requestID, task: task)
        let opened = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if Task.isCancelled, requests[key]?.id == requestID {
            await close(key: key)
            return false
        }
        if requests[key]?.id == requestID { requests.removeValue(forKey: key) }
        return opened
    }

    private func acquireAndOpen(
        _ item: ImmersiveMediaItem, key: Key, requestID: UUID,
        createWindow: Bool, cacheManager: PreviewLRUCacheManager
    ) async -> Bool {
        guard let prepared = await StandalonePreviewResources.acquire(for: item, cacheManager: cacheManager) else { return false }
        if let hook = onWillCommitAcquiredLeaseHook { await hook() }
        guard !Task.isCancelled, requests[key]?.id == requestID else {
            await prepared.resources.release()
            return false
        }
        let session = Session(item: prepared.item, resources: prepared.resources)
        sessions[key] = session
        if createWindow { present(session, key: key) }
        return true
    }

    /// Invalidates only this identity, including any acquisition currently in flight.
    public func close(item: ImmersiveMediaItem, originWindowID: UUID?) async {
        await close(key: key(for: item, originWindowID: originWindowID))
    }

    public func closeAll() async {
        for request in requests.values { request.task.cancel() }
        requests.removeAll()
        let keys = Array(sessions.keys)
        for key in keys { await close(key: key) }
    }

    public func resetForTesting() async {
        await closeAll()
        createdWindowCount = 0
        windowPresentationRequestCount = 0
        onWillCommitAcquiredLeaseHook = nil
        windowFactory = nil
        windowPresentationHandler = nil
    }

    public func isPresenting(item: ImmersiveMediaItem, originWindowID: UUID?) -> Bool {
        sessions[key(for: item, originWindowID: originWindowID)] != nil
    }

    public func cacheLease(item: ImmersiveMediaItem, originWindowID: UUID?) -> PreviewCacheLease? {
        sessions[key(for: item, originWindowID: originWindowID)]?.resources.cacheLease
    }

    func resolvedItem(item: ImmersiveMediaItem, originWindowID: UUID?) -> ImmersiveMediaItem? {
        sessions[key(for: item, originWindowID: originWindowID)]?.item
    }

    func activeWindow(item: ImmersiveMediaItem, originWindowID: UUID?) -> NSWindow? {
        sessions[key(for: item, originWindowID: originWindowID)]?.window
    }

    func makeHostingViewForActiveSession(
        item: ImmersiveMediaItem,
        originWindowID: UUID?,
        floatingToolsStateOverride: TTTextFloatingToolsPresentationState? = nil
    ) -> NSView? {
        let targetKey = key(for: item, originWindowID: originWindowID)
        guard let session = sessions[targetKey] else { return nil }
        return StandalonePreviewWindowContent.makeHostingView(
            item: session.item,
            floatingToolsStateOverride: floatingToolsStateOverride,
            onReturn: { [weak self] in Task { await self?.returnToOrigin(key: targetKey) } },
            onClose: { [weak self] in Task { await self?.close(key: targetKey) } }
        )
    }

    func makeConfiguredWindowForActiveSession(
        item: ImmersiveMediaItem,
        originWindowID: UUID?,
        contentRect: NSRect = NSRect(x: 120, y: 120, width: 1000, height: 720),
        floatingToolsStateOverride: TTTextFloatingToolsPresentationState? = nil
    ) -> NSWindow? {
        let targetKey = key(for: item, originWindowID: originWindowID)
        guard let session = sessions[targetKey] else { return nil }
        return buildConfiguredWindow(
            for: session,
            key: targetKey,
            contentRect: contentRect,
            floatingToolsStateOverride: floatingToolsStateOverride
        )
    }

    func performReturnToOrigin(item: ImmersiveMediaItem, originWindowID: UUID?) async {
        await returnToOrigin(key: key(for: item, originWindowID: originWindowID))
    }

    private func close(key: Key) async {
        requests.removeValue(forKey: key)?.task.cancel()
        guard let session = sessions.removeValue(forKey: key) else { return }
        session.window?.delegate = nil
        session.window?.close()
        session.window = nil
        await session.resources.release()
    }

    private func returnToOrigin(key: Key) async {
        if let origin = key.originWindowID,
           let window = BrowserWindowRegistry.shared.nsWindow(for: origin) {
            BrowserWindowRegistry.shared.activateWindow(id: origin)
            window.makeKeyAndOrderFront(nil)
        }
        await close(key: key)
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = sessions.first(where: { $0.value.window === window })?.key else { return }
        // Remove synchronously so a new request cannot reuse a closing window.
        guard let session = sessions.removeValue(forKey: key) else { return }
        session.window = nil
        Task { @MainActor in await session.resources.release() }
    }

    private func key(for item: ImmersiveMediaItem, originWindowID: UUID?) -> Key {
        Key(originWindowID: originWindowID, identity: StandalonePlaybackWindowManager.canonicalIdentityKey(for: item))
    }

    private func effectiveItem(_ item: ImmersiveMediaItem, resourceContext: TTPreviewResourceContext?) -> ImmersiveMediaItem {
        ImmersiveMediaItem(url: item.url, name: item.name, fileSizeBytes: item.fileSizeBytes,
                           sourceArchivePath: item.sourceArchivePath, archiveSubpath: item.archiveSubpath,
                           resourceCacheKey: item.resourceCacheKey, isEditable: false,
                           resourceContext: (resourceContext ?? item.resolvedResourceContext).forcingReadOnly())
    }

    private func buildConfiguredWindow(
        for session: Session,
        key: Key,
        contentRect: NSRect = NSRect(x: 120, y: 120, width: 1000, height: 720),
        floatingToolsStateOverride: TTTextFloatingToolsPresentationState? = nil
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = session.item.name
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.managed, .fullScreenNone]
        window.level = .normal
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        window.delegate = self
        window.contentView = StandalonePreviewWindowContent.makeHostingView(
            item: session.item,
            floatingToolsStateOverride: floatingToolsStateOverride,
            onReturn: { [weak self] in Task { await self?.returnToOrigin(key: key) } },
            onClose: { [weak self] in Task { await self?.close(key: key) } }
        )
        return window
    }

    private func present(_ session: Session, key: Key) {
        windowPresentationRequestCount += 1
        let window: NSWindow
        if let existing = session.window {
            window = existing
        } else {
            let created = windowFactory?(session.item, key.originWindowID)
                ?? buildConfiguredWindow(for: session, key: key)
            if created.delegate == nil {
                created.delegate = self
            }
            if created.contentView == nil {
                created.contentView = StandalonePreviewWindowContent.makeHostingView(
                    item: session.item,
                    floatingToolsStateOverride: nil,
                    onReturn: { [weak self] in Task { await self?.returnToOrigin(key: key) } },
                    onClose: { [weak self] in Task { await self?.close(key: key) } }
                )
            }
            session.window = created
            createdWindowCount += 1
            window = created
        }
        if let windowPresentationHandler {
            windowPresentationHandler(window, session.item, key.originWindowID)
            return
        }
        let shouldActivateInForeground =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && ProcessInfo.processInfo.environment["TEST_TMPDIR"] == nil
            && NSClassFromString("XCTestCase") == nil
        guard shouldActivateInForeground else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp?.activate(ignoringOtherApps: true)
    }
}
