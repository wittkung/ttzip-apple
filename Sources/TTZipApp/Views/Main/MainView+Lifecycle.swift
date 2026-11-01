// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import AppKit
import TTZipUI
import TTZipPreviewKit
import TTKitDesign

package extension View {
    @ViewBuilder
    func mainViewNotifications(
        viewModel: AppViewState,
        l10n: AppLocalizationState,
        openURLRegistrationToken: Binding<AppDelegate.RegistrationToken?>
    ) -> some View {
        self
            .onAppear {
                AppIntentDispatcher.shared.bind(state: viewModel)
                BrowserWindowRegistry.shared.register(viewModel, nsWindow: BrowserWindowRegistry.shared.nsWindow(for: viewModel.windowID))
            }
            .onDisappear {
                openURLRegistrationToken.wrappedValue?.cancel()
                openURLRegistrationToken.wrappedValue = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipEncryptedArchivePromptRequired"))) { notif in
                let targetWindowID = notif.userInfo?["windowID"] as? UUID
                let isTargeted: Bool
                if let targetWindowID {
                    isTargeted = (targetWindowID == viewModel.windowID)
                } else {
                    isTargeted = (BrowserWindowRegistry.shared.activeWindowID == nil || BrowserWindowRegistry.shared.activeWindowID == viewModel.windowID)
                }
                guard isTargeted, let path = notif.object as? String else { return }
                let kind: ArchivePasswordOperationContext.OperationKind = {
                    if let rawKind = notif.userInfo?["operationKind"] as? String {
                        switch rawKind {
                        case "quickExtract":
                            return .quickExtract(
                                targetDir: nil,
                                isSmartExtract: true,
                                trashSourceAfterExtract: false,
                                collisionHandling: nil
                            )
                        default:
                            return .browse
                        }
                    }
                    return .browse
                }()
                viewModel.stagePasswordPromptContext(archivePath: path, kind: kind)
                viewModel.taskState.statusMessage = l10n.t(L10n.Errors.passwordRequired)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ttzipToggleMediaFocus)) { notif in
                handleMediaFocusToggleNotification(notif, viewModel: viewModel)
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TTMediaToggleMediaFocusNotification"))) { notif in
                handleMediaFocusToggleNotification(notif, viewModel: viewModel)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notif in
                if let senderWindow = notif.object as? NSWindow,
                   let myWindow = BrowserWindowRegistry.shared.nsWindow(for: viewModel.windowID),
                   senderWindow !== myWindow {
                    return
                }
                withAnimation(UniversalTokens.Motion.micro) {
                    viewModel.navigationState.layoutMode = .standard
                }
            }
    }

    @MainActor
    private func handleMediaFocusToggleNotification(_ notif: Notification, viewModel: AppViewState) {
        if StandalonePlaybackWindowManager.shared.hasActivePlaybackSession,
           StandalonePlaybackWindowManager.shared.playerWindow?.isKeyWindow == true {
            StandalonePlaybackWindowManager.shared.toggleSystemFullScreen()
            return
        }
        let targetWindowID = notif.userInfo?["windowID"] as? UUID
        let isTargeted: Bool
        if let targetWindowID {
            isTargeted = (targetWindowID == viewModel.windowID)
        } else {
            isTargeted = viewModel.overlayState.showImmersiveMediaBrowser
                || BrowserWindowRegistry.shared.activeWindowID == viewModel.windowID
        }
        guard isTargeted else { return }
        if handleStandaloneMediaFocusNotification(notif, viewModel: viewModel) {
            return
        }
        withAnimation(UniversalTokens.Motion.micro) {
            if viewModel.overlayState.showImmersiveMediaBrowser {
                viewModel.closeImmersiveMedia()
            } else if let item = notif.object as? ImmersiveMediaItem {
                viewModel.openImmersiveMedia(url: item.url, name: item.name, fileSizeBytes: item.fileSizeBytes)
            } else if let url = notif.object as? URL {
                let name = (notif.userInfo?["name"] as? String) ?? url.lastPathComponent
                viewModel.openImmersiveMedia(url: url, name: name)
            } else if let item = viewModel.selectedDiskItem {
                let u = URL(fileURLWithPath: item.path)
                viewModel.openImmersiveMedia(url: u, name: item.name, fileSizeBytes: item.fileSizeBytes)
            }
        }
    }

    @MainActor
    private func handleStandaloneMediaFocusNotification(_ notif: Notification, viewModel: AppViewState) -> Bool {
        if let item = notif.object as? ImmersiveMediaItem {
            return viewModel.openStandaloneMediaIfSupported(
                url: item.url,
                name: item.name,
                fileSizeBytes: item.fileSizeBytes,
                sourceArchivePath: item.sourceArchivePath,
                archiveSubpath: item.archiveSubpath,
                resourceCacheKey: item.resourceCacheKey,
                isEditable: item.isEditable
            )
        }
        if let url = notif.object as? URL {
            let name = (notif.userInfo?["name"] as? String) ?? url.lastPathComponent
            let sourceArchivePath = notif.userInfo?["sourceArchivePath"] as? String
            let archiveSubpath = notif.userInfo?["archiveSubpath"] as? String
            let resourceCacheKey = notif.userInfo?["resourceCacheKey"] as? String
            let isEditable = notif.userInfo?["isEditable"] as? Bool
            return viewModel.openStandaloneMediaIfSupported(
                url: url,
                name: name,
                sourceArchivePath: sourceArchivePath,
                archiveSubpath: archiveSubpath,
                resourceCacheKey: resourceCacheKey,
                isEditable: isEditable
            )
        }
        if notif.object == nil, let item = viewModel.selectedDiskItem {
            let u = URL(fileURLWithPath: item.path)
            return viewModel.openStandaloneMediaIfSupported(
                url: u,
                name: item.name,
                fileSizeBytes: item.fileSizeBytes
            )
        }
        return false
    }
}

/// AppKit bridge that attaches an `NSWindow` lifecycle observer to a window's `AppViewState`.
struct BrowserWindowLifecycleBridge: NSViewRepresentable {
    let viewModel: AppViewState

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> WindowObserverNSView {
        let view = WindowObserverNSView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowObserverNSView, context: Context) {
        context.coordinator.viewModel = viewModel
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var viewModel: AppViewState
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(viewModel: AppViewState) {
            self.viewModel = viewModel
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if observedWindow === window {
                BrowserWindowRegistry.shared.bindNSWindow(window, for: viewModel.windowID)
                let geomCoordinator = InspectorWindowGeometryCoordinator.coordinator(
                    for: viewModel.windowID,
                    initialVisibility: viewModel.navigationState.isInspectorVisible
                )
                geomCoordinator.attachWindowLifecycleObservers(to: window)
                geomCoordinator.updateWindowMinimumSize(
                    window: window,
                    viewModel: viewModel,
                    isRightVisible: viewModel.navigationState.isInspectorVisible
                )
                return
            }
            removeObservers()
            observedWindow = window
            BrowserWindowRegistry.shared.register(viewModel, nsWindow: window)
            BrowserWindowRegistry.shared.bindNSWindow(window, for: viewModel.windowID)
            let geomCoordinator = InspectorWindowGeometryCoordinator.coordinator(
                for: viewModel.windowID,
                initialVisibility: viewModel.navigationState.isInspectorVisible
            )
            geomCoordinator.attachWindowLifecycleObservers(to: window)
            geomCoordinator.updateWindowMinimumSize(
                window: window,
                viewModel: viewModel,
                isRightVisible: viewModel.navigationState.isInspectorVisible
            )
            if window.isKeyWindow || window.isMainWindow {
                BrowserWindowRegistry.shared.activateWindow(id: viewModel.windowID)
                AppIntentDispatcher.shared.bind(state: viewModel)
            }

            let center = NotificationCenter.default
            let windowID = viewModel.windowID
            observers.append(
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        BrowserWindowRegistry.shared.activateWindow(id: windowID)
                        AppIntentDispatcher.shared.bind(state: self.viewModel)
                    }
                }
            )
            observers.append(
                center.addObserver(forName: NSWindow.didBecomeMainNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        BrowserWindowRegistry.shared.activateWindow(id: windowID)
                        AppIntentDispatcher.shared.bind(state: self.viewModel)
                    }
                }
            )
            observers.append(
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        InspectorWindowGeometryCoordinator.unregister(windowID: self.viewModel.windowID)
                        self.viewModel.prepareForWindowClose()
                        self.removeObservers()
                    }
                }
            )
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            for obs in observers {
                center.removeObserver(obs)
            }
            observers.removeAll()
            observedWindow = nil
        }
    }

    final class WindowObserverNSView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }
}
