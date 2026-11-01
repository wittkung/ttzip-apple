// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit
import TTZipCore
import TTZipPreviewKit
import TTZipUI

/// Hosts an immersive full-window non-video preview inside a standard movable, resizable NSWindow
/// with a bottom-right transparent Return button and unconsumed Escape return routing.
@MainActor
struct StandalonePreviewWindowContent: View {
    let item: ImmersiveMediaItem
    let onReturn: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    var floatingToolsStateOverride: TTTextFloatingToolsPresentationState? = nil
    @Bindable private var l10n = AppLocalizationState.shared
    @State var controls = MediaControlsVisibility()
    @State private var returnButtonCoordinator = PreviewCornerActionRevealCoordinator()
    @State private var windowAnchor = StandaloneWindowAnchorBox()
    @State private var keyMonitor: Any?

    static func makeHostingView(item: ImmersiveMediaItem,
                                floatingToolsStateOverride: TTTextFloatingToolsPresentationState? = nil,
                                controls: MediaControlsVisibility? = nil,
                                onReturn: @escaping @MainActor () -> Void,
                                onClose: @escaping @MainActor () -> Void) -> NSView {
        NSHostingView(
            rootView: Self(
                item: item,
                onReturn: onReturn,
                onClose: onClose,
                floatingToolsStateOverride: floatingToolsStateOverride,
                controls: controls ?? MediaControlsVisibility()
            )
        )
    }

    static func shouldInterceptEscapeReturn(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        eventWindowNumber: Int? = nil,
        hostWindowNumber: Int? = nil,
        isHostKeyWindow: Bool = false,
        hasAttachedSheet: Bool = false,
        hasActiveMenu: Bool = false,
        hasActivePopoverOrPanel: Bool = false,
        isAppKitTextInputActive: Bool = false
    ) -> Bool {
        guard keyCode == 53 else { return false }
        let cleanMods = modifiers.intersection(.deviceIndependentFlagsMask)
        if !cleanMods.intersection([.command, .option, .control, .shift]).isEmpty {
            return false
        }
        guard Self.matchesHostWindowIdentity(
            eventWindowNumber: eventWindowNumber,
            hostWindowNumber: hostWindowNumber,
            isHostKeyWindow: isHostKeyWindow
        ) else {
            return false
        }
        if hasAttachedSheet || hasActiveMenu || hasActivePopoverOrPanel || isAppKitTextInputActive {
            return false
        }
        let query = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(
            windowNumber: hostWindowNumber ?? eventWindowNumber,
            keyCode: keyCode
        )
        if query.isTextInputActive || query.isEventAlreadyHandled {
            return false
        }
        return true
    }

    private static func matchesHostWindowIdentity(
        eventWindowNumber: Int?,
        hostWindowNumber: Int?,
        isHostKeyWindow: Bool
    ) -> Bool {
        guard let hostWindowNumber, hostWindowNumber > 0 else {
            return false
        }
        guard let eventWindowNumber, eventWindowNumber != 0 else {
            return isHostKeyWindow
        }
        return eventWindowNumber == hostWindowNumber
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
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
                .environment(\.previewBottomTrailingReservedWidth, 34.0)
                .environment(\.textFloatingToolsStateOverride, floatingToolsStateOverride)
                .environment(\.mediaControlsVisibility, controls)
                .environment(\.previewResourceContext, item.resolvedResourceContext)
                .environment(
                    \.previewHostContentGeometry,
                    TTPreviewHostContentGeometry(
                        layoutClass: TTMediaDetector.inferHostLayoutClass(url: item.url, fileName: item.name),
                        hostHeaderHeight: 0,
                        contentTopSafeInset: 0,
                        availableSize: geometry.size,
                        isStandalonePlaybackWindow: false
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                returnToOriginFloatingButton
            }
            .background(StandaloneWindowAccessor(anchor: windowAnchor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { installEscapeMonitor() }
        .onDisappear { removeEscapeMonitor() }
    }

    private var returnToOriginFloatingButton: some View {
        let label = l10n.t(PlaybackWindowLocaleKey.returnToOriginPreview)
        let help = l10n.t(PlaybackWindowLocaleKey.returnToOriginPreviewHelp)
        return PreviewCornerActionOverlayView(
            id: "StandalonePreviewReturnButton",
            symbolName: "arrow.down.right.and.arrow.up.left",
            accessibilityLabel: label,
            helpText: help,
            explicitStateOverride: floatingToolsStateOverride,
            externalControlsVisibility: controls,
            coordinator: returnButtonCoordinator,
            action: onReturn
        )
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        let anchor = windowAnchor
        let controlsRef = controls
        let stateOverride = floatingToolsStateOverride
        let returnHandler = onReturn
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let shouldIntercept = MainActor.assumeIsolated { () -> Bool in
                guard let targetWindow = anchor.resolvedWindow else { return false }
                guard CodeReadingToolsInteractionCoordinator.doesEscapeEventBelongToWindow(
                    eventWindow: event.window,
                    eventWindowNumber: event.windowNumber,
                    targetWindow: targetWindow
                ) else {
                    return false
                }
                if CodeReadingToolsInteractionCoordinator.wasEscapeConsumedForPopoverDismissal(
                    windowNumber: targetWindow.windowNumber,
                    timestamp: event.timestamp
                ) {
                    return false
                }
                let hasPopoverOrChildPanel = (targetWindow.childWindows ?? []).contains { $0.isVisible && $0.level != .popUpMenu }
                    || controlsRef.hasActiveInteractionLock
                    || stateOverride == .popoverExpanded
                let isKeyOwner = targetWindow.isKeyWindow && NSApplication.shared.keyWindow === targetWindow
                if Self.shouldInterceptEscapeReturn(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags,
                    eventWindowNumber: event.window?.windowNumber ?? event.windowNumber,
                    hostWindowNumber: targetWindow.windowNumber,
                    isHostKeyWindow: isKeyOwner,
                    hasAttachedSheet: targetWindow.attachedSheet != nil,
                    hasActiveMenu: CodeReadingToolsInteractionCoordinator.isMenuTrackingActive(for: targetWindow),
                    hasActivePopoverOrPanel: hasPopoverOrChildPanel,
                    isAppKitTextInputActive: CodeReadingToolsInteractionCoordinator.isEditableWindowTextInputActive(targetWindow)
                ) {
                    returnHandler()
                    return true
                }
                return false
            }
            return shouldIntercept ? nil : event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

@MainActor
private final class StandaloneWindowAnchorBox {
    weak var anchorView: NSView?
    weak var hostWindow: NSWindow?
    var resolvedWindow: NSWindow? {
        anchorView?.window ?? hostWindow
    }
}

private struct StandaloneWindowAccessor: NSViewRepresentable {
    let anchor: StandaloneWindowAnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = StandaloneWindowReaderNSView()
        view.anchor = anchor
        anchor.anchorView = view
        anchor.hostWindow = view.window
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let reader = nsView as? StandaloneWindowReaderNSView {
            reader.anchor = anchor
        }
        anchor.anchorView = nsView
        if let win = nsView.window {
            anchor.hostWindow = win
        }
    }
}

private final class StandaloneWindowReaderNSView: NSView {
    weak var anchor: StandaloneWindowAnchorBox?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        anchor?.hostWindow = window
    }
}
