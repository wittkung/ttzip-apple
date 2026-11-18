// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import TTMediaDemux

/// Target ISO-BMFF container format for zero-transcode remuxing.
public enum MediaRemuxTargetContainer: UInt32, CaseIterable, Sendable, Equatable, Identifiable {
    case mp4 = 0
    case mov = 1

    public var id: UInt32 { rawValue }

    public var fileExtension: String {
        switch self {
        case .mp4:
            return "mp4"
        case .mov:
            return "mov"
        }
    }

    public var displayName: String {
        switch self {
        case .mp4:
            return "MP4 (ISO-BMFF)"
        case .mov:
            return "QuickTime MOV"
        }
    }

    public var avFileType: AVFileType {
        switch self {
        case .mp4:
            return .mp4
        case .mov:
            return .mov
        }
    }
}

/// Execution path selected based on the source container format.
public enum MediaRemuxExecutionPath: String, Sendable, Equatable {
    case isoBMFFPassthrough
    case rustBitstreamRemux
}

/// Configuration options for lossless container remuxing.
public struct MediaContainerRemuxOptions: Sendable, Equatable {
    public var targetContainer: MediaRemuxTargetContainer
    public var fastStart: Bool
    public var stripAudio: Bool

    public init(
        targetContainer: MediaRemuxTargetContainer = .mp4,
        fastStart: Bool = true,
        stripAudio: Bool = false
    ) {
        self.targetContainer = targetContainer
        self.fastStart = fastStart
        self.stripAudio = stripAudio
    }
}

/// Verified output metadata returned upon completing a container remux.
public struct MediaContainerRemuxResult: Sendable, Equatable {
    public let destinationURL: URL
    public let targetContainer: MediaRemuxTargetContainer
    public let executionPath: MediaRemuxExecutionPath
    public let outputBytes: UInt64
    public let durationSeconds: Double
    public let videoTrackCount: Int
    public let audioTrackCount: Int
    public let sampleCount: UInt64
    public let syncSampleCount: UInt64

    public init(
        destinationURL: URL,
        targetContainer: MediaRemuxTargetContainer,
        executionPath: MediaRemuxExecutionPath,
        outputBytes: UInt64,
        durationSeconds: Double,
        videoTrackCount: Int,
        audioTrackCount: Int,
        sampleCount: UInt64,
        syncSampleCount: UInt64
    ) {
        self.destinationURL = destinationURL
        self.targetContainer = targetContainer
        self.executionPath = executionPath
        self.outputBytes = outputBytes
        self.durationSeconds = durationSeconds
        self.videoTrackCount = videoTrackCount
        self.audioTrackCount = audioTrackCount
        self.sampleCount = sampleCount
        self.syncSampleCount = syncSampleCount
    }
}

/// Strongly-typed failure domains for lossless container remuxing.
public enum MediaContainerRemuxError: LocalizedError, Sendable, Equatable {
    case sourceFileNotFound(URL)
    case unsupportedSource(URL, reason: String)
    case inputTooLargeForInMemoryRemux(URL, fileBytes: UInt64, limitBytes: UInt64)
    case sameSourceAndDestination(URL)
    case destinationUnwritable(URL, reason: String)
    case cancelled
    case remuxFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceFileNotFound(let url):
            return "Source media file does not exist: \(url.path)"
        case .unsupportedSource(let url, let reason):
            return "Unsupported source (\(url.lastPathComponent)): \(reason)"
        case .inputTooLargeForInMemoryRemux(let url, let fileBytes, let limitBytes):
            return "Source (\(url.lastPathComponent)) size (\(fileBytes) bytes) exceeds in-memory remux limit (\(limitBytes) bytes)."
        case .sameSourceAndDestination(let url):
            return "Destination path must be distinct from source path: \(url.path)"
        case .destinationUnwritable(let url, let reason):
            return "Destination is not writable (\(url.path)): \(reason)"
        case .cancelled:
            return "Container remux was cancelled."
        case .remuxFailed(let reason):
            return "Container remux failed: \(reason)"
        case .verificationFailed(let reason):
            return "Remuxed container verification failed: \(reason)"
        }
    }
}

/// Production container remuxing pipeline combining AVAssetExportSession ISO-BMFF passthrough
/// (`mp4`/`mov`/`m4v`) and the Rust C-ABI bitstream remuxer (`mkv`/`webm`/`ts`/`h264`/`hevc`).
public final class MediaContainerRemuxPipeline: @unchecked Sendable {
    public static let shared = MediaContainerRemuxPipeline()

    public static let isoBMFFPassthroughExtensions: Set<String> = ["mp4", "mov", "m4v"]
    public static let rustBitstreamRemuxExtensions: Set<String> = [
        "mkv", "webm", "ts", "m2ts", "mts", "h264", "264", "hevc", "265"
    ]
    public static let supportedExtensions: Set<String> =
        isoBMFFPassthroughExtensions.union(rustBitstreamRemuxExtensions)

    /// Maximum input file size (bytes) permitted on the in-memory Rust bitstream remux path.
    public var maxInMemoryInputBytes: UInt64 = 256 * 1024 * 1024

    /// Optional cooperative delay (in nanoseconds) during staging export for deterministic cancellation tests.
    public var simulatedExportDelayNanoseconds: UInt64 = 0

    public init() {}

    public func defaultOutputURL(
        for sourceURL: URL,
        targetContainer: MediaRemuxTargetContainer = .mp4
    ) -> URL {
        let sourcePath = sourceURL.path
        var requiredLen: Int = 0
        let queryStatus = sourcePath.withCString { srcPtr in
            ttmedia_remux_default_output_path(srcPtr, targetContainer.rawValue, nil, 0, &requiredLen)
        }
        let fallbackName = "remuxed.\(targetContainer.fileExtension)"
        guard queryStatus == 0, requiredLen > 0 else {
            return sourceURL.deletingLastPathComponent().appendingPathComponent(fallbackName)
        }
        var buffer = [CChar](repeating: 0, count: requiredLen + 1)
        let copyStatus = sourcePath.withCString { srcPtr in
            ttmedia_remux_default_output_path(srcPtr, targetContainer.rawValue, &buffer, buffer.count, &requiredLen)
        }
        guard copyStatus == 0 else {
            return sourceURL.deletingLastPathComponent().appendingPathComponent(fallbackName)
        }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    public func makeStagingURL(
        for destinationURL: URL,
        targetContainer: MediaRemuxTargetContainer? = nil,
        token: String = UUID().uuidString
    ) -> URL {
        let ext = targetContainer?.fileExtension
            ?? (destinationURL.pathExtension.isEmpty ? "mp4" : destinationURL.pathExtension.lowercased())
        let name = "\(destinationURL.lastPathComponent).ttmedia-remux-staging-\(token).\(ext)"
        return destinationURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    public func classifyExecutionPath(
        for sourceURL: URL
    ) -> Result<MediaRemuxExecutionPath, MediaContainerRemuxError> {
        let ext = sourceURL.pathExtension.lowercased()
        if Self.isoBMFFPassthroughExtensions.contains(ext) {
            return .success(.isoBMFFPassthrough)
        }
        if Self.rustBitstreamRemuxExtensions.contains(ext) {
            return .success(.rustBitstreamRemux)
        }
        return .failure(
            .unsupportedSource(
                sourceURL,
                reason: "Container extension '.\(ext)' is not supported for lossless remuxing."
            )
        )
    }

    public func validateSourceCompatibility(
        _ sourceURL: URL
    ) -> Result<MediaRemuxExecutionPath, MediaContainerRemuxError> {
        let sizeResult = validateSourceFileSize(sourceURL)
        guard case .success(let size) = sizeResult else {
            if case .failure(let err) = sizeResult { return .failure(err) }
            return .failure(.sourceFileNotFound(sourceURL))
        }
        let pathResult = classifyExecutionPath(for: sourceURL)
        guard case .success(let executionPath) = pathResult else {
            return pathResult
        }
        return validateExecutionPathConstraints(
            sourceURL: sourceURL,
            executionPath: executionPath,
            fileSize: size
        )
    }

    private func validateSourceFileSize(
        _ sourceURL: URL
    ) -> Result<Int64, MediaContainerRemuxError> {
        guard sourceURL.isFileURL else {
            return .failure(.unsupportedSource(sourceURL, reason: "Only local media file URLs are supported."))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            return .failure(.sourceFileNotFound(sourceURL))
        }
        guard !isDir.boolValue else {
            return .failure(.unsupportedSource(sourceURL, reason: "Source path is a directory."))
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            return .failure(.unsupportedSource(sourceURL, reason: "Source media file is empty."))
        }
        return .success(size)
    }

    private func validateExecutionPathConstraints(
        sourceURL: URL,
        executionPath: MediaRemuxExecutionPath,
        fileSize: Int64
    ) -> Result<MediaRemuxExecutionPath, MediaContainerRemuxError> {
        if executionPath == .isoBMFFPassthrough {
            guard Self.hasRequiredISOBMFFBoxes(at: sourceURL) else {
                return .failure(.unsupportedSource(sourceURL, reason: "Invalid or corrupt ISO-BMFF container boxes."))
            }
            return .success(executionPath)
        }
        let fileBytes = UInt64(fileSize)
        let limitBytes = maxInMemoryInputBytes > 0 ? maxInMemoryInputBytes : (256 * 1024 * 1024)
        guard fileBytes <= limitBytes else {
            return .failure(.inputTooLargeForInMemoryRemux(sourceURL, fileBytes: fileBytes, limitBytes: limitBytes))
        }
        return .success(executionPath)
    }

    public func remuxMedia(
        sourceURL: URL,
        destinationURL: URL,
        options: MediaContainerRemuxOptions = MediaContainerRemuxOptions(),
        stagingToken: String = UUID().uuidString,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaContainerRemuxResult {
        let executionPath = try validatePreflight(sourceURL: sourceURL, destinationURL: destinationURL)
        let stagingURL = makeStagingURL(
            for: destinationURL,
            targetContainer: options.targetContainer,
            token: stagingToken
        )
        try? FileManager.default.removeItem(at: stagingURL)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        do {
            let result: MediaContainerRemuxResult
            switch executionPath {
            case .isoBMFFPassthrough:
                result = try await executeISOBMFFPassthrough(
                    sourceURL: sourceURL,
                    stagingURL: stagingURL,
                    destinationURL: destinationURL,
                    options: options,
                    progressHandler: progressHandler
                )
            case .rustBitstreamRemux:
                result = try await executeRustBitstreamRemux(
                    sourceURL: sourceURL,
                    stagingURL: stagingURL,
                    destinationURL: destinationURL,
                    options: options,
                    progressHandler: progressHandler
                )
            }
            try commitStagedFile(from: stagingURL, to: destinationURL, sourceURL: sourceURL)
            progressHandler?(1.0)
            return result
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: stagingURL)
            throw MediaContainerRemuxError.cancelled
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    private func validatePreflight(
        sourceURL: URL,
        destinationURL: URL
    ) throws -> MediaRemuxExecutionPath {
        let srcCanonical = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let dstCanonical = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        if srcCanonical == dstCanonical {
            throw MediaContainerRemuxError.sameSourceAndDestination(sourceURL)
        }
        let executionPath = try validateSourceCompatibility(sourceURL).get()
        let parentDir = destinationURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentDir.path, isDirectory: &isDir),
              isDir.boolValue,
              FileManager.default.isWritableFile(atPath: parentDir.path) else {
            throw MediaContainerRemuxError.destinationUnwritable(
                destinationURL,
                reason: "Parent directory does not exist or is not writable."
            )
        }
        return executionPath
    }

    private func executeISOBMFFPassthrough(
        sourceURL: URL,
        stagingURL: URL,
        destinationURL: URL,
        options: MediaContainerRemuxOptions,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> MediaContainerRemuxResult {
        let sourceAsset = AVURLAsset(url: sourceURL)
        let srcVideo = try await sourceAsset.loadTracks(withMediaType: .video)
        let srcAudio = try await sourceAsset.loadTracks(withMediaType: .audio)
        let srcDuration = CMTimeGetSeconds(try await sourceAsset.load(.duration))
        guard !srcVideo.isEmpty, srcDuration.isFinite, srcDuration > 0 else {
            throw MediaContainerRemuxError.unsupportedSource(sourceURL, reason: "No valid video track or duration.")
        }

        let exportAsset: AVAsset = try await buildPassthroughExportAsset(
            sourceAsset: sourceAsset,
            videoTracks: srcVideo,
            stripAudio: options.stripAudio
        )
        try await runExportSession(
            asset: exportAsset,
            stagingURL: stagingURL,
            options: options,
            progressHandler: progressHandler
        )
        try await applySimulatedExportDelayIfNeeded()

        let expectedAudioCount = options.stripAudio ? 0 : srcAudio.count
        let verified = try await verifyStagedOutput(
            stagingURL: stagingURL,
            fastStart: options.fastStart,
            expectedVideoCount: srcVideo.count,
            expectedAudioCount: expectedAudioCount,
            expectedVideoTracks: srcVideo,
            expectedDuration: srcDuration
        )
        return MediaContainerRemuxResult(
            destinationURL: destinationURL,
            targetContainer: options.targetContainer,
            executionPath: .isoBMFFPassthrough,
            outputBytes: verified.outputBytes,
            durationSeconds: verified.durationSeconds,
            videoTrackCount: verified.videoTrackCount,
            audioTrackCount: verified.audioTrackCount,
            sampleCount: 0,
            syncSampleCount: 0
        )
    }

    private func buildPassthroughExportAsset(
        sourceAsset: AVURLAsset,
        videoTracks: [AVAssetTrack],
        stripAudio: Bool
    ) async throws -> AVAsset {
        guard stripAudio else { return sourceAsset }
        let composition = AVMutableComposition()
        for srcTrack in videoTracks {
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            let timeRange = try await srcTrack.load(.timeRange)
            let transform = try await srcTrack.load(.preferredTransform)
            try compTrack.insertTimeRange(timeRange, of: srcTrack, at: .zero)
            compTrack.preferredTransform = transform
        }
        return composition
    }

    private func runExportSession(
        asset: AVAsset,
        stagingURL: URL,
        options: MediaContainerRemuxOptions,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaContainerRemuxError.remuxFailed("Unable to create passthrough AVAssetExportSession.")
        }
        session.outputURL = stagingURL
        let desiredType = options.targetContainer.avFileType
        guard session.supportedFileTypes.contains(desiredType) else {
            throw MediaContainerRemuxError.remuxFailed(
                "Passthrough export session does not support target container \(options.targetContainer.displayName)."
            )
        }
        session.outputFileType = desiredType
        session.shouldOptimizeForNetworkUse = options.fastStart

        try Task.checkCancellation()
        do {
            session.exportAsynchronously {}
            while session.status == .waiting || session.status == .exporting {
                try Task.checkCancellation()
                progressHandler?(Double(session.progress) * 0.9)
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            try Task.checkCancellation()
            if session.status == .cancelled {
                throw MediaContainerRemuxError.cancelled
            }
            guard session.status == .completed else {
                let reason = session.error?.localizedDescription ?? "Export ended with status \(session.status.rawValue)"
                throw MediaContainerRemuxError.remuxFailed(reason)
            }
        } catch is CancellationError {
            session.cancelExport()
            throw MediaContainerRemuxError.cancelled
        }
    }

    private func executeRustBitstreamRemux(
        sourceURL: URL,
        stagingURL: URL,
        destinationURL: URL,
        options: MediaContainerRemuxOptions,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> MediaContainerRemuxResult {
        progressHandler?(0.15)
        try await applySimulatedExportDelayIfNeeded()

        var videoCodecRaw: UInt32 = 0
        var sampleCount: UInt64 = 0
        var syncSampleCount: UInt64 = 0
        var durationMs: UInt64 = 0
        var bytesWritten: UInt64 = 0
        let limitBytes = maxInMemoryInputBytes > 0 ? maxInMemoryInputBytes : (256 * 1024 * 1024)

        let status: Int32 = sourceURL.path.withCString { srcPtr in
            stagingURL.path.withCString { dstPtr in
                ttmedia_remux_container_file(
                    srcPtr,
                    dstPtr,
                    options.targetContainer.rawValue,
                    options.fastStart,
                    options.stripAudio,
                    limitBytes,
                    &videoCodecRaw,
                    &sampleCount,
                    &syncSampleCount,
                    &durationMs,
                    &bytesWritten
                )
            }
        }
        try mapRustRemuxStatus(status, sourceURL: sourceURL, limitBytes: limitBytes)
        if Task.isCancelled {
            throw MediaContainerRemuxError.cancelled
        }
        progressHandler?(0.85)

        let expectedDuration = Double(durationMs) / 1000.0
        let verified = try await verifyStagedOutput(
            stagingURL: stagingURL,
            fastStart: options.fastStart,
            expectedVideoCount: 1,
            expectedAudioCount: 0,
            expectedVideoTracks: nil,
            expectedDuration: expectedDuration
        )
        return MediaContainerRemuxResult(
            destinationURL: destinationURL,
            targetContainer: options.targetContainer,
            executionPath: .rustBitstreamRemux,
            outputBytes: verified.outputBytes,
            durationSeconds: verified.durationSeconds,
            videoTrackCount: verified.videoTrackCount,
            audioTrackCount: verified.audioTrackCount,
            sampleCount: sampleCount,
            syncSampleCount: syncSampleCount
        )
    }

    private func mapRustRemuxStatus(
        _ status: Int32,
        sourceURL: URL,
        limitBytes: UInt64
    ) throws {
        switch status {
        case 0:
            return
        case -5:
            let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
            let fileBytes = (attrs?[.size] as? NSNumber)?.uint64Value ?? (limitBytes + 1)
            throw MediaContainerRemuxError.inputTooLargeForInMemoryRemux(
                sourceURL,
                fileBytes: fileBytes,
                limitBytes: limitBytes
            )
        case -2:
            throw MediaContainerRemuxError.sourceFileNotFound(sourceURL)
        case -1:
            throw MediaContainerRemuxError.remuxFailed("Invalid remux C-ABI arguments.")
        default:
            throw MediaContainerRemuxError.unsupportedSource(
                sourceURL,
                reason: "Unsupported or corrupt video bitstream in source container."
            )
        }
    }

    private func applySimulatedExportDelayIfNeeded() async throws {
        let delay = simulatedExportDelayNanoseconds
        guard delay > 0 else { return }
        let step: UInt64 = 10_000_000
        var elapsed: UInt64 = 0
        while elapsed < delay {
            if Task.isCancelled { throw MediaContainerRemuxError.cancelled }
            let chunk = min(step, delay - elapsed)
            try await Task.sleep(nanoseconds: chunk)
            elapsed += chunk
        }
        if Task.isCancelled { throw MediaContainerRemuxError.cancelled }
    }

    private func verifyStagedOutput(
        stagingURL: URL,
        fastStart: Bool,
        expectedVideoCount: Int,
        expectedAudioCount: Int,
        expectedVideoTracks: [AVAssetTrack]?,
        expectedDuration: Double
    ) async throws -> (outputBytes: UInt64, durationSeconds: Double, videoTrackCount: Int, audioTrackCount: Int) {
        let boxOffsets = try Self.readTopLevelBoxOffsets(at: stagingURL)
        guard let ftypOff = boxOffsets["ftyp"],
              let moovOff = boxOffsets["moov"],
              let mdatOff = boxOffsets["mdat"],
              ftypOff == 0 else {
            throw MediaContainerRemuxError.verificationFailed("Staged output is missing ftyp/moov/mdat boxes.")
        }
        if fastStart && moovOff > mdatOff {
            throw MediaContainerRemuxError.verificationFailed("FastStart enabled, but moov was placed after mdat.")
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
        let outputBytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard outputBytes > 0 else {
            throw MediaContainerRemuxError.verificationFailed("Staged output file is empty.")
        }

        let stagedAsset = AVURLAsset(url: stagingURL)
        let outVideo = try await stagedAsset.loadTracks(withMediaType: .video)
        let outAudio = try await stagedAsset.loadTracks(withMediaType: .audio)
        guard outVideo.count == expectedVideoCount, outAudio.count == expectedAudioCount else {
            throw MediaContainerRemuxError.verificationFailed(
                "Track count mismatch (video: \(outVideo.count)/\(expectedVideoCount), audio: \(outAudio.count)/\(expectedAudioCount))."
            )
        }
        if let expectedVideoTracks {
            try await verifyVideoCodecPreserved(sourceTracks: expectedVideoTracks, outputTracks: outVideo)
        } else if let firstTrack = outVideo.first {
            let descs = try await firstTrack.load(.formatDescriptions)
            guard !descs.isEmpty else {
                throw MediaContainerRemuxError.verificationFailed("Remuxed video track has no format description.")
            }
        }

        let actualDuration = CMTimeGetSeconds(try await stagedAsset.load(.duration))
        let tolerance = max(0.35, expectedDuration * 0.35)
        guard actualDuration.isFinite, actualDuration > 0,
              expectedDuration <= 0 || abs(actualDuration - expectedDuration) <= tolerance else {
            throw MediaContainerRemuxError.verificationFailed(
                "Remuxed duration \(actualDuration)s outside tolerance of \(expectedDuration)s."
            )
        }
        return (outputBytes, actualDuration, outVideo.count, outAudio.count)
    }

    private func verifyVideoCodecPreserved(
        sourceTracks: [AVAssetTrack],
        outputTracks: [AVAssetTrack]
    ) async throws {
        guard let srcFirst = sourceTracks.first, let outFirst = outputTracks.first else { return }
        let srcDescs = try await srcFirst.load(.formatDescriptions)
        let outDescs = try await outFirst.load(.formatDescriptions)
        guard let srcDesc = srcDescs.first, let outDesc = outDescs.first,
              CMFormatDescriptionGetMediaSubType(srcDesc) == CMFormatDescriptionGetMediaSubType(outDesc) else {
            throw MediaContainerRemuxError.verificationFailed("Video codec fourCC changed during passthrough remux.")
        }
    }

    private func commitStagedFile(
        from stagingURL: URL,
        to destinationURL: URL,
        sourceURL: URL
    ) throws {
        if Task.isCancelled {
            throw MediaContainerRemuxError.cancelled
        }
        try Self.preserveSourceAttributes(from: sourceURL, to: stagingURL)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        }
        try Self.preserveSourceAttributes(from: sourceURL, to: destinationURL)
    }

    private static func preserveSourceAttributes(from sourceURL: URL, to destinationURL: URL) throws {
        let srcAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        var updates: [FileAttributeKey: Any] = [:]
        if let mtime = srcAttrs[.modificationDate] {
            updates[.modificationDate] = mtime
        }
        if let perms = srcAttrs[.posixPermissions] {
            updates[.posixPermissions] = perms
        }
        if !updates.isEmpty {
            try FileManager.default.setAttributes(updates, ofItemAtPath: destinationURL.path)
        }
    }

    public static func hasRequiredISOBMFFBoxes(at url: URL) -> Bool {
        guard let offsets = try? readTopLevelBoxOffsets(at: url) else { return false }
        return offsets["ftyp"] != nil && offsets["moov"] != nil && offsets["mdat"] != nil
    }

    public static func readTopLevelBoxOffsets(at url: URL) throws -> [String: UInt64] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileLen = try handle.seekToEnd()
        var offset: UInt64 = 0
        var boxes: [String: UInt64] = [:]

        while fileLen >= 8 && offset <= fileLen - 8 {
            try handle.seek(toOffset: offset)
            guard let hdr = try handle.read(upToCount: 8), hdr.count == 8 else { break }
            let size32 = hdr[hdr.startIndex..<(hdr.startIndex + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let typeBytes = hdr[(hdr.startIndex + 4)..<(hdr.startIndex + 8)]
            if let name = String(bytes: typeBytes, encoding: .ascii), boxes[name] == nil {
                boxes[name] = offset
            }
            let minHeaderSize: UInt64
            let step: UInt64
            if size32 == 1 {
                guard fileLen >= 16,
                      offset <= fileLen - 16,
                      let ext = try handle.read(upToCount: 8), ext.count == 8 else {
                    throw MediaContainerRemuxError.verificationFailed("Truncated 64-bit ISO-BMFF box header.")
                }
                minHeaderSize = 16
                step = ext.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            } else if size32 == 0 {
                minHeaderSize = 8
                step = fileLen - offset
            } else {
                minHeaderSize = 8
                step = size32
            }
            let remaining = fileLen - offset
            guard step >= minHeaderSize, step <= remaining else {
                throw MediaContainerRemuxError.verificationFailed("Invalid or out-of-bounds ISO-BMFF box size.")
            }
            offset += step
        }
        return boxes
    }
}
