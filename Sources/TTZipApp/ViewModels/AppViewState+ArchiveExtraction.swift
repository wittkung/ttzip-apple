// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit
#if canImport(TTZipAppServices)
import TTZipAppServices
#endif

extension AppViewState {
    @discardableResult
    public func extractArchiveNonInteractive(
        at archiveURL: URL,
        to destinationURL: URL? = nil,
        password: String? = nil,
        isSmartExtract: Bool = true,
        trashSourceAfterExtract: Bool = false,
        collisionHandling: CollisionHandling? = .policy(.keepBoth),
        bookmarkSession: ActiveBookmarkSession? = nil
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            defer { bookmarkSession?.invalidate() }
            await self?.quickExtractArchive(
                archivePath: archiveURL.path,
                targetDir: destinationURL?.path,
                password: password,
                isSmartExtract: isSmartExtract,
                trashSourceAfterExtract: trashSourceAfterExtract,
                collisionHandling: collisionHandling,
                bookmarkSession: bookmarkSession
            )
        }
    }

    @discardableResult
    public func compressFiles(
        _ urls: [URL],
        to outputURL: URL? = nil,
        format: ArchiveCompressionFormat = .zip,
        bookmarkSession: ActiveBookmarkSession? = nil
    ) -> Task<ArchiveOperationResult?, Never> {
        let inputs = urls.map(\.path)
        let resolvedOutput: String = {
            if let outputURL { return outputURL.path }
            guard let first = urls.first else { return "" }
            let stem = first.deletingPathExtension().lastPathComponent
            return first.deletingLastPathComponent().appendingPathComponent("\(stem).\(format.rawValue)").path
        }()
        return Task { @MainActor [weak self] in
            defer { bookmarkSession?.invalidate() }
            guard let self, !inputs.isEmpty, !resolvedOutput.isEmpty else { return nil }
            return try? await self.quickCompressArchive(
                inputs: inputs,
                outputPath: resolvedOutput,
                format: format,
                bookmarkSession: bookmarkSession
            )
        }
    }

    public func quickExtractArchive(
        path: String,
        destination: String? = nil,
        collisionHandling: CollisionHandling? = nil,
        bookmarkSession: ActiveBookmarkSession? = nil
    ) async {
        await quickExtractArchive(
            archivePath: path,
            targetDir: destination,
            collisionHandling: collisionHandling,
            bookmarkSession: bookmarkSession
        )
    }

    internal func resolveCollisionHandling(destinationDir: String) -> CollisionHandling {
        let setting = UserDefaults.standard.string(forKey: "ttzip_collision_default") ?? "ask"
        switch setting {
        case "keep_both":
            return .policy(.keepBoth)
        case "replace":
            return .policy(.replace)
        case "skip":
            return .policy(.skip)
        default:
            let presenter = CollisionPromptPresenter(destinationRoot: destinationDir) { [weak self] prompt in
                guard let self else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.95)) {
                    self.overlayState.collisionPrompt = prompt
                }
            }
            return .interactive(presenter)
        }
    }

    internal func beginTrackedTask(
        statusMessage: String,
        canPause: Bool = true
    ) -> (id: UUID, handle: TaskExecutionHandle, sheet: ProgressAtomicSheet, uiTask: Task<Void, Never>) {
        let taskId = UUID()
        let handle = ArchiveTaskCoordinator.shared.registerTask(id: taskId)
        self.taskState.currentTaskID = taskId
        self.taskState.canCancelTask = true
        if canPause {
            self.taskState.canPauseTask = true
            self.taskState.canResumeTask = false
            self.taskState.taskStateName = "Processing"
        }
        // MM49: the tracked task keeps its own task UUID as its busy identity, so several
        // tracked tasks may overlap in one window without overwriting each other.
        self.taskState.beginBusyOperation(id: taskId)
        self.taskState.progressValue = 0.0
        self.taskState.statusMessage = statusMessage

        let sheet = ProgressAtomicSheet(handle: handle)
        let stream = SampledProgressStream.makeStream(sheet: sheet, frequency: .sixtyHz)
        let uiProgressTask = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard let self, !Task.isCancelled else { break }
                self.taskState.progressValue = snapshot.fraction
                DockProgressManager.shared.updateProgress(fraction: snapshot.fraction, activeCount: 1)
            }
        }
        return (taskId, handle, sheet, uiProgressTask)
    }

    internal func endTrackedTask(
        id: UUID,
        sheet: ProgressAtomicSheet,
        uiTask: Task<Void, Never>,
        resetPauseState: Bool = true
    ) {
        sheet.markFinished()
        uiTask.cancel()
        ArchiveTaskCoordinator.shared.unregisterTask(id: id)
        // MM49: the busy identity is released outside the focus guard. The window stays busy
        // while any other operation of this window is still alive; the focus fields keep their
        // existing guard.
        self.taskState.endBusyOperation(id: id)
        if self.taskState.currentTaskID == id {
            self.taskState.currentTaskID = nil
            self.taskState.canCancelTask = false
            if resetPauseState {
                self.taskState.canPauseTask = false
                self.taskState.canResumeTask = false
            }
        }
        DockProgressManager.shared.clearProgress()
    }

    public func quickExtractArchive(
        archivePath: String,
        targetDir: String? = nil,
        password: String? = nil,
        isSmartExtract: Bool = true,
        trashSourceAfterExtract: Bool = false,
        collisionHandling: CollisionHandling? = nil,
        bookmarkSession: ActiveBookmarkSession? = nil
    ) async {
        defer { bookmarkSession?.invalidate() }
        let archiveURL = URL(fileURLWithPath: archivePath)
        let archiveName = archiveURL.deletingPathExtension().lastPathComponent
        let candidatePwd = reusablePasswordCandidate(for: archivePath, explicitPassword: password)
        let allowVault = !Self.hasExplicitArchivePassword(password) && self.passwordVault.autoUnlockArchives

        do {
            try await performVerifiedQuickExtract(
                archivePath: archivePath,
                targetDir: targetDir,
                explicitPassword: candidatePwd,
                allowVaultFallback: allowVault,
                isSmartExtract: isSmartExtract,
                trashSourceAfterExtract: trashSourceAfterExtract,
                collisionHandling: collisionHandling
            )
        } catch {
            if Task.isCancelled || (error as? ArchiveError) == .cancelled {
                self.taskState.statusMessage = "Extraction cancelled: \(archiveName)"
                self.taskState.taskStateName = "Cancelled"
            } else if (error as? ArchiveError) == .extractionStopped {
                self.taskState.statusMessage = "Extraction stopped: \(archiveName)"
                self.taskState.taskStateName = "Stopped"
            } else {
                let classified = ArchivePasswordErrorClassifier.classify(error)
                if classified.category == .wrongPassword {
                    stagePasswordPromptContext(
                        archivePath: archivePath,
                        kind: .quickExtract(
                            targetDir: targetDir,
                            isSmartExtract: isSmartExtract,
                            trashSourceAfterExtract: trashSourceAfterExtract,
                            collisionHandling: collisionHandling
                        ),
                        failedPassword: candidatePwd,
                        errorMessage: Self.hasExplicitArchivePassword(password) ? classified.message : nil
                    )
                    self.taskState.statusMessage = "Archive is password-protected"
                } else if case .partialExtractionFailure(let outcome) = error as? ArchiveError {
                    self.taskState.statusMessage = "Extracted \(archiveName) with \(outcome.failed.count) failed item(s)"
                    self.taskState.taskStateName = "Completed with errors"
                    AppErrorReporter.shared.reportError(error, contextTitle: "Partial Extraction Error")
                } else {
                    self.taskState.statusMessage = "Extraction failed: \(classified.message)"
                    AppErrorReporter.shared.reportError(error, contextTitle: "Extraction Error")
                }
            }
        }
    }

    public func extractSingleEntry(archivePath: String, entryPath: String, isDirectory: Bool, destinationDir: String) async {
        await extractEntries(archivePath: archivePath, entryPaths: [entryPath], destinationDir: destinationDir)
    }

    /// Extracts the selected archive entries (directories include their descendants) into a user-chosen
    /// folder, placed relative to their deepest common parent, with the user's collision preference.
    public func extractEntries(
        archivePath: String,
        entryPaths: [String],
        destinationDir: String,
        password: String? = nil,
        collisionHandling: CollisionHandling? = nil,
        bookmarkSession: ActiveBookmarkSession? = nil
    ) async {
        defer { bookmarkSession?.invalidate() }
        guard let firstEntry = entryPaths.first else { return }
        let label = entryPaths.count == 1 ? (firstEntry as NSString).lastPathComponent : "\(entryPaths.count) items"
        let candidatePwd = reusablePasswordCandidate(for: archivePath, explicitPassword: password)

        do {
            try await performVerifiedExtractEntries(
                archivePath: archivePath,
                entryPaths: entryPaths,
                destinationDir: destinationDir,
                explicitPassword: candidatePwd,
                collisionHandling: collisionHandling
            )
        } catch {
            if Task.isCancelled || (error as? ArchiveError) == .cancelled {
                self.taskState.statusMessage = "Extraction cancelled: \(label)"
                self.taskState.taskStateName = "Cancelled"
            } else if (error as? ArchiveError) == .extractionStopped {
                finishEntryExtraction(
                    ExtractionOutcome(status: .stopped, extracted: 0, replaced: 0, keptBoth: 0, skipped: 0, failed: []),
                    label: label,
                    entryPaths: entryPaths,
                    destinationDir: destinationDir
                )
            } else if case .partialExtractionFailure(let outcome) = error as? ArchiveError {
                finishEntryExtraction(
                    outcome,
                    label: label,
                    entryPaths: entryPaths,
                    destinationDir: destinationDir
                )
            } else {
                let classified = ArchivePasswordErrorClassifier.classify(error)
                if classified.category == .wrongPassword {
                    stagePasswordPromptContext(
                        archivePath: archivePath,
                        kind: .extractEntries(
                            entryPaths: entryPaths,
                            destinationDir: destinationDir,
                            collisionHandling: collisionHandling
                        ),
                        failedPassword: candidatePwd,
                        errorMessage: Self.hasExplicitArchivePassword(password) ? classified.message : nil
                    )
                    self.taskState.statusMessage = "Archive is password-protected"
                } else {
                    self.taskState.statusMessage = "Extraction failed: \(classified.message)"
                    AppErrorReporter.shared.reportError(error, contextTitle: "Entry Extraction Failed")
                }
            }
        }
    }

    internal func finishEntryExtraction(
        _ outcome: ExtractionOutcome,
        label: String,
        entryPaths: [String],
        destinationDir: String
    ) {
        switch outcome.status {
        case .stopped:
            self.taskState.statusMessage = "Extraction stopped: \(label)"
            self.taskState.taskStateName = "Stopped"
            return
        case .completedWithFailures:
            self.taskState.statusMessage = "Extracted \(label) with \(outcome.failed.count) failed item(s)"
            self.taskState.taskStateName = "Completed with errors"
            AppErrorReporter.shared.reportError(
                ArchiveError.partialExtractionFailure(outcome: outcome),
                contextTitle: "Partial Extraction Error"
            )
            return
        case .completed:
            self.taskState.progressValue = 1.0
            self.taskState.statusMessage = "Extracted entry: \(label)"
            let revealsSingleItem = entryPaths.count == 1 && outcome.keptBoth == 0 && outcome.skipped == 0
            let revealPath = revealsSingleItem
                ? (destinationDir as NSString).appendingPathComponent((entryPaths[0] as NSString).lastPathComponent)
                : destinationDir
            self.fileViewer.revealInFinder(at: revealPath)
        }
    }

    /// Extracts an archive directly to the specified destination directory with smooth sampled UI progress.
    @discardableResult
    public func extractArchive(
        archivePath: String,
        destinationDir: String,
        password: String? = nil,
        autoVaultUnlock: Bool = true,
        bookmarkSession: ActiveBookmarkSession? = nil
    ) async throws -> ExtractResult {
        defer { bookmarkSession?.invalidate() }
        let archiveURL = URL(fileURLWithPath: archivePath)
        let archiveLease = RootFolderAccessManager.shared.acquireLease(for: archiveURL)
        let destLease = RootFolderAccessManager.shared.acquireLease(for: URL(fileURLWithPath: destinationDir))
        defer {
            destLease?.release()
            archiveLease?.release()
        }

        let archiveName = (archivePath as NSString).lastPathComponent
        let tracked = beginTrackedTask(statusMessage: "Extracting \(archiveName)...", canPause: true)
        defer { endTrackedTask(id: tracked.id, sheet: tracked.sheet, uiTask: tracked.uiTask, resetPauseState: true) }

        let handling = resolveCollisionHandling(destinationDir: destinationDir)
        if await extractQuarantinedArchiveIfRequired(
            archiveURL: archiveURL, destinationDir: destinationDir, password: password
        ) {
            return ExtractResult(
                archivePath: archivePath,
                destinationDir: destinationDir,
                durationSeconds: 0.1,
                unlockedPassword: nil,
                isVaultUnlocked: false
            )
        }
        do {
            let result = try await TTZipEngineFacade.shared.quickExtract(
                archivePath: archivePath,
                destinationDir: destinationDir,
                password: password,
                autoVaultUnlock: autoVaultUnlock,
                cachePasswordOnSuccess: false,
                handling: handling,
                progress: { prog in tracked.sheet.ingest(progress: prog) },
                token: tracked.handle.uniffiToken
            )
            self.taskState.progressValue = 1.0
            self.taskState.taskStateName = "Idle"
            self.taskState.statusMessage = "Extraction complete: \(archiveName)"
            return result
        } catch {
            if tracked.handle.isCancelled || Task.isCancelled || (error as? ArchiveError) == .cancelled {
                self.taskState.statusMessage = "Extraction cancelled: \(archiveName)"
                self.taskState.taskStateName = "Cancelled"
                throw ArchiveError.cancelled
            } else if (error as? ArchiveError) == .extractionStopped {
                self.taskState.statusMessage = "Extraction stopped: \(archiveName)"
                self.taskState.taskStateName = "Stopped"
                throw ArchiveError.extractionStopped
            } else if case .partialExtractionFailure(let outcome) = error as? ArchiveError {
                self.taskState.statusMessage = "Extracted \(archiveName) with \(outcome.failed.count) failed item(s)"
                self.taskState.taskStateName = "Completed with errors"
                AppErrorReporter.shared.reportError(error, contextTitle: "Partial Extraction Error")
                throw error
            } else {
                self.taskState.statusMessage = "Extraction failed: \(error.localizedDescription)"
                AppErrorReporter.shared.reportError(error, contextTitle: "Extraction Error")
                throw error
            }
        }
    }

    private static func hasExplicitArchivePassword(_ password: String?) -> Bool {
        guard let password else { return false }
        return !password.isEmpty
    }

    private func extractQuarantinedArchiveIfRequired(
        archiveURL: URL, destinationDir: String, password: String?
    ) async -> Bool {
        guard !Self.hasExplicitArchivePassword(password),
              QuarantineWorkerClient.shared.shouldRouteToSandboxWorker(url: archiveURL) else { return false }
        return await extractQuarantinedArchive(
            archiveURL: archiveURL, destinationDirectory: URL(fileURLWithPath: destinationDir)
        )
    }

    /// Compresses input files directly into target archive with smooth sampled UI progress and cancellation cascade.
    @discardableResult
    public func quickCompressArchive(
        inputs: [String],
        outputPath: String,
        format: ArchiveCompressionFormat = .zip,
        level: ArchiveCompressionLevel = .normal,
        password: String? = nil,
        splitSize: Int64? = nil,
        filterOptions: ArchiveFilterOptions = .defaultClean,
        advancedOptions: ArchiveAdvancedOptions? = nil,
        bookmarkSession: ActiveBookmarkSession? = nil
    ) async throws -> ArchiveOperationResult {
        defer { bookmarkSession?.invalidate() }
        let inputLeases = inputs.compactMap { RootFolderAccessManager.shared.acquireLease(for: URL(fileURLWithPath: $0)) }
        let outputDirURL = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        let outputLease = RootFolderAccessManager.shared.acquireLease(for: outputDirURL)
        defer {
            outputLease?.release()
            for lease in inputLeases {
                lease.release()
            }
        }

        let outputName = (outputPath as NSString).lastPathComponent
        let tracked = beginTrackedTask(statusMessage: "Compressing \(outputName)...", canPause: true)
        defer { endTrackedTask(id: tracked.id, sheet: tracked.sheet, uiTask: tracked.uiTask, resetPauseState: true) }

        do {
            let result = try await TTZipEngineFacade.shared.quickCompress(
                inputs: inputs,
                outputPath: outputPath,
                format: format,
                level: level,
                password: password,
                splitSize: splitSize,
                filterOptions: filterOptions,
                advancedOptions: advancedOptions,
                progress: { prog in tracked.sheet.ingest(progress: prog) },
                token: tracked.handle.uniffiToken
            )
            if let outcome = result.outcome, outcome.status == .completedWithFailures {
                self.taskState.progressValue = 1.0
                self.taskState.taskStateName = "Completed with warnings"
                self.taskState.statusMessage = "Compressed \(outputName) with \(outcome.failed.count) cleanup warning(s)"
            } else {
                self.taskState.progressValue = 1.0
                self.taskState.taskStateName = "Idle"
                self.taskState.statusMessage = "Compression complete: \(outputName)"
            }
            return result
        } catch {
            let archiveError = error as? ArchiveError
            let isCleanCancel: Bool
            if case .createTransactionIncomplete = archiveError {
                isCleanCancel = false
            } else if archiveError != nil {
                isCleanCancel = (archiveError == .cancelled)
            } else {
                isCleanCancel = error is CancellationError || Task.isCancelled || tracked.handle.isCancelled
            }
            if isCleanCancel {
                self.taskState.statusMessage = "Compression cancelled: \(outputName)"
                self.taskState.taskStateName = "Cancelled"
                throw ArchiveError.cancelled
            } else {
                self.taskState.statusMessage = "Compression failed: \(error.localizedDescription)"
                AppErrorReporter.shared.reportError(error, contextTitle: "Compression Error")
                throw error
            }
        }
    }

    public func openCompressWorkspace(
        paths: [String] = [],
        options: CompressIntentOptions? = nil,
        bookmarkSession: ActiveBookmarkSession? = nil
    ) {
        defer { bookmarkSession?.invalidate() }
        let flattened = paths.flatMap { $0.components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
        if !flattened.isEmpty {
            compressSession.loadInputPaths(flattened)
        }
        if let options {
            compressSession.applyIntentOptions(options)
        }
        self.navigationState.openCompressWorkspaceTab()
        if let window = BrowserWindowRegistry.shared.nsWindow(for: self.windowID)
            ?? NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
