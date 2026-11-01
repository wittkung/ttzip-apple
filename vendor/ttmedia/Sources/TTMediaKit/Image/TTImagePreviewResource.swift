// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import ImageIO

// MARK: - Decode Budget & Cancellation Contract

/// Explicit memory and concurrency budget governing animated frame caching and high-resolution zoom resampling.
public struct TTImageDecodeBudget: Sendable, Equatable {
    /// Policy when a single animated frame's decoded RGBA bytes would exceed `maxTotalAnimationMemoryBytes`.
    public enum OversizedFramePolicy: Sendable, Equatable {
        /// Downsample the frame dimension before decoding so its RGBA byte count fits within `maxTotalAnimationMemoryBytes`.
        case downsampleToFitBudget
        /// Decode at `maxAnimatedFrameDimension` and display transiently without inserting into `frameCache`.
        case bypassCache
        /// Reject any frame whose decoded RGBA byte count exceeds `maxTotalAnimationMemoryBytes`.
        case rejectFrame
    }

    /// Maximum pixel dimension for decoded animation frames (default `1024`).
    public let maxAnimatedFrameDimension: Int
    /// Maximum total memory bytes for cached animation frames across a single player (default `64 MiB`).
    public let maxTotalAnimationMemoryBytes: Int
    /// Policy when a single animated frame exceeds `maxTotalAnimationMemoryBytes` (default `.downsampleToFitBudget`).
    public let oversizedAnimatedFramePolicy: OversizedFramePolicy
    /// Maximum pixel dimension cap for static high-resolution zoom resampling (default `8192`).
    public let maxStaticZoomDimension: Int
    /// Maximum decoded RGBA bitmap memory bytes for static high-resolution zoom (default `256 MiB`).
    public let maxStaticZoomMemoryBytes: Int
    /// Maximum number of concurrent background image decode operations (default `2`).
    public let maxConcurrentDecodes: Int

    public static let `default` = TTImageDecodeBudget()

    public init(
        maxAnimatedFrameDimension: Int = 1024,
        maxTotalAnimationMemoryBytes: Int = 64 * 1024 * 1024,
        oversizedAnimatedFramePolicy: OversizedFramePolicy = .downsampleToFitBudget,
        maxStaticZoomDimension: Int = 8192,
        maxStaticZoomMemoryBytes: Int = 256 * 1024 * 1024,
        maxConcurrentDecodes: Int = 2
    ) {
        self.maxAnimatedFrameDimension = max(1, maxAnimatedFrameDimension)
        self.maxTotalAnimationMemoryBytes = max(4, maxTotalAnimationMemoryBytes)
        self.oversizedAnimatedFramePolicy = oversizedAnimatedFramePolicy
        self.maxStaticZoomDimension = max(1, maxStaticZoomDimension)
        self.maxStaticZoomMemoryBytes = max(4, maxStaticZoomMemoryBytes)
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
    }

    public func effectiveAnimatedFrameDimension(originalWidth: Int, originalHeight: Int) -> Int {
        guard oversizedAnimatedFramePolicy == .downsampleToFitBudget else {
            return maxAnimatedFrameDimension
        }
        return TTImageResolutionUpgrader.targetMaxPixelDimension(
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            viewportSize: CGSize(width: maxAnimatedFrameDimension, height: maxAnimatedFrameDimension),
            backingScale: 1.0,
            scale: 1.0,
            maxPixelDimensionCap: maxAnimatedFrameDimension,
            maxDecodedBytes: maxTotalAnimationMemoryBytes
        )
    }
}

/// Cooperative cancellation token shared between preview controllers and `TTImageDecodeScheduler`.
public final class TTImageDecodeCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled: Bool = false
    private var onCancelHandler: (@Sendable () -> Void)?

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        onCancelHandler = handler
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let handler = onCancelHandler
        onCancelHandler = nil
        lock.unlock()
        handler?()
    }
}

// MARK: - Bounded Concurrency Image Decode Scheduler

/// Bounded-concurrency background image decode scheduler enforcing `maxConcurrentDecodes`
/// and cooperative stage-by-stage cancellation without unstructured `Task.detached` proliferation.
public final class TTImageDecodeScheduler: @unchecked Sendable {
    public static let shared = TTImageDecodeScheduler()

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved: Bool = false
        private var result: CGImage?
        private var continuation: CheckedContinuation<CGImage?, Never>?

        func complete(_ image: CGImage?) {
            lock.lock()
            guard !resolved else {
                lock.unlock()
                return
            }
            resolved = true
            result = image
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: image)
        }

        func wait() async -> CGImage? {
            await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                lock.lock()
                if resolved {
                    let img = result
                    lock.unlock()
                    cont.resume(returning: img)
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }
    }

    private struct PendingJob {
        let id: UInt64
        let token: TTImageDecodeCancelToken
        let operation: @Sendable () -> CGImage?
        let box: ResultBox
    }

    private let lock = NSLock()
    private let maxConcurrentDecodes: Int
    private var nextJobID: UInt64 = 1
    private var activeCount: Int = 0
    private var peakCount: Int = 0
    private var cancelledCount: Int = 0
    private var pendingQueue: [PendingJob] = []
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrentDecodes: Int = TTImageDecodeBudget.default.maxConcurrentDecodes) {
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
    }

    public var activeDecodeCount: Int { lock.withLock { activeCount } }
    public var peakConcurrentDecodeCount: Int { lock.withLock { peakCount } }
    public var cancelledDecodeCount: Int { lock.withLock { cancelledCount } }

    public func resetMetrics() {
        lock.withLock {
            peakCount = activeCount
            cancelledCount = 0
        }
    }

    /// Suspends until all active and queued decode jobs have completed.
    public func waitForIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if activeCount == 0 && pendingQueue.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                idleContinuations.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Schedules a cancellable `CGImage` decode operation under the concurrency limit.
    public func decodeCGImage(
        from source: TTImagePreviewResource.Source,
        frameIndex: Int = 0,
        maxPixelDimension: Int,
        simulatedDelayNanoseconds: UInt64 = 0,
        token: TTImageDecodeCancelToken
    ) async -> CGImage? {
        let waitResult = startDecode(
            from: source,
            frameIndex: frameIndex,
            maxPixelDimension: maxPixelDimension,
            simulatedDelayNanoseconds: simulatedDelayNanoseconds,
            token: token
        )
        return await waitResult()
    }

    /// Synchronously registers and starts or enqueues a bounded decode job, returning an async waiter.
    public func startDecode(
        from source: TTImagePreviewResource.Source,
        frameIndex: Int = 0,
        maxPixelDimension: Int,
        simulatedDelayNanoseconds: UInt64 = 0,
        token: TTImageDecodeCancelToken
    ) -> @Sendable () async -> CGImage? {
        if token.isCancelled {
            recordCancellation()
            return { nil }
        }
        let box = ResultBox()
        enqueueOrStartBox(
            token: token,
            box: box,
            operation: {
                if simulatedDelayNanoseconds > 0 {
                    Thread.sleep(forTimeInterval: Double(simulatedDelayNanoseconds) / 1_000_000_000.0)
                }
                return TTImageResolutionUpgrader.decodeCGImage(
                    from: source,
                    frameIndex: frameIndex,
                    maxPixelDimension: maxPixelDimension,
                    cancelToken: token
                )
            }
        )
        return {
            await withTaskCancellationHandler {
                await box.wait()
            } onCancel: {
                token.cancel()
            }
        }
    }

    private func enqueueOrStartBox(
        token: TTImageDecodeCancelToken,
        box: ResultBox,
        operation: @escaping @Sendable () -> CGImage?
    ) {
        lock.lock()
        if token.isCancelled {
            cancelledCount += 1
            lock.unlock()
            box.complete(nil)
            return
        }
        let jobID = nextJobID
        nextJobID &+= 1
        if activeCount < maxConcurrentDecodes {
            activeCount += 1
            peakCount = max(peakCount, activeCount)
            lock.unlock()
            launchWorker(token: token, box: box, operation: operation)
        } else {
            let job = PendingJob(id: jobID, token: token, operation: operation, box: box)
            pendingQueue.append(job)
            lock.unlock()
            token.onCancel { [weak self] in
                self?.removePendingJob(id: jobID)
            }
        }
    }

    private func launchWorker(
        token: TTImageDecodeCancelToken,
        box: ResultBox,
        operation: @escaping @Sendable () -> CGImage?
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image: CGImage? = token.isCancelled ? nil : operation()
            self?.completeWorker(wasCancelled: token.isCancelled)
            box.complete(token.isCancelled ? nil : image)
        }
    }

    private func removePendingJob(id: UInt64) {
        lock.lock()
        guard let idx = pendingQueue.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let removed = pendingQueue.remove(at: idx)
        cancelledCount += 1
        let idleWaiters = (activeCount == 0 && pendingQueue.isEmpty) ? drainIdleWaitersLocked() : []
        lock.unlock()
        removed.box.complete(nil)
        idleWaiters.forEach { $0.resume() }
    }

    private func completeWorker(wasCancelled: Bool) {
        while true {
            lock.lock()
            if wasCancelled {
                cancelledCount += 1
            }
            if !pendingQueue.isEmpty {
                let next = pendingQueue.removeFirst()
                lock.unlock()
                if next.token.isCancelled {
                    recordCancellation()
                    next.box.complete(nil)
                    continue
                }
                launchWorker(token: next.token, box: next.box, operation: next.operation)
                return
            } else {
                activeCount = max(0, activeCount - 1)
                let idleWaiters = (activeCount == 0) ? drainIdleWaitersLocked() : []
                lock.unlock()
                idleWaiters.forEach { $0.resume() }
                return
            }
        }
    }

    private func recordCancellation() {
        lock.withLock { cancelledCount += 1 }
    }

    private func drainIdleWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        let waiters = idleContinuations
        idleContinuations.removeAll()
        return waiters
    }
}

// MARK: - Unified Image Preview Resource

/// Unified image resource descriptor encapsulating an immediate preview image, backing data source,
/// and ImageIO-probed dimensional and multi-frame animation metadata.
public struct TTImagePreviewResource: @unchecked Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case fileURL(URL)
        case memoryData(Data, suggestedName: String?)
        case staticImageOnly
    }

    public let initialImage: NSImage
    public let source: Source
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameCount: Int
    public let isAnimated: Bool
    public let loopCount: Int
    public let frameDurations: [TimeInterval]

    public init(
        initialImage: NSImage,
        source: Source = .staticImageOnly,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        frameCount: Int? = nil,
        isAnimated: Bool? = nil,
        loopCount: Int? = nil,
        frameDurations: [TimeInterval]? = nil
    ) {
        self.initialImage = initialImage
        self.source = source
        let probed = TTImageSourceProbe.probe(source: source, fallbackImage: initialImage)
        let resolvedFrameCount = max(1, frameCount ?? probed.frameCount)
        self.pixelWidth = max(1, pixelWidth ?? probed.pixelWidth)
        self.pixelHeight = max(1, pixelHeight ?? probed.pixelHeight)
        self.frameCount = resolvedFrameCount
        self.isAnimated = isAnimated ?? (resolvedFrameCount > 1)
        self.loopCount = max(0, loopCount ?? probed.loopCount)
        self.frameDurations = frameDurations ?? probed.frameDurations
    }

    public init(
        image: NSImage,
        sourceURL: URL? = nil,
        sourceData: Data? = nil,
        suggestedName: String? = nil
    ) {
        let resolvedSource: Source
        if let data = sourceData {
            resolvedSource = .memoryData(data, suggestedName: suggestedName ?? sourceURL?.lastPathComponent)
        } else if let url = sourceURL {
            resolvedSource = .fileURL(url)
        } else {
            resolvedSource = .staticImageOnly
        }
        self.init(initialImage: image, source: resolvedSource)
    }

    public static func load(
        from url: URL,
        baseMaxPixelSize: CGFloat = CGFloat(TTImageResolutionUpgrader.defaultBaseMaxPixelDimension)
    ) -> TTImagePreviewResource? {
        let source = Source.fileURL(url)
        guard let baseImage = TTImageResolutionUpgrader.decodeImage(
            from: source,
            maxPixelDimension: Int(ceil(baseMaxPixelSize))
        ) else {
            return nil
        }
        return TTImagePreviewResource(initialImage: baseImage, source: source)
    }

    public static func load(
        from data: Data,
        suggestedName: String? = nil,
        baseMaxPixelSize: CGFloat = CGFloat(TTImageResolutionUpgrader.defaultBaseMaxPixelDimension)
    ) -> TTImagePreviewResource? {
        let source = Source.memoryData(data, suggestedName: suggestedName)
        guard let baseImage = TTImageResolutionUpgrader.decodeImage(
            from: source,
            maxPixelDimension: Int(ceil(baseMaxPixelSize))
        ) else {
            return nil
        }
        return TTImagePreviewResource(initialImage: baseImage, source: source)
    }

    public var pixelDimensions: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    public func loadResampledImage(maxPixelSize: CGFloat) -> NSImage? {
        TTImageResolutionUpgrader.decodeImage(from: source, maxPixelDimension: Int(ceil(maxPixelSize)))
    }

    public static func pixelSize(of image: NSImage) -> CGSize {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        for rep in image.representations where rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    public static func == (lhs: TTImagePreviewResource, rhs: TTImagePreviewResource) -> Bool {
        lhs.source == rhs.source &&
            lhs.pixelWidth == rhs.pixelWidth &&
            lhs.pixelHeight == rhs.pixelHeight &&
            lhs.frameCount == rhs.frameCount &&
            lhs.isAnimated == rhs.isAnimated &&
            lhs.loopCount == rhs.loopCount &&
            lhs.initialImage.size == rhs.initialImage.size
    }
}

// MARK: - ImageIO Probe & Animation Metadata Extractor

/// Probes `CGImageSource` and container binary headers for dimensions, frame counts, loop counts, and delays.
public enum TTImageSourceProbe: Sendable {
    public static let minimumFrameDelayThreshold: TimeInterval = 0.011
    public static let clampedDefaultFrameDelay: TimeInterval = 0.100

    public struct ProbedMetadata: Sendable, Equatable {
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let frameCount: Int
        public let loopCount: Int
        public let frameDurations: [TimeInterval]
    }

    public static func createImageSource(from source: TTImagePreviewResource.Source) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        switch source {
        case .fileURL(let url):
            return CGImageSourceCreateWithURL(url as CFURL, options)
        case .memoryData(let data, _):
            return CGImageSourceCreateWithData(data as CFData, options)
        case .staticImageOnly:
            return nil
        }
    }

    public static func probe(
        source: TTImagePreviewResource.Source,
        fallbackImage: NSImage? = nil
    ) -> ProbedMetadata {
        let fallbackSize = fallbackImage.map { TTImagePreviewResource.pixelSize(of: $0) } ?? CGSize(width: 1, height: 1)
        guard let imageSource = createImageSource(from: source) else {
            return ProbedMetadata(
                pixelWidth: max(1, Int(round(fallbackSize.width))),
                pixelHeight: max(1, Int(round(fallbackSize.height))),
                frameCount: 1,
                loopCount: 0,
                frameDurations: []
            )
        }
        let rawData = loadRawContainerDataIfSmall(from: source)
        let count = max(1, CGImageSourceGetCount(imageSource))
        let (width, height) = extractDimensions(from: imageSource, fallback: fallbackSize)
        let loopCount = extractLoopCount(from: imageSource, rawData: rawData)
        let durations: [TimeInterval]
        if count > 1 {
            let fallbackDelays = rawData.map { parseBinaryFrameDelays(from: $0, expectedCount: count) } ?? []
            durations = (0..<count).map { idx in
                let rawDelay = extractRawFrameDelay(from: imageSource, at: idx)
                    ?? (idx < fallbackDelays.count ? fallbackDelays[idx] : nil)
                return clampFrameDelay(rawDelay)
            }
        } else {
            durations = []
        }
        return ProbedMetadata(
            pixelWidth: width,
            pixelHeight: height,
            frameCount: count,
            loopCount: loopCount,
            frameDurations: durations
        )
    }

    public static func clampFrameDelay(_ rawDelay: TimeInterval?) -> TimeInterval {
        guard let delay = rawDelay, delay.isFinite, delay >= minimumFrameDelayThreshold else {
            return clampedDefaultFrameDelay
        }
        return delay
    }

    private static func extractDimensions(from imageSource: CGImageSource, fallback: CGSize) -> (Int, Int) {
        if let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           w > 0, h > 0 {
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            return (5...8).contains(orientation) ? (h, w) : (w, h)
        }
        if let containerProps = CGImageSourceCopyProperties(imageSource, nil) as? [CFString: Any],
           let w = (containerProps[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (containerProps[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           w > 0, h > 0 {
            return (w, h)
        }
        if let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
            return (max(1, cgImage.width), max(1, cgImage.height))
        }
        return (max(1, Int(round(fallback.width))), max(1, Int(round(fallback.height))))
    }

    private static func extractRawFrameDelay(from imageSource: CGImageSource, at index: Int) -> TimeInterval? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any] else {
            return nil
        }
        let dictRules: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime)
        ]
        for (dictKey, unclampedKey, clampedKey) in dictRules {
            if let dict = props[dictKey] as? [CFString: Any] {
                if let unclamped = (dict[unclampedKey] as? NSNumber)?.doubleValue, unclamped > 0 {
                    return unclamped
                }
                if let clamped = (dict[clampedKey] as? NSNumber)?.doubleValue, clamped > 0 {
                    return clamped
                }
            }
        }
        return nil
    }

    private static func extractLoopCount(from imageSource: CGImageSource, rawData: Data?) -> Int {
        let loopKeys: [(CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSLoopCount)
        ]
        let candidates: [[CFString: Any]] = [
            (CGImageSourceCopyProperties(imageSource, nil) as? [CFString: Any]) ?? [:],
            (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        ]
        for props in candidates {
            for (dictKey, loopKey) in loopKeys {
                if let dict = props[dictKey] as? [CFString: Any],
                   let loopNum = (dict[loopKey] as? NSNumber)?.intValue,
                   loopNum >= 0 {
                    return loopNum
                }
            }
        }
        return rawData.flatMap { parseBinaryLoopCount(from: $0) } ?? 0
    }

    private static func loadRawContainerDataIfSmall(from source: TTImagePreviewResource.Source) -> Data? {
        switch source {
        case .memoryData(let data, _):
            return data.count <= 16 * 1024 * 1024 ? data : nil
        case .fileURL(let url):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 && size <= 16 * 1024 * 1024 else { return nil }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        case .staticImageOnly:
            return nil
        }
    }

    private static func parseBinaryLoopCount(from data: Data) -> Int? {
        let bytes = [UInt8](data)
        if bytes.count >= 30,
           bytes[0...3] == [0x52, 0x49, 0x46, 0x46],
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            var offset = 12
            while offset + 8 <= bytes.count {
                let tag = bytes[offset..<(offset + 4)]
                let chunkSize = Int(readUInt32LE(bytes, offset + 4))
                let payloadStart = offset + 8
                if tag.elementsEqual([0x41, 0x4E, 0x49, 0x4D]), payloadStart + 6 <= bytes.count {
                    return Int(UInt16(bytes[payloadStart + 4]) | (UInt16(bytes[payloadStart + 5]) << 8))
                }
                offset = payloadStart + chunkSize + (chunkSize & 1)
            }
        }
        if bytes.count >= 24, bytes[0...7] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            var offset = 8
            while offset + 12 <= bytes.count {
                let length = Int(readUInt32BE(bytes, offset))
                let tag = bytes[(offset + 4)..<(offset + 8)]
                if tag.elementsEqual([0x61, 0x63, 0x54, 0x4C]), offset + 16 <= bytes.count {
                    return Int(readUInt32BE(bytes, offset + 12))
                }
                offset += 12 + length
            }
        }
        return nil
    }

    private static func parseBinaryFrameDelays(from data: Data, expectedCount: Int) -> [TimeInterval] {
        let bytes = [UInt8](data)
        var delays: [TimeInterval] = []
        if bytes.count >= 30,
           bytes[0...3] == [0x52, 0x49, 0x46, 0x46],
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            var offset = 12
            while offset + 8 <= bytes.count && delays.count < expectedCount {
                let tag = bytes[offset..<(offset + 4)]
                let chunkSize = Int(readUInt32LE(bytes, offset + 4))
                let payloadStart = offset + 8
                if tag.elementsEqual([0x41, 0x4E, 0x4D, 0x46]), payloadStart + 16 <= bytes.count {
                    let durationMs = UInt32(bytes[payloadStart + 12])
                        | (UInt32(bytes[payloadStart + 13]) << 8)
                        | (UInt32(bytes[payloadStart + 14]) << 16)
                    delays.append(Double(durationMs) / 1000.0)
                }
                offset = payloadStart + chunkSize + (chunkSize & 1)
            }
        }
        return delays
    }

    private static func readUInt32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt32BE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}

// MARK: - High-Res Progressive Resampling Engine

/// Memory-budgeted progressive image resolution calculator and ImageIO downsampler.
public enum TTImageResolutionUpgrader: Sendable {
    public static let defaultBaseMaxPixelDimension: Int = 2048
    public static let defaultMaxPixelDimensionCap: Int = TTImageDecodeBudget.default.maxStaticZoomDimension
    public static let defaultMaxDecodedBytes: Int = TTImageDecodeBudget.default.maxStaticZoomMemoryBytes
    public static let zoomUpgradeThreshold: CGFloat = 1.05

    public static func targetMaxPixelDimension(
        originalWidth: Int,
        originalHeight: Int,
        viewportSize: CGSize,
        backingScale: CGFloat = 2.0,
        scale: CGFloat,
        maxPixelDimensionCap: Int = defaultMaxPixelDimensionCap,
        maxDecodedBytes: Int = defaultMaxDecodedBytes
    ) -> Int {
        let safeWidth = max(1, originalWidth)
        let safeHeight = max(1, originalHeight)
        let maxOriginalDimension = max(safeWidth, safeHeight)
        let maxViewportDimension = max(1.0, max(viewportSize.width, viewportSize.height))
        let requestedDimension = Int(ceil(maxViewportDimension * max(1.0, backingScale) * max(1.0, scale)))
        var targetDimension = min(maxOriginalDimension, min(requestedDimension, max(1, maxPixelDimensionCap)))

        let scaleRatio = Double(targetDimension) / Double(maxOriginalDimension)
        let estimatedWidth = max(1, Int(round(Double(safeWidth) * scaleRatio)))
        let estimatedHeight = max(1, Int(round(Double(safeHeight) * scaleRatio)))
        let estimatedBytes = Int64(estimatedWidth) * Int64(estimatedHeight) * 4

        if estimatedBytes > Int64(max(4, maxDecodedBytes)) {
            let maxAllowedPixels = Double(max(4, maxDecodedBytes) / 4)
            let originalPixels = Double(safeWidth) * Double(safeHeight)
            let budgetRatio = sqrt(maxAllowedPixels / originalPixels)
            let budgetMaxDimension = max(1, Int(floor(Double(maxOriginalDimension) * budgetRatio)))
            targetDimension = min(targetDimension, budgetMaxDimension)
        }
        return max(1, targetDimension)
    }

    public static func decodeImage(
        from source: TTImagePreviewResource.Source,
        frameIndex: Int = 0,
        maxPixelDimension: Int = defaultBaseMaxPixelDimension,
        cancelToken: TTImageDecodeCancelToken? = nil
    ) -> NSImage? {
        guard let cgImage = decodeCGImage(
            from: source,
            frameIndex: frameIndex,
            maxPixelDimension: maxPixelDimension,
            cancelToken: cancelToken
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    public static func decodeCGImage(
        from source: TTImagePreviewResource.Source,
        frameIndex: Int = 0,
        maxPixelDimension: Int = defaultBaseMaxPixelDimension,
        cancelToken: TTImageDecodeCancelToken? = nil
    ) -> CGImage? {
        guard !isAborted(cancelToken),
              let imageSource = TTImageSourceProbe.createImageSource(from: source),
              !isAborted(cancelToken) else {
            return nil
        }
        let count = CGImageSourceGetCount(imageSource)
        guard count > 0, frameIndex >= 0, frameIndex < count else {
            return nil
        }
        let clampedMax = max(1, maxPixelDimension)
        let metadata = TTImageSourceProbe.probe(source: source)
        let maxOriginal = max(metadata.pixelWidth, metadata.pixelHeight)

        // Note: Do not pass kCGImageSourceShouldCacheImmediately to CGImageSourceCreateImageAtIndex because
        // macOS ImageIO's WebP decoder swaps R/B channels when caching immediately.
        if clampedMax >= maxOriginal,
           let directImage = CGImageSourceCreateImageAtIndex(imageSource, frameIndex, nil) {
            return isAborted(cancelToken) ? nil : normalizeToStandardRGBA(directImage)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: clampedMax
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            frameIndex,
            thumbnailOptions as CFDictionary
        ), !isAborted(cancelToken) else {
            return nil
        }
        return normalizeToStandardRGBA(thumb)
    }

    private static func isAborted(_ token: TTImageDecodeCancelToken?) -> Bool {
        (token?.isCancelled == true) || Task.isCancelled
    }

    public static func normalizeToStandardRGBA(_ image: CGImage) -> CGImage {
        let width = max(1, image.width)
        let height = max(1, image.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
