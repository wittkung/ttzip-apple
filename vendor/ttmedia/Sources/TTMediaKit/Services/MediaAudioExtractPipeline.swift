// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
@preconcurrency import AVFoundation
import CoreAudioTypes
import CoreMedia
import TTMediaDemux

/// Production audio track extraction pipeline combining AVAssetReader/AVAssetWriter lossless M4A track extraction
/// (`mp4`/`mov`/`m4v`/`m4a`) and the Rust C-ABI bitstream demuxer (`mkv`/`webm`/`ts`/`aac`/`flac`/`opus`).
public final class MediaAudioExtractPipeline: @unchecked Sendable {
    public static let shared = MediaAudioExtractPipeline()

    public static let avFoundationISOBMFFExtensions: Set<String> = [
        "mp4", "mov", "m4v", "m4a"
    ]
    public static let rustBitstreamExtensions: Set<String> = [
        "mkv", "webm", "ts", "m2ts", "mts", "aac", "flac", "opus", "ogg"
    ]
    public static let supportedExtensions: Set<String> =
        avFoundationISOBMFFExtensions.union(rustBitstreamExtensions)

    public var maxInMemoryInputBytes: UInt64 = 256 * 1024 * 1024
    public var simulatedExtractDelayNanoseconds: UInt64 = 0

    public init() {}

    // MARK: - Output Naming & Staging

    public func defaultOutputURL(
        for sourceURL: URL,
        mode: MediaAudioExtractionMode = .encapsulatedM4a,
        codec: MediaAudioExtractCodec = .aac,
        trackIndex: Int = 0
    ) -> URL {
        let sourcePath = sourceURL.path
        let safeTrack = UInt32(max(0, trackIndex))
        var requiredLen: Int = 0
        let queryStatus = sourcePath.withCString { srcPtr in
            ttmedia_audio_extract_default_output_path(
                srcPtr,
                mode.rawValue,
                codec.rawValue,
                safeTrack,
                nil,
                0,
                &requiredLen
            )
        }
        let fallbackName = "audio.\(mode == .encapsulatedM4a ? "m4a" : codec.fileExtension)"
        guard queryStatus == 0, requiredLen > 0 else {
            return sourceURL.deletingLastPathComponent().appendingPathComponent(fallbackName)
        }

        var buffer = [CChar](repeating: 0, count: requiredLen + 1)
        let copyStatus = sourcePath.withCString { srcPtr in
            ttmedia_audio_extract_default_output_path(
                srcPtr,
                mode.rawValue,
                codec.rawValue,
                safeTrack,
                &buffer,
                buffer.count,
                &requiredLen
            )
        }
        guard copyStatus == 0 else {
            return sourceURL.deletingLastPathComponent().appendingPathComponent(fallbackName)
        }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    public func makeStagingURL(
        for destinationURL: URL,
        mode: MediaAudioExtractionMode = .encapsulatedM4a,
        codec: MediaAudioExtractCodec = .aac,
        token: String = UUID().uuidString
    ) -> URL {
        let ext = mode == .encapsulatedM4a ? "m4a" : codec.fileExtension
        let parentDir = destinationURL.deletingLastPathComponent()
        let stagedName = "\(destinationURL.lastPathComponent).ttmedia-audio-staging-\(token).\(ext)"
        return parentDir.appendingPathComponent(stagedName)
    }

    // MARK: - Source Classification & Validation

    public func classifyExecutionPath(
        for sourceURL: URL,
        mode: MediaAudioExtractionMode = .encapsulatedM4a
    ) -> Result<MediaAudioExtractExecutionPath, MediaAudioExtractError> {
        let ext = sourceURL.pathExtension.lowercased()
        if Self.avFoundationISOBMFFExtensions.contains(ext) {
            let resolvedPath: MediaAudioExtractExecutionPath =
                mode == .encapsulatedM4a ? .avFoundationM4A : .rustBitstreamExtract
            return .success(resolvedPath)
        }
        if Self.rustBitstreamExtensions.contains(ext) {
            return .success(.rustBitstreamExtract)
        }
        return .failure(
            .unsupportedSource(
                sourceURL,
                reason: "Container extension '.\(ext)' is not supported for audio extraction."
            )
        )
    }

    public func validateSourceCompatibility(
        _ sourceURL: URL,
        mode: MediaAudioExtractionMode = .encapsulatedM4a
    ) -> Result<MediaAudioExtractExecutionPath, MediaAudioExtractError> {
        let sizeResult = validateSourceFileSize(sourceURL)
        guard case .success(let size) = sizeResult else {
            if case .failure(let error) = sizeResult {
                return .failure(error)
            }
            return .failure(.sourceFileNotFound(sourceURL))
        }
        let pathResult = classifyExecutionPath(for: sourceURL, mode: mode)
        guard case .success(let executionPath) = pathResult else {
            return pathResult
        }
        return validateExecutionPathConstraints(
            sourceURL: sourceURL,
            executionPath: executionPath,
            mode: mode,
            fileSize: size
        )
    }

    private func validateSourceFileSize(_ sourceURL: URL) -> Result<Int64, MediaAudioExtractError> {
        guard sourceURL.isFileURL else {
            return .failure(
                .unsupportedSource(sourceURL, reason: "Only local media file URLs are supported.")
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            return .failure(.sourceFileNotFound(sourceURL))
        }
        guard !isDirectory.boolValue else {
            return .failure(.unsupportedSource(sourceURL, reason: "Source path is a directory."))
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            return .failure(.unsupportedSource(sourceURL, reason: "Source media file is empty."))
        }
        return .success(size)
    }

    private func validateExecutionPathConstraints(
        sourceURL: URL,
        executionPath: MediaAudioExtractExecutionPath,
        mode: MediaAudioExtractionMode,
        fileSize: Int64
    ) -> Result<MediaAudioExtractExecutionPath, MediaAudioExtractError> {
        let ext = sourceURL.pathExtension.lowercased()
        if mode == .encapsulatedM4a && ["flac", "opus", "ogg"].contains(ext) {
            return .failure(
                .unsupportedAudioCodec(
                    "'.\(ext)' bitstream cannot be encapsulated into .m4a without transcoding."
                )
            )
        }
        if Self.avFoundationISOBMFFExtensions.contains(ext) {
            guard MediaContainerRemuxPipeline.hasRequiredISOBMFFBoxes(at: sourceURL) else {
                return .failure(
                    .unsupportedSource(
                        sourceURL,
                        reason: "Invalid or corrupt ISO-BMFF container boxes."
                    )
                )
            }
            if executionPath == .avFoundationM4A {
                return .success(executionPath)
            }
        }
        let fileBytes = UInt64(fileSize)
        let limitBytes = maxInMemoryInputBytes > 0 ? maxInMemoryInputBytes : (256 * 1024 * 1024)
        guard fileBytes <= limitBytes else {
            return .failure(
                .inputTooLargeForInMemoryExtract(
                    sourceURL,
                    fileBytes: fileBytes,
                    limitBytes: limitBytes
                )
            )
        }
        return .success(executionPath)
    }

    // MARK: - Audio Track Discovery

    public func discoverAudioTracks(in sourceURL: URL) async -> [MediaAudioTrackDescriptor] {
        let ext = sourceURL.pathExtension.lowercased()
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return []
        }
        if Self.avFoundationISOBMFFExtensions.contains(ext) {
            let asset = AVURLAsset(url: sourceURL)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else {
                return []
            }
            var descriptors: [MediaAudioTrackDescriptor] = []
            for (index, track) in tracks.enumerated() {
                if let descriptor = await buildDescriptor(for: track, index: index) {
                    descriptors.append(descriptor)
                }
            }
            return descriptors
        }
        guard Self.rustBitstreamExtensions.contains(ext) else {
            return []
        }
        return Self.discoverRustBitstreamAudioTracks(at: sourceURL, ext: ext)
    }

    internal func buildDescriptor(
        for track: AVAssetTrack,
        index: Int
    ) async -> MediaAudioTrackDescriptor? {
        let formatDescriptions = (try? await track.load(.formatDescriptions)) ?? []
        let languageCode = try? await track.load(.languageCode)
        guard let firstDescription = formatDescriptions.first else {
            return MediaAudioTrackDescriptor(
                index: index,
                trackID: track.trackID,
                codec: .unknown,
                codecFourCC: "unkn",
                channels: 2,
                sampleRate: 44100,
                languageCode: languageCode
            )
        }
        let subType = CMFormatDescriptionGetMediaSubType(firstDescription)
        let streamBasic = CMAudioFormatDescriptionGetStreamBasicDescription(firstDescription)?.pointee
        let sampleRate = streamBasic?.mSampleRate ?? 44100.0
        let channels = Int(streamBasic?.mChannelsPerFrame ?? 2)
        return MediaAudioTrackDescriptor(
            index: index,
            trackID: track.trackID,
            codec: Self.mapAudioSubType(subType),
            codecFourCC: Self.fourCCString(subType),
            channels: max(1, channels),
            sampleRate: sampleRate > 0 ? sampleRate : 44100.0,
            languageCode: languageCode
        )
    }

    // MARK: - Extraction Entrypoint

    public func extractAudioTrack(
        sourceURL: URL,
        destinationURL: URL,
        options: MediaAudioExtractOptions = MediaAudioExtractOptions(),
        stagingToken: String = UUID().uuidString,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaAudioExtractResult {
        let executionPath = try validatePreflight(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            mode: options.mode
        )
        let stagingURL = makeStagingURL(
            for: destinationURL,
            mode: options.mode,
            codec: options.preferredCodec,
            token: stagingToken
        )
        try? FileManager.default.removeItem(at: stagingURL)
        defer {
            try? FileManager.default.removeItem(at: stagingURL)
        }

        do {
            let result: MediaAudioExtractResult
            switch executionPath {
            case .avFoundationM4A:
                result = try await executeAVFoundationM4A(
                    sourceURL: sourceURL,
                    stagingURL: stagingURL,
                    destinationURL: destinationURL,
                    options: options,
                    progressHandler: progressHandler
                )
            case .rustBitstreamExtract:
                result = try await executeRustBitstreamExtract(
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
            throw MediaAudioExtractError.cancelled
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    private func validatePreflight(
        sourceURL: URL,
        destinationURL: URL,
        mode: MediaAudioExtractionMode
    ) throws -> MediaAudioExtractExecutionPath {
        let normalizedSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedDestination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        if normalizedSource == normalizedDestination {
            throw MediaAudioExtractError.sameSourceAndDestination(sourceURL)
        }
        let executionPath = try validateSourceCompatibility(sourceURL, mode: mode).get()
        let parentDir = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: parentDir.path) else {
            throw MediaAudioExtractError.destinationUnwritable(
                destinationURL,
                reason: "Parent directory does not exist or is not writable."
            )
        }
        return executionPath
    }

    // MARK: - AVFoundation Lossless M4A Passthrough

    private func executeAVFoundationM4A(
        sourceURL: URL,
        stagingURL: URL,
        destinationURL: URL,
        options: MediaAudioExtractOptions,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> MediaAudioExtractResult {
        let sourceAsset = AVURLAsset(url: sourceURL)
        let audioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw MediaAudioExtractError.noAudioTracksFound(sourceURL)
        }
        guard options.trackIndex >= 0, options.trackIndex < audioTracks.count else {
            throw MediaAudioExtractError.trackIndexOutOfRange(
                index: options.trackIndex,
                availableCount: audioTracks.count
            )
        }
        let selectedTrack = audioTracks[options.trackIndex]
        guard let descriptor = await buildDescriptor(for: selectedTrack, index: options.trackIndex) else {
            throw MediaAudioExtractError.extractionFailed(
                "Unable to inspect selected audio track format."
            )
        }
        guard descriptor.codec == .aac else {
            throw MediaAudioExtractError.unsupportedAudioCodec(
                "Track \(options.trackIndex + 1) uses '\(descriptor.codecFourCC)'; M4A passthrough requires AAC."
            )
        }

        let packetCount = try await runPassthroughM4ARemux(
            from: selectedTrack,
            in: sourceAsset,
            stagingURL: stagingURL,
            progressHandler: progressHandler
        )
        try await applySimulatedExtractDelayIfNeeded()
        let verified = try await verifyStagedM4AOutput(
            stagingURL: stagingURL,
            expectedChannels: descriptor.channels,
            expectedSampleRate: descriptor.sampleRate
        )
        return MediaAudioExtractResult(
            destinationURL: destinationURL,
            mode: .encapsulatedM4a,
            executionPath: .avFoundationM4A,
            codec: .aac,
            trackIndex: options.trackIndex,
            channels: verified.channels,
            sampleRate: verified.sampleRate,
            packetCount: packetCount,
            durationSeconds: verified.durationSeconds,
            outputBytes: verified.outputBytes
        )
    }

    private func runPassthroughM4ARemux(
        from selectedTrack: AVAssetTrack,
        in sourceAsset: AVAsset,
        stagingURL: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> UInt64 {
        let formatDescriptions = (try? await selectedTrack.load(.formatDescriptions)) ?? []
        let trackTimeRange = (try? await selectedTrack.load(.timeRange)) ?? .zero
        let reader = try AVAssetReader(asset: sourceAsset)
        let readerOutput = AVAssetReaderTrackOutput(track: selectedTrack, outputSettings: nil)
        readerOutput.alwaysCopiesSampleData = false

        let writer = try AVAssetWriter(outputURL: stagingURL, fileType: .m4a)
        writer.shouldOptimizeForNetworkUse = true
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: formatDescriptions.first
        )
        writerInput.expectsMediaDataInRealTime = false

        guard reader.canAdd(readerOutput), writer.canAdd(writerInput) else {
            let composition = try await buildSingleAudioTrackComposition(from: selectedTrack)
            try await runM4AExportSession(
                composition: composition,
                stagingURL: stagingURL,
                progressHandler: progressHandler
            )
            return 0
        }
        reader.add(readerOutput)
        writer.add(writerInput)
        guard reader.startReading(), writer.startWriting() else {
            let failureReason = reader.error?.localizedDescription
                ?? writer.error?.localizedDescription
                ?? "Failed to start M4A passthrough."
            throw MediaAudioExtractError.extractionFailed(failureReason)
        }
        let packetsCopied = try await pumpAudioSamples(
            reader: reader,
            readerOutput: readerOutput,
            writer: writer,
            writerInput: writerInput,
            trackTimeRange: trackTimeRange
        )
        writerInput.markAsFinished()
        try await finalizeM4APassthrough(reader: reader, writer: writer)
        progressHandler?(0.9)
        return packetsCopied
    }

    private func pumpAudioSamples(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput,
        trackTimeRange: CMTimeRange
    ) async throws -> UInt64 {
        var packetsCopied: UInt64 = 0
        var sessionStarted = false
        while reader.status == .reading {
            try cancelReaderWriterIfNeeded(reader: reader, writer: writer)
            while !writerInput.isReadyForMoreMediaData {
                try cancelReaderWriterIfNeeded(reader: reader, writer: writer)
                do {
                    try Self.validateM4AReadinessStates(
                        readerStatus: reader.status,
                        writerStatus: writer.status,
                        readerError: reader.error,
                        writerError: writer.error
                    )
                } catch {
                    reader.cancelReading()
                    writer.cancelWriting()
                    throw error
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                break
            }
            if !sessionStarted {
                let firstPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let sessionStart = Self.resolvedM4ASessionStartTime(
                    trackTimeRange: trackTimeRange,
                    firstSamplePTS: firstPTS
                )
                writer.startSession(atSourceTime: sessionStart)
                sessionStarted = true
            }
            packetsCopied += UInt64(max(1, CMSampleBufferGetNumSamples(sampleBuffer)))
            if !writerInput.append(sampleBuffer) {
                break
            }
        }
        if !sessionStarted {
            let fallbackStart = Self.resolvedM4ASessionStartTime(
                trackTimeRange: trackTimeRange,
                firstSamplePTS: nil
            )
            writer.startSession(atSourceTime: fallbackStart)
        }
        return packetsCopied
    }

    /// Resolves the `AVAssetWriter` session start time so tracks with a nonzero source timeline offset
    /// start at output time zero without inserting leading silence.
    public static func resolvedM4ASessionStartTime(
        trackTimeRange: CMTimeRange,
        firstSamplePTS: CMTime?
    ) -> CMTime {
        if let firstSamplePTS,
           firstSamplePTS.isValid,
           firstSamplePTS.isNumeric,
           CMTimeCompare(firstSamplePTS, .zero) >= 0 {
            return firstSamplePTS
        }
        if trackTimeRange.start.isValid,
           trackTimeRange.start.isNumeric,
           CMTimeCompare(trackTimeRange.start, .zero) >= 0 {
            return trackTimeRange.start
        }
        return .zero
    }

    /// Validates that neither `AVAssetReader` nor `AVAssetWriter` has entered a terminal failure or cancellation
    /// state while waiting for `writerInput.isReadyForMoreMediaData`.
    public static func validateM4AReadinessStates(
        readerStatus: AVAssetReader.Status,
        writerStatus: AVAssetWriter.Status,
        readerError: (any Error)?,
        writerError: (any Error)?
    ) throws {
        if readerStatus == .cancelled || writerStatus == .cancelled {
            throw MediaAudioExtractError.cancelled
        }
        if writerStatus == .failed {
            let reason = writerError?.localizedDescription
                ?? "Audio writer failed while waiting for readiness."
            throw MediaAudioExtractError.extractionFailed(reason)
        }
        if readerStatus == .failed {
            let reason = readerError?.localizedDescription
                ?? "Audio reader failed while waiting for writer readiness."
            throw MediaAudioExtractError.extractionFailed(reason)
        }
    }

    private func cancelReaderWriterIfNeeded(
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) throws {
        guard Task.isCancelled else {
            return
        }
        reader.cancelReading()
        writer.cancelWriting()
        throw MediaAudioExtractError.cancelled
    }

    private func finalizeM4APassthrough(
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws {
        if reader.status == .failed {
            writer.cancelWriting()
            let reason = reader.error?.localizedDescription ?? "Audio reader failed."
            throw MediaAudioExtractError.extractionFailed(reason)
        }
        await writer.finishWriting()
        if Task.isCancelled || writer.status == .cancelled {
            throw MediaAudioExtractError.cancelled
        }
        guard writer.status == .completed else {
            let reason = writer.error?.localizedDescription ?? "Audio writer failed."
            throw MediaAudioExtractError.extractionFailed(reason)
        }
    }

    private func buildSingleAudioTrackComposition(
        from sourceTrack: AVAssetTrack
    ) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaAudioExtractError.extractionFailed(
                "Unable to allocate mutable audio composition track."
            )
        }
        let timeRange = try await sourceTrack.load(.timeRange)
        guard timeRange.duration.isValid, CMTimeGetSeconds(timeRange.duration) > 0 else {
            throw MediaAudioExtractError.extractionFailed(
                "Selected audio track has zero or invalid duration."
            )
        }
        try compositionTrack.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
        return composition
    }

    private func runM4AExportSession(
        composition: AVMutableComposition,
        stagingURL: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) ?? AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw MediaAudioExtractError.extractionFailed("Unable to create M4A export session.")
        }
        session.outputURL = stagingURL
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = true

        try await withTaskCancellationHandler {
            session.exportAsynchronously {}
            while session.status == .waiting || session.status == .exporting {
                if Task.isCancelled {
                    session.cancelExport()
                    throw MediaAudioExtractError.cancelled
                }
                progressHandler?(Double(session.progress) * 0.9)
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            if Task.isCancelled || session.status == .cancelled {
                session.cancelExport()
                throw MediaAudioExtractError.cancelled
            }
            guard session.status == .completed else {
                let reason = session.error?.localizedDescription ?? "Export failed."
                throw MediaAudioExtractError.extractionFailed(reason)
            }
        } onCancel: {
            session.cancelExport()
        }
    }

    // MARK: - Verification & Atomic Commit

    internal func verifyStagedM4AOutput(
        stagingURL: URL,
        expectedChannels: Int,
        expectedSampleRate: Double
    ) async throws -> (outputBytes: UInt64, durationSeconds: Double, channels: Int, sampleRate: Double) {
        let offsets = try MediaContainerRemuxPipeline.readTopLevelBoxOffsets(at: stagingURL)
        guard offsets["ftyp"] == 0, offsets["moov"] != nil, offsets["mdat"] != nil else {
            throw MediaAudioExtractError.verificationFailed(
                "Staged M4A output is missing ftyp/moov/mdat boxes."
            )
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
        let outputBytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard outputBytes > 0 else {
            throw MediaAudioExtractError.verificationFailed("Staged M4A output file is empty.")
        }
        let stagedAsset = AVURLAsset(url: stagingURL)
        let outVideo = try await stagedAsset.loadTracks(withMediaType: .video)
        let outAudio = try await stagedAsset.loadTracks(withMediaType: .audio)
        guard outVideo.isEmpty,
              outAudio.count == 1,
              let outDescriptor = await buildDescriptor(for: outAudio[0], index: 0) else {
            throw MediaAudioExtractError.verificationFailed(
                "Staged M4A must contain exactly 1 audio track and 0 video tracks."
            )
        }
        let durationSec = CMTimeGetSeconds(try await stagedAsset.load(.duration))
        guard durationSec.isFinite, durationSec > 0 else {
            throw MediaAudioExtractError.verificationFailed(
                "Staged M4A has non-positive duration (\(durationSec)s)."
            )
        }
        let resolvedChannels = outDescriptor.channels > 0
            ? outDescriptor.channels
            : max(1, expectedChannels)
        let resolvedRate = outDescriptor.sampleRate > 0
            ? outDescriptor.sampleRate
            : expectedSampleRate
        return (outputBytes, durationSec, resolvedChannels, resolvedRate)
    }

    internal func verifyStagedElementaryOutput(
        stagingURL: URL,
        codec: MediaAudioExtractCodec
    ) throws -> UInt64 {
        let data = try Data(contentsOf: stagingURL)
        guard !data.isEmpty else {
            throw MediaAudioExtractError.verificationFailed("Staged elementary audio stream is empty.")
        }
        if codec == .aac && !Self.hasADTSSyncWord(data) {
            throw MediaAudioExtractError.verificationFailed(
                "Extracted AAC elementary stream is missing ADTS sync header."
            )
        }
        if codec == .flac && !(data.count >= 4 && String(data: data.prefix(4), encoding: .ascii) == "fLaC") {
            throw MediaAudioExtractError.verificationFailed(
                "Extracted FLAC elementary stream is missing 'fLaC' magic header."
            )
        }
        return UInt64(data.count)
    }

    internal func applySimulatedExtractDelayIfNeeded() async throws {
        let delay = simulatedExtractDelayNanoseconds
        guard delay > 0 else {
            return
        }
        var elapsed: UInt64 = 0
        while elapsed < delay {
            if Task.isCancelled {
                throw MediaAudioExtractError.cancelled
            }
            let chunk = min(10_000_000, delay - elapsed)
            try await Task.sleep(nanoseconds: chunk)
            elapsed += chunk
        }
        if Task.isCancelled {
            throw MediaAudioExtractError.cancelled
        }
    }

    private func commitStagedFile(
        from stagingURL: URL,
        to destinationURL: URL,
        sourceURL: URL
    ) throws {
        if Task.isCancelled {
            throw MediaAudioExtractError.cancelled
        }
        try Self.preserveSourceAttributes(from: sourceURL, to: stagingURL)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        }
        try Self.preserveSourceAttributes(from: sourceURL, to: destinationURL)
    }

    private static func preserveSourceAttributes(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
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
}
