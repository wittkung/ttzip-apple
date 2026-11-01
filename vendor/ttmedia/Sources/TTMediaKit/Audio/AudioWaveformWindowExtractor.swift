// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AVFoundation
import AudioToolbox
import Accelerate
import Darwin

/// Actor providing bounded, version-consistent, high-resolution local time-window waveform extraction.
/// Shares the global decode concurrency budget (`AudioWaveformExtractor.maxConcurrentDecodes = 2`) with whole-track extraction.
public actor AudioWaveformWindowExtractor: AudioWaveformWindowExtracting {
    public static let shared = AudioWaveformWindowExtractor()
    private typealias TileCacheKey = WindowTileCacheKey

    private struct CachedTileEntry: Sendable {
        let key: TileCacheKey
        let tile: AudioWaveformWindowTile
        let payloadBytes: Int
        var lastAccessSequence: UInt64
    }

    private final class InFlightWindowOperation: @unchecked Sendable {
        let key: TileCacheKey
        let request: AudioWaveformWindowRequest
        let initialVersion: AudioWaveformResourceVersion
        let refContext: (peak: Float, source: AudioWaveformReferencePeakSource)
        let callStartNanos: UInt64
        let cancelToken: WaveformCancelToken
        var subscribers: [UUID: CheckedContinuation<Result<AudioWaveformWindowTile, AudioWaveformWindowError>, Never>] = [:]
        var subscriberMeta: [UUID: (sessionID: String?, generation: UInt64?, standardizedPath: String)] = [:]
        var cancelRequestedAtNanos: UInt64 = 0

        init(
            key: TileCacheKey,
            request: AudioWaveformWindowRequest,
            initialVersion: AudioWaveformResourceVersion,
            refContext: (peak: Float, source: AudioWaveformReferencePeakSource),
            callStartNanos: UInt64
        ) {
            self.key = key
            self.request = request
            self.initialVersion = initialVersion
            self.refContext = refContext
            self.callStartNanos = callStartNanos
            self.cancelToken = WaveformCancelToken()
        }
    }

    private struct DecodeContext: Sendable {
        let request: AudioWaveformWindowRequest
        let resourceVersion: AudioWaveformResourceVersion
        let refContext: (peak: Float, source: AudioWaveformReferencePeakSource)
        let wholeTrackAnalysis: AudioWaveformAnalysis?
        let sequentialSeekThresholdFrames: Int64
        let cancelToken: WaveformCancelToken
        let perBufferDelayNanos: UInt64
        let onFirstBufferRead: (@Sendable () -> Void)?
        let failAfterBufferCount: Int?
    }

    private struct WindowStreamSession {
        let extFile: ExtAudioFileRef
        let fileFormat: AudioStreamBasicDescription
        let buffer: AVAudioPCMBuffer
        let bufferCapacity: AVAudioFrameCount
        let channelCount: Int
        let totalValidFrames: Int64
        let sampleRate: Double
        let context: DecodeContext
    }

    private var tileCache: [TileCacheKey: CachedTileEntry] = [:]
    private var currentCachePayloadBytes: Int = 0
    private var accessSequenceCounter: UInt64 = 0
    private var inFlightOperations: [TileCacheKey: InFlightWindowOperation] = [:]
    private var latchedTrackReferences: [String: (peak: Float, source: AudioWaveformReferencePeakSource)] = [:]
    private var sessionValidator: (@Sendable (URL, String?, UInt64?) -> Bool)? = nil

    private var maxCachedTilesLimit: Int = AudioWaveformWindowLimits.maxCachedTiles
    private var maxCachePayloadBytesLimit: Int = AudioWaveformWindowLimits.maxCachePayloadBytes
    private var sequentialSeekThresholdFrames: Int64 = AudioWaveformWindowLimits.sequentialAccurateSeekThresholdFrames

    private var cacheHitCount: Int = 0
    private var cacheMissCount: Int = 0
    private var coalescedJoinCount: Int = 0
    private var evictionCount: Int = 0
    private var lastColdExtractDurationMs: Double = 0.0
    private var lastWarmCacheHitDurationMs: Double = 0.0
    private var lastCancelLatencyMs: Double = 0.0
    private var lastDecodedFrameCount: Int64 = 0

    private var testPerBufferDelayNanoseconds: UInt64 = 0
    private var testOnFirstBufferRead: (@Sendable () -> Void)? = nil
    private var testFailAfterBufferCount: Int? = nil

    public init() {}

    // MARK: - Configuration & Metrics

    public func setCacheLimits(maxTiles: Int, maxPayloadBytes: Int) {
        maxCachedTilesLimit = max(1, maxTiles)
        maxCachePayloadBytesLimit = max(1024, maxPayloadBytes)
        evictCacheIfNeeded()
    }

    public func setSequentialSeekThresholdFrames(_ frames: Int64) {
        sequentialSeekThresholdFrames = max(0, frames)
    }

    public func setSessionValidator(_ validator: (@Sendable (URL, String?, UInt64?) -> Bool)?) {
        sessionValidator = validator
    }

    public func setTestPerBufferDelay(nanoseconds: UInt64) {
        testPerBufferDelayNanoseconds = nanoseconds
    }

    public func setTestOnFirstBufferRead(_ handler: (@Sendable () -> Void)?) {
        testOnFirstBufferRead = handler
    }

    public func setTestFailAfterBufferCount(_ count: Int?) {
        testFailAfterBufferCount = count
    }

    public func lastDecodedTotalFrames() -> Int64 {
        lastDecodedFrameCount
    }

    public func metricsSnapshot() async -> AudioWaveformWindowExtractorMetrics {
        let concurrency = await AudioWaveformExtractor.shared.concurrencySnapshot()
        return AudioWaveformWindowExtractorMetrics(
            cacheHitCount: cacheHitCount,
            cacheMissCount: cacheMissCount,
            coalescedJoinCount: coalescedJoinCount,
            evictionCount: evictionCount,
            cachedTileCount: tileCache.count,
            cachedPayloadBytes: currentCachePayloadBytes,
            inFlightOperationCount: inFlightOperations.count,
            peakConcurrentDecodesObserved: concurrency.peak,
            lastColdExtractDurationMs: lastColdExtractDurationMs,
            lastWarmCacheHitDurationMs: lastWarmCacheHitDurationMs,
            lastCancelLatencyMs: lastCancelLatencyMs
        )
    }

    public func clearCache() {
        tileCache.removeAll()
        currentCachePayloadBytes = 0
        latchedTrackReferences.removeAll()
        cacheHitCount = 0
        cacheMissCount = 0
        coalescedJoinCount = 0
        evictionCount = 0
    }

    // MARK: - Public Extraction & Cancellation Entry Points

    public func extractWindow(_ request: AudioWaveformWindowRequest) async throws -> AudioWaveformWindowTile {
        let callStartNanos = DispatchTime.now().uptimeNanoseconds
        if Task.isCancelled {
            throw AudioWaveformWindowError.cancelled
        }
        try request.validateParameters()
        try validateSessionFence(for: request)

        let initialVersion = try validateFileAndCaptureVersion(for: request)
        let refContext = await resolveStableReferencePeak(for: request, version: initialVersion)
        let key = makeCacheKey(for: request, version: initialVersion, referencePeak: refContext.peak)

        if let cached = lookupValidCachedTile(for: key, request: request, expectedVersion: initialVersion) {
            lastWarmCacheHitDurationMs = Self.elapsedMs(since: callStartNanos)
            return cached
        }

        cacheMissCount += 1
        let seedOp = InFlightWindowOperation(
            key: key,
            request: request,
            initialVersion: initialVersion,
            refContext: refContext,
            callStartNanos: callStartNanos
        )
        let tile = try await joinOrStartInFlightDecode(seedOp: seedOp)
        try validateSessionFence(for: request)
        return tile
    }

    public func extractWindowedTile(_ request: AudioWaveformWindowRequest) async -> AudioWaveformWindowTile? {
        try? await extractWindow(request)
    }

    public func cancelRequests(forOwnerSessionID sessionID: String) {
        cancelMatchingSubscribers { $0.sessionID == sessionID }
    }

    public func cancelRequests(forURL url: URL, olderThanGeneration minGeneration: UInt64? = nil) {
        let targetPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        cancelMatchingSubscribers { meta in
            guard meta.standardizedPath == targetPath else { return false }
            if let minGen = minGeneration, let subGen = meta.generation { return subGen < minGen }
            return true
        }
    }

    public func cancelAllRequests() {
        cancelMatchingSubscribers { _ in true }
    }

    private func cancelMatchingSubscribers(
        where predicate: ((sessionID: String?, generation: UInt64?, standardizedPath: String)) -> Bool
    ) {
        for (key, op) in Array(inFlightOperations) {
            let matchingIDs = op.subscriberMeta.compactMap { predicate($0.value) ? $0.key : nil }
            for subID in matchingIDs {
                unsubscribeCaller(key: key, subscriberID: subID)
            }
        }
    }

    // MARK: - Validation, Reference Latching & LRU Cache

    private func validateSessionFence(for request: AudioWaveformWindowRequest) throws {
        guard let validator = sessionValidator else { return }
        if !validator(request.url, request.ownerSessionID, request.loadGeneration) {
            throw AudioWaveformWindowError.staleSessionOrGeneration(
                requestedGeneration: request.loadGeneration,
                activeGeneration: nil,
                requestedSessionID: request.ownerSessionID,
                activeSessionID: nil
            )
        }
    }

    private func validateFileAndCaptureVersion(
        for request: AudioWaveformWindowRequest
    ) throws -> AudioWaveformResourceVersion {
        let path = request.url.standardizedFileURL.resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw AudioWaveformWindowError.fileNotFound(path: path)
        }
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw AudioWaveformWindowError.fileNotFound(path: path)
        }
        guard st.st_size > 0 else {
            throw AudioWaveformWindowError.emptyAudioFile(path: path)
        }
        let ext = request.url.pathExtension.lowercased()
        switch MPVAudioEngine.formatSupport(forExtension: ext) {
        case .requiresSynthesizer(_, let reason), .unsupportedCodec(_, let reason):
            throw AudioWaveformWindowError.unsupportedFormat(extensionName: ext, reason: reason)
        default:
            break
        }
        guard let liveVersion = AudioWaveformResourceVersion.capture(for: request.url) else {
            throw AudioWaveformWindowError.fileNotFound(path: path)
        }
        if let expected = request.expectedResourceVersion, expected != liveVersion {
            invalidateCachedTiles(forStandardizedPath: path)
            throw AudioWaveformWindowError.resourceVersionChanged(
                expectedSignature: expected.rawSignature,
                actualSignature: liveVersion.rawSignature
            )
        }
        return liveVersion
    }

    private func resolveStableReferencePeak(
        for request: AudioWaveformWindowRequest,
        version: AudioWaveformResourceVersion
    ) async -> (peak: Float, source: AudioWaveformReferencePeakSource) {
        if let explicitPeak = request.referencePeak {
            return (max(explicitPeak, AudioWaveformWindowLimits.normalizationReferenceFloor), .callerProvided)
        }
        let versionKey = "\(version.standardizedPath)#\(version.rawSignature)"
        if let latched = latchedTrackReferences[versionKey] {
            return latched
        }
        if let cachedWholeTrack = await AudioWaveformExtractor.shared.cachedAnalysis(
            forStandardizedPath: version.standardizedPath,
            signature: version.rawSignature
        ), cachedWholeTrack.rawMaxPeak > 0 {
            let resolved = (
                peak: max(cachedWholeTrack.rawMaxPeak, AudioWaveformWindowLimits.normalizationReferenceFloor),
                source: AudioWaveformReferencePeakSource.wholeTrackAnalysis
            )
            latchedTrackReferences[versionKey] = resolved
            return resolved
        }
        let canonical = (peak: Float(1.0), source: AudioWaveformReferencePeakSource.canonicalFullScale0dBFS)
        latchedTrackReferences[versionKey] = canonical
        return canonical
    }

    private func makeCacheKey(
        for request: AudioWaveformWindowRequest,
        version: AudioWaveformResourceVersion,
        referencePeak: Float
    ) -> TileCacheKey {
        TileCacheKey(
            standardizedPath: version.standardizedPath,
            resourceSignature: version.rawSignature,
            quantizedStartMicros: Int64((request.startTime * 1_000_000.0).rounded()),
            quantizedDurationMicros: Int64((request.windowDuration * 1_000_000.0).rounded()),
            targetBucketCount: request.targetBucketCount,
            quantizedReferencePeak: Int32((referencePeak * 100_000.0).rounded())
        )
    }

    private func lookupValidCachedTile(
        for key: TileCacheKey,
        request: AudioWaveformWindowRequest,
        expectedVersion: AudioWaveformResourceVersion
    ) -> AudioWaveformWindowTile? {
        guard var entry = tileCache[key] else { return nil }
        guard let currentOnDisk = AudioWaveformResourceVersion.capture(for: request.url),
              currentOnDisk == expectedVersion,
              entry.tile.resourceVersion == currentOnDisk else {
            invalidateCachedTiles(forStandardizedPath: key.standardizedPath)
            return nil
        }
        accessSequenceCounter &+= 1
        entry.lastAccessSequence = accessSequenceCounter
        tileCache[key] = entry
        cacheHitCount += 1
        return entry.tile.recontextualized(for: request, servedFromCache: true)
    }

    private func storeTileInCache(key: TileCacheKey, tile: AudioWaveformWindowTile) {
        let payloadBytes = tile.estimatedMemoryFootprintBytes
        if let existing = tileCache.removeValue(forKey: key) {
            currentCachePayloadBytes = max(0, currentCachePayloadBytes - existing.payloadBytes)
        }
        accessSequenceCounter &+= 1
        tileCache[key] = CachedTileEntry(
            key: key,
            tile: tile,
            payloadBytes: payloadBytes,
            lastAccessSequence: accessSequenceCounter
        )
        currentCachePayloadBytes += payloadBytes
        evictCacheIfNeeded()
    }

    private func evictCacheIfNeeded() {
        while tileCache.count > maxCachedTilesLimit || currentCachePayloadBytes > maxCachePayloadBytesLimit {
            guard let oldest = tileCache.values.min(by: { $0.lastAccessSequence < $1.lastAccessSequence }) else {
                break
            }
            tileCache.removeValue(forKey: oldest.key)
            currentCachePayloadBytes = max(0, currentCachePayloadBytes - oldest.payloadBytes)
            evictionCount += 1
        }
    }

    private func invalidateCachedTiles(forStandardizedPath path: String) {
        for k in tileCache.keys where k.standardizedPath == path {
            if let removed = tileCache.removeValue(forKey: k) {
                currentCachePayloadBytes = max(0, currentCachePayloadBytes - removed.payloadBytes)
            }
        }
    }

    // MARK: - In-Flight Coalescing & Multi-Caller Cancellation Isolation

    private func joinOrStartInFlightDecode(seedOp: InFlightWindowOperation) async throws -> AudioWaveformWindowTile {
        let subscriberID = UUID()
        let key = seedOp.key
        let result: Result<AudioWaveformWindowTile, AudioWaveformWindowError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerSubscriber(subscriberID: subscriberID, seedOp: seedOp, continuation: continuation)
            }
        } onCancel: {
            Task { await self.unsubscribeCaller(key: key, subscriberID: subscriberID) }
        }
        return try result.get().recontextualized(for: seedOp.request, servedFromCache: false)
    }

    private func registerSubscriber(
        subscriberID: UUID,
        seedOp: InFlightWindowOperation,
        continuation: CheckedContinuation<Result<AudioWaveformWindowTile, AudioWaveformWindowError>, Never>
    ) {
        if Task.isCancelled {
            continuation.resume(returning: .failure(.cancelled))
            return
        }
        let meta = (seedOp.request.ownerSessionID, seedOp.request.loadGeneration, seedOp.initialVersion.standardizedPath)
        if let existingOp = inFlightOperations[seedOp.key] {
            coalescedJoinCount += 1
            existingOp.subscribers[subscriberID] = continuation
            existingOp.subscriberMeta[subscriberID] = meta
            return
        }
        seedOp.subscribers[subscriberID] = continuation
        seedOp.subscriberMeta[subscriberID] = meta
        inFlightOperations[seedOp.key] = seedOp

        Task {
            await self.executeCoalescedWindowDecode(op: seedOp)
        }
    }

    private func unsubscribeCaller(key: TileCacheKey, subscriberID: UUID) {
        guard let op = inFlightOperations[key],
              let continuation = op.subscribers.removeValue(forKey: subscriberID) else {
            return
        }
        let cancelNanos = DispatchTime.now().uptimeNanoseconds
        op.subscriberMeta.removeValue(forKey: subscriberID)
        continuation.resume(returning: .failure(.cancelled))

        if op.subscribers.isEmpty {
            op.cancelRequestedAtNanos = cancelNanos
            op.cancelToken.cancel()
            inFlightOperations.removeValue(forKey: key)
            lastCancelLatencyMs = Self.elapsedMs(since: cancelNanos)
        }
    }

    private func executeCoalescedWindowDecode(op: InFlightWindowOperation) async {
        let acquired = await AudioWaveformExtractor.shared.acquireDecodeSlot(cancelToken: op.cancelToken)
        guard acquired else {
            recordCancelLatencyIfNeeded(for: op)
            finishOperation(op: op, result: .failure(.cancelled))
            return
        }
        defer { Task { await AudioWaveformExtractor.shared.releaseDecodeSlot() } }

        guard let preDecodeVersion = verifyResourceUnchanged(url: op.request.url, expected: op.initialVersion) else {
            finishWithVersionMismatch(op: op)
            return
        }
        let wholeTrackCached = await AudioWaveformExtractor.shared.cachedAnalysis(
            forStandardizedPath: preDecodeVersion.standardizedPath,
            signature: preDecodeVersion.rawSignature
        )
        let ctx = DecodeContext(
            request: op.request,
            resourceVersion: preDecodeVersion,
            refContext: op.refContext,
            wholeTrackAnalysis: wholeTrackCached,
            sequentialSeekThresholdFrames: sequentialSeekThresholdFrames,
            cancelToken: op.cancelToken,
            perBufferDelayNanos: testPerBufferDelayNanoseconds,
            onFirstBufferRead: testOnFirstBufferRead,
            failAfterBufferCount: testFailAfterBufferCount
        )
        let decodedOutcome = await Task.detached(priority: .utility) {
            Self.decodeWindowOffActor(context: ctx)
        }.value

        commitCoalescedOutcome(op: op, preDecodeVersion: preDecodeVersion, decodedOutcome: decodedOutcome)
    }

    private func verifyResourceUnchanged(
        url: URL,
        expected: AudioWaveformResourceVersion
    ) -> AudioWaveformResourceVersion? {
        guard let current = AudioWaveformResourceVersion.capture(for: url), current == expected else {
            invalidateCachedTiles(forStandardizedPath: expected.standardizedPath)
            return nil
        }
        return current
    }

    private func finishWithVersionMismatch(op: InFlightWindowOperation) {
        let actualSig = AudioWaveformResourceVersion.capture(for: op.request.url)?.rawSignature ?? "missing"
        finishOperation(
            op: op,
            result: .failure(.resourceVersionChanged(
                expectedSignature: op.initialVersion.rawSignature,
                actualSignature: actualSig
            ))
        )
    }

    private func commitCoalescedOutcome(
        op: InFlightWindowOperation,
        preDecodeVersion: AudioWaveformResourceVersion,
        decodedOutcome: Result<(AudioWaveformWindowTile, Int64), AudioWaveformWindowError>
    ) {
        if op.cancelToken.isCancelled {
            recordCancelLatencyIfNeeded(for: op)
            finishOperation(op: op, result: .failure(.cancelled))
            return
        }
        guard verifyResourceUnchanged(url: op.request.url, expected: preDecodeVersion) != nil else {
            finishWithVersionMismatch(op: op)
            return
        }
        switch decodedOutcome {
        case .success(let (tile, framesDecoded)):
            lastDecodedFrameCount = framesDecoded
            lastColdExtractDurationMs = Self.elapsedMs(since: op.callStartNanos)
            storeTileInCache(key: op.key, tile: tile)
            finishOperation(op: op, result: .success(tile))
        case .failure(let error):
            finishOperation(op: op, result: .failure(error))
        }
    }

    private func recordCancelLatencyIfNeeded(for op: InFlightWindowOperation) {
        if op.cancelRequestedAtNanos > 0 {
            lastCancelLatencyMs = Self.elapsedMs(since: op.cancelRequestedAtNanos)
        }
    }

    private func finishOperation(
        op: InFlightWindowOperation,
        result: Result<AudioWaveformWindowTile, AudioWaveformWindowError>
    ) {
        inFlightOperations.removeValue(forKey: op.key)
        let continuations = Array(op.subscribers.values)
        op.subscribers.removeAll()
        op.subscriberMeta.removeAll()
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }

    // MARK: - Off-Actor Window Decoding & Post-Seek Frame Alignment

    nonisolated private static func decodeWindowOffActor(
        context: DecodeContext
    ) -> Result<(AudioWaveformWindowTile, Int64), AudioWaveformWindowError> {
        guard !context.cancelToken.isCancelled else { return .failure(.cancelled) }
        let path = context.resourceVersion.standardizedPath
        let declaredFrames = AudioWaveformExtractor.inspectDeclaredWAVDataFrames(
            path: path,
            fileSize: context.resourceVersion.fileSize
        )

        var extFileRef: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(context.request.url as CFURL, &extFileRef)
        guard openStatus == noErr, let extFile = extFileRef else {
            return .failure(.corruptOrTruncatedStream(path: path, diagnostic: "ExtAudioFileOpenURL failed (\(openStatus))"))
        }
        defer { ExtAudioFileDispose(extFile) }

        guard let (fileFormat, rawLengthFrames) = AudioWaveformExtractor.queryFileFormatAndLength(extFile: extFile) else {
            return .failure(.corruptOrTruncatedStream(path: path, diagnostic: "Invalid ASBD or zero FileLengthFrames"))
        }

        let sampleRate = fileFormat.mSampleRate
        let totalValidFrames = AudioWaveformExtractor.resolveValidTrackFrames(
            extFile: extFile,
            fallbackLengthFrames: rawLengthFrames
        )
        let requestedStartFrame = Int64((context.request.startTime * sampleRate).rounded(.down))
        let requestedWindowFrames = max(1, Int64((context.request.windowDuration * sampleRate).rounded()))

        if let declared = declaredFrames,
           declared > rawLengthFrames,
           requestedStartFrame + requestedWindowFrames > rawLengthFrames {
            return .failure(.corruptOrTruncatedStream(
                path: path,
                diagnostic: "Container header declared \(declared) frames but physical file ends at \(rawLengthFrames)"
            ))
        }
        if requestedStartFrame >= totalValidFrames {
            let emptyTile = AudioWaveformWindowTile.makeDecodedTile(
                request: context.request,
                resourceVersion: context.resourceVersion,
                refContext: context.refContext,
                wholeTrackAnalysis: context.wholeTrackAnalysis,
                actualStartFrame: totalValidFrames,
                actualEndFrame: totalValidFrames,
                totalValidFrames: totalValidFrames,
                sampleRate: sampleRate,
                channelCount: Int(max(1, fileFormat.mChannelsPerFrame)),
                didApplySeekOffsetAdjustment: false,
                rawBuckets: [],
                coverageStatus: .emptyAtOrPastEOF
            )
            return .success((emptyTile, 0))
        }
        let bufferCapacity: AVAudioFrameCount = 16384
        guard let (buffer, channelCount) = AudioContainerCompletenessValidator.makeSequentialClientBuffer(
            extFile: extFile,
            fileFormat: fileFormat,
            bufferCapacity: bufferCapacity
        ) else {
            return .failure(.corruptOrTruncatedStream(path: path, diagnostic: "Failed to configure Float32 client format"))
        }
        let session = WindowStreamSession(
            extFile: extFile,
            fileFormat: fileFormat,
            buffer: buffer,
            bufferCapacity: bufferCapacity,
            channelCount: channelCount,
            totalValidFrames: totalValidFrames,
            sampleRate: sampleRate,
            context: context
        )
        return decodeActiveWindowRange(
            session: session,
            requestedStartFrame: requestedStartFrame,
            requestedWindowFrames: requestedWindowFrames
        )
    }

    nonisolated private static func decodeActiveWindowRange(
        session: WindowStreamSession,
        requestedStartFrame: Int64,
        requestedWindowFrames: Int64
    ) -> Result<(AudioWaveformWindowTile, Int64), AudioWaveformWindowError> {
        let alignResult = positionStreamAtStartFrame(session: session, requestedStartFrame: requestedStartFrame)
        guard case .success(let (actualStartFrame, warmupFramesDecoded, didAdjustSeek)) = alignResult else {
            if case .failure(let err) = alignResult { return .failure(err) }
            return .failure(.cancelled)
        }

        let targetEndFrame = min(session.totalValidFrames, actualStartFrame + requestedWindowFrames)
        let expectedFramesInWindow = max(1, targetEndFrame - actualStartFrame)
        let req = session.context.request
        let bucketDuration = req.windowDuration / Double(req.targetBucketCount)
        let isPartialTail = (targetEndFrame == session.totalValidFrames) && (expectedFramesInWindow < requestedWindowFrames)
        let coveredBucketCount = isPartialTail
            ? min(req.targetBucketCount, max(1, Int(ceil((Double(expectedFramesInWindow) / session.sampleRate) / bucketDuration))))
            : req.targetBucketCount

        let grid = WindowBucketGrid(
            expectedFramesInWindow: expectedFramesInWindow,
            coveredBucketCount: coveredBucketCount,
            isPartialTail: isPartialTail,
            framesPerBucket: bucketDuration * session.sampleRate,
            totalSpan: Double(max(1, expectedFramesInWindow))
        )
        let readResult = readWindowFramesSIMD(session: session, grid: grid)
        guard case .success(let (rawBuckets, windowFramesRead)) = readResult else {
            if case .failure(let err) = readResult { return .failure(err) }
            return .failure(.cancelled)
        }

        let ctx = session.context
        let tile = AudioWaveformWindowTile.makeDecodedTile(
            request: ctx.request,
            resourceVersion: ctx.resourceVersion,
            refContext: ctx.refContext,
            wholeTrackAnalysis: ctx.wholeTrackAnalysis,
            actualStartFrame: actualStartFrame,
            actualEndFrame: actualStartFrame + windowFramesRead,
            totalValidFrames: session.totalValidFrames,
            sampleRate: session.sampleRate,
            channelCount: session.channelCount,
            didApplySeekOffsetAdjustment: didAdjustSeek,
            rawBuckets: rawBuckets,
            coverageStatus: isPartialTail ? .partialTailAtEOF : .completeWindow
        )
        return .success((tile, warmupFramesDecoded + windowFramesRead))
    }

    nonisolated private static func positionStreamAtStartFrame(
        session: WindowStreamSession,
        requestedStartFrame: Int64
    ) -> Result<(actualStartFrame: Int64, warmupFrames: Int64, didAdjust: Bool), AudioWaveformWindowError> {
        guard requestedStartFrame > 0 else { return .success((0, 0, false)) }
        let path = session.context.resourceVersion.standardizedPath
        if session.fileFormat.mFormatID == kAudioFormatLinearPCM {
            let seekStatus = ExtAudioFileSeek(session.extFile, requestedStartFrame)
            guard seekStatus == noErr else {
                return .failure(.corruptOrTruncatedStream(path: path, diagnostic: "PCM ExtAudioFileSeek failed (\(seekStatus))"))
            }
            var tellFrame: Int64 = requestedStartFrame
            _ = ExtAudioFileTell(session.extFile, &tellFrame)
            let aligned = max(0, tellFrame)
            return .success((aligned, 0, aligned != requestedStartFrame))
        }

        var discardRemaining = requestedStartFrame
        var didAdjust = false
        if requestedStartFrame > session.context.sequentialSeekThresholdFrames {
            let seekTarget = max(0, requestedStartFrame - AudioWaveformWindowLimits.compressedSeekPrerollFrames)
            if ExtAudioFileSeek(session.extFile, seekTarget) == noErr {
                var landedFrame: Int64 = seekTarget
                if ExtAudioFileTell(session.extFile, &landedFrame) == noErr, landedFrame >= 0 {
                    didAdjust = true
                    if landedFrame > requestedStartFrame {
                        return .success((landedFrame, 0, true))
                    }
                    discardRemaining = requestedStartFrame - landedFrame
                } else {
                    discardRemaining = requestedStartFrame - seekTarget
                    didAdjust = true
                }
            }
        }
        return AudioWaveformExtractor.discardWarmupFrames(
            extFile: session.extFile,
            buffer: session.buffer,
            bufferCapacity: session.bufferCapacity,
            discardCount: discardRemaining,
            requestedStartFrame: requestedStartFrame,
            didAdjust: didAdjust,
            cancelToken: session.context.cancelToken,
            path: path
        )
    }

    nonisolated private static func readWindowFramesSIMD(
        session: WindowStreamSession,
        grid: WindowBucketGrid
    ) -> Result<([Float], Int64), AudioWaveformWindowError> {
        let context = session.context
        let path = context.resourceVersion.standardizedPath
        var rawBuckets = [Float](repeating: 0.0, count: grid.coveredBucketCount)
        var framesReadInWindow: Int64 = 0
        var bufferIndex = 0

        while framesReadInWindow < grid.expectedFramesInWindow {
            if context.cancelToken.isCancelled { return .failure(.cancelled) }
            if let failAfter = context.failAfterBufferCount, bufferIndex >= failAfter {
                return .failure(.corruptOrTruncatedStream(path: path, diagnostic: "Injected mid-window decode failure"))
            }
            if !context.cancelToken.sleepCooperatively(nanos: context.perBufferDelayNanos) {
                return .failure(.cancelled)
            }
            let requestFrames = UInt32(min(Int64(session.bufferCapacity), grid.expectedFramesInWindow - framesReadInWindow))
            session.buffer.frameLength = requestFrames
            var ioFrames: UInt32 = requestFrames
            let readStatus = ExtAudioFileRead(session.extFile, &ioFrames, session.buffer.mutableAudioBufferList)
            guard readStatus == noErr else {
                return .failure(.corruptOrTruncatedStream(path: path, diagnostic: "ExtAudioFileRead error \(readStatus)"))
            }
            if ioFrames == 0 { break }
            guard let channelData = session.buffer.floatChannelData else {
                return .failure(.corruptOrTruncatedStream(path: path, diagnostic: "Missing floatChannelData"))
            }
            accumulateWindowSliceSIMD(
                channelData: channelData,
                channelCount: session.channelCount,
                framesRead: Int(ioFrames),
                localStartFrame: framesReadInWindow,
                grid: grid,
                buckets: &rawBuckets
            )
            framesReadInWindow += Int64(ioFrames)
            if bufferIndex == 0 { context.onFirstBufferRead?() }
            bufferIndex += 1
        }

        if context.cancelToken.isCancelled { return .failure(.cancelled) }
        guard framesReadInWindow > 0,
              framesReadInWindow >= min(grid.expectedFramesInWindow, max(1, grid.expectedFramesInWindow - 512)) else {
            return .failure(.corruptOrTruncatedStream(
                path: path,
                diagnostic: "Premature EOF in window: read \(framesReadInWindow) of \(grid.expectedFramesInWindow) frames"
            ))
        }
        return .success((rawBuckets, framesReadInWindow))
    }

    nonisolated private static func accumulateWindowSliceSIMD(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        framesRead: Int,
        localStartFrame: Int64,
        grid: WindowBucketGrid,
        buckets: inout [Float]
    ) {
        guard grid.coveredBucketCount > 0, framesRead > 0 else { return }
        let localEndFrame = localStartFrame + Int64(framesRead)
        let (firstBucket, lastBucket) = grid.bucketRange(localStartFrame: localStartFrame, localEndFrame: localEndFrame)

        for b in firstBucket...lastBucket {
            let (bStart, bEnd) = grid.frameBounds(forBucket: b)
            let sliceStart = max(0, Int(bStart - localStartFrame))
            let sliceEnd = min(framesRead, max(sliceStart + 1, Int(bEnd - localStartFrame)))
            let sliceCount = sliceEnd - sliceStart
            guard sliceCount > 0 else { continue }

            let sliceMax = AudioWaveformExtractor.peakAmplitudeSIMD(
                channelData: channelData,
                channelCount: channelCount,
                framesRead: sliceCount,
                offset: sliceStart
            )
            if sliceMax > buckets[b] { buckets[b] = sliceMax }
        }
    }

    nonisolated private static func elapsedMs(since startNanos: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= startNanos else { return 0.0 }
        return Double(now - startNanos) / 1_000_000.0
    }
}
