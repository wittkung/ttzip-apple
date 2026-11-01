// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTKitUI
import TTKitDesign
#if canImport(TTZipAppServices)
#endif

/// Host view rendering root system modals (password prompt, immersive media viewer, Cmd+K Omnibar, and collision resolver).
@MainActor
public struct MainRootOverlaysView: View {
    @Environment(AppViewState.self) private var viewModel
    private var l10n = AppLocalizationState.shared
    @State private var applyCollisionToAll: Bool = false
    
    public init() {}
    
    public var body: some View {
        Group {
            passwordPromptOverlay
            mediaBrowserOverlay
            omnibarOverlay
            forensicCollisionOverlay
            goToFolderOverlay
            smartFolderOverlay
            connectToServerOverlay
        }
    }
    
    // MARK: - Sub-Overlays
    
    @ViewBuilder
    private var passwordPromptOverlay: some View {
        if viewModel.overlayState.showPasswordPrompt, let targetPath = viewModel.overlayState.pendingEncryptedPath {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { viewModel.cancelPasswordPrompt() }
                PasswordPromptSheetView(
                    archivePath: targetPath,
                    initialErrorMessage: viewModel.pendingPasswordContext?.lastErrorMessage,
                    canRememberPassword: viewModel.archiveRememberedPasswordController != nil,
                    onSubmitPasswordResult: { pwd, remember in
                        await viewModel.submitArchivePassword(pwd, remember: remember)
                    },
                    onCancel: { viewModel.cancelPasswordPrompt() }
                )
                .id(viewModel.pendingPasswordContext?.operationID)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: viewModel.overlayState.showPasswordPrompt)
        }
    }
    
    @ViewBuilder
    private var mediaBrowserOverlay: some View {
        if viewModel.overlayState.showImmersiveMediaBrowser,
           let item = viewModel.overlayState.immersiveMediaItem {
            ImmersiveMediaBrowserView(
                item: item,
                onClose: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        viewModel.closeImmersiveMedia()
                    }
                },
                onNavigatePrevious: viewModel.hasPreviousMedia ? {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        viewModel.navigatePreviousMedia()
                    }
                } : nil,
                onNavigateNext: viewModel.hasNextMedia ? {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        viewModel.navigateNextMedia()
                    }
                } : nil
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .zIndex(1000)
        }
    }
    
    @ViewBuilder
    private var omnibarOverlay: some View {
        if viewModel.overlayState.showOmnibar {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        viewModel.overlayState.showOmnibar = false
                    }
                
                OmnibarView(
                    actions: buildOmnibarActions(),
                    onDismiss: {
                        viewModel.overlayState.showOmnibar = false
                    }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .zIndex(2000)
            .animation(.spring(response: 0.32, dampingFraction: 0.95), value: viewModel.overlayState.showOmnibar)
        }
    }
    
    @ViewBuilder
    private var forensicCollisionOverlay: some View {
        if let prompt = viewModel.overlayState.collisionPrompt {
            let vm = viewModel
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.95)) {
                            vm.overlayState.collisionPrompt = nil
                        }
                        prompt.resolver(.stop, false)
                    }
                
                ForensicCollisionPanel(
                    sourceFile: prompt.sourceFile,
                    targetFile: prompt.targetFile,
                    conflictIndex: prompt.conflictIndex,
                    totalConflicts: prompt.totalConflicts,
                    applyToAllRemaining: $applyCollisionToAll,
                    localization: CollisionPanelLocalization.makeLocalization(from: l10n),
                    onResolve: { action, applyAll in
                        Task { @MainActor in
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.95)) {
                                vm.overlayState.collisionPrompt = nil
                            }
                            prompt.resolver(action, applyAll)
                        }
                    }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .zIndex(2500)
            .animation(.spring(response: 0.32, dampingFraction: 0.95), value: viewModel.overlayState.collisionPrompt?.id)
        }
    }

    @ViewBuilder
    private var goToFolderOverlay: some View {
        if viewModel.overlayState.showGoToFolderModal {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        viewModel.overlayState.showGoToFolderModal = false
                    }

                GoToFolderSheetView(
                    viewModel: viewModel,
                    onDismiss: {
                        viewModel.overlayState.showGoToFolderModal = false
                    }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .zIndex(2200)
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: viewModel.overlayState.showGoToFolderModal)
        }
    }

    @ViewBuilder
    private var smartFolderOverlay: some View {
        if viewModel.overlayState.showSmartFolderModal {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        viewModel.overlayState.showSmartFolderModal = false
                    }

                SmartFolderSheetView(
                    viewModel: viewModel,
                    onDismiss: {
                        viewModel.overlayState.showSmartFolderModal = false
                    }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .zIndex(2300)
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: viewModel.overlayState.showSmartFolderModal)
        }
    }

    @ViewBuilder
    private var connectToServerOverlay: some View {
        if viewModel.overlayState.showConnectToServerModal {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        viewModel.overlayState.showConnectToServerModal = false
                    }

                ConnectToServerSheetView(
                    viewModel: viewModel,
                    onDismiss: {
                        viewModel.overlayState.showConnectToServerModal = false
                    }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .zIndex(2400)
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: viewModel.overlayState.showConnectToServerModal)
        }
    }
    
    // MARK: - Action Generators
    
    private func buildOmnibarActions() -> [OmnibarAction] {
        var actions: [OmnibarAction] = [
            OmnibarAction(
                title: l10n.t(MultiWindowLocaleKey.newWindow),
                subtitle: "Open a new independent browser window",
                category: .commands,
                iconSystemName: "macwindow.badge.plus",
                shortcutHint: "⌘N",
                handler: {
                    viewModel.overlayState.showOmnibar = false
                    BrowserWindowRouter.shared.openNewWindow(with: viewModel.navigationState.currentDirectory)
                }
            ),
            OmnibarAction(
                title: "Open Archive",
                subtitle: "Select and browse an archive file",
                category: .archives,
                iconSystemName: "doc.zipper.fill",
                shortcutHint: "⌘O",
                handler: {
                    viewModel.overlayState.showOmnibar = false
                    viewModel.pickAndOpenArchive()
                }
            ),
            OmnibarAction(
                title: "New Archive / Compress Workspace",
                subtitle: "Create new archive or open compression workspace",
                category: .commands,
                iconSystemName: "archivebox.fill",
                shortcutHint: "⇧⌘N",
                handler: {
                    viewModel.overlayState.showOmnibar = false
                    viewModel.openCompressWorkspace()
                }
            ),
            OmnibarAction(
                title: "Toggle Left Sidebar",
                subtitle: "Show or hide the favorites navigation sidebar",
                category: .navigation,
                iconSystemName: "sidebar.left",
                shortcutHint: "⌥⌘S",
                handler: {
                    viewModel.overlayState.showOmnibar = false
                    viewModel.toggleLeftSidebar()
                }
            ),
            OmnibarAction(
                title: "Toggle Inspector",
                subtitle: "Show or hide the file and archive inspector",
                category: .navigation,
                iconSystemName: "sidebar.right",
                shortcutHint: "⌥⌘I",
                handler: {
                    viewModel.overlayState.showOmnibar = false
                    viewModel.toggleInspector()
                }
            ),
            OmnibarAction(
                title: "Go to Downloads",
                subtitle: "Navigate to user Downloads directory",
                category: .navigation,
                iconSystemName: "arrow.down.circle",
                handler: {
                    viewModel.overlayState.showOmnibar = false
                    if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                        viewModel.navigationState.currentDirectory = downloads
                    }
                }
            ),
            OmnibarAction(
                title: "Go to Documents",
                subtitle: "Navigate to user Documents directory",
                category: .navigation,
                iconSystemName: "doc.text",
                handler: {
                    viewModel.overlayState.showOmnibar = false
                    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                        viewModel.navigationState.currentDirectory = docs
                    }
                }
            )
        ]
        
        let recentActions = viewModel.recentArchives
            .sorted(by: { $0.date > $1.date })
            .prefix(10)
            .map { record in
                OmnibarAction(
                    title: record.name,
                    subtitle: record.path,
                    category: .archives,
                    iconSystemName: "doc.zipper",
                    handler: {
                        viewModel.overlayState.showOmnibar = false
                        viewModel.openArchiveAsFolder(url: URL(fileURLWithPath: record.path))
                    }
                )
            }
        actions.append(contentsOf: recentActions)
        
        return actions
    }
}

// MARK: - AppViewState Convenience Extensions

extension AppViewState {
    public func pickAndOpenArchive() {
        let envelope = AppIntentEnvelope(intent: .pickAndOpenArchive, source: .appKitMenu)
        AppIntentDispatcher.shared.dispatch(envelope, targetWindowID: self.windowID)
    }

    public func toggleLeftSidebar() {
        navigationState.isLeftSidebarVisible.toggle()
    }

    @discardableResult
    public func setInspectorVisible(
        _ isVisible: Bool,
        animated: Bool = false
    ) -> InspectorWindowGeometryTransitionOutcome {
        let coordinator = InspectorWindowGeometryCoordinator.coordinator(
            for: self.windowID,
            initialVisibility: navigationState.isInspectorVisible
        )
        if animated {
            return withAnimation(.ttLayout) {
                coordinator.setInspectorVisible(isVisible, for: self)
            }
        }
        return coordinator.setInspectorVisible(isVisible, for: self)
    }

    @discardableResult
    public func toggleInspector(animated: Bool = false) -> InspectorWindowGeometryTransitionOutcome {
        setInspectorVisible(!navigationState.isInspectorVisible, animated: animated)
    }
}
