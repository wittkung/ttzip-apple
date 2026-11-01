// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreGraphics
import Foundation
import Observation

/// Primary timeline presentation mode for the audio inspector waveform viewport.
public enum AudioTimelineViewportMode: String, Sendable, Equatable {
    /// Default Voice-Memos style mode: playhead is fixed at horizontal center and dense vertical ticks scroll right-to-left.
    case scrollingTimeWindow
    /// Whole-track overview mode: `[0, duration]` spans the full width and the playhead moves left-to-right.
    case wholeTrackOverview
}

/// Protocol for local high-resolution time-window waveform extraction (`AudioWaveformWindowExtractor` or test doubles).
/// When nil on long audio (`> 133.3s`), A2 refuses to stretch the 1600 whole-track peaks
/// and transparently falls back to honest whole-track overview with a pending badge.
public protocol AudioWaveformWindowedTileProviding: Sendable {
    func extractWindowTile(_ request: AudioWaveformWindowRequest) async -> AudioWaveformWindowResponse?
}

extension AudioWaveformWindowExtractor: AudioWaveformWindowedTileProviding {
    public func extractWindowTile(_ request: AudioWaveformWindowRequest) async -> AudioWaveformWindowResponse? {
        await extractWindowedTile(request)
    }
}

extension AudioWaveformWindowTile {
    /// Convenience initializer for UI viewport tests and mock tile providers.
    public init(
        resourceURL: URL,
        loadGeneration: UInt64 = 1,
        actualStart: TimeInterval,
        actualDuration: TimeInterval,
        peaks: [Float],
        trackDuration: TimeInterval? = nil,
        samplingMode: AudioWaveformSamplingMode = .exhaustiveBucketPeak,
        isWindowComplete: Bool = true,
        isLocalWindowSilent: Bool? = nil
    ) {
        let safeStart = max(0.0, actualStart)
        let safeDuration = max(0.001, actualDuration)
        let safeEnd = safeStart + safeDuration
        let resolvedTrackDuration = max(safeEnd, trackDuration ?? safeEnd)
        let bucketCount = max(1, peaks.count)
        let bucketDur = safeDuration / Double(bucketCount)
        let sampleRate = 48_000.0
        let startFrame = Int64((safeStart * sampleRate).rounded())
        let endFrame = Int64((safeEnd * sampleRate).rounded())
        let totalFrames = Int64((resolvedTrackDuration * sampleRate).rounded())
        let maxPeak = peaks.max() ?? 0.0
        let computedSilent = isLocalWindowSilent ?? peaks.allSatisfy { abs($0) <= AudioWaveformWindowLimits.silencePeakFloor }

        let syntheticVersion = AudioWaveformResourceVersion(
            standardizedPath: resourceURL.standardizedFileURL.path,
            deviceID: 0,
            inode: 0,
            fileSize: 0,
            modificationTimeSeconds: 0,
            modificationTimeNanoseconds: 0,
            changeTimeSeconds: 0,
            modificationTimeNanosecondsAlias: 0,
            contentEdgeDigest: 0,
            rawSignature: "synthetic_test_version"
        )

        self.init(
            url: resourceURL,
            resourceVersion: syntheticVersion,
            ownerSessionID: nil,
            loadGeneration: loadGeneration,
            requestedStartTime: safeStart,
            requestedWindowDuration: safeDuration,
            requestedBucketCount: bucketCount,
            coveredStartTime: safeStart,
            coveredEndTime: safeEnd,
            trackDuration: resolvedTrackDuration,
            bucketDuration: bucketDur,
            startFrame: startFrame,
            endFrame: endFrame,
            totalTrackFrames: totalFrames,
            sampleRate: sampleRate,
            channelCount: 1,
            didApplySeekOffsetAdjustment: false,
            rawAbsolutePeaks: peaks,
            peaks: peaks,
            rawMaxPeak: maxPeak,
            referencePeak: 1.0,
            referencePeakSource: .callerProvided,
            channelAggregation: .maxAbsoluteAcrossChannels,
            coverageStatus: .completeWindow,
            samplingMode: samplingMode,
            isLocalWindowComplete: isWindowComplete,
            isLocalWindowSilent: computedSilent,
            isWholeTrackCompletenessVerified: false,
            isWholeTrackVerifiedDigitalSilence: false,
            servedFromCache: false
        )
    }
}

/// Single positioned vertical tick inside the fixed-playhead scrolling waveform viewport.
public struct AudioScrollingWaveformTick: Sendable, Equatable {
    public let slotIndex: Int
    public let trackTime: Double
    public let xPosition: CGFloat
    public let amplitude: Float
    public let isPlayed: Bool

    public init(
        slotIndex: Int,
        trackTime: Double,
        xPosition: CGFloat,
        amplitude: Float,
        isPlayed: Bool
    ) {
        self.slotIndex = slotIndex
        self.trackTime = trackTime
        self.xPosition = xPosition
        self.amplitude = amplitude
        self.isPlayed = isPlayed
    }
}

/// Resolution source for the scrolling time-window viewport.
public enum AudioScrollingWindowResolutionState: Sendable, Equatable {
    /// Local ticks resolved from high-resolution `AudioWaveformWindowedTileProviding` tiles.
    case highResolutionTiles(ticks: [AudioScrollingWaveformTick])
    /// Local ticks resolved directly from whole-track peaks because track is short enough (`>= 12 buckets/sec`).
    case denseWholeTrackPeaks(ticks: [AudioScrollingWaveformTick])
    /// Whole-track peaks are too sparse (`< 12 buckets/sec`, e.g. 30-minute audio) and tile provider is not connected.
    case awaitingHighResTileProvider
    /// Requested high-resolution tile is currently loading.
    case loadingWindowTile(partialTicks: [AudioScrollingWaveformTick])
}

/// Bounded, generation-isolated tile cache preventing duplicate window requests on playback refresh ticks.
@MainActor
@Observable
public final class AudioWindowedWaveformTileCache {
    public struct TileKey: Hashable, Sendable {
        public let resourcePath: String
        public let loadGeneration: UInt64
        public let tileIndex: Int

        public init(resourceURL: URL, loadGeneration: UInt64, tileIndex: Int) {
            self.resourcePath = resourceURL.standardizedFileURL.path
            self.loadGeneration = loadGeneration
            self.tileIndex = tileIndex
        }
    }

    nonisolated public static let defaultTileDuration: TimeInterval = 6.0
    nonisolated public static let defaultBucketsPerTile: Int = 180
    nonisolated public static let maxCachedTiles: Int = 32

    public private(set) var cachedTiles: [TileKey: AudioWaveformWindowResponse] = [:]
    public private(set) var inFlightKeys: Set<TileKey> = []
    public private(set) var requestCountByKey: [TileKey: Int] = [:]
    public private(set) var totalRequestCount: Int = 0
    public private(set) var cancelledTaskCount: Int = 0
    public private(set) var activeResourcePath: String?
    public private(set) var activeGeneration: UInt64 = 0

    private var inFlightTasks: [TileKey: Task<Void, Never>] = [:]

    public init() {}

    /// Cancels all in-flight window requests and clears cached tiles when switching files or closing the view.
    public func invalidateAll() {
        for (_, task) in inFlightTasks {
            task.cancel()
            cancelledTaskCount += 1
        }
        inFlightTasks.removeAll()
        inFlightKeys.removeAll()
        cachedTiles.removeAll()
    }

    /// Synchronizes active resource identity and generation, purging any stale state if either changed.
    public func syncSession(resourceURL: URL, loadGeneration: UInt64) {
        let normalizedPath = resourceURL.standardizedFileURL.path
        if activeResourcePath != normalizedPath || activeGeneration != loadGeneration {
            invalidateAll()
            activeResourcePath = normalizedPath
            activeGeneration = loadGeneration
        }
    }

    /// Ensures the tiles covering `[currentTime - windowDuration/2, currentTime + windowDuration/2]` are cached or in-flight.
    /// Never re-requests a tile that is already cached or currently in-flight for the same `(resourceURL, loadGeneration)`.
    public func ensureVisibleTilesLoaded(
        currentTime: Double,
        duration: Double,
        windowDuration: Double = AudioWindowedWaveformTileCache.defaultTileDuration,
        resourceURL: URL,
        loadGeneration: UInt64,
        ownerSessionID: String? = nil,
        stableReferencePeak: Float = 0.05,
        provider: (any AudioWaveformWindowedTileProviding)?
    ) {
        guard let provider, duration > 0, duration.isFinite else { return }
        syncSession(resourceURL: resourceURL, loadGeneration: loadGeneration)

        let tileDur = max(1.0, windowDuration)
        let clampedTime = max(0.0, min(duration, currentTime.isFinite ? currentTime : 0.0))
        let minVisibleTime = max(0.0, clampedTime - tileDur * 0.5)
        let maxVisibleTime = min(duration, clampedTime + tileDur * 0.5)

        let firstTile = max(0, Int(floor(minVisibleTime / tileDur)))
        let lastTile = max(firstTile, Int(floor(max(0.0, maxVisibleTime - 0.0001) / tileDur)))

        for tileIdx in firstTile...lastTile {
            let key = TileKey(resourceURL: resourceURL, loadGeneration: loadGeneration, tileIndex: tileIdx)
            if cachedTiles[key] != nil || inFlightKeys.contains(key) {
                continue
            }
            let tileStart = Double(tileIdx) * tileDur
            guard tileStart < duration else { continue }

            let request = AudioWaveformWindowRequest(
                resourceURL: resourceURL,
                loadGeneration: loadGeneration,
                ownerSessionID: ownerSessionID,
                windowStart: tileStart,
                windowDuration: min(tileDur, duration - tileStart),
                targetBucketCount: Self.defaultBucketsPerTile,
                stableReferencePeak: stableReferencePeak
            )

            inFlightKeys.insert(key)
            requestCountByKey[key, default: 0] += 1
            totalRequestCount += 1

            let task = Task { @MainActor [weak self] in
                let response = await provider.extractWindowTile(request)
                guard let self else { return }
                self.inFlightTasks.removeValue(forKey: key)
                self.inFlightKeys.remove(key)
                guard !Task.isCancelled,
                      self.activeResourcePath == key.resourcePath,
                      self.activeGeneration == key.loadGeneration,
                      let response else {
                    return
                }
                self.cachedTiles[key] = response
                self.evictIfNeeded(aroundTileIndex: tileIdx)
            }
            inFlightTasks[key] = task
        }
    }

    public func sampleAmplitude(
        at trackTime: Double,
        tileDuration: Double = AudioWindowedWaveformTileCache.defaultTileDuration,
        resourceURL: URL,
        loadGeneration: UInt64
    ) -> Float? {
        guard trackTime >= 0, trackTime.isFinite, tileDuration > 0 else { return nil }
        let tileIdx = Int(floor(trackTime / tileDuration))
        let key = TileKey(resourceURL: resourceURL, loadGeneration: loadGeneration, tileIndex: tileIdx)
        guard let tile = cachedTiles[key], !tile.peaks.isEmpty, tile.actualDuration > 0 else {
            return nil
        }
        let localOffset = max(0.0, min(tile.actualDuration, trackTime - tile.actualStart))
        let ratio = localOffset / tile.actualDuration
        let bucketIdx = min(tile.peaks.count - 1, max(0, Int(floor(ratio * Double(tile.peaks.count)))))
        return tile.peaks[bucketIdx]
    }

    private func evictIfNeeded(aroundTileIndex centerTile: Int) {
        guard cachedTiles.count > Self.maxCachedTiles else { return }
        let sortedKeys = cachedTiles.keys.sorted {
            abs($0.tileIndex - centerTile) > abs($1.tileIndex - centerTile)
        }
        let excess = cachedTiles.count - Self.maxCachedTiles
        for idx in 0..<excess {
            cachedTiles.removeValue(forKey: sortedKeys[idx])
        }
    }
}

/// Pure mathematical coordinate and time mapper for the fixed-playhead scrolling waveform viewport.
public enum AudioScrollingTimelineMapper {
    /// Default local window duration (`6.0` seconds: `3.0s` before and `3.0s` after the center playhead).
    public static let defaultWindowDuration: Double = 6.0
    /// Minimum whole-track bucket density (`12.0` buckets/sec) required to render local scrolling ticks
    /// directly from whole-track 1600 peaks without stretching. Tracks longer than `133.3s` (including 30-min tracks)
    /// have `< 12.0` buckets/sec and require `AudioWaveformWindowedTileProviding` tiles.
    public static let minimumWholeTrackBucketsPerSecond: Double = 12.0

    /// Computes preview time while dragging horizontally inside the scrolling viewport.
    /// Dragging left (`translationX < 0`) pulls future waveform into the playhead (`time` increases).
    public static func resolveDragPreviewTime(
        dragStartTime: Double,
        translationX: CGFloat,
        canvasWidth: CGFloat,
        windowDuration: Double = defaultWindowDuration,
        duration: Double
    ) -> Double? {
        guard duration.isFinite, duration > 0, canvasWidth > 1.0, windowDuration > 0 else {
            return nil
        }
        let safeStart = max(0.0, min(duration, dragStartTime.isFinite ? dragStartTime : 0.0))
        let deltaSeconds = -Double(translationX / canvasWidth) * windowDuration
        return max(0.0, min(duration, safeStart + deltaSeconds))
    }

    /// Computes target seek time when clicking at `clickX` inside the fixed-playhead scrolling viewport.
    public static func resolveClickTargetTime(
        currentTime: Double,
        clickX: CGFloat,
        canvasWidth: CGFloat,
        windowDuration: Double = defaultWindowDuration,
        duration: Double
    ) -> Double? {
        guard duration.isFinite, duration > 0, canvasWidth > 1.0, windowDuration > 0 else {
            return nil
        }
        let safeCurrent = max(0.0, min(duration, currentTime.isFinite ? currentTime : 0.0))
        let clampedX = max(0.0, min(canvasWidth, clickX))
        let offsetRatio = Double((clampedX - canvasWidth * 0.5) / canvasWidth)
        let target = safeCurrent + offsetRatio * windowDuration
        return max(0.0, min(duration, target))
    }

    /// Resolves the visible vertical ticks in `[currentTime - windowDuration/2, currentTime + windowDuration/2]`.
    /// Enforces start/end boundaries (`[0, duration]`) without looping, repeating, or fabricating peaks,
    /// and refuses to stretch whole-track 1600 peaks on long tracks (`< 12 buckets/sec`).
    @MainActor
    public static func resolveVisibleTicks(
        currentTime: Double,
        duration: Double,
        canvasWidth: CGFloat,
        slotPitch: CGFloat = 3.0,
        windowDuration: Double = defaultWindowDuration,
        wholeTrackPeaks: [Float],
        tileCache: AudioWindowedWaveformTileCache? = nil,
        hasWindowedProvider: Bool = false,
        resourceURL: URL? = nil,
        loadGeneration: UInt64 = 0
    ) -> AudioScrollingWindowResolutionState {
        guard duration.isFinite, duration > 0, canvasWidth > 4.0, slotPitch > 1.0, windowDuration > 0 else {
            return .denseWholeTrackPeaks(ticks: [])
        }

        let clampedCurrent = max(0.0, min(duration, currentTime.isFinite ? currentTime : 0.0))
        let wholeTrackDensity = Double(wholeTrackPeaks.count) / duration
        let canUseWholeTrackDirectly = !wholeTrackPeaks.isEmpty && wholeTrackDensity >= minimumWholeTrackBucketsPerSecond

        if !canUseWholeTrackDirectly && !hasWindowedProvider {
            return .awaitingHighResTileProvider
        }

        let slotsInWindow = max(12, Int(floor(canvasWidth / slotPitch)))
        let timeStep = windowDuration / Double(slotsInWindow)
        let windowStart = clampedCurrent - windowDuration * 0.5
        let windowEnd = clampedCurrent + windowDuration * 0.5

        let minSlotIndex = max(0, Int(floor(windowStart / timeStep)))
        let maxSlotIndex = Int(ceil(min(duration, windowEnd) / timeStep))
        guard maxSlotIndex >= minSlotIndex else {
            return hasWindowedProvider ? .highResolutionTiles(ticks: []) : .denseWholeTrackPeaks(ticks: [])
        }

        let sampleSource = AudioScrollingSampleSource(
            duration: duration, windowDuration: windowDuration, peaks: wholeTrackPeaks,
            tileCache: tileCache, hasWindowedProvider: hasWindowedProvider,
            resourceURL: resourceURL, loadGeneration: loadGeneration
        )
        var ticks: [AudioScrollingWaveformTick] = []
        ticks.reserveCapacity(max(0, maxSlotIndex - minSlotIndex + 1))
        var missingTileSample = false

        for slotIdx in minSlotIndex...maxSlotIndex {
            let trackTime = (Double(slotIdx) + 0.5) * timeStep
            // Strict boundary rule: never loop, repeat, or fabricate ticks outside [0, duration].
            guard trackTime >= 0.0, trackTime <= duration else { continue }
            guard trackTime >= windowStart - timeStep, trackTime <= windowEnd + timeStep else { continue }

            let xPos = (canvasWidth * 0.5) + CGFloat((trackTime - clampedCurrent) / windowDuration) * canvasWidth
            guard xPos >= -slotPitch, xPos <= canvasWidth + slotPitch else { continue }

            guard let amplitude = sampleSource.amplitude(at: trackTime) else {
                missingTileSample = true
                continue
            }

            ticks.append(
                AudioScrollingWaveformTick(
                    slotIndex: slotIdx,
                    trackTime: trackTime,
                    xPosition: xPos,
                    amplitude: amplitude,
                    isPlayed: trackTime <= clampedCurrent + 1e-6
                )
            )
        }

        if hasWindowedProvider {
            if missingTileSample {
                return .loadingWindowTile(partialTicks: ticks)
            }
            return .highResolutionTiles(ticks: ticks)
        }
        return .denseWholeTrackPeaks(ticks: ticks)
    }
}

/// Keeps source selection independent of viewport geometry and output tick placement.
@MainActor
private struct AudioScrollingSampleSource {
    let duration: Double
    let windowDuration: Double
    let peaks: [Float]
    let tileCache: AudioWindowedWaveformTileCache?
    let hasWindowedProvider: Bool
    let resourceURL: URL?
    let loadGeneration: UInt64

    func amplitude(at trackTime: Double) -> Float? {
        if hasWindowedProvider, let tileCache, let resourceURL {
            return tileCache.sampleAmplitude(
                at: trackTime, tileDuration: windowDuration,
                resourceURL: resourceURL, loadGeneration: loadGeneration
            )
        }
        guard !peaks.isEmpty else { return nil }
        let ratio = max(0.0, min(1.0, trackTime / duration))
        let index = min(peaks.count - 1, max(0, Int(floor(ratio * Double(peaks.count)))))
        return peaks[index]
    }
}
