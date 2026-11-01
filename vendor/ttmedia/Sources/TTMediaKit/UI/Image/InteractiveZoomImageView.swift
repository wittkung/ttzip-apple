// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
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
        // Strict ceiling: a single frame must NEVER elevate `maxTotalAnimationMemoryBytes`.
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

/// Coordinates bounded multi-frame animation playback and progressive high-resolution zoom resampling.
@MainActor
public final class TTImagePreviewController: ObservableObject {
    public let resource: TTImagePreviewResource
    public let budget: TTImageDecodeBudget
    public let scheduler: TTImageDecodeScheduler
    public let animationController: TTAnimatedImageController?

    @Published public private(set) var displayedImage: NSImage
    @Published public private(set) var currentScale: CGFloat = 1.0
    @Published public private(set) var generation: UInt64 = 0
    @Published public private(set) var isHighResLoaded: Bool = false

    public var maxPixelDimensionCap: Int
    public var maxDecodedBytes: Int
    public var simulatedDecodeDelayNanoseconds: UInt64 = 0

    private var upgradeTask: Task<Void, Never>?
    private var activeZoomCancelToken: TTImageDecodeCancelToken?
    private var animationCancellable: AnyCancellable?
    private var currentLoadedMaxDimension: Int

    public var currentDisplayedPixelSize: CGSize { TTImagePreviewResource.pixelSize(of: displayedImage) }
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
        scheduler: TTImageDecodeScheduler? = nil
    ) {
        let resolvedScheduler = scheduler ?? TTImageDecodeScheduler(maxConcurrentDecodes: budget.maxConcurrentDecodes)
        self.resource = resource
        self.budget = budget
        self.scheduler = resolvedScheduler
        self.maxPixelDimensionCap = budget.maxStaticZoomDimension
        self.maxDecodedBytes = budget.maxStaticZoomMemoryBytes

        let initialSize = TTImagePreviewResource.pixelSize(of: resource.initialImage)
        self.currentLoadedMaxDimension = Int(max(initialSize.width, initialSize.height))

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
        revertToBaseResolution()
    }

    @discardableResult
    public func updateViewport(
        viewportSize: CGSize,
        backingScale: CGFloat = 2.0,
        scale: CGFloat
    ) -> Task<Void, Never>? {
        updateZoom(scale: scale, viewportSize: viewportSize, backingScale: backingScale)
    }

    @discardableResult
    public func updateZoom(
        scale: CGFloat,
        viewportSize: CGSize,
        backingScale: CGFloat = 2.0
    ) -> Task<Void, Never>? {
        currentScale = scale
        generation &+= 1
        let requestGeneration = generation
        cancelActiveZoomDecode()

        if scale <= TTImageResolutionUpgrader.zoomUpgradeThreshold {
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
        guard targetDimension > currentLoadedMaxDimension else {
            return nil
        }

        let token = TTImageDecodeCancelToken()
        activeZoomCancelToken = token
        let waitResult = scheduler.startDecode(
            from: resource.source,
            frameIndex: 0,
            maxPixelDimension: targetDimension,
            simulatedDelayNanoseconds: simulatedDecodeDelayNanoseconds,
            token: token
        )

        let task = Task { @MainActor [weak self] in
            let cgImage = await waitResult()
            guard !Task.isCancelled, !token.isCancelled,
                  let self = self,
                  let decodedCG = cgImage else {
                return
            }
            let highRes = NSImage(cgImage: decodedCG, size: NSSize(width: decodedCG.width, height: decodedCG.height))
            self.commitUpgradedImageIfCurrent(highRes, forGeneration: requestGeneration)
        }
        upgradeTask = task
        return task
    }

    public func commitUpgradedImageIfCurrent(_ image: NSImage, forGeneration requestGeneration: UInt64) {
        guard requestGeneration == generation,
              currentScale > TTImageResolutionUpgrader.zoomUpgradeThreshold else {
            return
        }
        displayedImage = image
        let size = TTImagePreviewResource.pixelSize(of: image)
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
        currentLoadedMaxDimension = Int(max(baseSize.width, baseSize.height))
        isHighResLoaded = false
    }
}

// MARK: - Fluid Gesture Physics Engine

/// Implements continuous non-linear rubber-banding, exponential momentum projection, and spring injection.
public enum FluidGesturePhysics: Sendable {
    /// Apple standard continuous rubber-band boundary resistance formula: f(x, d, c) = (x * d * c) / (d + c * |x|).
    public static func rubberBandClamp(
        offset: Double,
        range: ClosedRange<Double>,
        dimension: Double,
        factor: Double = 0.55
    ) -> Double {
        precondition(dimension > 0.0, "Dimension must be strictly positive.")
        if offset < range.lowerBound {
            let overscroll = range.lowerBound - offset
            let damped = (overscroll * dimension * factor) / (dimension + factor * overscroll)
            return range.lowerBound - damped
        } else if offset > range.upperBound {
            let overscroll = offset - range.upperBound
            let damped = (overscroll * dimension * factor) / (dimension + factor * overscroll)
            return range.upperBound + damped
        }
        return offset
    }

    /// Continuous exponential decay momentum projection model: project(v, d) = (v / 1000) * (d / (1 - d)).
    public static func projectMomentum(
        initialOffset: Double,
        velocity: Double,
        decelerationRate: Double = 0.998
    ) -> Double {
        guard decelerationRate > 0.0 && decelerationRate < 1.0 else { return initialOffset }
        let projectedDelta = (velocity / 1000.0) * (decelerationRate / (1.0 - decelerationRate))
        return initialOffset + projectedDelta
    }
}

// MARK: - ScrollView Appearance Configurator

/// Configures enclosing NSScrollView to overlay scrollers and clear backgrounds.
struct ConfigureNSScrollView: NSViewRepresentable {
    var onDismantle: (() -> Void)?

    init(onDismantle: (() -> Void)? = nil) {
        self.onDismantle = onDismantle
    }

    func makeNSView(context: Context) -> SmartScrollerConfiguratorView {
        SmartScrollerConfiguratorView()
    }

    func updateNSView(_ nsView: SmartScrollerConfiguratorView, context: Context) {
        nsView.configureEnclosingScrollView()
    }

    static func dismantleNSView(_ nsView: SmartScrollerConfiguratorView, coordinator: ()) {
        nsView.onDismantle?()
    }
}

@MainActor
public final class SmartScrollerConfiguratorView: NSView {
    var onDismantle: (() -> Void)?

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            onDismantle?()
        } else {
            configureTargetScrollView()
        }
    }

    public override func layout() {
        super.layout()
        configureTargetScrollView()
    }

    public func configureTargetScrollView() {
        if let target = findTargetScrollView() {
            applyClearConfiguration(to: target)
        }
    }

    public func configureEnclosingScrollView() {
        configureTargetScrollView()
    }

    private func findTargetScrollView() -> NSScrollView? {
        if let sv = enclosingScrollView { return sv }
        if let siblings = superview?.subviews {
            for sub in siblings {
                if let sv = sub as? NSScrollView { return sv }
            }
        }
        if let parentSiblings = superview?.superview?.subviews {
            for sub in parentSiblings {
                if let sv = sub as? NSScrollView { return sv }
                for inner in sub.subviews {
                    if let sv = inner as? NSScrollView { return sv }
                }
            }
        }
        return nil
    }

    private func applyClearConfiguration(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        if let doc = scrollView.documentView {
            doc.wantsLayer = true
            doc.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

// MARK: - Interactive Zoom Image View

/// Interactive zoom and pan image preview canvas supporting multi-frame animation (GIF/APNG/WebP)
/// and memory-budgeted progressive high-resolution resampling on zoom.
@MainActor
public struct InteractiveZoomImageView: View {
    public let image: NSImage
    public let resource: TTImagePreviewResource
    public let controller: TTImagePreviewController

    @ObservedObject private var observedController: TTImagePreviewController
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isHovered: Bool = false

    public init(image: NSImage) {
        let res = TTImagePreviewResource(initialImage: image, source: .staticImageOnly)
        let ctrl = TTImagePreviewController(resource: res)
        self.image = image
        self.resource = res
        self.controller = ctrl
        self.observedController = ctrl
    }

    public init(image: NSImage, sourceURL: URL? = nil, sourceData: Data? = nil) {
        let res = TTImagePreviewResource(image: image, sourceURL: sourceURL, sourceData: sourceData)
        let ctrl = TTImagePreviewController(resource: res)
        self.image = image
        self.resource = res
        self.controller = ctrl
        self.observedController = ctrl
    }

    public init(resource: TTImagePreviewResource, budget: TTImageDecodeBudget = .default) {
        let ctrl = TTImagePreviewController(resource: resource, budget: budget)
        self.image = resource.initialImage
        self.resource = resource
        self.controller = ctrl
        self.observedController = ctrl
    }

    public init(resource: TTImagePreviewResource, controller: TTImagePreviewController) {
        self.image = resource.initialImage
        self.resource = resource
        self.controller = controller
        self.observedController = controller
    }

    public var currentDisplayedPixelSize: CGSize { observedController.currentDisplayedPixelSize }
    public var currentFrameIndex: Int { observedController.currentFrameIndex }
    public var isPlayingAnimation: Bool { observedController.isPlayingAnimation }
    public var frameDurations: [TimeInterval] { observedController.frameDurations }
    public var loopCount: Int { observedController.loopCount }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                zoomScrollCanvas(geometry: geometry)
                zoomControlsHUD(geometry: geometry)
            }
            .onHover { hovering in
                isHovered = hovering
            }
            .onAppear {
                observedController.startPlaybackIfNeeded()
            }
            .onDisappear {
                observedController.dismantle()
            }
            .onChange(of: scale) { _, newScale in
                let backing = NSScreen.main?.backingScaleFactor ?? 2.0
                observedController.updateZoom(
                    scale: newScale,
                    viewportSize: geometry.size,
                    backingScale: backing
                )
            }
        }
    }

    private func zoomScrollCanvas(geometry: GeometryProxy) -> some View {
        ScrollView([.vertical, .horizontal], showsIndicators: scale > 1.05) {
            ZStack {
                Color.clear

                Image(nsImage: observedController.displayedImage)
                    .interpolation(.high)
                    .antialiased(true)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnificationGesture(geometry: geometry))
                    .simultaneousGesture(dragGesture(geometry: geometry))
                    .onTapGesture(count: 2) {
                        handleDoubleTap(geometry: geometry)
                    }
            }
            .frame(
                width: max(geometry.size.width, geometry.size.width * scale),
                height: max(geometry.size.height, geometry.size.height * scale)
            )
        }
        .background(ConfigureNSScrollView(onDismantle: {
            observedController.dismantle()
        }))
    }

    private func zoomControlsHUD(geometry: GeometryProxy) -> some View {
        HStack(spacing: 8) {
            Button(action: { stepZoom(by: -0.25, geometry: geometry) }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .ttButtonHelp("Zoom Out (-)")

            Text("\(Int(round(scale * 100)))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(TTMediaTheme.bambooGreen)
                .frame(width: 44)

            Button(action: { stepZoom(by: 0.25, geometry: geometry) }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .ttButtonHelp("Zoom In (+)")

            if scale != 1.0 || offset != .zero {
                Divider()
                    .frame(height: 12)

                Button(action: { resetZoom(geometry: geometry) }) {
                    Text("100%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .ttButtonHelp("Reset 100%")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.thinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        )
        .overlay(
            Capsule()
                .strokeBorder(TTMediaTheme.hairlineBorder, lineWidth: 0.5)
        )
        .opacity((isHovered || scale != 1.0) ? 1.0 : 0.0)
        .animation(.ttMicro, value: isHovered)
        .animation(.ttMicro, value: scale)
        .padding(12)
    }

    private func magnificationGesture(geometry: GeometryProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                let newScale = scale * delta
                if newScale < 1.0 {
                    scale = FluidGesturePhysics.rubberBandClamp(
                        offset: newScale,
                        range: 1.0...10.0,
                        dimension: 1.0,
                        factor: 0.55
                    )
                } else if newScale > 10.0 {
                    scale = FluidGesturePhysics.rubberBandClamp(
                        offset: newScale,
                        range: 1.0...10.0,
                        dimension: 2.0,
                        factor: 0.55
                    )
                } else {
                    scale = newScale
                }
            }
            .onEnded { _ in
                lastScale = 1.0
                if scale < 1.0 {
                    resetZoom(geometry: geometry)
                } else if scale > 10.0 {
                    withAnimation(.ttSnap) {
                        scale = 10.0
                    }
                }
            }
    }

    private func dragGesture(geometry: GeometryProxy) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }
                let maxOffsetX = max(0, (geometry.size.width * scale - geometry.size.width) / 2)
                let maxOffsetY = max(0, (geometry.size.height * scale - geometry.size.height) / 2)
                let rawX = lastOffset.width + value.translation.width
                let rawY = lastOffset.height + value.translation.height
                let clampedX = FluidGesturePhysics.rubberBandClamp(
                    offset: rawX,
                    range: -maxOffsetX...maxOffsetX,
                    dimension: max(1.0, geometry.size.width),
                    factor: 0.55
                )
                let clampedY = FluidGesturePhysics.rubberBandClamp(
                    offset: rawY,
                    range: -maxOffsetY...maxOffsetY,
                    dimension: max(1.0, geometry.size.height),
                    factor: 0.55
                )
                offset = CGSize(width: clampedX, height: clampedY)
            }
            .onEnded { value in
                handleDragEnded(value, geometry: geometry)
            }
    }

    private func handleDragEnded(_ value: DragGesture.Value, geometry: GeometryProxy) {
        guard scale > 1.0 else {
            withAnimation(.ttSnap) {
                offset = .zero
                lastOffset = .zero
            }
            return
        }
        let maxOffsetX = max(0, (geometry.size.width * scale - geometry.size.width) / 2)
        let maxOffsetY = max(0, (geometry.size.height * scale - geometry.size.height) / 2)
        let isBeyondX = offset.width < -maxOffsetX || offset.width > maxOffsetX
        let isBeyondY = offset.height < -maxOffsetY || offset.height > maxOffsetY

        if isBeyondX || isBeyondY {
            let targetX = min(max(offset.width, -maxOffsetX), maxOffsetX)
            let targetY = min(max(offset.height, -maxOffsetY), maxOffsetY)
            withAnimation(.ttSnap) {
                offset = CGSize(width: targetX, height: targetY)
                lastOffset = offset
            }
        } else {
            let velocityX = value.predictedEndTranslation.width - value.translation.width
            let velocityY = value.predictedEndTranslation.height - value.translation.height
            let projectedX = FluidGesturePhysics.projectMomentum(
                initialOffset: offset.width,
                velocity: velocityX * 10.0,
                decelerationRate: 0.998
            )
            let projectedY = FluidGesturePhysics.projectMomentum(
                initialOffset: offset.height,
                velocity: velocityY * 10.0,
                decelerationRate: 0.998
            )
            let settledX = min(max(projectedX, -maxOffsetX), maxOffsetX)
            let settledY = min(max(projectedY, -maxOffsetY), maxOffsetY)
            withAnimation(.ttLayout) {
                offset = CGSize(width: settledX, height: settledY)
                lastOffset = offset
            }
        }
    }

    private func handleDoubleTap(geometry: GeometryProxy) {
        if scale > 1.2 {
            resetZoom(geometry: geometry)
        } else {
            withAnimation(.ttSnap) {
                scale = 2.5
            }
        }
    }

    private func stepZoom(by delta: CGFloat, geometry: GeometryProxy) {
        withAnimation(.ttMicro) {
            scale = min(max(scale + delta, 0.5), 10.0)
            if scale <= 1.0 {
                offset = .zero
                lastOffset = .zero
            }
        }
    }

    private func resetZoom(geometry: GeometryProxy) {
        withAnimation(.ttSnap) {
            scale = 1.0
            offset = .zero
            lastOffset = .zero
        }
    }
}
