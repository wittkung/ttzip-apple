// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Combine

// MARK: - Bounded-Memory Multi-Frame Animation Controller

/// Deterministic `CGImageSource`-backed multi-frame animation player with a bounded LRU/FIFO frame cache
/// and on-demand background frame decoding. Never decodes all frames on `@MainActor` initialization.
@MainActor
public final class TTAnimatedImageController: ObservableObject {
    private struct CachedFrame {
        let image: NSImage
        let cgImage: CGImage
        let byteCount: Int
    }

    @Published public private(set) var currentFrameIndex: Int = 0
    @Published public private(set) var currentFrameImage: NSImage
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var completedLoops: Int = 0
    @Published public private(set) var currentCachedMemoryBytes: Int = 0
    @Published public private(set) var evictedFrameCount: Int = 0
    @Published public private(set) var oversizedUncachedFrameCount: Int = 0
    @Published public private(set) var rejectedOversizedFrameCount: Int = 0

    public let resource: TTImagePreviewResource
    public let budget: TTImageDecodeBudget
    public let scheduler: TTImageDecodeScheduler
    public let frameDurations: [TimeInterval]
    public let loopCount: Int
    public let frameCount: Int

    private var frameCache: [Int: CachedFrame] = [:]
    private var cacheOrder: [Int] = []
    private var playbackTask: Task<Void, Never>?
    private var activeDecodeToken: TTImageDecodeCancelToken?

    public var cachedFrameCount: Int { frameCache.count }

    public init?(
        resource: TTImagePreviewResource,
        budget: TTImageDecodeBudget = .default,
        scheduler: TTImageDecodeScheduler = .shared
    ) {
        guard resource.frameCount > 1 else { return nil }
        self.resource = resource
        self.budget = budget
        self.scheduler = scheduler
        self.frameCount = resource.frameCount
        self.currentFrameImage = resource.initialImage
        self.loopCount = max(0, resource.loopCount)
        if resource.frameDurations.count == resource.frameCount {
            self.frameDurations = resource.frameDurations.map { TTImageSourceProbe.clampFrameDelay($0) }
        } else {
            self.frameDurations = Array(
                repeating: TTImageSourceProbe.clampedDefaultFrameDelay,
                count: resource.frameCount
            )
        }
    }

    /// Asynchronously loads a single frame through the bounded concurrency scheduler and enforces `budget`.
    public func loadFrameImage(at index: Int) async -> NSImage? {
        let safeIndex = max(0, min(index, frameCount - 1))
        if let hit = frameCache[safeIndex] {
            touchCacheOrder(for: safeIndex)
            return hit.image
        }
        let token = TTImageDecodeCancelToken()
        activeDecodeToken?.cancel()
        activeDecodeToken = token
        let targetMaxDimension = budget.effectiveAnimatedFrameDimension(
            originalWidth: resource.pixelWidth,
            originalHeight: resource.pixelHeight
        )
        let cgImage = await scheduler.decodeCGImage(
            from: resource.source,
            frameIndex: safeIndex,
            maxPixelDimension: targetMaxDimension,
            token: token
        )
        guard !Task.isCancelled, !token.isCancelled, let decodedCG = cgImage else {
            return nil
        }
        return resolveDecodedFrame(cgImage: decodedCG, for: safeIndex)
    }

    public func startPlayback() {
        guard frameCount > 1, !isPlaying else { return }
        if loopCount > 0 && completedLoops >= loopCount {
            completedLoops = 0
            currentFrameIndex = 0
        }
        isPlaying = true
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.isPlaying else { break }
                let delay = self.frameDurations[self.currentFrameIndex]
                try? await Task.sleep(nanoseconds: UInt64(max(0.011, delay) * 1_000_000_000))
                guard !Task.isCancelled, self.isPlaying else { break }
                await self.advanceFrameAsync()
            }
        }
    }

    public func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        activeDecodeToken?.cancel()
        activeDecodeToken = nil
        isPlaying = false
    }

    public func dismantle() {
        stopPlayback()
        releaseCachedFrames()
    }

    public func releaseCachedFrames() {
        frameCache.removeAll()
        cacheOrder.removeAll()
        currentCachedMemoryBytes = 0
        currentFrameImage = resource.initialImage
    }

    public func resetPlayback() {
        stopPlayback()
        currentFrameIndex = 0
        completedLoops = 0
        currentFrameImage = frameCache[0]?.image ?? resource.initialImage
    }

    public func advanceFrameAsync() async {
        guard frameCount > 1, let targetIndex = stepTargetFrameIndex() else { return }
        if let image = await loadFrameImage(at: targetIndex) {
            currentFrameIndex = targetIndex
            currentFrameImage = image
        } else if !Task.isCancelled {
            currentFrameIndex = targetIndex
        }
    }

    private func stepTargetFrameIndex() -> Int? {
        let nextIndex = currentFrameIndex + 1
        if nextIndex < frameCount {
            return nextIndex
        }
        completedLoops += 1
        if loopCount > 0 && completedLoops >= loopCount {
            stopPlayback()
            return nil
        }
        return 0
    }

    private func touchCacheOrder(for index: Int) {
        if let pos = cacheOrder.firstIndex(of: index) {
            cacheOrder.remove(at: pos)
        }
        cacheOrder.append(index)
    }

    private func resolveDecodedFrame(cgImage: CGImage, for index: Int) -> NSImage? {
        let byteCount = max(4, cgImage.width * cgImage.height * 4)
        if let existing = frameCache.removeValue(forKey: index) {
            currentCachedMemoryBytes = max(0, currentCachedMemoryBytes - existing.byteCount)
            if let pos = cacheOrder.firstIndex(of: index) {
                cacheOrder.remove(at: pos)
            }
        }
        let maxBytes = budget.maxTotalAnimationMemoryBytes
        if byteCount > maxBytes {
            if budget.oversizedAnimatedFramePolicy == .rejectFrame {
                rejectedOversizedFrameCount += 1
                return nil
            }
            oversizedUncachedFrameCount += 1
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        while currentCachedMemoryBytes + byteCount > maxBytes && !cacheOrder.isEmpty {
            let victimIndex = cacheOrder.removeFirst()
            if let removed = frameCache.removeValue(forKey: victimIndex) {
                currentCachedMemoryBytes = max(0, currentCachedMemoryBytes - removed.byteCount)
                evictedFrameCount += 1
            }
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let entry = CachedFrame(image: image, cgImage: cgImage, byteCount: byteCount)
        frameCache[index] = entry
        cacheOrder.append(index)
        currentCachedMemoryBytes += byteCount
        return image
    }
}

// MARK: - Unified Image Preview Controller

/// Coordinates bounded multi-frame animation playback, Rust tile pyramid extraction, and Metal viewport rendering.
@MainActor
public final class TTImagePreviewController: ObservableObject {
    public let resource: TTImagePreviewResource
    public let budget: TTImageDecodeBudget
    public let scheduler: TTImageDecodeScheduler
    public let tileRenderer: TTMetalTileViewportRenderer
    public let animationController: TTAnimatedImageController?

    @Published public private(set) var displayedImage: NSImage
    @Published public private(set) var currentScale: CGFloat = 1.0
    @Published public private(set) var currentOffset: CGSize = .zero
    @Published public private(set) var currentViewportSize: CGSize = .zero
    @Published public private(set) var currentBackingScale: CGFloat = 2.0
    @Published public private(set) var generation: UInt64 = 0
    @Published public private(set) var isHighResLoaded: Bool = false

    public var maxPixelDimensionCap: Int
    public var maxDecodedBytes: Int
    public var simulatedDecodeDelayNanoseconds: UInt64 = 0

    private var upgradeTask: Task<Void, Never>?
    private var activeZoomCancelToken: TTImageDecodeCancelToken?
    private var animationCancellable: AnyCancellable?
    private var currentLoadedMaxDimension: Int
    private var currentLoadedPixelSize: CGSize

    public var currentDisplayedPixelSize: CGSize {
        isHighResLoaded ? currentLoadedPixelSize : TTImagePreviewResource.pixelSize(of: displayedImage)
    }
    public var currentFrameIndex: Int { animationController?.currentFrameIndex ?? 0 }
    public var isPlayingAnimation: Bool { animationController?.isPlaying ?? false }
    public var frameDurations: [TimeInterval] { animationController?.frameDurations ?? resource.frameDurations }
    public var loopCount: Int { animationController?.loopCount ?? resource.loopCount }
    public var activeDecodeCount: Int { scheduler.activeDecodeCount }
    public var peakConcurrentDecodeCount: Int { scheduler.peakConcurrentDecodeCount }
    public var cancelledDecodeCount: Int { scheduler.cancelledDecodeCount }

    public init(
        resource: TTImagePreviewResource,
        budget: TTImageDecodeBudget = .default,
        scheduler: TTImageDecodeScheduler? = nil,
        tileRenderer: TTMetalTileViewportRenderer? = nil
    ) {
        let resolvedScheduler = scheduler ?? TTImageDecodeScheduler(maxConcurrentDecodes: budget.maxConcurrentDecodes)
        self.resource = resource
        self.budget = budget
        self.scheduler = resolvedScheduler
        self.tileRenderer = tileRenderer ?? TTMetalTileViewportRenderer()
        self.maxPixelDimensionCap = budget.maxStaticZoomDimension
        self.maxDecodedBytes = budget.maxStaticZoomMemoryBytes

        let initialSize = TTImagePreviewResource.pixelSize(of: resource.initialImage)
        self.currentLoadedMaxDimension = Int(max(initialSize.width, initialSize.height))
        self.currentLoadedPixelSize = initialSize

        if resource.isAnimated,
           let anim = TTAnimatedImageController(resource: resource, budget: budget, scheduler: resolvedScheduler) {
            self.animationController = anim
            self.displayedImage = anim.currentFrameImage
            self.animationCancellable = anim.$currentFrameImage
                .sink { [weak self] newFrame in
                    self?.displayedImage = newFrame
                }
        } else {
            self.animationController = nil
            self.displayedImage = resource.initialImage
        }
    }

    public func startPlaybackIfNeeded() {
        animationController?.startPlayback()
    }

    public func stopPlayback() {
        animationController?.stopPlayback()
        cancelActiveZoomDecode()
    }

    public func dismantle() {
        animationController?.dismantle()
        resetToBaseImage()
    }

    public func resetToBaseImage() {
        generation &+= 1
        cancelActiveZoomDecode()
        currentScale = 1.0
        currentOffset = .zero
        currentViewportSize = .zero
        tileRenderer.clearCache()
        revertToBaseResolution()
    }

    @discardableResult
    public func updateViewport(
        viewportSize: CGSize,
        backingScale: CGFloat = 2.0,
        scale: CGFloat,
        offset: CGSize = .zero
    ) -> Task<Void, Never>? {
        updateZoom(
            scale: scale,
            viewportSize: viewportSize,
            backingScale: backingScale,
            offset: offset
        )
    }

    @discardableResult
    public func updateZoom(
        scale: CGFloat,
        viewportSize: CGSize,
        backingScale: CGFloat = 2.0,
        offset: CGSize = .zero
    ) -> Task<Void, Never>? {
        let scaleChanged = (scale != currentScale)
        let offsetChanged = (offset != currentOffset)
        let viewportChanged = (viewportSize != currentViewportSize) || (backingScale != currentBackingScale)
        currentScale = scale
        currentOffset = offset
        currentViewportSize = viewportSize
        currentBackingScale = backingScale
        generation &+= 1
        let requestGeneration = generation
        cancelActiveZoomDecode()

        if scale <= TTImageResolutionUpgrader.zoomUpgradeThreshold {
            tileRenderer.clearCache()
            revertToBaseResolution()
            return nil
        }
        guard !resource.isAnimated, resource.source != .staticImageOnly else {
            return nil
        }
        let targetDimension = TTImageResolutionUpgrader.targetMaxPixelDimension(
            originalWidth: resource.pixelWidth,
            originalHeight: resource.pixelHeight,
            viewportSize: viewportSize,
            backingScale: backingScale,
            scale: scale,
            maxPixelDimensionCap: maxPixelDimensionCap,
            maxDecodedBytes: maxDecodedBytes
        )
        guard targetDimension > currentLoadedMaxDimension
                || scaleChanged
                || offsetChanged
                || viewportChanged
                || tileRenderer.lastRenderedTileCoords.isEmpty else {
            return nil
        }
        return dispatchZoomDecodeTask(
            targetDimension: targetDimension,
            viewportSize: viewportSize,
            backingScale: backingScale,
            scale: scale,
            offset: offset,
            requestGeneration: requestGeneration
        )
    }

    private func dispatchZoomDecodeTask(
        targetDimension: Int,
        viewportSize: CGSize,
        backingScale: CGFloat,
        scale: CGFloat,
        offset: CGSize,
        requestGeneration: UInt64
    ) -> Task<Void, Never> {
        let token = TTImageDecodeCancelToken()
        activeZoomCancelToken = token
        let renderer = tileRenderer
        let waitResult = scheduler.startDecode(
            from: resource.source,
            frameIndex: 0,
            maxPixelDimension: targetDimension,
            simulatedDelayNanoseconds: simulatedDecodeDelayNanoseconds,
            token: token
        )

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let cgImage = await waitResult()
            guard !Task.isCancelled, !token.isCancelled,
                  let decodedCG = cgImage else {
                return
            }
            let decodedSize = CGSize(width: decodedCG.width, height: decodedCG.height)
            guard let highRes = renderer.renderViewport(
                from: decodedCG,
                viewportSize: viewportSize,
                backingScale: backingScale,
                scale: scale,
                offset: offset,
                cancelToken: token
            ), !Task.isCancelled, !token.isCancelled else {
                return
            }
            await MainActor.run { [weak self] in
                self?.commitUpgradedImageIfCurrent(
                    highRes,
                    decodedPixelSize: decodedSize,
                    forGeneration: requestGeneration
                )
            }
        }
        upgradeTask = task
        return task
    }

    public func commitUpgradedImageIfCurrent(
        _ image: NSImage,
        decodedPixelSize: CGSize? = nil,
        forGeneration requestGeneration: UInt64
    ) {
        guard requestGeneration == generation,
               currentScale > TTImageResolutionUpgrader.zoomUpgradeThreshold else {
            return
        }
        displayedImage = image
        let size = decodedPixelSize ?? TTImagePreviewResource.pixelSize(of: image)
        currentLoadedPixelSize = size
        currentLoadedMaxDimension = Int(max(size.width, size.height))
        isHighResLoaded = true
    }

    private func cancelActiveZoomDecode() {
        activeZoomCancelToken?.cancel()
        activeZoomCancelToken = nil
        upgradeTask?.cancel()
        upgradeTask = nil
    }

    private func revertToBaseResolution() {
        guard !resource.isAnimated else { return }
        displayedImage = resource.initialImage
        let baseSize = TTImagePreviewResource.pixelSize(of: resource.initialImage)
        currentLoadedPixelSize = baseSize
        currentLoadedMaxDimension = Int(max(baseSize.width, baseSize.height))
        isHighResLoaded = false
    }
}
