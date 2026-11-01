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
    
    /// Reference to the active asynchronous export task for cancellation control.
    private var currentExportTask: Task<Void, Never>? = nil
    
    private init() {}
    
    // MARK: - Public Export API
    
    /// Initiates animated GIF export for the active player's A-B loop segment.
    ///
    /// - Parameters:
    ///   - loopA: Loop start timestamp.
    ///   - loopB: Loop end timestamp.
    ///   - currentTime: Current playback time.
    ///   - duration: Total duration of the media.
    ///   - sourceURL: File URL of the source media container.
    ///   - options: Custom encoding options (defaults to 15 fps, 480px width, Bayer dithering).
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
        
        let timeRange = resolveExportTimeRange(loopA: loopA, loopB: loopB, currentTime: currentTime, duration: duration)
        
        Task { [weak self] in
            guard let self else { return }
            guard let destinationURL = await self.presentSavePanel() else {
                self.logger.info("User cancelled GIF export save panel")
                return
            }
            
            self.startExportTask(
                sourceURL: sourceURL,
                timeRange: timeRange,
                destinationURL: destinationURL,
                options: options
            )
        }
    }
    
    /// Cancels any ongoing GIF export operation.
    public func cancelExport() {
        currentExportTask?.cancel()
        currentExportTask = nil
        isExporting = false
        exportProgress = 0.0
        logger.info("Active GIF export task cancelled by user request")
    }
    
    /// Updates the normalized progress from background tasks.
    public func updateProgress(_ progress: Double) {
        guard isExporting else { return }
        exportProgress = progress
    }
    
    // MARK: - Time Range Resolution
    
    /// Resolves export bounds from `loopA` and `loopB`, falling back to +/- 3 seconds of `currentTime`.
    private func resolveExportTimeRange(loopA: Double?, loopB: Double?, currentTime: Double, duration: Double) -> ClosedRange<Double> {
        if let a = loopA, let b = loopB, abs(b - a) >= 0.1 {
            let start = max(0.0, min(a, b))
            let end = max(start + 0.1, max(a, b))
            return start...end
        }
        
        let effDuration = duration > 0 ? duration : (currentTime + 3.0)
        let lower = max(0.0, currentTime - 3.0)
        let upper = min(effDuration, currentTime + 3.0)
        
        if upper - lower >= 0.1 {
            return lower...upper
        } else {
            return lower...(lower + 3.0)
        }
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
    
    // MARK: - Export Execution Lifecycle
    
    private func startExportTask(
        sourceURL: URL,
        timeRange: ClosedRange<Double>,
        destinationURL: URL,
        options: GIFExportOptions
    ) {
        isExporting = true
        exportProgress = 0.0
        lastErrorMessage = nil
        
        currentExportTask?.cancel()
        currentExportTask = Task { [weak self] in
            do {
                try await GIFExportPipeline.shared.exportGIF(
                    sourceURL: sourceURL,
                    timeRange: timeRange,
                    destinationURL: destinationURL,
                    options: options
                ) { progress in
                    Task { @MainActor in
                        GIFExportManager.shared.updateProgress(progress)
                    }
                }
                
                guard let self else { return }
                self.isExporting = false
                self.exportProgress = 1.0
                self.currentExportTask = nil
                self.handleExportSuccess(destinationURL: destinationURL)
            } catch is CancellationError {
                guard let self else { return }
                self.isExporting = false
                self.exportProgress = 0.0
                self.currentExportTask = nil
                self.logger.info("GIF export cancelled cleanly")
            } catch {
                guard let self else { return }
                self.isExporting = false
                self.exportProgress = 0.0
                self.currentExportTask = nil
                self.lastErrorMessage = error.localizedDescription
                self.handleExportFailure(error: error)
            }
        }
    }
    
    // MARK: - Notifications & Sounds
    
    private func handleExportSuccess(destinationURL: URL) {
        logger.info("GIF export succeeded -> \(destinationURL.path)")
        
        // 1. Play macOS system auditory feedback
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
        
        // 2. Deliver UserNotification
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
        
        // 3. Post notification center event for UI components
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
