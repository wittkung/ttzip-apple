// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AVFoundation
import AudioToolbox
import Accelerate
import CoreGraphics
import Darwin

/// High-performance actor coordinating bounded off-actor acoustic waveform extraction and versioned caching.
public actor AudioWaveformExtractor {
    /// Shared extractor actor instance.
    public static let shared = AudioWaveformExtractor()

    /// Maximum in-memory byte payload accepted for temporary file waveform decoding (64 MiB).
    nonisolated public static let maxInMemoryWaveformBytes: Int = 64 * 1024 * 1024

    /// Maximum number of concurrent background CoreAudio decode tasks.
    nonisolated public static let maxConcurrentDecodes: Int = 2

    /// Frame count threshold above which extraction switches from full sequential scan to windowed sampling (4M frames).
    nonisolated public static let windowedSeekFrameThreshold: Int64 = 4_000_000

    /// Upper frame bound for sequential silence verification when windowed sampling detects zero energy (16M frames).
    nonisolated public static let maxSequentialSilenceVerificationFrames: Int64 = 16_000_000

    /// Minimum peak floor below which a fully scanned signal is treated as digital silence (-80 dBFS).
    nonisolated internal static let silencePeakFloor: Float = 0.0001

    /// Normalization reference floor preventing quiet background noise from scaling to full amplitude (-26 dBFS).
    nonisolated internal static let normalizationReferenceFloor: Float = 0.05

    private struct CachedEntry: Sendable {
        let resourceSignature: String
        let analysis: AudioWaveformAnalysis
    }

    private var cache: [String: CachedEntry] = [:]
    private var activeDecodeCount: Int = 0
    private var peakConcurrentDecodeCount: Int = 0
    private var slotWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private var testPerBufferDelayNanoseconds: UInt64 = 0
    private var testOnFirstBufferRead: (@Sendable () -> Void)? = nil
    private var testFailAfterBufferCount: Int? = nil

    public init() {}

    /// Configures an artificial per-buffer delay in nanoseconds for deterministic cancellation testing.
    public func setTestPerBufferDelay(nanoseconds: UInt64) {
        testPerBufferDelayNanoseconds = nanoseconds
    }

    /// Configures a deterministic hook invoked once immediately after the first PCM buffer is read.
    public func setTestOnFirstBufferRead(_ handler: (@Sendable () -> Void)?) {
        testOnFirstBufferRead = handler
    }

    /// Configures deterministic mid-decode failure after `count` buffers have been read (`nil` disables).
    public func setTestFailAfterBufferCount(_ count: Int?) {
        testFailAfterBufferCount = count
    }

    /// Returns whether the in-memory cache currently holds a complete waveform analysis for `url`.
    public func hasCachedAnalysis(
        for url: URL,
        targetSampleCount: Int = 1600,
        allowSequentialSilenceVerification: Bool = true
    ) -> Bool {
        let standardizedPath = url.standardizedFileURL.path
        let slotKey = "\(standardizedPath)#\(targetSampleCount)#\(allowSequentialSilenceVerification)"
        guard let signature = Self.computeResourceSignature(forPath: standardizedPath),
              let existing = cache[slotKey] else {
            return false
        }
        return existing.resourceSignature == signature
    }

    /// Extracts waveform analysis including precision mode and silence verification metadata.
    /// Enforces the complete-decode and version-consistency contracts:
    /// - Any mid-stream read error, premature EOF, or container/syncframe truncation returns `nil` and is never cached.
    /// - When stream completeness cannot be authoritatively confirmed (e.g. headerless elementary streams without total-length header or EOS marker, or sparse windowed sampling), the result is never marked `.exhaustiveBucketPeak`, never marked `isVerifiedDigitalSilence = true`, and never written to the complete-result cache.
    /// - If the file's resource signature changes while waiting or decoding, the stale/torn result is discarded (`nil`) and never cached.
    public func extractWaveformAnalysis(
        from url: URL,
        targetSampleCount: Int = 1600,
        allowSequentialSilenceVerification: Bool = true
    ) async -> AudioWaveformAnalysis? {
        guard targetSampleCount > 0, !Task.isCancelled else { return nil }
        let standardizedPath = url.standardizedFileURL.path
        let slotKey = "\(standardizedPath)#\(targetSampleCount)#\(allowSequentialSilenceVerification)"

        if let initialSig = Self.computeResourceSignature(forPath: standardizedPath),
           let existing = cache[slotKey],
           existing.resourceSignature == initialSig {
            return existing.analysis
        }

        let cancelToken = WaveformCancelToken()
        let acquired = await acquireDecodeSlot(cancelToken: cancelToken)
        guard acquired else { return nil }
        defer { releaseDecodeSlot() }

        guard let preDecodeSignature = Self.computeResourceSignature(forPath: standardizedPath) else {
            return nil
        }
        if let existing = cache[slotKey], existing.resourceSignature == preDecodeSignature {
            return existing.analysis
        }

        let delayNanos = testPerBufferDelayNanoseconds
        let firstBufferHook = testOnFirstBufferRead
        let failAfterBuffers = testFailAfterBufferCount
        let decoded = await Self.runOffActorDecode(
            url: url,
            targetSampleCount: targetSampleCount,
            allowSequentialSilenceVerification: allowSequentialSilenceVerification,
            cancelToken: cancelToken,
            perBufferDelayNanos: delayNanos,
            onFirstBufferRead: firstBufferHook,
            failAfterBufferCount: failAfterBuffers
        )

        guard let analysis = decoded,
              !cancelToken.isCancelled,
              !Task.isCancelled,
              let postDecodeSignature = Self.computeResourceSignature(forPath: standardizedPath),
              postDecodeSignature == preDecodeSignature else {
            return nil
        }

        if analysis.isCompletenessVerified {
            storeInCache(slotKey: slotKey, signature: preDecodeSignature, analysis: analysis)
        }
        return analysis
    }

    /// Extracts authentic normalized peak amplitudes `[0.0 ... 1.0]` across `targetSampleCount` bins.
    public func extractAuthenticWaveform(from url: URL, targetSampleCount: Int = 1600) async -> [Float]? {
        let analysis = await extractWaveformAnalysis(from: url, targetSampleCount: targetSampleCount)
        return analysis?.peaks
    }

    /// Extracts waveform analysis from in-memory audio data, honoring the same completeness and silence contracts.
    public func extractWaveformAnalysis(
        from data: Data,
        targetSampleCount: Int = 1600
    ) async -> AudioWaveformAnalysis? {
        guard targetSampleCount > 0,
              !data.isEmpty,
              data.count <= Self.maxInMemoryWaveformBytes,
              !Task.isCancelled else {
            return nil
        }

        let cancelToken = WaveformCancelToken()
        let acquired = await acquireDecodeSlot(cancelToken: cancelToken)
        guard acquired else { return nil }
        defer { releaseDecodeSlot() }

        let delayNanos = testPerBufferDelayNanoseconds
        let firstBufferHook = testOnFirstBufferRead
        let failAfterBuffers = testFailAfterBufferCount
        let ext = (data.count >= 12 && data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46) ? "wav" : "tmp"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ttmedia_waveform_\(UUID().uuidString).\(ext)"
        )
        do {
            try data.write(to: tempURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let analysis = await Self.runOffActorDecode(
                url: tempURL,
                targetSampleCount: targetSampleCount,
                allowSequentialSilenceVerification: true,
                cancelToken: cancelToken,
                perBufferDelayNanos: delayNanos,
                onFirstBufferRead: firstBufferHook,
                failAfterBufferCount: failAfterBuffers
            )
            guard !cancelToken.isCancelled, !Task.isCancelled else { return nil }
            return analysis
        } catch {
            return nil
        }
    }

    /// Extracts authentic normalized peak amplitudes `[0.0 ... 1.0]` from in-memory audio data.
    public func extractAuthenticWaveform(from data: Data, targetSampleCount: Int = 1600) async -> [Float]? {
        let analysis = await extractWaveformAnalysis(from: data, targetSampleCount: targetSampleCount)
        return analysis?.peaks
    }

    /// Extracts normalized peak amplitudes `[0.0 ... 1.0]` across `targetSampleCount` bins for legacy callers.
    public func extractWaveform(from url: URL, targetSampleCount: Int = 1600) async -> [CGFloat] {
        guard targetSampleCount > 0 else { return [] }
        if let authentic = await extractAuthenticWaveform(from: url, targetSampleCount: targetSampleCount) {
            return authentic.map { CGFloat($0) }
        }
        guard !Task.isCancelled else { return [] }
        return defaultWaveform(count: targetSampleCount)
    }

    /// Extracts waveform from in-memory audio data for legacy callers.
    public func extractWaveform(from data: Data, targetSampleCount: Int = 1600) async -> [CGFloat] {
        guard targetSampleCount > 0 else { return [] }
        if let authentic = await extractAuthenticWaveform(from: data, targetSampleCount: targetSampleCount) {
            return authentic.map { CGFloat($0) }
        }
        guard !Task.isCancelled else { return [] }
        return defaultWaveform(count: targetSampleCount)
    }

    // MARK: - Shared Bounded Concurrency Gate

    internal func acquireDecodeSlot(cancelToken: WaveformCancelToken) async -> Bool {
        if Task.isCancelled || cancelToken.isCancelled {
            return false
        }
        if activeDecodeCount < Self.maxConcurrentDecodes {
            activeDecodeCount += 1
            peakConcurrentDecodeCount = max(peakConcurrentDecodeCount, activeDecodeCount)
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || cancelToken.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    slotWaiters.append((id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            cancelToken.cancel()
            Task {
                await self.cancelQueuedWaiter(id: waiterID)
            }
        }
    }

    private func cancelQueuedWaiter(id: UUID) {
        guard let idx = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
        let removed = slotWaiters.remove(at: idx)
        removed.continuation.resume(returning: false)
    }

    internal func releaseDecodeSlot() {
        while !slotWaiters.isEmpty {
            let next = slotWaiters.removeFirst()
            peakConcurrentDecodeCount = max(peakConcurrentDecodeCount, activeDecodeCount)
            next.continuation.resume(returning: true)
            return
        }
        activeDecodeCount = max(0, activeDecodeCount - 1)
    }

    internal func concurrencySnapshot() -> (active: Int, peak: Int) {
        (activeDecodeCount, peakConcurrentDecodeCount)
    }

    internal func cachedAnalysis(forStandardizedPath path: String, signature: String) -> AudioWaveformAnalysis? {
        let prefix = "\(path)#"
        for (key, entry) in cache where key.hasPrefix(prefix) && entry.resourceSignature == signature {
            return entry.analysis
        }
        return nil
    }

    // MARK: - Off-Actor Synchronous CoreAudio Decoding

    nonisolated private static func runOffActorDecode(
        url: URL,
        targetSampleCount: Int,
        allowSequentialSilenceVerification: Bool,
        cancelToken: WaveformCancelToken,
        perBufferDelayNanos: UInt64,
        onFirstBufferRead: (@Sendable () -> Void)?,
        failAfterBufferCount: Int?
    ) async -> AudioWaveformAnalysis? {
        await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                decodeWaveformAnalysis(
                    url: url,
                    targetSampleCount: targetSampleCount,
                    allowSequentialSilenceVerification: allowSequentialSilenceVerification,
                    cancelToken: cancelToken,
                    perBufferDelayNanos: perBufferDelayNanos,
                    onFirstBufferRead: onFirstBufferRead,
                    failAfterBufferCount: failAfterBufferCount
                )
            }.value
        } onCancel: {
            cancelToken.cancel()
        }
    }

    nonisolated private static func decodeWaveformAnalysis(
        url: URL,
        targetSampleCount: Int,
        allowSequentialSilenceVerification: Bool,
        cancelToken: WaveformCancelToken,
        perBufferDelayNanos: UInt64,
        onFirstBufferRead: (@Sendable () -> Void)?,
        failAfterBufferCount: Int?
    ) -> AudioWaveformAnalysis? {
        guard !cancelToken.isCancelled, !Task.isCancelled, targetSampleCount > 0 else { return nil }

        var extFileRef: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &extFileRef) == noErr,
              let extFile = extFileRef else {
            return nil
        }
        defer { ExtAudioFileDispose(extFile) }

        var fileFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var frameCount: Int64 = 0
        var lengthSize = UInt32(MemoryLayout<Int64>.size)
        guard ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileDataFormat, &formatSize, &fileFormat) == noErr,
              ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &frameCount) == noErr,
              frameCount > 0 else {
            return nil
        }

        let proof = AudioContainerCompletenessValidator.evaluate(
            url: url,
            extFile: extFile,
            fileFormat: fileFormat,
            fileLengthFrames: frameCount
        )
        guard proof != .rejectedTruncatedOrCorrupt else { return nil }

        if frameCount > windowedSeekFrameThreshold {
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            return decodeLongStreamAnalysis(
                file: file,
                extFile: extFile,
                fileFormat: fileFormat,
                frameCount: frameCount,
                proof: proof,
                targetSampleCount: targetSampleCount,
                allowSequentialSilenceVerification: allowSequentialSilenceVerification,
                cancelToken: cancelToken,
                perBufferDelayNanos: perBufferDelayNanos,
                onFirstBufferRead: onFirstBufferRead,
                failAfterBufferCount: failAfterBufferCount
            )
        }

        guard let sequential = sampleSequentialFrames(
            extFile: extFile,
            fileFormat: fileFormat,
            frameCount: frameCount,
            proof: proof,
            targetSampleCount: targetSampleCount,
            cancelToken: cancelToken,
            perBufferDelayNanos: perBufferDelayNanos,
            onFirstBufferRead: onFirstBufferRead,
            failAfterBufferCount: failAfterBufferCount
        ) else {
            return nil
        }
        return finalizeAnalysis(
            rawBuckets: sequential.buckets,
            requestedSamplingMode: .exhaustiveBucketPeak,
            proof: proof,
            totalFrames: frameCount,
            sampledFrames: sequential.framesRead
        )
    }

    nonisolated private static func decodeLongStreamAnalysis(
        file: AVAudioFile,
        extFile: ExtAudioFileRef,
        fileFormat: AudioStreamBasicDescription,
        frameCount: AVAudioFramePosition,
        proof: AudioStreamCompletenessProof,
        targetSampleCount: Int,
        allowSequentialSilenceVerification: Bool,
        cancelToken: WaveformCancelToken,
        perBufferDelayNanos: UInt64,
        onFirstBufferRead: (@Sendable () -> Void)?,
        failAfterBufferCount: Int?
    ) -> AudioWaveformAnalysis? {
        guard let windowed = sampleWindowedFrames(
            file: file,
            frameCount: frameCount,
            targetSampleCount: targetSampleCount,
            cancelToken: cancelToken,
            perBufferDelayNanos: perBufferDelayNanos,
            onFirstBufferRead: onFirstBufferRead,
            failAfterBufferCount: failAfterBufferCount
        ) else {
            return nil
        }

        let maxWindowPeak = windowed.buckets.max() ?? 0.0
        if maxWindowPeak <= silencePeakFloor,
           allowSequentialSilenceVerification,
           frameCount <= maxSequentialSilenceVerificationFrames {
            guard ExtAudioFileSeek(extFile, 0) == noErr,
                  let verified = sampleSequentialFrames(
                      extFile: extFile,
                      fileFormat: fileFormat,
                      frameCount: frameCount,
                      proof: proof,
                      targetSampleCount: targetSampleCount,
                      cancelToken: cancelToken,
                      perBufferDelayNanos: perBufferDelayNanos,
                      onFirstBufferRead: nil,
                      failAfterBufferCount: failAfterBufferCount
                  ) else {
                return nil
            }
            return finalizeAnalysis(
                rawBuckets: verified.buckets,
                requestedSamplingMode: .exhaustiveBucketPeak,
                proof: proof,
                totalFrames: frameCount,
                sampledFrames: verified.framesRead
            )
        }

        return finalizeAnalysis(
            rawBuckets: windowed.buckets,
            requestedSamplingMode: .windowedSampledEnvelope,
            proof: proof,
            totalFrames: frameCount,
            sampledFrames: windowed.framesRead
        )
    }

    nonisolated private static func sampleSequentialFrames(
        extFile: ExtAudioFileRef,
        fileFormat: AudioStreamBasicDescription,
        frameCount: AVAudioFramePosition,
        proof: AudioStreamCompletenessProof,
        targetSampleCount: Int,
        cancelToken: WaveformCancelToken,
        perBufferDelayNanos: UInt64,
        onFirstBufferRead: (@Sendable () -> Void)?,
        failAfterBufferCount: Int?
    ) -> (buckets: [Float], framesRead: Int64)? {
        let bufferCapacity: AVAudioFrameCount = 32768
        guard let (buffer, channelCount) = AudioContainerCompletenessValidator.makeSequentialClientBuffer(
            extFile: extFile,
            fileFormat: fileFormat,
            bufferCapacity: bufferCapacity
        ) else {
            return nil
        }

        let expectedTotalFrames = Double(max(1, expectedDecodedFrameCount(for: proof, fallback: frameCount)))
        var buckets = [Float](repeating: 0.0, count: targetSampleCount)
        var totalFramesRead: Int64 = 0
        var bufferIndex: Int = 0

        while true {
            if cancelToken.isCancelled || Task.isCancelled { return nil }
            if let failAfter = failAfterBufferCount, bufferIndex >= failAfter { return nil }
            if !sleepCooperatively(nanos: perBufferDelayNanos, cancelToken: cancelToken) { return nil }

            buffer.frameLength = bufferCapacity
            var ioFrames: UInt32 = bufferCapacity
            let readStatus = ExtAudioFileRead(extFile, &ioFrames, buffer.mutableAudioBufferList)
            guard readStatus == noErr else { return nil }
            if ioFrames == 0 { break }

            buffer.frameLength = ioFrames
            let framesRead = Int(ioFrames)
            guard let channelData = buffer.floatChannelData else { return nil }
            let startFrame = totalFramesRead
            totalFramesRead += Int64(framesRead)

            accumulateBufferBucketsSIMD(
                channelData: channelData,
                channelCount: channelCount,
                framesRead: framesRead,
                startFrame: startFrame,
                totalFrames: expectedTotalFrames,
                buckets: &buckets
            )

            if bufferIndex == 0 { onFirstBufferRead?() }
            bufferIndex += 1
        }

        guard isCompleteSequentialRead(proof: proof, totalFramesRead: totalFramesRead),
              !cancelToken.isCancelled,
              !Task.isCancelled else {
            return nil
        }
        return (buckets, totalFramesRead)
    }

    nonisolated private static func expectedDecodedFrameCount(
        for proof: AudioStreamCompletenessProof,
        fallback: Int64
    ) -> Int64 {
        switch proof {
        case .authoritative(let expectedValidFrames, _, _):
            return expectedValidFrames
        case .unverifiedElementaryStream(let expectedDecodedFrames, _):
            return expectedDecodedFrames
        case .rejectedTruncatedOrCorrupt:
            return fallback
        }
    }

    nonisolated private static func sleepCooperatively(
        nanos: UInt64,
        cancelToken: WaveformCancelToken
    ) -> Bool {
        cancelToken.sleepCooperatively(nanos: nanos)
    }

    nonisolated private static func isCompleteSequentialRead(
        proof: AudioStreamCompletenessProof,
        totalFramesRead: Int64
    ) -> Bool {
        guard totalFramesRead > 0 else { return false }
        switch proof {
        case .authoritative(let expectedValidFrames, _, _):
            return totalFramesRead == expectedValidFrames
        case .unverifiedElementaryStream(let expectedDecodedFrames, _):
            return totalFramesRead == expectedDecodedFrames
        case .rejectedTruncatedOrCorrupt:
            return false
        }
    }

    nonisolated private static func accumulateBufferBucketsSIMD(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        framesRead: Int,
        startFrame: Int64,
        totalFrames: Double,
        buckets: inout [Float]
    ) {
        let bucketCount = buckets.count
        let endFrame = startFrame + Int64(framesRead)
        let firstBucket = min(bucketCount - 1, max(0, Int((Double(startFrame) / totalFrames) * Double(bucketCount))))
        let lastBucket = min(bucketCount - 1, max(firstBucket, Int((Double(endFrame - 1) / totalFrames) * Double(bucketCount))))

        for b in firstBucket...lastBucket {
            let bucketFrameStart = Int64((Double(b) / Double(bucketCount)) * totalFrames)
            let bucketFrameEnd = max(bucketFrameStart + 1, Int64((Double(b + 1) / Double(bucketCount)) * totalFrames))
            let localStart = max(0, Int(bucketFrameStart - startFrame))
            let localEnd = min(framesRead, max(localStart + 1, Int(bucketFrameEnd - startFrame)))
            let sliceCount = localEnd - localStart
            guard sliceCount > 0 else { continue }

            let sliceMax = peakAmplitudeSIMD(
                channelData: channelData,
                channelCount: channelCount,
                framesRead: sliceCount,
                offset: localStart
            )
            if sliceMax > buckets[b] {
                buckets[b] = sliceMax
            }
        }
    }

    nonisolated private static func sampleWindowedFrames(
        file: AVAudioFile,
        frameCount: AVAudioFramePosition,
        targetSampleCount: Int,
        cancelToken: WaveformCancelToken,
        perBufferDelayNanos: UInt64,
        onFirstBufferRead: (@Sendable () -> Void)?,
        failAfterBufferCount: Int?
    ) -> (buckets: [Float], framesRead: Int64)? {
        let format = file.processingFormat
        let windowFrames: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return nil
        }

        let windowCount = min(targetSampleCount, 256)
        var buckets = [Float](repeating: 0.0, count: targetSampleCount)
        var totalSampledFrames: Int64 = 0

        for w in 0..<windowCount {
            if cancelToken.isCancelled || Task.isCancelled { return nil }
            if let failAfter = failAfterBufferCount, w >= failAfter { return nil }
            if !cancelToken.sleepCooperatively(nanos: perBufferDelayNanos) { return nil }

            let startRatio = Double(w) / Double(windowCount)
            let endRatio = Double(w + 1) / Double(windowCount)
            let targetFrame = min(frameCount - 1, max(0, AVAudioFramePosition(startRatio * Double(frameCount))))

            file.framePosition = targetFrame
            do {
                try file.read(into: buffer, frameCount: windowFrames)
            } catch {
                return nil
            }

            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0, let channelData = buffer.floatChannelData else { return nil }
            totalSampledFrames += Int64(framesRead)

            let peak = peakAmplitudeSIMD(
                channelData: channelData,
                channelCount: Int(format.channelCount),
                framesRead: framesRead
            )
            let bStart = min(targetSampleCount - 1, max(0, Int(startRatio * Double(targetSampleCount))))
            let bEnd = min(targetSampleCount, max(bStart + 1, Int(endRatio * Double(targetSampleCount))))
            for b in bStart..<bEnd where peak > buckets[b] {
                buckets[b] = peak
            }

            if w == 0 { onFirstBufferRead?() }
        }

        guard totalSampledFrames > 0, !cancelToken.isCancelled, !Task.isCancelled else { return nil }
        return (buckets, totalSampledFrames)
    }

    nonisolated internal static func peakAmplitudeSIMD(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        framesRead: Int,
        offset: Int = 0
    ) -> Float {
        var peak: Float = 0.0
        for c in 0..<channelCount {
            var chMax: Float = 0.0
            vDSP_maxmgv(channelData[c].advanced(by: offset), 1, &chMax, vDSP_Length(framesRead))
            if chMax.isFinite && chMax > peak {
                peak = chMax
            }
        }
        return peak
    }

    nonisolated internal static func queryFileFormatAndLength(
        extFile: ExtAudioFileRef
    ) -> (AudioStreamBasicDescription, Int64)? {
        var fileFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var rawLengthFrames: Int64 = 0
        var lengthSize = UInt32(MemoryLayout<Int64>.size)
        guard ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileDataFormat, &formatSize, &fileFormat) == noErr,
              ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &rawLengthFrames) == noErr,
              rawLengthFrames > 0,
              fileFormat.mSampleRate > 0 else {
            return nil
        }
        return (fileFormat, rawLengthFrames)
    }

    nonisolated internal static func resolveValidTrackFrames(
        extFile: ExtAudioFileRef,
        fallbackLengthFrames: Int64
    ) -> Int64 {
        var audioFile: AudioFileID?
        var afSize = UInt32(MemoryLayout<AudioFileID>.size)
        guard ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_AudioFile, &afSize, &audioFile) == noErr,
              let af = audioFile else {
            return fallbackLengthFrames
        }
        var pti = AudioFilePacketTableInfo()
        var ptiSize = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        if AudioFileGetProperty(af, kAudioFilePropertyPacketTableInfo, &ptiSize, &pti) == noErr,
           pti.mNumberValidFrames > 0,
           pti.mNumberValidFrames <= fallbackLengthFrames {
            return pti.mNumberValidFrames
        }
        return fallbackLengthFrames
    }

    nonisolated internal static func inspectDeclaredWAVDataFrames(path: String, fileSize: Int64) -> Int64? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var header = [UInt8](repeating: 0, count: 64)
        guard pread(fd, &header, 64, 0) >= 44,
              header[0] == 0x52, header[1] == 0x49, header[2] == 0x46, header[3] == 0x46,
              header[8] == 0x57, header[9] == 0x41, header[10] == 0x56, header[11] == 0x45 else {
            return nil
        }
        let riffBytes = UInt32(header[4])
            | (UInt32(header[5]) << 8)
            | (UInt32(header[6]) << 16)
            | (UInt32(header[7]) << 24)
        let blockAlign = max(1, Int64(UInt16(header[32]) | (UInt16(header[33]) << 8)))
        return (Int64(8) + Int64(riffBytes) > fileSize) ? (Int64(riffBytes) / blockAlign) : nil
    }

    nonisolated internal static func discardWarmupFrames(
        extFile: ExtAudioFileRef,
        buffer: AVAudioPCMBuffer,
        bufferCapacity: AVAudioFrameCount,
        discardCount: Int64,
        requestedStartFrame: Int64,
        didAdjust: Bool,
        cancelToken: WaveformCancelToken,
        path: String
    ) -> Result<(actualStartFrame: Int64, warmupFrames: Int64, didAdjust: Bool), AudioWaveformWindowError> {
        var remaining = discardCount
        var warmupDecoded: Int64 = 0
        while remaining > 0 {
            if cancelToken.isCancelled { return .failure(.cancelled) }
            let chunk = UInt32(min(Int64(bufferCapacity), remaining))
            buffer.frameLength = chunk
            var ioFrames: UInt32 = chunk
            let status = ExtAudioFileRead(extFile, &ioFrames, buffer.mutableAudioBufferList)
            guard status == noErr, ioFrames > 0 else {
                return .failure(.corruptOrTruncatedStream(
                    path: path,
                    diagnostic: "Compressed preroll warmup failed at remaining=\(remaining), status=\(status)"
                ))
            }
            remaining -= Int64(ioFrames)
            warmupDecoded += Int64(ioFrames)
        }
        return .success((requestedStartFrame, warmupDecoded, didAdjust))
    }

    nonisolated private static func finalizeAnalysis(
        rawBuckets: [Float],
        requestedSamplingMode: AudioWaveformSamplingMode,
        proof: AudioStreamCompletenessProof,
        totalFrames: Int64,
        sampledFrames: Int64
    ) -> AudioWaveformAnalysis {
        let isAuthoritativeProof: Bool = {
            if case .authoritative = proof { return true }
            return false
        }()
        let isCompletenessVerified = (requestedSamplingMode == .exhaustiveBucketPeak) && isAuthoritativeProof
        let effectiveSamplingMode: AudioWaveformSamplingMode = isCompletenessVerified
            ? .exhaustiveBucketPeak
            : .windowedSampledEnvelope
        let actualMaxPeak = rawBuckets.max() ?? 0.0
        let isSilent = actualMaxPeak <= silencePeakFloor
        let denominator = max(actualMaxPeak, normalizationReferenceFloor)
        let peaks: [Float] = isSilent
            ? [Float](repeating: 0.0, count: rawBuckets.count)
            : rawBuckets.map { min(1.0, max(0.0, $0 / denominator)) }

        return AudioWaveformAnalysis(
            peaks: peaks,
            samplingMode: effectiveSamplingMode,
            isVerifiedDigitalSilence: isSilent && isCompletenessVerified,
            isCompletenessVerified: isCompletenessVerified,
            completenessProof: proof,
            totalFrames: totalFrames,
            sampledFrames: sampledFrames,
            rawMaxPeak: actualMaxPeak
        )
    }

    // MARK: - Resource Version Signature & Cache

    nonisolated private static func computeResourceSignature(forPath path: String) -> String? {
        AudioContainerCompletenessValidator.computeResourceSignature(forPath: path)
    }

    private func storeInCache(slotKey: String, signature: String, analysis: AudioWaveformAnalysis) {
        if cache.count > 128 {
            cache.removeAll()
        }
        cache[slotKey] = CachedEntry(resourceSignature: signature, analysis: analysis)
    }

    /// Generates a subtle minimal baseline waveform when decoding is unavailable for legacy callers.
    public func defaultWaveform(count: Int) -> [CGFloat] {
        Array(repeating: CGFloat(0.04), count: max(count, 1))
    }

    /// Clears cached waveform profiles from memory.
    public func clearCache() {
        cache.removeAll()
        peakConcurrentDecodeCount = activeDecodeCount
    }
}

extension AudioWaveformExtractor: AudioWaveformWindowExtracting {
    public func extractWindow(_ request: AudioWaveformWindowRequest) async throws -> AudioWaveformWindowTile {
        try await AudioWaveformWindowExtractor.shared.extractWindow(request)
    }

    public func extractWindowedTile(_ request: AudioWaveformWindowRequest) async -> AudioWaveformWindowTile? {
        await AudioWaveformWindowExtractor.shared.extractWindowedTile(request)
    }
}
