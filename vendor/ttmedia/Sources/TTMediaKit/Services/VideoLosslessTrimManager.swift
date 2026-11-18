// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os.log
import UserNotifications

/// High-level presentation manager orchestrating lossless video trimming,
/// staging cleanup, cancellation lifecycle, and user notifications.
@MainActor
public final class VideoLosslessTrimManager: ObservableObject {
    public static let shared = VideoLosslessTrimManager()

    private let logger = Logger(subsystem: "dev.metastudyline.ttmedia", category: "VideoLosslessTrimManager")

    @Published public var isTrimming: Bool = false
    @Published public var trimProgress: Double = 0.0
    @Published public var lastErrorMessage: String? = nil
    @Published public var activeSourceURL: URL? = nil
    @Published public var lastCompletedDestinationURL: URL? = nil
    @Published public var lastCompletedResult: VideoLosslessTrimResult? = nil
    @Published public var customTrimStart: Double? = nil
    @Published public var customTrimEnd: Double? = nil

    /// Optional injectable save panel presenter for deterministic headless testing.
    public var savePanelPresenter: (@MainActor (URL) async -> URL?)? = nil

    private var currentTrimTask: Task<Void, Never>? = nil
    private var lastDispatchedTask: Task<Void, Never>? = nil
    private var activeStagingURL: URL? = nil
    private var activeOperationID: UUID? = nil

    private init() {}

    public func compatibilityIssue(for sourceURL: URL?) -> String? {
        guard let sourceURL else {
            return "No video source URL is available for lossless trimming."
        }
        switch VideoLosslessTrimPipeline.shared.validateSourceCompatibility(sourceURL) {
        case .success:
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }

    public func defaultOutputURL(for sourceURL: URL) -> URL {
        VideoLosslessTrimPipeline.shared.defaultOutputURL(for: sourceURL)
    }

    public func plannedBranch(startSeconds: Double) -> VideoLosslessTrimBranch {
        startSeconds <= 0.001 ? .tailOnlyZeroCopy : .headOrMidEditList
    }

    public func resolvedTimeRange(
        trimStart: Double?,
        trimEnd: Double?,
        currentTime: Double,
        duration: Double
    ) -> ClosedRange<Double> {
        if let start = trimStart, let end = trimEnd {
            if end <= start {
                let clamped = max(0.0, start)
                return clamped...clamped
            }
            if end - start >= 0.1 {
                let lower = max(0.0, start)
                let upper = duration > 0 ? min(duration, max(lower + 0.1, end)) : max(lower + 0.1, end)
                return lower...max(lower, upper)
            }
        }
        let effDuration = duration > 0 ? duration : max(1.0, currentTime + 3.0)
        let lower = max(0.0, currentTime - 3.0)
        let upper = min(effDuration, max(lower + 0.1, currentTime + 3.0))
        if upper - lower >= 0.1 {
            return lower...upper
        }
        return 0.0...max(0.1, effDuration)
    }

    public func trimCurrentRange(
        trimStart: Double?,
        trimEnd: Double?,
        currentTime: Double,
        duration: Double,
        sourceURL: URL
    ) {
        guard !isTrimming else {
            logger.warning("Lossless trim already in progress; ignoring duplicate trigger")
            return
        }
        if let issue = compatibilityIssue(for: sourceURL) {
            lastErrorMessage = issue
            isTrimming = false
            trimProgress = 0.0
            return
        }

        let effectiveStart = trimStart ?? customTrimStart
        let effectiveEnd = trimEnd ?? customTrimEnd
        let resolvedRange = resolvedTimeRange(
            trimStart: effectiveStart,
            trimEnd: effectiveEnd,
            currentTime: currentTime,
            duration: duration
        )
        let startSecs = effectiveStart ?? resolvedRange.lowerBound
        let endSecs = effectiveEnd ?? resolvedRange.upperBound

        let operationID = UUID()
        activeOperationID = operationID
        isTrimming = true
        trimProgress = 0.0
        lastErrorMessage = nil
        activeSourceURL = sourceURL
        activeStagingURL = nil

        currentTrimTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runTrimWorkflow(
                sourceURL: sourceURL,
                startSeconds: startSecs,
                endSeconds: endSecs,
                operationID: operationID
            )
        }
        currentTrimTask = task
        lastDispatchedTask = task
    }

    public func cancelTrim() {
        let stagingURL = activeStagingURL
        activeOperationID = nil
        currentTrimTask?.cancel()
        currentTrimTask = nil
        isTrimming = false
        trimProgress = 0.0
        activeSourceURL = nil
        activeStagingURL = nil
        if let stagingURL {
            try? FileManager.default.removeItem(at: stagingURL)
        }
        logger.info("Active lossless video trim cancelled")
    }

    public func handlePreviewClosed(for sourceURL: URL) {
        guard let active = activeSourceURL else { return }
        let activeCanonical = active.standardizedFileURL.resolvingSymlinksInPath()
        let closedCanonical = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard activeCanonical == closedCanonical else { return }
        logger.info("Preview closed for active lossless trim source \(sourceURL.lastPathComponent); cancelling")
        cancelTrim()
    }

    public func waitForCurrentTrim() async {
        await lastDispatchedTask?.value
    }

    public func updateProgress(_ progress: Double, operationID: UUID? = nil) {
        if let operationID, activeOperationID != operationID { return }
        guard isTrimming else { return }
        trimProgress = progress
    }

    private func resolveDestinationURL(for sourceURL: URL) async -> URL? {
        if let presenter = savePanelPresenter {
            return await presenter(sourceURL)
        }
        return await presentSavePanel(for: sourceURL)
    }

    private func runTrimWorkflow(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        operationID: UUID
    ) async {
        guard let destinationURL = await resolveDestinationURL(for: sourceURL) else {
            resetActiveState(operationID: operationID)
            return
        }
        let token = UUID().uuidString
        let stagingURL = VideoLosslessTrimPipeline.shared.makeStagingURL(for: destinationURL, token: token)
        if activeOperationID == operationID {
            activeStagingURL = stagingURL
        }

        if Task.isCancelled || activeOperationID != operationID {
            cleanupStagingAndReset(stagingURL: stagingURL, operationID: operationID)
            return
        }
        await executeTrimRequest(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            stagingURL: stagingURL,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            token: token,
            operationID: operationID
        )
    }

    private func executeTrimRequest(
        sourceURL: URL,
        destinationURL: URL,
        stagingURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        token: String,
        operationID: UUID
    ) async {
        do {
            let result = try await VideoLosslessTrimPipeline.shared.trimVideo(
                sourceURL: sourceURL,
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                destinationURL: destinationURL,
                stagingToken: token
            ) { progress in
                Task { @MainActor in
                    VideoLosslessTrimManager.shared.updateProgress(progress, operationID: operationID)
                }
            }
            try Task.checkCancellation()
            guard activeOperationID == operationID else {
                try? FileManager.default.removeItem(at: stagingURL)
                return
            }
            lastCompletedResult = result
            lastCompletedDestinationURL = destinationURL
            resetActiveState(finalProgress: 1.0, operationID: operationID)
            notifyTrimSuccess(destinationURL: destinationURL)
        } catch is CancellationError {
            cleanupStagingAndReset(stagingURL: stagingURL, operationID: operationID)
        } catch VideoLosslessTrimError.cancelled {
            cleanupStagingAndReset(stagingURL: stagingURL, operationID: operationID)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            guard activeOperationID == operationID else { return }
            resetActiveState(operationID: operationID)
            lastErrorMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private func cleanupStagingAndReset(stagingURL: URL, operationID: UUID) {
        try? FileManager.default.removeItem(at: stagingURL)
        resetActiveState(operationID: operationID)
    }

    private func resetActiveState(finalProgress: Double = 0.0, operationID: UUID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        isTrimming = false
        trimProgress = finalProgress
        activeSourceURL = nil
        activeStagingURL = nil
        currentTrimTask = nil
    }

    private func presentSavePanel(for sourceURL: URL) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Lossless Video Trim"
        let defaultURL = defaultOutputURL(for: sourceURL)
        panel.directoryURL = defaultURL.deletingLastPathComponent()
        panel.nameFieldStringValue = defaultURL.lastPathComponent
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
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
        guard response == .OK else { return nil }
        return panel.url
    }

    private func notifyTrimSuccess(destinationURL: URL) {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        }
        if Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" {
            let content = UNMutableNotificationContent()
            content.title = "Lossless Video Trim Completed"
            content.body = "Saved \(destinationURL.lastPathComponent)"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "dev.metastudyline.ttmedia.trim.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
        NotificationCenter.default.post(name: .videoLosslessTrimCompletedNotification, object: destinationURL)
    }
}

extension Notification.Name {
    public static let videoLosslessTrimCompletedNotification = Notification.Name(
        "dev.metastudyline.ttmedia.videoLosslessTrimCompleted"
    )
}
