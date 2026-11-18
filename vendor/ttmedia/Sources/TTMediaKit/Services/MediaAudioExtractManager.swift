// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers
import os.log
import UserNotifications

/// Audio codecs supported for zero-copy audio track extraction.
public enum MediaAudioExtractCodec: UInt32, CaseIterable, Sendable, Equatable, Identifiable {
    case aac = 0
    case flac = 1
    case opus = 2
    case mp3 = 3
    case unknown = 4

    public var id: UInt32 { rawValue }

    public var fileExtension: String {
        switch self {
        case .aac: return "aac"
        case .flac: return "flac"
        case .opus: return "opus"
        case .mp3: return "mp3"
        case .unknown: return "bin"
        }
    }

    public var displayName: String {
        switch self {
        case .aac: return "AAC"
        case .flac: return "FLAC"
        case .opus: return "Opus"
        case .mp3: return "MP3"
        case .unknown: return "Raw Audio"
        }
    }
}

/// Target output format mode for extracted audio tracks.
public enum MediaAudioExtractionMode: UInt32, CaseIterable, Sendable, Equatable, Identifiable {
    case elementaryStream = 0
    case encapsulatedM4a = 1

    public var id: UInt32 { rawValue }

    public var displayName: String {
        switch self {
        case .encapsulatedM4a: return "M4A Container (.m4a)"
        case .elementaryStream: return "Elementary Stream (.aac/.flac/.opus)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .encapsulatedM4a: return "M4A"
        case .elementaryStream: return "Stream"
        }
    }
}

/// Execution path selected based on source container and extraction mode.
public enum MediaAudioExtractExecutionPath: String, Sendable, Equatable {
    case avFoundationM4A
    case rustBitstreamExtract
}

/// Metadata descriptor for a discoverable audio track in a source container.
public struct MediaAudioTrackDescriptor: Sendable, Equatable, Identifiable {
    public let index: Int
    public let trackID: Int32
    public let codec: MediaAudioExtractCodec
    public let codecFourCC: String
    public let channels: Int
    public let sampleRate: Double
    public let languageCode: String?
    public let displayName: String

    public var id: Int { index }

    public init(
        index: Int,
        trackID: Int32,
        codec: MediaAudioExtractCodec,
        codecFourCC: String,
        channels: Int,
        sampleRate: Double,
        languageCode: String? = nil,
        displayName: String? = nil
    ) {
        self.index = index
        self.trackID = trackID
        self.codec = codec
        self.codecFourCC = codecFourCC
        self.channels = max(1, channels)
        let safeSampleRate = (sampleRate.isFinite && sampleRate >= 800.0 && sampleRate <= 384_000.0)
            ? sampleRate
            : 44100.0
        self.sampleRate = safeSampleRate
        self.languageCode = languageCode
        if let displayName {
            self.displayName = displayName
        } else {
            let langSuffix = languageCode.map { " [\($0)]" } ?? ""
            self.displayName = "Track \(index + 1) · \(codec.displayName) \(Int(safeSampleRate.rounded())) Hz (\(self.channels)ch)\(langSuffix)"
        }
    }
}

/// Configuration options for lossless audio track extraction.
public struct MediaAudioExtractOptions: Sendable, Equatable {
    public var mode: MediaAudioExtractionMode
    public var trackIndex: Int
    public var preferredCodec: MediaAudioExtractCodec

    public init(
        mode: MediaAudioExtractionMode = .encapsulatedM4a,
        trackIndex: Int = 0,
        preferredCodec: MediaAudioExtractCodec = .aac
    ) {
        self.mode = mode
        self.trackIndex = trackIndex
        self.preferredCodec = preferredCodec
    }
}

/// Verified output metadata returned upon completing an audio track extraction.
public struct MediaAudioExtractResult: Sendable, Equatable {
    public let destinationURL: URL
    public let mode: MediaAudioExtractionMode
    public let executionPath: MediaAudioExtractExecutionPath
    public let codec: MediaAudioExtractCodec
    public let trackIndex: Int
    public let channels: Int
    public let sampleRate: Double
    public let packetCount: UInt64
    public let durationSeconds: Double
    public let outputBytes: UInt64

    public init(
        destinationURL: URL,
        mode: MediaAudioExtractionMode,
        executionPath: MediaAudioExtractExecutionPath,
        codec: MediaAudioExtractCodec,
        trackIndex: Int,
        channels: Int,
        sampleRate: Double,
        packetCount: UInt64,
        durationSeconds: Double,
        outputBytes: UInt64
    ) {
        self.destinationURL = destinationURL
        self.mode = mode
        self.executionPath = executionPath
        self.codec = codec
        self.trackIndex = trackIndex
        self.channels = channels
        self.sampleRate = sampleRate
        self.packetCount = packetCount
        self.durationSeconds = durationSeconds
        self.outputBytes = outputBytes
    }
}

/// Strongly-typed failure domains for lossless audio track extraction.
public enum MediaAudioExtractError: LocalizedError, Sendable, Equatable {
    case sourceFileNotFound(URL)
    case unsupportedSource(URL, reason: String)
    case noAudioTracksFound(URL)
    case trackIndexOutOfRange(index: Int, availableCount: Int)
    case unsupportedAudioCodec(String)
    case inputTooLargeForInMemoryExtract(URL, fileBytes: UInt64, limitBytes: UInt64)
    case sameSourceAndDestination(URL)
    case destinationUnwritable(URL, reason: String)
    case cancelled
    case extractionFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceFileNotFound(let url):
            return "Source media file does not exist: \(url.path)"
        case .unsupportedSource(let url, let reason):
            return "Unsupported source (\(url.lastPathComponent)): \(reason)"
        case .noAudioTracksFound(let url):
            return "No extractable audio tracks found in \(url.lastPathComponent)."
        case .trackIndexOutOfRange(let index, let availableCount):
            return "Requested audio track index \(index) is out of range (available tracks: \(availableCount))."
        case .unsupportedAudioCodec(let reason):
            return "Unsupported audio codec for requested extraction mode: \(reason)"
        case .inputTooLargeForInMemoryExtract(let url, let fileBytes, let limitBytes):
            return "Source (\(url.lastPathComponent)) size (\(fileBytes) bytes) exceeds in-memory extraction limit (\(limitBytes) bytes)."
        case .sameSourceAndDestination(let url):
            return "Destination path must be distinct from source path: \(url.path)"
        case .destinationUnwritable(let url, let reason):
            return "Destination is not writable (\(url.path)): \(reason)"
        case .cancelled:
            return "Audio track extraction was cancelled."
        case .extractionFailed(let reason):
            return "Audio track extraction failed: \(reason)"
        case .verificationFailed(let reason):
            return "Extracted audio verification failed: \(reason)"
        }
    }
}

/// High-level presentation manager orchestrating lossless media audio track extraction,
/// track discovery, staging cleanup, cancellation lifecycle, and user notifications.
@MainActor
@Observable
public final class MediaAudioExtractManager {
    public static let shared = MediaAudioExtractManager()

    private let logger = Logger(
        subsystem: "dev.metastudyline.ttmedia",
        category: "MediaAudioExtractManager"
    )

    public var availableTracks: [MediaAudioTrackDescriptor] = []
    public var selectedTrackIndex: Int = 0
    public var selectedMode: MediaAudioExtractionMode = .encapsulatedM4a
    public var isAudioExtractPopoverPresented: Bool = false
    public var isExtracting: Bool = false
    public var extractProgress: Double = 0.0
    public var lastExtractedURL: URL? = nil
    public var lastExtractResult: MediaAudioExtractResult? = nil
    public var errorMessage: String? = nil
    public var activeSourceURL: URL? = nil

    /// Optional injectable save panel presenter for deterministic headless testing.
    public var savePanelPresenter: (@MainActor (URL) async -> URL?)? = nil

    private var currentExtractTask: Task<Void, Never>? = nil
    private var lastDispatchedTask: Task<Void, Never>? = nil
    private var activeStagingURL: URL? = nil

    private init() {}

    public var selectedCodec: MediaAudioExtractCodec {
        if selectedTrackIndex >= 0 && selectedTrackIndex < availableTracks.count {
            return availableTracks[selectedTrackIndex].codec
        }
        return availableTracks.first?.codec ?? .aac
    }

    public var selectedOptions: MediaAudioExtractOptions {
        MediaAudioExtractOptions(
            mode: selectedMode,
            trackIndex: max(0, selectedTrackIndex),
            preferredCodec: selectedCodec
        )
    }

    public func compatibilityIssue(
        for sourceURL: URL?,
        mode: MediaAudioExtractionMode? = nil
    ) -> String? {
        guard let sourceURL else {
            return "No media source URL is available for audio track extraction."
        }
        let effectiveMode = mode ?? selectedMode
        switch MediaAudioExtractPipeline.shared.validateSourceCompatibility(sourceURL, mode: effectiveMode) {
        case .success:
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }

    public func executionPath(
        for sourceURL: URL?,
        mode: MediaAudioExtractionMode? = nil
    ) -> MediaAudioExtractExecutionPath? {
        guard let sourceURL else { return nil }
        let effectiveMode = mode ?? selectedMode
        return try? MediaAudioExtractPipeline.shared.classifyExecutionPath(for: sourceURL, mode: effectiveMode).get()
    }

    public func defaultOutputURL(
        for sourceURL: URL,
        mode: MediaAudioExtractionMode? = nil,
        codec: MediaAudioExtractCodec? = nil,
        trackIndex: Int? = nil
    ) -> URL {
        let effectiveMode = mode ?? selectedMode
        let effectiveCodec = codec ?? selectedCodec
        let effectiveTrack = trackIndex ?? selectedTrackIndex
        return MediaAudioExtractPipeline.shared.defaultOutputURL(
            for: sourceURL,
            mode: effectiveMode,
            codec: effectiveCodec,
            trackIndex: effectiveTrack
        )
    }

    public func refreshAvailableTracks(for sourceURL: URL?) async {
        guard let sourceURL else {
            availableTracks = []
            selectedTrackIndex = 0
            return
        }
        let discovered = await MediaAudioExtractPipeline.shared.discoverAudioTracks(in: sourceURL)
        availableTracks = discovered
        if selectedTrackIndex < 0 || selectedTrackIndex >= max(1, discovered.count) {
            selectedTrackIndex = 0
        }
        if let first = discovered.first, first.codec != .aac && selectedMode == .encapsulatedM4a {
            selectedMode = .elementaryStream
        }
    }

    public func extractCurrentAudio(
        sourceURL: URL,
        options: MediaAudioExtractOptions? = nil
    ) {
        guard !isExtracting else {
            logger.warning("Audio extraction already in progress; ignoring duplicate trigger")
            return
        }
        let effectiveOptions = options ?? selectedOptions
        if let issue = compatibilityIssue(for: sourceURL, mode: effectiveOptions.mode) {
            errorMessage = issue
            isExtracting = false
            extractProgress = 0.0
            return
        }

        selectedMode = effectiveOptions.mode
        selectedTrackIndex = effectiveOptions.trackIndex

        isExtracting = true
        extractProgress = 0.0
        errorMessage = nil
        activeSourceURL = sourceURL
        activeStagingURL = nil

        currentExtractTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runExtractWorkflow(sourceURL: sourceURL, options: effectiveOptions)
        }
        currentExtractTask = task
        lastDispatchedTask = task
    }

    public func cancelExtraction() {
        let stagingURL = activeStagingURL
        currentExtractTask?.cancel()
        currentExtractTask = nil
        isExtracting = false
        extractProgress = 0.0
        activeSourceURL = nil
        activeStagingURL = nil
        if let stagingURL {
            try? FileManager.default.removeItem(at: stagingURL)
        }
        logger.info("Active audio track extraction cancelled")
    }

    public func resetForPreviewClose(for sourceURL: URL? = nil) {
        if let sourceURL, let active = activeSourceURL {
            let activeCanonical = active.standardizedFileURL.resolvingSymlinksInPath()
            let closedCanonical = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
            if activeCanonical == closedCanonical {
                logger.info("Preview closed for active audio extract source \(sourceURL.lastPathComponent); cancelling")
                cancelExtraction()
            }
        } else if sourceURL == nil {
            cancelExtraction()
        }
        isAudioExtractPopoverPresented = false
    }

    public func handlePreviewClosed(for sourceURL: URL) {
        resetForPreviewClose(for: sourceURL)
    }

    public func waitForCurrentExtraction() async {
        await lastDispatchedTask?.value
    }

    public func updateProgress(_ progress: Double) {
        guard isExtracting else { return }
        extractProgress = progress
    }

    private func resolveDestinationURL(
        for sourceURL: URL,
        options: MediaAudioExtractOptions
    ) async -> URL? {
        if let presenter = savePanelPresenter {
            return await presenter(sourceURL)
        }
        return await presentSavePanel(for: sourceURL, options: options)
    }

    private func runExtractWorkflow(
        sourceURL: URL,
        options: MediaAudioExtractOptions
    ) async {
        guard let destinationURL = await resolveDestinationURL(for: sourceURL, options: options) else {
            resetActiveState()
            return
        }
        let token = UUID().uuidString
        let stagingURL = MediaAudioExtractPipeline.shared.makeStagingURL(
            for: destinationURL,
            mode: options.mode,
            codec: options.preferredCodec,
            token: token
        )
        activeStagingURL = stagingURL

        if Task.isCancelled {
            cleanupStagingAndReset(stagingURL: stagingURL)
            return
        }

        do {
            let result = try await MediaAudioExtractPipeline.shared.extractAudioTrack(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                options: options,
                stagingToken: token
            ) { progress in
                Task { @MainActor in
                    MediaAudioExtractManager.shared.updateProgress(progress)
                }
            }
            try Task.checkCancellation()
            lastExtractResult = result
            lastExtractedURL = destinationURL
            resetActiveState(finalProgress: 1.0)
            notifyExtractSuccess(destinationURL: destinationURL)
        } catch is CancellationError {
            cleanupStagingAndReset(stagingURL: stagingURL)
        } catch MediaAudioExtractError.cancelled {
            cleanupStagingAndReset(stagingURL: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            resetActiveState()
            errorMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private func cleanupStagingAndReset(stagingURL: URL) {
        try? FileManager.default.removeItem(at: stagingURL)
        resetActiveState()
    }

    private func resetActiveState(finalProgress: Double = 0.0) {
        isExtracting = false
        extractProgress = finalProgress
        activeSourceURL = nil
        activeStagingURL = nil
        currentExtractTask = nil
    }

    private func presentSavePanel(
        for sourceURL: URL,
        options: MediaAudioExtractOptions
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Extract Audio Track"
        let defaultURL = defaultOutputURL(
            for: sourceURL,
            mode: options.mode,
            codec: options.preferredCodec,
            trackIndex: options.trackIndex
        )
        panel.directoryURL = defaultURL.deletingLastPathComponent()
        panel.nameFieldStringValue = defaultURL.lastPathComponent
        let ext = defaultURL.pathExtension.isEmpty ? "m4a" : defaultURL.pathExtension
        if let utType = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [utType]
        } else {
            panel.allowedContentTypes = [.mpeg4Audio, .audio]
        }
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

    private func notifyExtractSuccess(destinationURL: URL) {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        }
        if Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" {
            let content = UNMutableNotificationContent()
            content.title = "Audio Extraction Completed"
            content.body = "Saved \(destinationURL.lastPathComponent)"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "dev.metastudyline.ttmedia.audioextract.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
        NotificationCenter.default.post(name: .mediaAudioExtractCompletedNotification, object: destinationURL)
    }
}

extension Notification.Name {
    public static let mediaAudioExtractCompletedNotification = Notification.Name(
        "dev.metastudyline.ttmedia.mediaAudioExtractCompleted"
    )
}
