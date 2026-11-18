// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

/// Reactive SwiftUI Commands struct for macOS native menu bar integration.
public struct TTZipMenuCommands: Commands {
    @FocusedValue(\.appViewState) private var viewModel
    private var l10n = AppLocalizationState.shared

    private var targetViewModel: AppViewState? {
        viewModel ?? (BrowserWindowRegistry.shared.activeController as? AppViewState)
    }
    
    private let checkForUpdates: (@MainActor () -> Void)?

    public init(checkForUpdates: (@MainActor () -> Void)?) {
        self.checkForUpdates = checkForUpdates
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            if let checkForUpdates {
                Button(l10n.t(L10n.Menu.checkForUpdates), action: checkForUpdates)
            }
        }
        
        CommandGroup(replacing: .newItem) {
            Button(l10n.t(MultiWindowLocaleKey.newWindow)) {
                _ = BrowserWindowRouter.shared.openNewWindow(
                    with: targetViewModel?.navigationState.currentDirectory
                )
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(l10n.t(MultiWindowLocaleKey.newSmartFolder)) {
                _ = BrowserWindowRouter.shared.dispatchApplicationCommand(
                    .presentNewSmartFolder(initialScopeDirectory: targetViewModel?.effectiveDisplayDirectory),
                    preferredWindowID: targetViewModel?.windowID
                )
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button(l10n.t(MultiWindowLocaleKey.findInWindow)) {
                _ = BrowserWindowRouter.shared.dispatchApplicationCommand(
                    .focusFind(initialQuery: nil),
                    preferredWindowID: targetViewModel?.windowID
                )
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button(l10n.t(MultiWindowLocaleKey.goToFolder)) {
                _ = BrowserWindowRouter.shared.dispatchApplicationCommand(
                    .presentGoToFolder(initialPath: targetViewModel?.effectiveDisplayDirectory.path),
                    preferredWindowID: targetViewModel?.windowID
                )
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Button(l10n.t(MultiWindowLocaleKey.connectToServer)) {
                _ = BrowserWindowRouter.shared.dispatchApplicationCommand(
                    .presentConnectToServer(initialAddress: nil),
                    preferredWindowID: targetViewModel?.windowID
                )
            }
            .keyboardShortcut("k", modifiers: [.command, .option])

            Divider()

            Button(l10n.t(MultiWindowLocaleKey.newArchiveMenu)) {
                let envelope = AppIntentEnvelope(
                    intent: .createArchive(sourcePaths: [], options: CompressIntentOptions()),
                    source: .appKitMenu
                )
                AppIntentDispatcher.shared.dispatch(envelope, targetWindowID: targetViewModel?.windowID)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            
            Button(l10n.t(L10n.Menu.openArchive)) {
                let envelope = AppIntentEnvelope(intent: .pickAndOpenArchive, source: .appKitMenu)
                AppIntentDispatcher.shared.dispatch(envelope, targetWindowID: targetViewModel?.windowID)
            }
            .keyboardShortcut("o", modifiers: .command)
            
            Button(l10n.t(L10n.Menu.omnibar)) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.95)) {
                    targetViewModel?.overlayState.showOmnibar.toggle()
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(targetViewModel == nil)
            
            Button(l10n.t(L10n.Menu.globalSearch)) {
                GlobalSearchPanelController.shared.toggle()
            }
            .keyboardShortcut(" ", modifiers: [.command, .shift])
            
            Divider()
            
            Button(l10n.t(L10n.Extract.action) + "...") {
                targetViewModel?.overlayState.showExtractModal = true
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(targetViewModel?.explorerState.currentArchivePath == nil)
            
            Button(l10n.t(L10n.Menu.quickExtractAll)) {
                if let target = targetViewModel, let path = target.explorerState.currentArchivePath {
                    Task { @MainActor in
                        await target.quickExtractArchive(path: path, destination: nil)
                    }
                }
            }
            .keyboardShortcut("e", modifiers: [.option, .command])
            .disabled(targetViewModel?.explorerState.currentArchivePath == nil)
        }
        
        CommandGroup(after: .sidebar) {
            Button(l10n.t(L10n.Menu.toggleSidebar)) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    targetViewModel?.toggleLeftSidebar()
                }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(targetViewModel == nil)

            Button(l10n.t(L10n.Menu.toggleInspector)) {
                _ = targetViewModel?.toggleInspector(animated: true)
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(targetViewModel == nil)
        }
        
        CommandGroup(replacing: .help) {
            Button(l10n.t(L10n.Menu.revealLogsInFinder)) {
                DiagnosticsSupportService.revealLogsInFinder()
            }

            Button(l10n.t(L10n.Menu.exportDiagnosticReport)) {
                DiagnosticsSupportService.exportDiagnosticReport()
            }
        }
    }
}
