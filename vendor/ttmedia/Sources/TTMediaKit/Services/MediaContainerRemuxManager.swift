// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os.log
import UserNotifications

/// High-level presentation manager orchestrating lossless media container remuxing,
/// staging cleanup, cancellation lifecycle, and user notifications.
@MainActor
public final class MediaContainerRemuxManager: ObservableObject {
    public static let shared = MediaContainerRemuxManager()

    private let logger = Logger(
        subsystem: "dev.metastudyline.ttmedia",
        category: "MediaContainerRemuxManager"
    )

    @Published public var isRemuxing: Bool = false
    @Published public var remuxProgress: Double = 0.0
    @Published public var lastErrorMessage: String? = nil
    @Published public var activeSourceURL: URL? = nil
    @Published public var lastCompletedDestinationURL: URL? = nil
    @Published public var lastCompletedResult: MediaContainerRemuxResult? = nil
    @Published public var targetContainer: MediaRemuxTargetContainer = .mp4
    @Published public var fastStart: Bool = true
    @Published public var stripAudio: Bool = false

    /// Optional injectable save panel presenter for deterministic headless testing.
    public var savePanelPresenter: (@MainActor (URL) async -> URL?)? = nil

    private var currentRemuxTask: Task<Void, Never>? = nil
    private var lastDispatchedTask: Task<Void, Never>? = nil
    private var activeStagingURL: URL? = nil
    private var activeOperationID: UUID? = nil

    private init() {}

    public var selectedOptions: MediaContainerRemuxOptions {
        MediaContainerRemuxOptions(
            targetContainer: targetContainer,
            fastStart: fastStart,
            stripAudio: stripAudio
        )
    }

    public func compatibilityIssue(for sourceURL: URL?) -> String? {
        guard let sourceURL else {
            return "No media source URL is available for container remuxing."
        }
        switch MediaContainerRemuxPipeline.shared.validateSourceCompatibility(sourceURL) {
        case .success:
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }

    public func executionPath(for sourceURL: URL?) -> MediaRemuxExecutionPath? {
        guard let sourceURL else { return nil }
        return try? MediaContainerRemuxPipeline.shared.classifyExecutionPath(for: sourceURL).get()
    }

    public func defaultOutputURL(
        for sourceURL: URL,
        targetContainer: MediaRemuxTargetContainer? = nil
    ) -> URL {
        MediaContainerRemuxPipeline.shared.defaultOutputURL(
            for: sourceURL,
            targetContainer: targetContainer ?? self.targetContainer
        )
    }

    public func remuxCurrentMedia(
        sourceURL: URL,
        options: MediaContainerRemuxOptions? = nil
    ) {
        guard !isRemuxing else {
            logger.warning("Container remux already in progress; ignoring duplicate trigger")
            return
        }
        if let issue = compatibilityIssue(for: sourceURL) {
            lastErrorMessage = issue
            isRemuxing = false
            remuxProgress = 0.0
            return
        }

        let effectiveOptions = options ?? selectedOptions
        targetContainer = effectiveOptions.targetContainer
        fastStart = effectiveOptions.fastStart
        stripAudio = effectiveOptions.stripAudio

        let operationID = UUID()
        activeOperationID = operationID
        isRemuxing = true
        remuxProgress = 0.0
        lastErrorMessage = nil
        activeSourceURL = sourceURL
        activeStagingURL = nil

        currentRemuxTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRemuxWorkflow(sourceURL: sourceURL, options: effectiveOptions, operationID: operationID)
        }
        currentRemuxTask = task
        lastDispatchedTask = task
    }

    public func cancelRemux() {
        let stagingURL = activeStagingURL
        activeOperationID = nil
        currentRemuxTask?.cancel()
        currentRemuxTask = nil
        isRemuxing = false
        remuxProgress = 0.0
        activeSourceURL = nil
        activeStagingURL = nil
        if let stagingURL {
            try? FileManager.default.removeItem(at: stagingURL)
        }
        logger.info("Active media container remux cancelled")
    }

    public func handlePreviewClosed(for sourceURL: URL) {
        guard let active = activeSourceURL else { return }
        let activeCanonical = active.standardizedFileURL.resolvingSymlinksInPath()
        let closedCanonical = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard activeCanonical == closedCanonical else { return }
        logger.info("Preview closed for active remux source \(sourceURL.lastPathComponent); cancelling")
        cancelRemux()
    }

    public func waitForCurrentRemux() async {
        await lastDispatchedTask?.value
    }

    public func updateProgress(_ progress: Double, operationID: UUID? = nil) {
        if let operationID, activeOperationID != operationID { return }
        guard isRemuxing else { return }
        remuxProgress = progress
    }

    private func resolveDestinationURL(
        for sourceURL: URL,
        targetContainer: MediaRemuxTargetContainer
    ) async -> URL? {
        if let presenter = savePanelPresenter {
            return await presenter(sourceURL)
        }
        return await presentSavePanel(for: sourceURL, targetContainer: targetContainer)
    }

    private func runRemuxWorkflow(
        sourceURL: URL,
        options: MediaContainerRemuxOptions,
        operationID: UUID
    ) async {
        guard let destinationURL = await resolveDestinationURL(
            for: sourceURL,
            targetContainer: options.targetContainer
        ) else {
            resetActiveState(operationID: operationID)
            return
        }
        let token = UUID().uuidString
        let stagingURL = MediaContainerRemuxPipeline.shared.makeStagingURL(
            for: destinationURL,
            targetContainer: options.targetContainer,
            token: token
        )
        if activeOperationID == operationID {
            activeStagingURL = stagingURL
        }

        if Task.isCancelled || activeOperationID != operationID {
            cleanupStagingAndReset(stagingURL: stagingURL, operationID: operationID)
            return
        }
        await executeRemuxRequest(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            stagingURL: stagingURL,
            options: options,
            token: token,
            operationID: operationID
        )
    }

    private func executeRemuxRequest(
        sourceURL: URL,
        destinationURL: URL,
        stagingURL: URL,
        options: MediaContainerRemuxOptions,
        token: String,
        operationID: UUID
    ) async {
        do {
            let result = try await MediaContainerRemuxPipeline.shared.remuxMedia(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                options: options,
                stagingToken: token
            ) { progress in
                Task { @MainActor in
                    MediaContainerRemuxManager.shared.updateProgress(progress, operationID: operationID)
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
            notifyRemuxSuccess(destinationURL: destinationURL)
        } catch is CancellationError {
            cleanupStagingAndReset(stagingURL: stagingURL, operationID: operationID)
        } catch MediaContainerRemuxError.cancelled {
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
        isRemuxing = false
        remuxProgress = finalProgress
        activeSourceURL = nil
        activeStagingURL = nil
        currentRemuxTask = nil
    }

    private func presentSavePanel(
        for sourceURL: URL,
        targetContainer: MediaRemuxTargetContainer
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Remux Media Container"
        let defaultURL = defaultOutputURL(for: sourceURL, targetContainer: targetContainer)
        panel.directoryURL = defaultURL.deletingLastPathComponent()
        panel.nameFieldStringValue = defaultURL.lastPathComponent
        panel.allowedContentTypes = targetContainer == .mov ? [.quickTimeMovie] : [.mpeg4Movie]
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

    private func notifyRemuxSuccess(destinationURL: URL) {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        }
        if Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" {
            let content = UNMutableNotificationContent()
            content.title = "Container Remux Completed"
            content.body = "Saved \(destinationURL.lastPathComponent)"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "dev.metastudyline.ttmedia.remux.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
        NotificationCenter.default.post(name: .mediaContainerRemuxCompletedNotification, object: destinationURL)
    }
}

extension Notification.Name {
    public static let mediaContainerRemuxCompletedNotification = Notification.Name(
        "dev.metastudyline.ttmedia.mediaContainerRemuxCompleted"
    )
}
