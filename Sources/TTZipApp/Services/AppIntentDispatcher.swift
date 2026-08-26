// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
import AppKit
import TTZipCore

public enum IntentDispatchResult: Sendable, Equatable {
    case success
    case rejected(reason: String)
    case queued
}

@MainActor
public final class AppIntentDispatcher {
    public static let shared = AppIntentDispatcher()
    
    private weak var appViewState: AppViewState?
    
    private init() {}
    
    public func bind(state: AppViewState) {
        self.appViewState = state
    }
    
    @discardableResult
    public func dispatch(_ envelope: AppIntentEnvelope) -> IntentDispatchResult {
        guard let state = appViewState else {
            return .rejected(reason: "AppViewState is not bound to dispatcher")
        }
        
        // Bring application to foreground
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        switch envelope.intent {
        case .openArchive(let url, let password):
            state.activeTab = .home
            state.openArchiveAsFolder(url: url)
            if let pwd = password {
                Task { await state.loadArchive(path: url.path, password: pwd) }
            }
            return .success
            
        case .navigateToDirectory(let url):
            state.activeTab = .home
            state.currentDirectory = url
            state.selectedDiskItem = nil
            return .success
            
        case .switchTab(let tab):
            state.activeTab = tab
            return .success
            
        case .pickAndOpenArchive:
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                state.openArchiveAsFolder(url: url)
            }
            return .success
            
        case .createArchive(let sourcePaths, _):
            state.openCompressWorkspace(paths: sourcePaths)
            return .success
            
        case .extractArchive(let archivePaths, let options):
            for path in archivePaths {
                Task {
                    await state.quickExtractArchive(
                        archivePath: path,
                        targetDir: options.destinationDirectory?.path,
                        password: options.password,
                        isSmartExtract: options.isSmartExtract,
                        trashSourceAfterExtract: options.deleteSourceAfterExtraction
                    )
                }
            }
            return .success
            
        case .inspectArchive(let archivePath):
            state.overlayState.inspectingArchivePath = archivePath
            state.overlayState.showArchiveInspectorModal = true
            return .success
            
        case .verifyIntegrity(let archivePath):
            state.overlayState.inspectingArchivePath = archivePath
            state.overlayState.showArchiveInspectorModal = true
            return .success
            
        case .autofillVaultPassword(let archivePath):
            Task {
                await state.loadArchive(path: archivePath, password: nil)
            }
            return .success
            
        case .promptPassword(let archivePath):
            state.pendingEncryptedPath = archivePath
            state.showPasswordPrompt = true
            return .success
            
        case .addFilesToArchive(let archivePath, let sourcePaths, let destinationSubfolder):
            Task {
                try? await InPlaceArchiveMutationEngine.shared.addFilesToArchive(
                    archivePath: archivePath,
                    sourceFilePaths: sourcePaths,
                    destinationVirtualFolder: destinationSubfolder,
                    password: state.activePassword
                )
                await state.loadArchive(path: archivePath, password: state.activePassword)
            }
            return .success
            
        case .deleteArchiveEntries(let archivePath, let entryPaths):
            Task {
                try? await InPlaceArchiveMutationEngine.shared.deleteEntriesFromArchive(
                    archivePath: archivePath,
                    entryPathsToDelete: entryPaths,
                    password: state.activePassword
                )
                await state.loadArchive(path: archivePath, password: state.activePassword)
            }
            return .success
            
        case .previewItem(let url):
            state.previewMediaFile(path: url.path)
            return .success
            
        case .revealInFinder(let url):
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            return .success
        }
    }
    
    @discardableResult
    public func dispatch(_ intent: AppIntent, from source: AppIntentSource) -> IntentDispatchResult {
        let envelope = AppIntentEnvelope(intent: intent, source: source)
        return dispatch(envelope)
    }
}
