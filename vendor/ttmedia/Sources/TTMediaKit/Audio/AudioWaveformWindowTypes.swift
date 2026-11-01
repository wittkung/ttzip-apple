// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Darwin
import os

/// Describes the sampling precision of an extracted audio waveform.
public enum AudioWaveformSamplingMode: String, Sendable, Equatable, Hashable {
    /// Every PCM frame across all buckets was inspected sequentially via SIMD `vDSP_maxmgv` and stream completeness was authoritatively verified.
    case exhaustiveBucketPeak
    /// Long-stream strided window sampling (`> 4_000_000` frames) or headerless elementary stream without total-length proof; represents a sampled envelope rather than verified exhaustive peaks.
    case windowedSampledEnvelope
}

/// Explicit precision and completeness verification state of an extracted waveform.
public enum AudioWaveformPrecisionStatus: String, Sendable, Equatable, Hashable {
    /// Full-track sequential scan with authoritative container/codec frame-completeness proof.
    case exhaustiveVerified
    /// Sparse windowed sampling or stream without authoritative container total-length/EOS proof.
    case sampledOrCompletenessUnverified
}

/// Complete waveform extraction result including normalized bucket amplitudes and precision metadata.
public struct AudioWaveformAnalysis: Sendable, Equatable {
    public let peaks: [Float]
    public let samplingMode: AudioWaveformSamplingMode
    public let isVerifiedDigitalSilence: Bool
    public let isCompletenessVerified: Bool
    public let completenessProof: AudioStreamCompletenessProof?
    public let totalFrames: Int64
    public let sampledFrames: Int64
    public let rawMaxPeak: Float

    /// Independent precision and completeness status for UI badges and diagnostic consumers.
    public var precisionStatus: AudioWaveformPrecisionStatus {
        (isCompletenessVerified && samplingMode == .exhaustiveBucketPeak)
            ? .exhaustiveVerified
            : .sampledOrCompletenessUnverified
    }

    public init(
        peaks: [Float],
        samplingMode: AudioWaveformSamplingMode,
        isVerifiedDigitalSilence: Bool,
        isCompletenessVerified: Bool = false,
        completenessProof: AudioStreamCompletenessProof? = nil,
        totalFrames: Int64,
        sampledFrames: Int64,
        rawMaxPeak: Float = 0.0
    ) {
        self.peaks = peaks
        self.samplingMode = samplingMode
        self.isVerifiedDigitalSilence = isVerifiedDigitalSilence
        self.isCompletenessVerified = isCompletenessVerified
        self.completenessProof = completenessProof
        self.totalFrames = totalFrames
        self.sampledFrames = sampledFrames
        self.rawMaxPeak = rawMaxPeak
    }
}

/// Thread-safe cooperative cancellation token propagated into off-actor synchronous CoreAudio decode loops.
public final class WaveformCancelToken: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public var isCancelled: Bool {
        state.withLock { $0 }
    }

    public func cancel() {
        state.withLock { $0 = true }
    }

    /// Cooperatively sleeps in <=2ms slices while checking cancellation.
    public func sleepCooperatively(nanos: UInt64) -> Bool {
        guard nanos > 0 else { return true }
        var slept: UInt64 = 0
        let stepSleep: UInt64 = min(nanos, 2_000_000)
        while slept < nanos {
            if isCancelled || Task.isCancelled { return false }
            usleep(UInt32(max(1, stepSleep / 1_000)))
            slept += stepSleep
        }
        return true
    }
}

/// Hard safety and resource budget constants for local time-window waveform extraction.
public enum AudioWaveformWindowLimits {
    /// Minimum allowed window duration in seconds (50 ms).
    public static let minWindowDuration: TimeInterval = 0.05
    /// Maximum allowed window duration in seconds (300 seconds / 5 minutes).
    public static let maxWindowDuration: TimeInterval = 300.0
    /// Default scrolling viewport time-window duration in seconds (6.0 seconds).
    public static let defaultWindowDuration: TimeInterval = 6.0

    /// Minimum allowed peak bucket count per window request.
    public static let minBucketCount: Int = 1
    /// Maximum allowed peak bucket count per window request.
    public static let maxBucketCount: Int = 4096
    /// Default peak bucket count for a 6.0s window (180 buckets = 30 Hz resolution).
    public static let defaultBucketCount: Int = 180

    /// Maximum number of local window tiles retained in the bounded LRU cache.
    public static let maxCachedTiles: Int = 64
    /// Maximum total memory footprint of cached local window tiles (512 KiB).
    public static let maxCachePayloadBytes: Int = 512 * 1024

    /// Digital silence amplitude floor (-80 dBFS), matching `AudioWaveformExtractor`.
    public static let silencePeakFloor: Float = 0.0001
    /// Minimum normalization reference floor (-26 dBFS) preventing quiet noise floor amplification.
    public static let normalizationReferenceFloor: Float = 0.05

    /// Codec warmup preroll frames sought before the target start frame for compressed streams.
    public static let compressedSeekPrerollFrames: Int64 = 4096
    /// Frame threshold below which compressed streams decode sequentially from frame 0 for zero packet-table drift (30s @ 48kHz).
    public static let sequentialAccurateSeekThresholdFrames: Int64 = 1_440_000
}

/// Physical file identity and content-edge digest version token.
/// Ensures cache lookup and in-flight decode validation never rely solely on file path or filename.
public struct AudioWaveformResourceVersion: Sendable, Hashable, Equatable {
    public let standardizedPath: String
    public let deviceID: Int32
    public let inode: UInt64
    public let fileSize: Int64
    public let modificationTimeSeconds: Int
    public let modificationTimeNanoseconds: Int
    public let changeTimeSeconds: Int
    public let modificationTimeNanosecondsAlias: Int
    public let contentEdgeDigest: UInt64
    public let rawSignature: String

    public var changeTimeNanoseconds: Int { modificationTimeNanosecondsAlias }

    /// Captures the live filesystem identity and 16-window content digest for `url`.
    /// Reads at most 64 KiB via `pread`, avoiding full-file memory loads on long audio tracks.
    public static func capture(for url: URL) -> AudioWaveformResourceVersion? {
        let standardizedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        var st = stat()
        guard stat(standardizedPath, &st) == 0, st.st_size > 0,
              let sig = AudioContainerCompletenessValidator.computeResourceSignature(forPath: standardizedPath) else {
            return nil
        }
        let digestHex = sig.split(separator: "_").last.flatMap { UInt64($0) } ?? 0
        return AudioWaveformResourceVersion(
            standardizedPath: standardizedPath,
            deviceID: st.st_dev,
            inode: st.st_ino,
            fileSize: Int64(st.st_size),
            modificationTimeSeconds: st.st_mtimespec.tv_sec,
            modificationTimeNanoseconds: st.st_mtimespec.tv_nsec,
            changeTimeSeconds: st.st_ctimespec.tv_sec,
            modificationTimeNanosecondsAlias: st.st_ctimespec.tv_nsec,
            contentEdgeDigest: digestHex,
            rawSignature: sig
        )
    }
}

/// Multi-channel peak aggregation rule applied when reducing PCM frames into window buckets.
public enum AudioWaveformChannelAggregation: String, Sendable, Equatable, Hashable {
    /// Maximum absolute sample magnitude across all decoded channels (`max_c vDSP_maxmgv(channel_c)`).
    case maxAbsoluteAcrossChannels
}

/// Provenance of the stable amplitude normalization denominator used for `AudioWaveformWindowTile.peaks`.
public enum AudioWaveformReferencePeakSource: String, Sendable, Equatable, Hashable {
    /// Explicit reference peak provided by the caller in `AudioWaveformWindowRequest`.
    case callerProvided
    /// Whole-track maximum peak previously extracted and cached by `AudioWaveformExtractor`.
    case wholeTrackAnalysis
    /// Canonical `1.0` (`0 dBFS` linear full-scale) reference latched for tracks without prior whole-track analysis.
    case canonicalFullScale0dBFS
}

/// Describes how much of the requested time window was covered by actual audio frames in the file.
public enum AudioWaveformWindowCoverageStatus: String, Sendable, Equatable, Hashable {
    /// The full `[startTime, startTime + windowDuration]` interval lies within the audio track and was completely decoded.
    case completeWindow
    /// The request extended past track EOF; only the real audio in `[coveredStartTime, coveredEndTime]` was returned without padding.
    case partialTailAtEOF
    /// The requested `startTime` is at or beyond track EOF; no audio frames exist in this range (`peaks.isEmpty == true`).
    case emptyAtOrPastEOF
}

/// Typed errors thrown by `AudioWaveformWindowExtractor` and `MPVAudioEngine` window extraction APIs.
public enum AudioWaveformWindowError: Error, Sendable, Equatable {
    case cancelled
    case invalidStartTime(TimeInterval)
    case invalidWindowDuration(TimeInterval, minAllowed: TimeInterval, maxAllowed: TimeInterval)
    case bucketCountOutOfBounds(requested: Int, minAllowed: Int, maxAllowed: Int)
    case fileNotFound(path: String)
    case emptyAudioFile(path: String)
    case unsupportedFormat(extensionName: String, reason: String)
    case corruptOrTruncatedStream(path: String, diagnostic: String)
    case resourceVersionChanged(expectedSignature: String, actualSignature: String)
    case staleSessionOrGeneration(
        requestedGeneration: UInt64?,
        activeGeneration: UInt64?,
        requestedSessionID: String?,
        activeSessionID: String?
    )
}

/// Formal request for a local high-resolution time-window waveform tile.
public struct AudioWaveformWindowRequest: Sendable, Hashable {
    public let url: URL
    public let expectedResourceVersion: AudioWaveformResourceVersion?
    public let startTime: TimeInterval
    public let windowDuration: TimeInterval
    public let targetBucketCount: Int
    public let ownerSessionID: String?
    public let loadGeneration: UInt64?
    public let referencePeak: Float?

    public var resourceURL: URL { url }
    public var windowStart: TimeInterval { startTime }
    public var stableReferencePeak: Float {
        max(referencePeak ?? 1.0, AudioWaveformWindowLimits.normalizationReferenceFloor)
    }

    public init(
        url: URL,
        startTime: TimeInterval,
        windowDuration: TimeInterval = AudioWaveformWindowLimits.defaultWindowDuration,
        targetBucketCount: Int = AudioWaveformWindowLimits.defaultBucketCount,
        expectedResourceVersion: AudioWaveformResourceVersion? = nil,
        ownerSessionID: String? = nil,
        loadGeneration: UInt64? = nil,
        referencePeak: Float? = nil
    ) {
        self.url = url
        self.startTime = startTime
        self.windowDuration = windowDuration
        self.targetBucketCount = targetBucketCount
        self.expectedResourceVersion = expectedResourceVersion
        self.ownerSessionID = ownerSessionID
        self.loadGeneration = loadGeneration
        self.referencePeak = referencePeak
    }

    public init(
        resourceURL: URL,
        loadGeneration: UInt64?,
        ownerSessionID: String? = nil,
        windowStart: TimeInterval,
        windowDuration: TimeInterval = AudioWaveformWindowLimits.defaultWindowDuration,
        targetBucketCount: Int = AudioWaveformWindowLimits.defaultBucketCount,
        stableReferencePeak: Float? = nil,
        expectedResourceVersion: AudioWaveformResourceVersion? = nil
    ) {
        self.init(
            url: resourceURL,
            startTime: windowStart,
            windowDuration: windowDuration,
            targetBucketCount: targetBucketCount,
            expectedResourceVersion: expectedResourceVersion,
            ownerSessionID: ownerSessionID,
            loadGeneration: loadGeneration,
            referencePeak: stableReferencePeak
        )
    }

    public func validateParameters() throws {
        guard startTime.isFinite, startTime >= 0.0 else {
            throw AudioWaveformWindowError.invalidStartTime(startTime)
        }
        guard windowDuration.isFinite,
              windowDuration >= AudioWaveformWindowLimits.minWindowDuration,
              windowDuration <= AudioWaveformWindowLimits.maxWindowDuration else {
            throw AudioWaveformWindowError.invalidWindowDuration(
                windowDuration,
                minAllowed: AudioWaveformWindowLimits.minWindowDuration,
                maxAllowed: AudioWaveformWindowLimits.maxWindowDuration
            )
        }
        guard targetBucketCount >= AudioWaveformWindowLimits.minBucketCount,
              targetBucketCount <= AudioWaveformWindowLimits.maxBucketCount else {
            throw AudioWaveformWindowError.bucketCountOutOfBounds(
                requested: targetBucketCount,
                minAllowed: AudioWaveformWindowLimits.minBucketCount,
                maxAllowed: AudioWaveformWindowLimits.maxBucketCount
            )
        }
        if let ref = referencePeak, (!ref.isFinite || ref <= 0.0) {
            throw AudioWaveformWindowError.invalidWindowDuration(
                Double(ref),
                minAllowed: Double(AudioWaveformWindowLimits.normalizationReferenceFloor),
                maxAllowed: 1.0
            )
        }
    }
}

/// Extracted local high-resolution waveform tile with verified time-axis mapping and coverage state.
public struct AudioWaveformWindowTile: Sendable, Equatable {
    public var url: URL
    public let resourceVersion: AudioWaveformResourceVersion
    public var ownerSessionID: String?
    public var loadGeneration: UInt64?

    public var requestedStartTime: TimeInterval
    public var requestedWindowDuration: TimeInterval
    public var requestedBucketCount: Int

    public let coveredStartTime: TimeInterval
    public let coveredEndTime: TimeInterval
    public let trackDuration: TimeInterval
    public let bucketDuration: TimeInterval

    public let startFrame: Int64
    public let endFrame: Int64
    public let totalTrackFrames: Int64
    public let sampleRate: Double
    public let channelCount: Int
    public let didApplySeekOffsetAdjustment: Bool

    public let rawAbsolutePeaks: [Float]
    public let peaks: [Float]
    public let rawMaxPeak: Float
    public let referencePeak: Float
    public let referencePeakSource: AudioWaveformReferencePeakSource
    public let channelAggregation: AudioWaveformChannelAggregation

    public let coverageStatus: AudioWaveformWindowCoverageStatus
    public let samplingMode: AudioWaveformSamplingMode
    public let isLocalWindowComplete: Bool
    public let isLocalWindowSilent: Bool
    public let isWholeTrackCompletenessVerified: Bool
    public let isWholeTrackVerifiedDigitalSilence: Bool
    public var servedFromCache: Bool

    public var resourceURL: URL { url }
    public var actualStart: TimeInterval { coveredStartTime }
    public var startTime: TimeInterval { coveredStartTime }
    public var coveredDuration: TimeInterval { max(0.0, coveredEndTime - coveredStartTime) }
    public var actualDuration: TimeInterval { coveredDuration }
    public var windowDuration: TimeInterval { coveredDuration }
    public var referenceGlobalPeak: Float { referencePeak }
    public var isWindowComplete: Bool { isLocalWindowComplete }

    public init(
        url: URL,
        resourceVersion: AudioWaveformResourceVersion,
        ownerSessionID: String?,
        loadGeneration: UInt64?,
        requestedStartTime: TimeInterval,
        requestedWindowDuration: TimeInterval,
        requestedBucketCount: Int,
        coveredStartTime: TimeInterval,
        coveredEndTime: TimeInterval,
        trackDuration: TimeInterval,
        bucketDuration: TimeInterval,
        startFrame: Int64,
        endFrame: Int64,
        totalTrackFrames: Int64,
        sampleRate: Double,
        channelCount: Int,
        didApplySeekOffsetAdjustment: Bool,
        rawAbsolutePeaks: [Float],
        peaks: [Float],
        rawMaxPeak: Float,
        referencePeak: Float,
        referencePeakSource: AudioWaveformReferencePeakSource,
        channelAggregation: AudioWaveformChannelAggregation = .maxAbsoluteAcrossChannels,
        coverageStatus: AudioWaveformWindowCoverageStatus,
        samplingMode: AudioWaveformSamplingMode = .exhaustiveBucketPeak,
        isLocalWindowComplete: Bool,
        isLocalWindowSilent: Bool,
        isWholeTrackCompletenessVerified: Bool = false,
        isWholeTrackVerifiedDigitalSilence: Bool = false,
        servedFromCache: Bool = false
    ) {
        self.url = url
        self.resourceVersion = resourceVersion
        self.ownerSessionID = ownerSessionID
        self.loadGeneration = loadGeneration
        self.requestedStartTime = requestedStartTime
        self.requestedWindowDuration = requestedWindowDuration
        self.requestedBucketCount = requestedBucketCount
        self.coveredStartTime = coveredStartTime
        self.coveredEndTime = coveredEndTime
        self.trackDuration = trackDuration
        self.bucketDuration = bucketDuration
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.totalTrackFrames = totalTrackFrames
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.didApplySeekOffsetAdjustment = didApplySeekOffsetAdjustment
        self.rawAbsolutePeaks = rawAbsolutePeaks
        self.peaks = peaks
        self.rawMaxPeak = rawMaxPeak
        self.referencePeak = referencePeak
        self.referencePeakSource = referencePeakSource
        self.channelAggregation = channelAggregation
        self.coverageStatus = coverageStatus
        self.samplingMode = samplingMode
        self.isLocalWindowComplete = isLocalWindowComplete
        self.isLocalWindowSilent = isLocalWindowSilent
        self.isWholeTrackCompletenessVerified = isWholeTrackCompletenessVerified
        self.isWholeTrackVerifiedDigitalSilence = isWholeTrackVerifiedDigitalSilence
        self.servedFromCache = servedFromCache
    }

    /// Returns a copy bound to `request`'s caller metadata (`ownerSessionID`, `loadGeneration`) and `servedFromCache` flag.
    public func recontextualized(
        for request: AudioWaveformWindowRequest,
        servedFromCache: Bool
    ) -> AudioWaveformWindowTile {
        var copy = self
        copy.url = request.url
        copy.ownerSessionID = request.ownerSessionID
        copy.loadGeneration = request.loadGeneration
        copy.requestedStartTime = request.startTime
        copy.requestedWindowDuration = request.windowDuration
        copy.requestedBucketCount = request.targetBucketCount
        copy.servedFromCache = servedFromCache
        return copy
    }

    public func bucketTimeRange(at index: Int) -> ClosedRange<TimeInterval>? {
        guard index >= 0, index < peaks.count, bucketDuration > 0 else { return nil }
        let start = coveredStartTime + Double(index) * bucketDuration
        let end = min(coveredEndTime, coveredStartTime + Double(index + 1) * bucketDuration)
        guard end >= start else { return nil }
        return start...end
    }

    public func bucketCenterTime(at index: Int) -> TimeInterval? {
        guard let range = bucketTimeRange(at: index) else { return nil }
        return (range.lowerBound + range.upperBound) * 0.5
    }

    public func bucketIndex(forTime time: TimeInterval) -> Int? {
        guard time.isFinite, !peaks.isEmpty, bucketDuration > 0,
              time >= coveredStartTime, time < coveredEndTime else {
            return nil
        }
        let rawIndex = Int(((time - coveredStartTime) / bucketDuration).rounded(.down))
        guard rawIndex >= 0, rawIndex < peaks.count else { return nil }
        return rawIndex
    }

    public func normalizedPeak(atTime time: TimeInterval) -> Float? {
        guard let idx = bucketIndex(forTime: time) else { return nil }
        return peaks[idx]
    }

    public func rawAbsolutePeak(atTime time: TimeInterval) -> Float? {
        guard let idx = bucketIndex(forTime: time) else { return nil }
        return rawAbsolutePeaks[idx]
    }

    public var estimatedMemoryFootprintBytes: Int {
        (peaks.count * MemoryLayout<Float>.size) +
        (rawAbsolutePeaks.count * MemoryLayout<Float>.size) +
        192
    }

    internal static func makeDecodedTile(
        request: AudioWaveformWindowRequest,
        resourceVersion: AudioWaveformResourceVersion,
        refContext: (peak: Float, source: AudioWaveformReferencePeakSource),
        wholeTrackAnalysis: AudioWaveformAnalysis?,
        actualStartFrame: Int64,
        actualEndFrame: Int64,
        totalValidFrames: Int64,
        sampleRate: Double,
        channelCount: Int,
        didApplySeekOffsetAdjustment: Bool,
        rawBuckets: [Float],
        coverageStatus: AudioWaveformWindowCoverageStatus
    ) -> AudioWaveformWindowTile {
        let sanitizedRaw = rawBuckets.map { $0.isFinite && $0 >= 0.0 ? $0 : Float(0.0) }
        let rawMax = sanitizedRaw.max() ?? 0.0
        let isLocalSilent = !sanitizedRaw.isEmpty && (rawMax <= AudioWaveformWindowLimits.silencePeakFloor)
        let denominator = max(refContext.peak, AudioWaveformWindowLimits.normalizationReferenceFloor)
        let normalized: [Float] = isLocalSilent
            ? [Float](repeating: 0.0, count: sanitizedRaw.count)
            : sanitizedRaw.map { min(1.0, max(0.0, $0 / denominator)) }

        return AudioWaveformWindowTile(
            url: request.url,
            resourceVersion: resourceVersion,
            ownerSessionID: request.ownerSessionID,
            loadGeneration: request.loadGeneration,
            requestedStartTime: request.startTime,
            requestedWindowDuration: request.windowDuration,
            requestedBucketCount: request.targetBucketCount,
            coveredStartTime: Double(actualStartFrame) / sampleRate,
            coveredEndTime: Double(actualEndFrame) / sampleRate,
            trackDuration: Double(totalValidFrames) / sampleRate,
            bucketDuration: request.windowDuration / Double(request.targetBucketCount),
            startFrame: actualStartFrame,
            endFrame: actualEndFrame,
            totalTrackFrames: totalValidFrames,
            sampleRate: sampleRate,
            channelCount: channelCount,
            didApplySeekOffsetAdjustment: didApplySeekOffsetAdjustment,
            rawAbsolutePeaks: sanitizedRaw,
            peaks: normalized,
            rawMaxPeak: rawMax,
            referencePeak: denominator,
            referencePeakSource: refContext.source,
            channelAggregation: .maxAbsoluteAcrossChannels,
            coverageStatus: coverageStatus,
            samplingMode: .exhaustiveBucketPeak,
            isLocalWindowComplete: true,
            isLocalWindowSilent: isLocalSilent,
            isWholeTrackCompletenessVerified: wholeTrackAnalysis?.isCompletenessVerified ?? false,
            isWholeTrackVerifiedDigitalSilence: wholeTrackAnalysis?.isVerifiedDigitalSilence ?? false,
            servedFromCache: false
        )
    }
}

internal struct WindowBucketGrid: Sendable {
    let expectedFramesInWindow: Int64
    let coveredBucketCount: Int
    let isPartialTail: Bool
    let framesPerBucket: Double
    let totalSpan: Double

    func bucketRange(localStartFrame: Int64, localEndFrame: Int64) -> (Int, Int) {
        if isPartialTail, framesPerBucket > 0 {
            let first = min(coveredBucketCount - 1, max(0, Int((Double(localStartFrame) / framesPerBucket).rounded(.down))))
            let last = min(coveredBucketCount - 1, max(first, Int((Double(localEndFrame - 1) / framesPerBucket).rounded(.down))))
            return (first, last)
        }
        let first = min(coveredBucketCount - 1, max(0, Int((Double(localStartFrame) / totalSpan) * Double(coveredBucketCount))))
        let last = min(coveredBucketCount - 1, max(first, Int((Double(localEndFrame - 1) / totalSpan) * Double(coveredBucketCount))))
        return (first, last)
    }

    func frameBounds(forBucket bucket: Int) -> (Int64, Int64) {
        if isPartialTail, framesPerBucket > 0 {
            let bStart = Int64((Double(bucket) * framesPerBucket).rounded(.down))
            let bEnd = (bucket == coveredBucketCount - 1)
                ? expectedFramesInWindow
                : max(bStart + 1, Int64((Double(bucket + 1) * framesPerBucket).rounded(.down)))
            return (bStart, bEnd)
        }
        let bStart = Int64((Double(bucket) / Double(coveredBucketCount)) * totalSpan)
        let bEnd = max(bStart + 1, Int64((Double(bucket + 1) / Double(coveredBucketCount)) * totalSpan))
        return (bStart, bEnd)
    }
}

/// Telemetry and resource budget metrics for `AudioWaveformWindowExtractor`.
public struct AudioWaveformWindowExtractorMetrics: Sendable, Equatable {
    public let cacheHitCount: Int
    public let cacheMissCount: Int
    public let coalescedJoinCount: Int
    public let evictionCount: Int
    public let cachedTileCount: Int
    public let cachedPayloadBytes: Int
    public let inFlightOperationCount: Int
    public let peakConcurrentDecodesObserved: Int
    public let lastColdExtractDurationMs: Double
    public let lastWarmCacheHitDurationMs: Double
    public let lastCancelLatencyMs: Double
}

/// Protocol abstraction for local high-resolution time-window waveform extraction.
public protocol AudioWaveformWindowExtracting: Sendable {
    func extractWindow(_ request: AudioWaveformWindowRequest) async throws -> AudioWaveformWindowTile
}

internal struct WindowTileCacheKey: Hashable, Sendable {
    let standardizedPath: String
    let resourceSignature: String
    let quantizedStartMicros: Int64
    let quantizedDurationMicros: Int64
    let targetBucketCount: Int
    let quantizedReferencePeak: Int32
}

public typealias AudioWaveformWindowResponse = AudioWaveformWindowTile
public typealias AudioWaveformTimeWindowRequest = AudioWaveformWindowRequest
public typealias AudioWaveformTimeWindowTile = AudioWaveformWindowTile

// MARK: - Decode vs Playback Capability Queries & Engine Window Entry Points

extension MPVAudioFormatSupport {
    /// Indicates whether CoreAudio (`ExtAudioFile`) can extract authentic PCM waveform peaks for this format.
    public var isWaveformDecodable: Bool {
        switch self {
        case .verifiedNativeCoreAudio(let spec):
            return spec.waveformExtracted
        case .candidateNativeCoreAudio:
            return true
        case .requiresSynthesizer, .unsupportedCodec, .unknown:
            return false
        }
    }

    /// True when the format supports authentic waveform extraction (`isWaveformDecodable == true`)
    /// but native `AVAudioPlayer` playback is unsupported (`isPlayableNatively == false`, e.g. `.ogg`/`.oga`/`.opus`).
    public var isWaveformOnlyWithoutPlayback: Bool {
        isWaveformDecodable && !isPlayableNatively
    }
}

extension MPVAudioEngine {
    public var isCurrentFormatWaveformOnly: Bool {
        guard let ext = currentURL?.pathExtension.lowercased(), !ext.isEmpty else { return false }
        return Self.formatSupport(forExtension: ext).isWaveformOnlyWithoutPlayback
    }

    public var canExtractWaveformForCurrentResource: Bool {
        guard let ext = currentURL?.pathExtension.lowercased(), !ext.isEmpty else { return false }
        return Self.formatSupport(forExtension: ext).isWaveformDecodable
    }

    @discardableResult
    public func extractWaveformWindow(
        startTime: TimeInterval,
        windowDuration: TimeInterval = AudioWaveformWindowLimits.defaultWindowDuration,
        targetBucketCount: Int = AudioWaveformWindowLimits.defaultBucketCount
    ) async throws -> AudioWaveformWindowTile {
        guard let url = currentURL else {
            throw AudioWaveformWindowError.fileNotFound(path: "")
        }
        let req = makeEngineWindowRequest(
            url: url,
            startTime: startTime,
            windowDuration: windowDuration,
            targetBucketCount: targetBucketCount
        )
        return try await extractWaveformWindow(req)
    }

    @discardableResult
    public func extractWaveformWindow(
        _ request: AudioWaveformWindowRequest
    ) async throws -> AudioWaveformWindowTile {
        let expectedGen = request.loadGeneration ?? activeLoadGeneration
        let expectedSession = request.ownerSessionID ?? activeOwnerSessionID
        guard isMatchingActiveSession(url: request.url, generation: expectedGen, sessionID: expectedSession) else {
            throw staleSessionError(expectedGen: expectedGen, expectedSession: expectedSession)
        }
        isExtractingWaveformWindow = true
        lastWaveformWindowError = nil
        do {
            let tile = try await AudioWaveformWindowExtractor.shared.extractWindow(request)
            guard isMatchingActiveSession(url: request.url, generation: expectedGen, sessionID: expectedSession) else {
                isExtractingWaveformWindow = false
                throw staleSessionError(expectedGen: expectedGen, expectedSession: expectedSession)
            }
            activeWaveformWindowTile = tile
            isExtractingWaveformWindow = false
            return tile
        } catch let error as AudioWaveformWindowError {
            if isMatchingActiveSession(url: request.url, generation: expectedGen, sessionID: expectedSession) {
                isExtractingWaveformWindow = false
                if error != .cancelled { lastWaveformWindowError = error }
            }
            throw error
        } catch {
            isExtractingWaveformWindow = false
            throw AudioWaveformWindowError.cancelled
        }
    }

    public func requestScrollingWaveformWindow(
        aroundTime playheadTime: TimeInterval,
        windowDuration: TimeInterval = AudioWaveformWindowLimits.defaultWindowDuration,
        targetBucketCount: Int = AudioWaveformWindowLimits.defaultBucketCount,
        prefetchNextTile: Bool = true
    ) {
        guard let url = currentURL, windowDuration > 0, playheadTime.isFinite else { return }
        let stepSize = max(AudioWaveformWindowLimits.minWindowDuration, windowDuration * 0.5)
        let stepIndex = max(0, Int(floor(max(0.0, playheadTime - windowDuration * 0.5) / stepSize)))
        if lastQuantizedWindowStepIndex == stepIndex,
           (activeWaveformWindowTile != nil || isExtractingWaveformWindow) {
            return
        }
        lastQuantizedWindowStepIndex = stepIndex
        let quantizedStart = Double(stepIndex) * stepSize
        let primaryReq = makeEngineWindowRequest(
            url: url,
            startTime: quantizedStart,
            windowDuration: windowDuration,
            targetBucketCount: targetBucketCount
        )
        let nextReq = makeEngineWindowRequest(
            url: url,
            startTime: quantizedStart + windowDuration,
            windowDuration: windowDuration,
            targetBucketCount: targetBucketCount
        )
        scheduleQuantizedWindowTask(primaryReq: primaryReq, nextReq: nextReq, prefetchNextTile: prefetchNextTile)
    }

    private func makeEngineWindowRequest(
        url: URL,
        startTime: TimeInterval,
        windowDuration: TimeInterval,
        targetBucketCount: Int
    ) -> AudioWaveformWindowRequest {
        AudioWaveformWindowRequest(
            url: url,
            startTime: startTime,
            windowDuration: windowDuration,
            targetBucketCount: targetBucketCount,
            expectedResourceVersion: activeResourceVersion ?? AudioWaveformResourceVersion.capture(for: url),
            ownerSessionID: activeOwnerSessionID,
            loadGeneration: activeLoadGeneration,
            referencePeak: waveformSamples.isEmpty ? nil : waveformReferencePeak
        )
    }

    private func scheduleQuantizedWindowTask(
        primaryReq: AudioWaveformWindowRequest,
        nextReq: AudioWaveformWindowRequest,
        prefetchNextTile: Bool
    ) {
        let capturedGen = activeLoadGeneration
        let capturedSession = activeOwnerSessionID
        activeWindowTask?.cancel()
        activeWindowTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.extractWaveformWindow(primaryReq)
            guard prefetchNextTile, !Task.isCancelled,
                  self.isMatchingActiveSession(url: primaryReq.url, generation: capturedGen, sessionID: capturedSession),
                  (self.duration <= 0 || nextReq.startTime < self.duration) else {
                return
            }
            self.windowPrefetchTask?.cancel()
            self.windowPrefetchTask = Task {
                _ = try? await AudioWaveformWindowExtractor.shared.extractWindow(nextReq)
            }
        }
    }

    public func waitForWaveformWindow() async {
        await activeWindowTask?.value
    }

    public func cancelWaveformWindowRequests() {
        let url = currentURL
        let session = activeOwnerSessionID
        activeWindowTask?.cancel()
        activeWindowTask = nil
        windowPrefetchTask?.cancel()
        windowPrefetchTask = nil
        isExtractingWaveformWindow = false
        lastQuantizedWindowStepIndex = nil
        if let session {
            Task { await AudioWaveformWindowExtractor.shared.cancelRequests(forOwnerSessionID: session) }
        } else if let url {
            Task { await AudioWaveformWindowExtractor.shared.cancelRequests(forURL: url) }
        }
    }

    private func staleSessionError(expectedGen: UInt64, expectedSession: String?) -> AudioWaveformWindowError {
        .staleSessionOrGeneration(
            requestedGeneration: expectedGen,
            activeGeneration: activeLoadGeneration,
            requestedSessionID: expectedSession,
            activeSessionID: activeOwnerSessionID
        )
    }

    private func isMatchingActiveSession(url: URL, generation: UInt64, sessionID: String?) -> Bool {
        guard activeLoadGeneration == generation,
              let current = currentURL,
              current.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() else {
            return false
        }
        if let activeOwner = activeOwnerSessionID, let sessionID {
            return activeOwner == sessionID
        }
        return true
    }
}
