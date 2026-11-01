// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI
#if canImport(TTZipAppServices)
#endif
#if canImport(TTZipAppViewModels)
#endif

/// Reactive SwiftUI Commands struct for macOS native menu bar integration.
public struct TTZipMenuCommands: Commands {
    @FocusedValue(\.appViewState) private var viewModel
    private var l10n = AppLocalizationState.shared

    private var targetViewModel: AppViewState? {
        viewModel ?? (BrowserWindowRegistry.shared.activeController as? AppViewState)
    }
    
    public init() {}
    
    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            #if DIRECT_DISTRIBUTION || DIRECT_BUILD
            Button(l10n.t(L10n.Menu.checkForUpdates)) {
                UpdateManager.shared.checkForUpdates()
            }
            #endif
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
                revealLogsInFinder()
            }
            
            Button(l10n.t(L10n.Menu.exportDiagnosticReport)) {
                exportDiagnosticReport()
            }
        }
    }
    
    // MARK: - Diagnostics Actions
    
    private func revealLogsInFinder() {
        TTLogFileWriter.shared.flushSync()
        let logPath = TTLogFileWriter.shared.logFilePath
        let logDir = TTLogFileWriter.shared.logDirectoryPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: logPath) {
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true, attributes: nil)
            fm.createFile(atPath: logPath, contents: nil, attributes: nil)
        }
        NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: logDir)
    }
    
    private func exportDiagnosticReport() {
        TTLogFileWriter.shared.flushSync()
        
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory.appendingPathComponent("TTZip-Diagnostics-\(UUID().uuidString)")
            try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
            defer {
                try? fm.removeItem(at: tempDir)
            }
            
            // 1. Collect system hardware model and macOS version
            var size: size_t = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var modelBuffer = [CChar](repeating: 0, count: max(1, size))
            sysctlbyname("hw.model", &modelBuffer, &size, nil, 0)
            let hardwareModel = modelBuffer.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) } ?? "Unknown"
            }
            
            let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
            let processorCount = ProcessInfo.processInfo.activeProcessorCount
            let memoryGB = String(format: "%.1f GB", Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024))
            let timestamp = Date().formatted(.iso8601)
            
            let reportContent = """
            TTZip Diagnostic Report
            =======================
            Generated: \(timestamp)
            Hardware Model: \(hardwareModel)
            macOS Version: \(osVersion)
            Active Processors: \(processorCount)
            Physical Memory: \(memoryGB)
            """
            
            let reportFile = tempDir.appendingPathComponent("system_info.txt")
            try? reportContent.write(to: reportFile, atomically: true, encoding: .utf8)
            
            // 2. Collect ttzip.log* files
            let logDirURL = URL(fileURLWithPath: TTLogFileWriter.shared.logDirectoryPath)
            if let entries = try? fm.contentsOfDirectory(at: logDirURL, includingPropertiesForKeys: nil) {
                for fileURL in entries {
                    let name = fileURL.lastPathComponent
                    if name == "ttzip.log" || (name.hasPrefix("ttzip.") && name.hasSuffix(".log")) {
                        let dest = tempDir.appendingPathComponent(name)
                        try? fm.copyItem(at: fileURL, to: dest)
                    }
                }
            }
            
            // 3. Archive to ~/Desktop/TTZip-Diagnostics-[Date].zip
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
            let dateStr = dateFormatter.string(from: Date())
            let desktopURL = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
            let targetZipURL = desktopURL.appendingPathComponent("TTZip-Diagnostics-\(dateStr).zip")
            
            let writer = ArchiveWriter()
            var archivedSuccessfully = false
            if let collectedItems = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil),
               !collectedItems.isEmpty {
                let inputPaths = collectedItems.map { $0.path }
                do {
                    try writer.createArchiveSync(
                        outputPath: targetZipURL.path,
                        format: .zip,
                        inputPaths: inputPaths
                    )
                    archivedSuccessfully = true
                } catch {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    process.arguments = ["-c", "-k", "--sequesterRsrc", tempDir.path, targetZipURL.path]
                    try? process.run()
                    process.waitUntilExit()
                    archivedSuccessfully = (process.terminationStatus == 0)
                }
            }
            
            if archivedSuccessfully && fm.fileExists(atPath: targetZipURL.path) {
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([targetZipURL])
                }
            }
        }
    }
}
