// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import TTMediaDemux

/// Physical trim execution branch selected by the native C-ABI planner.
public enum VideoLosslessTrimBranch: UInt32, Sendable, Equatable {
    case tailOnlyZeroCopy = 0
    case headOrMidEditList = 1
    case streamingRemux = 2
}

/// ISO BMFF / QuickTime edit-list (`edts`/`elst`) synchronization parameters.
public struct VideoLosslessTrimEditListSync: Sendable, Equatable {
    public let movieTimescale: UInt32
    public let segmentDuration: UInt32
    public let mediaTime: Int32

    public init(movieTimescale: UInt32, segmentDuration: UInt32, mediaTime: Int32) {
        self.movieTimescale = movieTimescale
        self.segmentDuration = segmentDuration
        self.mediaTime = mediaTime
    }
}

/// Verified output metadata returned upon completing a lossless trim.
public struct VideoLosslessTrimResult: Sendable, Equatable {
    public let destinationURL: URL
    public let branch: VideoLosslessTrimBranch
    public let editListSync: VideoLosslessTrimEditListSync
    public let outputBytes: UInt64
    public let trimmedDurationSeconds: Double
    public let videoTrackCount: Int
    public let audioTrackCount: Int

    public init(
        destinationURL: URL,
        branch: VideoLosslessTrimBranch,
        editListSync: VideoLosslessTrimEditListSync,
        outputBytes: UInt64,
        trimmedDurationSeconds: Double,
        videoTrackCount: Int,
        audioTrackCount: Int
    ) {
        self.destinationURL = destinationURL
        self.branch = branch
        self.editListSync = editListSync
        self.outputBytes = outputBytes
        self.trimmedDurationSeconds = trimmedDurationSeconds
        self.videoTrackCount = videoTrackCount
        self.audioTrackCount = audioTrackCount
    }
}

/// Strongly-typed failure domains for lossless video trimming.
public enum VideoLosslessTrimError: LocalizedError, Sendable, Equatable {
    case invalidTimeRange(lower: Double, upper: Double, duration: Double?)
    case sourceFileNotFound(URL)
    case unsupportedSource(URL, reason: String)
    case sameSourceAndDestination(URL)
    case destinationUnwritable(URL, reason: String)
    case cancelled
    case exportFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTimeRange(let lower, let upper, _):
            return "Invalid trim time range: [\(lower), \(upper)]."
        case .sourceFileNotFound(let url):
            return "Source video file does not exist: \(url.path)"
        case .unsupportedSource(let url, let reason):
            return "Unsupported source (\(url.lastPathComponent)): \(reason)"
        case .sameSourceAndDestination(let url):
            return "Destination path must be distinct from source path: \(url.path)"
        case .destinationUnwritable(let url, let reason):
            return "Destination is not writable (\(url.path)): \(reason)"
        case .cancelled:
            return "Lossless video trim was cancelled."
        case .exportFailed(let reason):
            return "Lossless video export failed: \(reason)"
        case .verificationFailed(let reason):
            return "Trimmed video verification failed: \(reason)"
        }
    }
}

/// Production lossless video trimming pipeline backed by Rust C-ABI planning/metadata preservation
/// and AVAssetExportSession passthrough bitstream slicing.
public final class VideoLosslessTrimPipeline: @unchecked Sendable {
    public static let shared = VideoLosslessTrimPipeline()
    public static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Optional cooperative delay (in nanoseconds) during staging export for deterministic cancellation tests.
    public var simulatedExportDelayNanoseconds: UInt64 = 0

    public init() {}

    public func defaultOutputURL(for sourceURL: URL) -> URL {
        let sourcePath = sourceURL.path
        var requiredLen: Int = 0
        let queryStatus = sourcePath.withCString { srcPtr in
            ttmedia_trim_default_output_path(srcPtr, nil, 0, &requiredLen)
        }
        guard queryStatus == 0, requiredLen > 0 else {
            return sourceURL.deletingLastPathComponent().appendingPathComponent("trimmed.mp4")
        }
        var buffer = [CChar](repeating: 0, count: requiredLen + 1)
        let copyStatus = sourcePath.withCString { srcPtr in
            ttmedia_trim_default_output_path(srcPtr, &buffer, buffer.count, &requiredLen)
        }
        guard copyStatus == 0 else {
            return sourceURL.deletingLastPathComponent().appendingPathComponent("trimmed.mp4")
        }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    public func makeStagingURL(for destinationURL: URL, token: String = UUID().uuidString) -> URL {
        let ext = destinationURL.pathExtension.isEmpty ? "mp4" : destinationURL.pathExtension
        let name = "\(destinationURL.lastPathComponent).ttmedia-staging-\(token).\(ext)"
        return destinationURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    public func validateSourceCompatibility(_ sourceURL: URL) -> Result<Void, VideoLosslessTrimError> {
        guard sourceURL.isFileURL else {
            return .failure(.unsupportedSource(sourceURL, reason: "Only local video file URLs are supported."))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            return .failure(.sourceFileNotFound(sourceURL))
        }
        guard !isDir.boolValue else {
            return .failure(.unsupportedSource(sourceURL, reason: "Source path is a directory."))
        }
        let ext = sourceURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            return .failure(.unsupportedSource(sourceURL, reason: "Only MP4, MOV, and M4V containers support lossless passthrough trim."))
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            return .failure(.unsupportedSource(sourceURL, reason: "Source video file is empty."))
        }
        switch planTrim(sourceURL: sourceURL, destinationURL: nil, startSeconds: 0.0, endSeconds: 0.1) {
        case .success:
            return .success(())
        case .failure(let err):
            return .failure(err)
        }
    }

    public func planTrim(
        sourceURL: URL,
        destinationURL: URL?,
        startSeconds: Double,
        endSeconds: Double
    ) -> Result<(VideoLosslessTrimBranch, VideoLosslessTrimEditListSync), VideoLosslessTrimError> {
        var branchRaw: UInt32 = 0
        var movieTimescale: UInt32 = 0
        var segmentDuration: UInt32 = 0
        var mediaTime: Int32 = 0

        let status: Int32 = sourceURL.path.withCString { srcPtr in
            if let dstPath = destinationURL?.path {
                return dstPath.withCString { dstPtr in
                    ttmedia_trim_plan_and_preserve_metadata(
                        srcPtr, dstPtr, startSeconds, endSeconds,
                        &branchRaw, &movieTimescale, &segmentDuration, &mediaTime
                    )
                }
            }
            return ttmedia_trim_plan_and_preserve_metadata(
                srcPtr, nil, startSeconds, endSeconds,
                &branchRaw, &movieTimescale, &segmentDuration, &mediaTime
            )
        }

        switch status {
        case 0:
            let branch = VideoLosslessTrimBranch(rawValue: branchRaw) ?? .streamingRemux
            let sync = VideoLosslessTrimEditListSync(
                movieTimescale: movieTimescale,
                segmentDuration: segmentDuration,
                mediaTime: mediaTime
            )
            return .success((branch, sync))
        case -1:
            return .failure(.invalidTimeRange(lower: startSeconds, upper: endSeconds, duration: nil))
        case -2:
            return .failure(.sourceFileNotFound(sourceURL))
        default:
            return .failure(.unsupportedSource(sourceURL, reason: "Invalid or corrupt ISO BMFF container boxes."))
        }
    }

    public func trimVideo(
        sourceURL: URL,
        timeRange: ClosedRange<Double>,
        destinationURL: URL,
        stagingToken: String = UUID().uuidString,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VideoLosslessTrimResult {
        try await trimVideo(
            sourceURL: sourceURL,
            startSeconds: timeRange.lowerBound,
            endSeconds: timeRange.upperBound,
            destinationURL: destinationURL,
            stagingToken: stagingToken,
            progressHandler: progressHandler
        )
    }

    public func trimVideo(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        destinationURL: URL,
        stagingToken: String = UUID().uuidString,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VideoLosslessTrimResult {
        try validatePreflight(sourceURL: sourceURL, startSeconds: startSeconds, endSeconds: endSeconds, destinationURL: destinationURL)
        let sourceAsset = AVURLAsset(url: sourceURL)
        let clampedEnd = try await resolveClampedEndSeconds(
            sourceURL: sourceURL,
            asset: sourceAsset,
            startSeconds: startSeconds,
            endSeconds: endSeconds
        )
        let (branch, editSync) = try planTrim(
            sourceURL: sourceURL, destinationURL: nil, startSeconds: startSeconds, endSeconds: clampedEnd
        ).get()

        let stagingURL = makeStagingURL(for: destinationURL, token: stagingToken)
        try? FileManager.default.removeItem(at: stagingURL)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        do {
            try await runPassthroughExportSession(
                asset: sourceAsset,
                startSeconds: startSeconds,
                endSeconds: clampedEnd,
                stagingURL: stagingURL,
                destinationURL: destinationURL,
                progressHandler: progressHandler
            )
            try await applySimulatedExportDelayIfNeeded()
            let verified = try await verifyStagedOutput(
                stagingURL: stagingURL,
                sourceAsset: sourceAsset,
                expectedDuration: clampedEnd - startSeconds
            )
            try commitStagedFile(from: stagingURL, to: destinationURL, sourceURL: sourceURL, startSeconds: startSeconds, endSeconds: clampedEnd)
            progressHandler?(1.0)
            return VideoLosslessTrimResult(
                destinationURL: destinationURL,
                branch: branch,
                editListSync: editSync,
                outputBytes: verified.outputBytes,
                trimmedDurationSeconds: verified.trimmedDurationSeconds,
                videoTrackCount: verified.videoTrackCount,
                audioTrackCount: verified.audioTrackCount
            )
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: stagingURL)
            throw VideoLosslessTrimError.cancelled
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    private func resolveClampedEndSeconds(
        sourceURL: URL,
        asset: AVURLAsset,
        startSeconds: Double,
        endSeconds: Double
    ) async throws -> Double {
        let totalDuration = CMTimeGetSeconds(try await asset.load(.duration))
        guard totalDuration.isFinite, totalDuration > 0.0 else {
            throw VideoLosslessTrimError.unsupportedSource(sourceURL, reason: "Source media has no valid duration.")
        }
        guard startSeconds < totalDuration, endSeconds <= totalDuration + 0.05 else {
            throw VideoLosslessTrimError.invalidTimeRange(lower: startSeconds, upper: endSeconds, duration: totalDuration)
        }
        let clampedEnd = min(endSeconds, totalDuration)
        guard clampedEnd - startSeconds >= 0.1 else {
            throw VideoLosslessTrimError.invalidTimeRange(lower: startSeconds, upper: clampedEnd, duration: totalDuration)
        }
        return clampedEnd
    }

    private func validatePreflight(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        destinationURL: URL
    ) throws {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0.0, endSeconds > startSeconds, (endSeconds - startSeconds) >= 0.1 else {
            throw VideoLosslessTrimError.invalidTimeRange(lower: startSeconds, upper: endSeconds, duration: nil)
        }
        let srcCanonical = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let dstCanonical = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        if srcCanonical == dstCanonical {
            throw VideoLosslessTrimError.sameSourceAndDestination(sourceURL)
        }
        if case .failure(let err) = validateSourceCompatibility(sourceURL) {
            throw err
        }
        let parentDir = destinationURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentDir.path, isDirectory: &isDir),
              isDir.boolValue,
              FileManager.default.isWritableFile(atPath: parentDir.path) else {
            throw VideoLosslessTrimError.destinationUnwritable(destinationURL, reason: "Parent directory does not exist or is not writable.")
        }
    }

    private func runPassthroughExportSession(
        asset: AVURLAsset,
        startSeconds: Double,
        endSeconds: Double,
        stagingURL: URL,
        destinationURL: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoLosslessTrimError.exportFailed("Unable to create AVAssetExportSession for passthrough preset.")
        }
        exportSession.outputURL = stagingURL
        exportSession.outputFileType = resolveOutputFileType(for: destinationURL, supported: exportSession.supportedFileTypes)
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            end: CMTime(seconds: endSeconds, preferredTimescale: 600)
        )

        try Task.checkCancellation()
        do {
            exportSession.exportAsynchronously {}
            while exportSession.status == .waiting || exportSession.status == .exporting {
                try Task.checkCancellation()
                progressHandler?(Double(exportSession.progress) * 0.9)
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            try Task.checkCancellation()
            if exportSession.status == .cancelled {
                throw VideoLosslessTrimError.cancelled
            }
            guard exportSession.status == .completed else {
                let reason = exportSession.error?.localizedDescription ?? "Export session ended with status \(exportSession.status.rawValue)"
                throw VideoLosslessTrimError.exportFailed(reason)
            }
        } catch is CancellationError {
            exportSession.cancelExport()
            throw VideoLosslessTrimError.cancelled
        }
    }

    private func applySimulatedExportDelayIfNeeded() async throws {
        let delay = simulatedExportDelayNanoseconds
        guard delay > 0 else { return }
        let step: UInt64 = 10_000_000
        var elapsed: UInt64 = 0
        while elapsed < delay {
            if Task.isCancelled { throw VideoLosslessTrimError.cancelled }
            let chunk = min(step, delay - elapsed)
            try await Task.sleep(nanoseconds: chunk)
            elapsed += chunk
        }
        if Task.isCancelled { throw VideoLosslessTrimError.cancelled }
    }

    private func verifyStagedOutput(
        stagingURL: URL,
        sourceAsset: AVURLAsset,
        expectedDuration: Double
    ) async throws -> (outputBytes: UInt64, trimmedDurationSeconds: Double, videoTrackCount: Int, audioTrackCount: Int) {
        if case .failure(let err) = planTrim(
            sourceURL: stagingURL, destinationURL: nil, startSeconds: 0.0, endSeconds: max(0.1, expectedDuration * 0.5)
        ) {
            throw VideoLosslessTrimError.verificationFailed("Staged output failed ISO BMFF box check: \(err.localizedDescription)")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
        let outputBytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard outputBytes > 0 else {
            throw VideoLosslessTrimError.verificationFailed("Staged output file is empty.")
        }

        let stagedAsset = AVURLAsset(url: stagingURL)
        let srcVideo = try await sourceAsset.loadTracks(withMediaType: .video)
        let srcAudio = try await sourceAsset.loadTracks(withMediaType: .audio)
        let outVideo = try await stagedAsset.loadTracks(withMediaType: .video)
        let outAudio = try await stagedAsset.loadTracks(withMediaType: .audio)
        guard outVideo.count == srcVideo.count, outAudio.count == srcAudio.count, (outVideo.count + outAudio.count) > 0 else {
            throw VideoLosslessTrimError.verificationFailed("Track count mismatch between source and trimmed output.")
        }
        try await verifyTrackCodecMatch(sourceTracks: srcVideo, outputTracks: outVideo)
        try await verifyTrackCodecMatch(sourceTracks: srcAudio, outputTracks: outAudio)

        let actualDuration = CMTimeGetSeconds(try await stagedAsset.load(.duration))
        let tolerance = max(0.45, expectedDuration * 0.35)
        guard actualDuration.isFinite, actualDuration > 0, abs(actualDuration - expectedDuration) <= tolerance else {
            throw VideoLosslessTrimError.verificationFailed("Trimmed duration \(actualDuration)s outside tolerance of \(expectedDuration)s.")
        }
        if let vTrack = outVideo.first, let aTrack = outAudio.first {
            let vDur = CMTimeGetSeconds((try await vTrack.load(.timeRange)).duration)
            let aDur = CMTimeGetSeconds((try await aTrack.load(.timeRange)).duration)
            guard abs(vDur - aDur) <= 0.35 else {
                throw VideoLosslessTrimError.verificationFailed("A/V track duration desynchronization (\(vDur)s vs \(aDur)s).")
            }
        }
        return (outputBytes, actualDuration, outVideo.count, outAudio.count)
    }

    private func verifyTrackCodecMatch(sourceTracks: [AVAssetTrack], outputTracks: [AVAssetTrack]) async throws {
        guard let srcFirst = sourceTracks.first, let outFirst = outputTracks.first else { return }
        let srcDescs = try await srcFirst.load(.formatDescriptions)
        let outDescs = try await outFirst.load(.formatDescriptions)
        guard let srcDesc = srcDescs.first, let outDesc = outDescs.first,
              CMFormatDescriptionGetMediaSubType(srcDesc) == CMFormatDescriptionGetMediaSubType(outDesc) else {
            throw VideoLosslessTrimError.verificationFailed("Codec fourCC changed during lossless passthrough.")
        }
    }

    private func commitStagedFile(
        from stagingURL: URL,
        to destinationURL: URL,
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double
    ) throws {
        if Task.isCancelled {
            throw VideoLosslessTrimError.cancelled
        }
        _ = planTrim(sourceURL: sourceURL, destinationURL: stagingURL, startSeconds: startSeconds, endSeconds: endSeconds)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        }
        if case .failure(let err) = planTrim(
            sourceURL: sourceURL, destinationURL: destinationURL, startSeconds: startSeconds, endSeconds: endSeconds
        ) {
            throw err
        }
    }

    private func resolveOutputFileType(for destinationURL: URL, supported: [AVFileType]) -> AVFileType {
        switch destinationURL.pathExtension.lowercased() {
        case "mov":
            return supported.contains(.mov) ? .mov : (supported.first ?? .mp4)
        case "m4v":
            return supported.contains(.m4v) ? .m4v : (supported.first ?? .mp4)
        default:
            return supported.contains(.mp4) ? .mp4 : (supported.first ?? .mp4)
        }
    }
}
