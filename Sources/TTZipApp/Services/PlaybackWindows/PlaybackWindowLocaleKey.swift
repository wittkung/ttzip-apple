// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import SwiftUI
import TTMediaKit
import TTZipCore
import TTZipPreviewKit
import TTZipUI
#if canImport(TTI18nCore)
import TTI18nCore
import TTI18nUI
#endif

/// Explicit lifecycle transition states for the standalone video playback window (Feedback ②).
public enum StandalonePlaybackLifecycleEvent: String, Sendable, Equatable {
    case openedNewWindow
    case focusedExistingWindow
    case replacedMediaInPlace
    case originSelectionChanged
    case originBrowserWindowClosed
    case enteredSystemFullScreen
    case exitedSystemFullScreen
    case returnedToOriginPreview
    case closedStandalonePlayer
    case leaseAcquisitionFailed
    case handoffFailed
}

/// Immutable snapshot of an active standalone video playback session and its origin browser context.
public struct StandalonePlaybackSessionState: Sendable, Equatable {
    public let sessionID: UUID
    public var item: ImmersiveMediaItem
    public let canonicalIdentityKey: String
    public var originBrowserWindowID: UUID?
    public var originSelectedItem: DiskItemInfo?
    public var originDirectoryURL: URL?
    public var originArchivePath: String?
    public var isOriginWindowClosed: Bool
    public var hasOriginSelectionChanged: Bool
    public var isInSystemFullScreen: Bool
    public var focusRequestCount: Int
    public var handoffID: UUID?

    public init(
        sessionID: UUID = UUID(),
        item: ImmersiveMediaItem,
        canonicalIdentityKey: String,
        originBrowserWindowID: UUID?,
        originSelectedItem: DiskItemInfo?,
        originDirectoryURL: URL? = nil,
        originArchivePath: String? = nil,
        isOriginWindowClosed: Bool = false,
        hasOriginSelectionChanged: Bool = false,
        isInSystemFullScreen: Bool = false,
        focusRequestCount: Int = 1,
        handoffID: UUID? = nil
    ) {
        self.sessionID = sessionID
        self.item = item
        self.canonicalIdentityKey = canonicalIdentityKey
        self.originBrowserWindowID = originBrowserWindowID
        self.originSelectedItem = originSelectedItem
        self.originDirectoryURL = originDirectoryURL
        self.originArchivePath = originArchivePath
        self.isOriginWindowClosed = isOriginWindowClosed
        self.hasOriginSelectionChanged = hasOriginSelectionChanged
        self.isInSystemFullScreen = isInSystemFullScreen
        self.focusRequestCount = focusRequestCount
        self.handoffID = handoffID
    }
}

/// Independent per-handoff resource record created when returning playback to the origin preview.
/// Opening a new standalone video never cancels or drops cleanup responsibility for an earlier handoff record.
public struct StandalonePlaybackHandoffRecord {
    public let handoffID: UUID
    public let session: StandalonePlaybackSessionState
    public let mediaURL: URL
    public let cacheLease: PreviewCacheLease?
    public let cacheManager: PreviewLRUCacheManager
    package let ephemeralLeaseBox: TTMediaEphemeralLeaseBox
    package let securityScope: SecurityScopeLease?

    package init(
        handoffID: UUID,
        session: StandalonePlaybackSessionState,
        mediaURL: URL,
        cacheLease: PreviewCacheLease?,
        cacheManager: PreviewLRUCacheManager,
        ephemeralLeaseBox: TTMediaEphemeralLeaseBox,
        securityScope: SecurityScopeLease? = nil
    ) {
        self.handoffID = handoffID
        self.session = session
        self.mediaURL = mediaURL
        self.cacheLease = cacheLease
        self.cacheManager = cacheManager
        self.ephemeralLeaseBox = ephemeralLeaseBox
        self.securityScope = securityScope
    }

    @MainActor
    package func release() async {
        if let lease = cacheLease {
            await cacheManager.releaseLease(lease, reclaimImmediatelyIfIdle: true)
        }
        TTMediaDetector.endFullscreenEphemeralHandoff(for: mediaURL)
        ephemeralLeaseBox.release()
        securityScope?.release()
    }
}

/// Dedicated per-session resource bundle owning its own F4 consumer lease and ephemeral media box.
package struct StandalonePlaybackSessionResources {
    package let sessionID: UUID
    package let consumerID: UUID
    package let canonicalIdentityKey: String
    package let mediaURL: URL
    package let cacheLease: PreviewCacheLease?
    package let cacheManager: PreviewLRUCacheManager
    package let ephemeralLeaseBox: TTMediaEphemeralLeaseBox
    package let securityScope: SecurityScopeLease?

    @MainActor
    package func release() async {
        if let lease = cacheLease {
            await cacheManager.releaseLease(lease, reclaimImmediatelyIfIdle: true)
        }
        TTMediaDetector.endFullscreenEphemeralHandoff(for: mediaURL)
        ephemeralLeaseBox.release()
        securityScope?.release()
    }
}

/// Per-window origin bridge lease record binding `windowID + cacheKey + handoffID`.
package struct OriginWindowRestoredLeaseRecord {
    package let windowID: UUID
    package let handoffID: UUID
    package let selectedPath: String?
    package let lease: PreviewCacheLease
    package let cacheManager: PreviewLRUCacheManager
}

/// Standard, resizable, main-capable macOS window hosting standalone video playback.
/// Never defaults to `.floating` or `.nonactivatingPanel` PiP behavior.
@MainActor
public final class StandalonePlaybackNSWindow: NSWindow {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    package private(set) var clockNow: MediaControlsVisibility.Now = { ContinuousClock.now }
    package private(set) var clockWait: MediaControlsVisibility.Wait = { try await Task.sleep(for: $0) }
    public private(set) var trafficLightsController: StandalonePlaybackTrafficLightsController?
    public private(set) var topRightControlsCoordinator = PreviewCornerActionRevealCoordinator()

    public var isSystemFullScreenOverrideForTesting: Bool? {
        didSet {
            trafficLightsController?.applyNativeTrafficLightsVisibility()
        }
    }

    public var isMenuTrackingOverrideForTesting: Bool = false {
        didSet {
            CodeReadingToolsInteractionCoordinator.setMenuTrackingActive(isMenuTrackingOverrideForTesting, for: self)
            trafficLightsController?.reconcileExternalLock()
            trafficLightsController?.applyNativeTrafficLightsVisibility()
            topRightControlsCoordinator.setExternallyLocked(isMenuTrackingOverrideForTesting)
        }
    }

    public var isSystemFullScreenActive: Bool {
        isSystemFullScreenOverrideForTesting ?? styleMask.contains(.fullScreen)
    }

    public static func makeStandardPlayerWindow(
        title: String,
        now: @escaping MediaControlsVisibility.Now = { ContinuousClock.now },
        wait: @escaping MediaControlsVisibility.Wait = { try await Task.sleep(for: $0) }
    ) -> StandalonePlaybackNSWindow {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 120, y: 120, width: 1440, height: 900)
        let width = min(1080, max(720, screenFrame.width * 0.72))
        let height = min(660, max(440, screenFrame.height * 0.72))
        let originX = screenFrame.origin.x + (screenFrame.width - width) * 0.5 + 28
        let originY = screenFrame.origin.y + (screenFrame.height - height) * 0.5 - 20
        let contentRect = NSRect(x: originX, y: originY, width: width, height: height)

        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ]
        let window = StandalonePlaybackNSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.level = .normal
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .black
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 640, height: 400)
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.clockNow = now
        window.clockWait = wait
        window.topRightControlsCoordinator = PreviewCornerActionRevealCoordinator(now: now, wait: wait)
        let controller = StandalonePlaybackTrafficLightsController(
            window: window,
            coordinator: PreviewCornerActionRevealCoordinator(now: now, wait: wait)
        )
        window.trafficLightsController = controller
        controller.applyNativeTrafficLightsVisibility()
        return window
    }

    package func configureAndFocus(
        for session: StandalonePlaybackSessionState,
        manager: StandalonePlaybackWindowManager,
        activateInForeground: Bool = (
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && ProcessInfo.processInfo.environment["TEST_TMPDIR"] == nil
            && NSClassFromString("XCTestCase") == nil
        )
    ) {
        self.title = session.item.name
        self.appearance = nil
        if trafficLightsController == nil {
            trafficLightsController = StandalonePlaybackTrafficLightsController(
                window: self,
                coordinator: PreviewCornerActionRevealCoordinator(now: clockNow, wait: clockWait)
            )
        }
        let rootView = StandalonePlaybackWindowContentView(manager: manager, windowOverride: self)
        if let hosting = self.contentView as? NSHostingView<StandalonePlaybackWindowContentView> {
            hosting.rootView = rootView
        } else {
            let hosting = NSHostingView(rootView: rootView)
            hosting.sizingOptions = []
            self.contentView = hosting
        }
        trafficLightsController?.applyNativeTrafficLightsVisibility()
        guard activateInForeground else { return }
        if self.isMiniaturized {
            self.deminiaturize(nil)
        }
        self.makeKeyAndOrderFront(nil)
        NSApp?.activate(ignoringOtherApps: true)
    }

    public override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let kind = trafficLightsController?.isStandardWindowButton(responder) {
            trafficLightsController?.setFocusedStandardButton(kind)
            return super.makeFirstResponder(responder)
        }
        let accepted = super.makeFirstResponder(responder)
        if accepted {
            trafficLightsController?.setFocusedStandardButton(nil)
        }
        return accepted
    }

    public override func performClose(_ sender: Any?) {
        let closeBtn = standardWindowButton(.closeButton)
        closeBtn?.isHidden = false
        closeBtn?.alphaValue = 1.0
        super.performClose(sender)
        trafficLightsController?.applyNativeTrafficLightsVisibility()
    }

    public override func performMiniaturize(_ sender: Any?) {
        let minBtn = standardWindowButton(.miniaturizeButton)
        minBtn?.isHidden = false
        minBtn?.alphaValue = 1.0
        super.performMiniaturize(sender)
        trafficLightsController?.applyNativeTrafficLightsVisibility()
    }

    public override func performZoom(_ sender: Any?) {
        let zoomBtn = standardWindowButton(.zoomButton)
        zoomBtn?.isHidden = false
        zoomBtn?.alphaValue = 1.0
        super.performZoom(sender)
        trafficLightsController?.applyNativeTrafficLightsVisibility()
    }

    public override func close() {
        CodeReadingToolsInteractionCoordinator.setMenuTrackingActive(false, for: self)
        trafficLightsController?.tearDown()
        topRightControlsCoordinator.tearDown()
        super.close()
    }
}

/// Strongly-typed localization keys for the standalone video playback window and browser-player handoff (W1 — Feedback ②).
public enum PlaybackWindowLocaleKey: String, TTZipCore.LocaleKeyProtocol, CaseIterable, Sendable {
    case returnToOriginPreview = "playback.window.return_to_origin_preview"
    case returnToOriginPreviewHelp = "playback.window.return_to_origin_preview.help"
    case openInStandalonePlayer = "playback.window.open_in_standalone_player"
    case playingInStandaloneWindowTitle = "playback.window.playing_in_standalone.title"
    case playingInStandaloneWindowSubtitle = "playback.window.playing_in_standalone.subtitle"
    case focusStandaloneWindowButton = "playback.window.focus_standalone_window"

    public var rawKey: String { rawValue }

    @MainActor
    public func localized(for language: TTZipCore.AppLanguage? = nil) -> String {
        let lang = language ?? TTZipUI.AppLocalizationState.shared.currentLanguage
        return translation(for: lang)
    }

    public func translation(for language: TTZipCore.AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawValue }
        switch language {
        case .zhHans:
            return values.zh
        case .zhHant:
            return values.hant
        default:
            return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .returnToOriginPreview: (
            "Return to Preview",
            "返回原预览",
            "返回原預覽"
        ),
        .returnToOriginPreviewHelp: (
            "Close standalone player window and continue playback in the browser inspector",
            "关闭独立播放器窗口并在原浏览窗口侧栏继续预览",
            "關閉獨立播放器視窗並在原瀏覽視窗側欄繼續預覽"
        ),
        .openInStandalonePlayer: (
            "Open in Standalone Player",
            "在独立播放器中打开",
            "在獨立播放器中打開"
        ),
        .playingInStandaloneWindowTitle: (
            "Playing in Standalone Player Window",
            "正在独立播放器窗口中播放",
            "正在獨立播放器視窗中播放"
        ),
        .playingInStandaloneWindowSubtitle: (
            "This video is active in an independent window so you can continue browsing files freely.",
            "当前视频已在独立播放器窗口中打开，您可以继续在此浏览文件。",
            "目前影片已在獨立播放器視窗中打開，您可以繼續在此瀏覽檔案。"
        ),
        .focusStandaloneWindowButton: (
            "Focus Player Window",
            "聚焦播放器窗口",
            "聚焦播放器視窗"
        )
    ]
}

#if canImport(TTI18nCore)
extension PlaybackWindowLocaleKey: FallbackLocaleKeyProtocol {
    public func fallbackTranslation(for language: TTI18nCore.AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawValue }
        switch language {
        case .zhHans:
            return values.zh
        case .zhHant:
            return values.hant
        default:
            return values.en
        }
    }
}
#endif

// MARK: - Standalone Player Window Root View

@MainActor
public struct StandalonePlaybackWindowContentView: View {
    @Bindable public var manager: StandalonePlaybackWindowManager
    public weak var windowOverride: StandalonePlaybackNSWindow?
    public let itemOverride: ImmersiveMediaItem?
    public let controlsOverride: MediaControlsVisibility?
    @Bindable private var l10n = TTZipUI.AppLocalizationState.shared
    @State private var ownedControls: MediaControlsVisibility
    @State private var eventMonitor: Any?
    @State private var hostWindowNumber: Int?

    public init(
        manager: StandalonePlaybackWindowManager,
        windowOverride: StandalonePlaybackNSWindow? = nil,
        itemOverride: ImmersiveMediaItem? = nil,
        controlsOverride: MediaControlsVisibility? = nil
    ) {
        self.manager = manager
        self.windowOverride = windowOverride
        self.itemOverride = itemOverride
        self.controlsOverride = controlsOverride
        let visibility: MediaControlsVisibility
        if let hostWindow = windowOverride ?? manager.playerWindow {
            visibility = MediaControlsVisibility(now: hostWindow.clockNow, wait: hostWindow.clockWait)
        } else {
            visibility = MediaControlsVisibility()
        }
        self._ownedControls = State(initialValue: visibility)
    }

    private var activeWindow: StandalonePlaybackNSWindow? {
        windowOverride ?? manager.playerWindow
    }

    private var activeItem: ImmersiveMediaItem? {
        itemOverride ?? manager.activeSession?.item
    }

    private var controls: MediaControlsVisibility {
        controlsOverride ?? ownedControls
    }

    public var body: some View {
        GeometryReader { geometry in
            if let item = activeItem {
                ZStack {
                    Color.black.ignoresSafeArea()

                    MediaPreviewView(
                        fileURL: item.url,
                        fileName: item.name,
                        isImmersiveFullscreen: true,
                        showsFloatingFullScreenButton: false,
                        sourceArchivePath: item.sourceArchivePath,
                        archiveSubpath: item.archiveSubpath,
                        resourceCacheKey: item.resourceCacheKey,
                        isEditable: false,
                        resourceContext: item.resolvedResourceContext
                    )
                    .environment(\.isImmersiveFullscreen, true)
                    .environment(\.previewResourceContext, item.resolvedResourceContext)
                    .environment(
                        \.previewHostContentGeometry,
                        TTPreviewHostContentGeometry(
                            layoutClass: .canvasMedia,
                            hostHeaderHeight: 0,
                            contentTopSafeInset: 0,
                            availableSize: geometry.size,
                            isStandalonePlaybackWindow: true
                        )
                    )
                    .id(item.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()

                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 0) {
                            StandalonePlaybackTrafficLightsSensorOverlay(window: activeWindow)
                            Spacer(minLength: 0)
                            standaloneTopRightCornerCluster
                        }
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea(edges: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TTPreviewHostWindowNumberReader(windowNumber: $hostWindowNumber))
                .environment(\.mediaControlsVisibility, controls)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        controls.recordMouseMove(at: location)
                    case .ended:
                        controls.setHovered(false)
                    }
                }
                .onChange(of: item.url) { _, _ in
                    controls.resetForNewItem()
                    activeWindow?.topRightControlsCoordinator.tearDown()
                    activeWindow?.trafficLightsController?.resetForNewItem()
                }
                .onAppear {
                    activeWindow?.trafficLightsController?.applyNativeTrafficLightsVisibility()
                    setupKeyboardMonitor()
                }
                .onDisappear {
                    teardownKeyboardMonitor()
                    controls.tearDown()
                    activeWindow?.topRightControlsCoordinator.tearDown()
                    activeWindow?.trafficLightsController?.resetForNewItem()
                }
            } else {
                Color.black.ignoresSafeArea()
            }
        }
    }

    private var standaloneTopRightCornerCluster: some View {
        let returnTitle = l10n.t(PlaybackWindowLocaleKey.returnToOriginPreview)
        let returnHelp = l10n.t(PlaybackWindowLocaleKey.returnToOriginPreviewHelp)
        let items: [VideoWindowCornerControlItem] = [
            VideoWindowCornerControlItem(
                id: "StandalonePlaybackReturnToPreviewButton",
                symbolName: "arrow.down.right.and.arrow.up.left",
                title: returnTitle,
                accessibilityLabel: returnTitle,
                helpText: returnHelp,
                shapeStyle: .roundedPill,
                action: { _ = manager.requestReturnToOriginPreview() }
            ),
            VideoWindowCornerControlItem(
                id: "StandalonePlaybackCloseButton",
                symbolName: "xmark",
                accessibilityLabel: MediaLocalization.text(.close),
                accessibilityHint: MediaLocalization.text(.escapeHint),
                helpText: MediaLocalization.text(.dismissHelp),
                shapeStyle: .circle,
                action: { _ = manager.requestReturnToOriginPreview() }
            )
        ]
        let win = activeWindow
        return VideoWindowCornerControlClusterView(
            sensorID: "StandalonePlaybackTopRightControls.HoverSensor",
            items: items,
            coordinator: win?.topRightControlsCoordinator,
            isMenuTrackingOverride: win?.isMenuTrackingOverrideForTesting ?? false,
            externalLockProvider: { win?.isMenuTrackingOverrideForTesting == true }
        )
    }

    private func setupKeyboardMonitor() {
        teardownKeyboardMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let eventWinNum = event.window?.windowNumber ?? NSApp?.keyWindow?.windowNumber
            if let hostWindowNumber, let eventWinNum, eventWinNum != hostWindowNumber {
                return event
            }
            let targetWindow = event.window ?? activeWindow
            if TTPreviewHorizontalKeyPolicy.isWindowTextInputActive(targetWindow) {
                return event
            }
            if event.keyCode == 53 {
                if let standaloneWin = (targetWindow as? StandalonePlaybackNSWindow) ?? activeWindow,
                   standaloneWin.isSystemFullScreenActive {
                    if standaloneWin.isSystemFullScreenOverrideForTesting == true {
                        standaloneWin.isSystemFullScreenOverrideForTesting = false
                        if manager.activeSession?.isInSystemFullScreen == true {
                            manager.toggleSystemFullScreen()
                        }
                    } else {
                        standaloneWin.toggleFullScreen(nil)
                    }
                    return nil
                }
                _ = manager.requestReturnToOriginPreview()
                return nil
            }
            return event
        }
    }

    private func teardownKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - Lease Acquisition Validation Helpers

package struct ValidatedLeaseAcquisition {
    package let succeeded: Bool
    package let lease: PreviewCacheLease?
    package let resolvedURL: URL

    package init(succeeded: Bool, lease: PreviewCacheLease?, resolvedURL: URL) {
        self.succeeded = succeeded
        self.lease = lease
        self.resolvedURL = resolvedURL
    }
}

extension StandalonePlaybackWindowManager {
    package func acquireValidatedCacheLease(
        for item: ImmersiveMediaItem,
        requiredCacheKey: String?,
        consumerID: UUID,
        cacheManager: PreviewLRUCacheManager
    ) async -> ValidatedLeaseAcquisition {
        if let key = requiredCacheKey {
            if let cachedHit = await cacheManager.acquireCachedURL(forKey: key, consumerID: consumerID) {
                return ValidatedLeaseAcquisition(succeeded: true, lease: cachedHit.lease, resolvedURL: cachedHit.url)
            }
            if let urlLease = await cacheManager.acquireIndependentPlayerLease(forFileURL: item.url, consumerID: consumerID) {
                return ValidatedLeaseAcquisition(succeeded: true, lease: urlLease, resolvedURL: item.url)
            }
            return ValidatedLeaseAcquisition(succeeded: false, lease: nil, resolvedURL: item.url)
        }

        let cacheRootPath = cacheManager.getSessionRoot().standardizedFileURL.resolvingSymlinksInPath().path
        let itemPath = item.url.standardizedFileURL.resolvingSymlinksInPath().path
        if itemPath.hasPrefix(cacheRootPath + "/") {
            if let urlLease = await cacheManager.acquireIndependentPlayerLease(forFileURL: item.url, consumerID: consumerID) {
                return ValidatedLeaseAcquisition(succeeded: true, lease: urlLease, resolvedURL: item.url)
            }
            return ValidatedLeaseAcquisition(succeeded: false, lease: nil, resolvedURL: item.url)
        }

        return ValidatedLeaseAcquisition(succeeded: true, lease: nil, resolvedURL: item.url)
    }
}

