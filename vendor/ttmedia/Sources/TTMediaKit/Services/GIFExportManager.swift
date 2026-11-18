// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os.log
import UserNotifications

/// High-level presentation manager orchestrating animated GIF exports,
/// cancellation lifecycle, and system sound/banner notifications upon completion.
@MainActor
public final class GIFExportManager: ObservableObject {
    public static let shared = GIFExportManager()

    private let logger = Logger(subsystem: "dev.metastudyline.ttmedia", category: "GIFExportManager")

    // MARK: - Published Reactive State

    /// Indicates whether a GIF export operation is currently in progress.
    @Published public var isExporting: Bool = false

    /// Normalized progress value between 0.0 (started) and 1.0 (completed).
    @Published public var exportProgress: Double = 0.0

    /// Holds the localized error description if the last export operation failed.
    @Published public var lastErrorMessage: String? = nil

    /// Source URL of the currently active GIF export operation.
    @Published public var activeSourceURL: URL? = nil

    /// Destination URL of the most recently completed GIF export.
    @Published public var lastCompletedDestinationURL: URL? = nil

    /// User-configured GIF export parameters in the video preview popover.
    @Published public var selectedOptions: GIFExportOptions = GIFExportOptions()

    /// Optional custom loop start timestamp in seconds.
    @Published public var customLoopStart: Double? = nil

    /// Optional custom loop end timestamp in seconds.
    @Published public var customLoopEnd: Double? = nil

    /// Optional injectable save panel presenter for deterministic headless testing.
    public var savePanelPresenter: (@MainActor (URL) async -> URL?)? = nil

    /// Reference to the active asynchronous export task for cancellation control.
    private var currentExportTask: Task<Void, Never>? = nil

    /// Retains the most recent task reference so callers awaiting completion observe cancellation cleanup.
    private var lastDispatchedTask: Task<Void, Never>? = nil

    /// Tracks the in-flight temporary staging URL so cancellation removes only staged partial output.
    private var activeStagingURL: URL? = nil

    /// Identifies the currently active export operation so stale unwinding tasks cannot mutate replacement state.
    private var activeOperationID: UUID? = nil

    private init() {}

    // MARK: - Source Validation & Time Range Resolution

    /// Returns a human-readable reason if the source URL cannot be exported as a GIF, or nil when compatible.
    public func compatibilityIssue(for sourceURL: URL?) -> String? {
        guard let sourceURL else {
            return "No video source URL is available for GIF export."
        }
        switch GIFExportPipeline.shared.validateSourceCompatibility(sourceURL) {
        case .success:
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }

    /// Resolves export bounds from `loopA` and `loopB`, falling back to +/- 3 seconds of `currentTime`.
    public func resolvedTimeRange(
        loopA: Double?,
        loopB: Double?,
        currentTime: Double,
        duration: Double
    ) -> ClosedRange<Double> {
        resolveExportTimeRange(loopA: loopA, loopB: loopB, currentTime: currentTime, duration: duration)
    }

    // MARK: - Public Export API

    /// Initiates animated GIF export for the active player's A-B loop segment.
    public func exportCurrentLoopAsGIF(
        loopA: Double?,
        loopB: Double?,
        currentTime: Double,
        duration: Double,
        sourceURL: URL,
        options: GIFExportOptions = GIFExportOptions()
    ) {
        guard !isExporting else {
            logger.warning("GIF export already in progress; ignoring duplicate trigger")
            return
        }

        if let issue = compatibilityIssue(for: sourceURL) {
            lastErrorMessage = issue
            isExporting = false
            exportProgress = 0.0
            return
        }

        let effectiveLoopA = loopA ?? customLoopStart
        let effectiveLoopB = loopB ?? customLoopEnd
        let timeRange = resolveExportTimeRange(
            loopA: effectiveLoopA,
            loopB: effectiveLoopB,
            currentTime: currentTime,
            duration: duration
        )

        let operationID = UUID()
        activeOperationID = operationID
        isExporting = true
        exportProgress = 0.0
        lastErrorMessage = nil
        activeSourceURL = sourceURL
        activeStagingURL = nil

        currentExportTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runExportWorkflow(
                sourceURL: sourceURL,
                loopA: effectiveLoopA,
                loopB: effectiveLoopB,
                timeRange: timeRange,
                options: options,
                operationID: operationID
            )
        }
        currentExportTask = task
        lastDispatchedTask = task
    }

    /// Cancels any ongoing GIF export operation and removes any partial output file.
    public func cancelExport() {
        let partialURL = activeStagingURL
        activeOperationID = nil
        currentExportTask?.cancel()
        currentExportTask = nil
        isExporting = false
        exportProgress = 0.0
        activeSourceURL = nil
        activeStagingURL = nil
        if let partialURL {
            try? FileManager.default.removeItem(at: partialURL)
        }
        logger.info("Active GIF export task cancelled by user request")
    }

    /// Cancels any active GIF export associated with a video preview that is closing.
    public func handlePreviewClosed(for sourceURL: URL) {
        guard let active = activeSourceURL else { return }
        let activeCanonical = active.standardizedFileURL.resolvingSymlinksInPath()
        let closedCanonical = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard activeCanonical == closedCanonical else { return }
        logger.info("Preview closed for active GIF export source \(sourceURL.lastPathComponent); cancelling export")
        cancelExport()
    }

    /// Waits for the currently active or cancelling export task to finish.
    public func waitForCurrentExport() async {
        await lastDispatchedTask?.value
    }

    /// Updates the normalized progress from background tasks.
    public func updateProgress(_ progress: Double) {
        guard isExporting else { return }
        exportProgress = progress
    }

    // MARK: - Internal Workflow & Time Range Resolution

    private func resolveExportTimeRange(
        loopA: Double?,
        loopB: Double?,
        currentTime: Double,
        duration: Double
    ) -> ClosedRange<Double> {
        if let a = loopA, let b = loopB {
            if b <= a {
                let clamped = max(0.0, a)
                return clamped...clamped
            }
            if b - a >= 0.1 {
                let start = max(0.0, a)
                let end = max(start + 0.1, b)
                return start...end
            }
        }

        let effDuration = duration > 0 ? duration : (currentTime + 3.0)
        let lower = max(0.0, currentTime - 3.0)
        let upper = min(effDuration, currentTime + 3.0)

        if upper - lower >= 0.1 {
            return lower...upper
        }
        return lower...(lower + 3.0)
    }

    private func resolveDestinationURL(for sourceURL: URL) async -> URL? {
        if let presenter = savePanelPresenter {
            return await presenter(sourceURL)
        }
        return await presentSavePanel()
    }

    private func runExportWorkflow(
        sourceURL: URL,
        loopA: Double?,
        loopB: Double?,
        timeRange: ClosedRange<Double>,
        options: GIFExportOptions,
        operationID: UUID
    ) async {
        guard let destinationURL = await resolveDestinationURL(for: sourceURL) else {
            if activeOperationID == operationID {
                resetActiveState()
            }
            logger.info("User cancelled GIF export save panel")
            return
        }

        if Task.isCancelled || activeOperationID != operationID {
            cleanupPartialAndReset(stagingURL: nil, operationID: operationID)
            return
        }

        if let a = loopA, let b = loopB, b <= a {
            failExport(
                with: GIFExportError.invalidTimeRange(lower: a, upper: b),
                stagingURL: nil,
                operationID: operationID
            )
            return
        }

        let stagingURL = GIFExportPipeline.shared.makeStagingURL(for: destinationURL)
        if activeOperationID == operationID {
            activeStagingURL = stagingURL
        }
        await executePipelineExport(
            sourceURL: sourceURL,
            timeRange: timeRange,
            destinationURL: destinationURL,
            stagingURL: stagingURL,
            options: options,
            operationID: operationID
        )
    }

    private func executePipelineExport(
        sourceURL: URL,
        timeRange: ClosedRange<Double>,
        destinationURL: URL,
        stagingURL: URL,
        options: GIFExportOptions,
        operationID: UUID
    ) async {
        do {
            try await GIFExportPipeline.shared.exportGIF(
                sourceURL: sourceURL,
                timeRange: timeRange,
                destinationURL: destinationURL,
                options: options,
                stagingURL: stagingURL
            ) { progress in
                Task { @MainActor in
                    guard GIFExportManager.shared.activeOperationID == operationID else { return }
                    GIFExportManager.shared.updateProgress(progress)
                }
            }
            try Task.checkCancellation()
            guard activeOperationID == operationID else {
                cleanupPartialAndReset(stagingURL: stagingURL, operationID: operationID)
                return
            }
            lastCompletedDestinationURL = destinationURL
            resetActiveState(finalProgress: 1.0)
            handleExportSuccess(destinationURL: destinationURL)
        } catch is CancellationError {
            cleanupPartialAndReset(stagingURL: stagingURL, operationID: operationID)
        } catch GIFExportError.cancelled {
            cleanupPartialAndReset(stagingURL: stagingURL, operationID: operationID)
        } catch {
            failExport(with: error, stagingURL: stagingURL, operationID: operationID)
        }
    }

    internal func beginOperationForTesting(operationID: UUID, stagingURL: URL) {
        activeOperationID = operationID
        activeStagingURL = stagingURL
        isExporting = true
    }

    internal func cleanupPartialAndReset(stagingURL: URL?, operationID: UUID) {
        if let stagingURL {
            try? FileManager.default.removeItem(at: stagingURL)
        }
        guard activeOperationID == operationID else { return }
        resetActiveState()
        logger.info("GIF export cancelled cleanly")
    }

    private func failExport(with error: any Error, stagingURL: URL?, operationID: UUID) {
        if let stagingURL {
            try? FileManager.default.removeItem(at: stagingURL)
        }
        guard activeOperationID == operationID else { return }
        resetActiveState()
        lastErrorMessage = error.localizedDescription
        handleExportFailure(error: error)
    }

    private func resetActiveState(finalProgress: Double = 0.0) {
        activeOperationID = nil
        isExporting = false
        exportProgress = finalProgress
        activeSourceURL = nil
        activeStagingURL = nil
        currentExportTask = nil
    }

    // MARK: - Save Dialog

    private func presentSavePanel() async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export A-B Loop as GIF"

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        panel.nameFieldStringValue = "TTMedia_Clip_\(timestamp).gif"
        panel.allowedContentTypes = [.gif]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window) { res in
                    continuation.resume(returning: res)
                }
            } else {
                continuation.resume(returning: panel.runModal())
            }
        }

        guard response == .OK, let targetURL = panel.url else {
            return nil
        }
        return targetURL
    }

    // MARK: - Notifications & Sounds

    private func handleExportSuccess(destinationURL: URL) {
        logger.info("GIF export succeeded -> \(destinationURL.path)")

        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }

        if Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" {
            let content = UNMutableNotificationContent()
            content.title = "GIF Export Completed"
            content.body = "Saved \(destinationURL.lastPathComponent)"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "dev.metastudyline.ttmedia.gif.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }

        NotificationCenter.default.post(
            name: .gifExportCompletedNotification,
            object: destinationURL
        )
    }

    private func handleExportFailure(error: any Error) {
        logger.error("GIF export failed: \(error.localizedDescription)")
        NSSound.beep()
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    /// Dispatched when an animated GIF export successfully finishes.
    public static let gifExportCompletedNotification = Notification.Name("dev.metastudyline.ttmedia.gifExportCompleted")
}
