// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import CoreGraphics
import Foundation
import Metal
import SwiftUI
import TTMediaDemux

// MARK: - Pyramid Tile Coordinate & Viewport Renderer

/// Canonical tile coordinate in the multi-resolution pyramid hierarchy.
public struct TTTileCoord: Hashable, Sendable, Equatable {
    public let level: UInt32
    public let x: UInt32
    public let y: UInt32

    public init(level: UInt32, x: UInt32, y: UInt32) {
        self.level = level
        self.x = x
        self.y = y
    }
}

/// Bounded-memory tile pyramid viewport renderer bridging Rust `TilePyramid` C-ABI extraction
/// and `MetalTilePipeline` GPU compositing with automatic CPU fallback.
public final class TTMetalTileViewportRenderer: @unchecked Sendable {
    public static let defaultMaxCachedTileBytes: Int = 32 * 1024 * 1024
    public static let defaultTileSize: UInt32 = 256

    private struct CachedTileEntry {
        let coord: TTTileCoord
        let sourceWidth: UInt32
        let sourceHeight: UInt32
        let width: Int
        let height: Int
        let rgbaBytes: Data
        let byteCount: Int
        var texture: (any MTLTexture)?
    }

    private let lock = NSLock()
    private let renderSerializationLock = NSLock()
    private var maxCachedTileBytesStorage: Int
    public let tileSize: UInt32
    private let makeMetalPipeline: @Sendable () throws -> MetalTilePipeline

    private var cachedPipeline: MetalTilePipeline?
    private var tileCache: [TTTileCoord: CachedTileEntry] = [:]
    private var cacheOrder: [TTTileCoord] = []
    private var currentCachedBytesStorage: Int = 0
    private var evictedCountStorage: Int = 0
    private var lastCoordsStorage: [TTTileCoord] = []
    private var lastLevelStorage: UInt32 = 0
    private var usedMetalStorage: Bool = false
    private var didFallbackStorage: Bool = false
    private var lastRenderExecutedOnMainThreadStorage: Bool = false
    private var lastViewportImageStorage: NSImage?

    private var cachedSourceWidth: Int = 0
    private var cachedSourceHeight: Int = 0
    private var cachedSourceRGBA: [UInt8] = []

    public init(
        maxCachedTileBytes: Int = TTMetalTileViewportRenderer.defaultMaxCachedTileBytes,
        tileSize: UInt32 = TTMetalTileViewportRenderer.defaultTileSize,
        makeMetalPipeline: (@Sendable () throws -> MetalTilePipeline)? = nil
    ) {
        self.maxCachedTileBytesStorage = max(4, maxCachedTileBytes)
        self.tileSize = max(1, tileSize)
        self.makeMetalPipeline = makeMetalPipeline ?? { try MetalTilePipeline() }
    }

    public var maxCachedTileBytes: Int {
        get { lock.withLock { maxCachedTileBytesStorage } }
        set {
            lock.withLock {
                maxCachedTileBytesStorage = max(4, newValue)
                evictToFitLocked(additionalBytes: 0)
            }
        }
    }

    public var cachedTileCount: Int { lock.withLock { tileCache.count } }
    public var currentCachedTileBytes: Int { lock.withLock { currentCachedBytesStorage } }
    public var evictedTileCount: Int { lock.withLock { evictedCountStorage } }
    public var lastRenderedTileCoords: [TTTileCoord] { lock.withLock { lastCoordsStorage } }
    public var lastSelectedLevel: UInt32 { lock.withLock { lastLevelStorage } }
    public var usedMetalTilePipeline: Bool { lock.withLock { usedMetalStorage } }
    public var didFallbackToCPU: Bool { lock.withLock { didFallbackStorage } }
    public var lastRenderExecutedOnMainThread: Bool { lock.withLock { lastRenderExecutedOnMainThreadStorage } }
    public var lastViewportImage: NSImage? { lock.withLock { lastViewportImageStorage } }
    public var allCachedTilesMatchCurrentSourceDimensions: Bool {
        lock.withLock {
            tileCache.values.allSatisfy {
                Int($0.sourceWidth) == cachedSourceWidth && Int($0.sourceHeight) == cachedSourceHeight
            }
        }
    }

    /// Releases all cached tile textures, tile byte buffers, and source RGBA buffers.
    public func clearCache() {
        lock.withLock {
            tileCache.removeAll()
            cacheOrder.removeAll()
            currentCachedBytesStorage = 0
            lastCoordsStorage.removeAll()
            lastViewportImageStorage = nil
            cachedSourceRGBA.removeAll()
            cachedSourceWidth = 0
            cachedSourceHeight = 0
        }
    }

    /// Plans visible pyramid tiles for the requested viewport zoom and pan offset, extracts missing tiles
    /// via the Rust C-ABI bridge, and renders the viewport via `MetalTilePipeline` (or CPU fallback).
    public func renderViewport(
        from baseCGImage: CGImage,
        viewportSize: CGSize,
        backingScale: CGFloat,
        scale: CGFloat,
        offset: CGSize,
        cancelToken: TTImageDecodeCancelToken? = nil
    ) -> NSImage? {
        renderSerializationLock.withLock {
            renderViewportSerialized(
                from: baseCGImage,
                viewportSize: viewportSize,
                backingScale: backingScale,
                scale: scale,
                offset: offset,
                cancelToken: cancelToken
            )
        }
    }

    private func renderViewportSerialized(
        from baseCGImage: CGImage,
        viewportSize: CGSize,
        backingScale: CGFloat,
        scale: CGFloat,
        offset: CGSize,
        cancelToken: TTImageDecodeCancelToken?
    ) -> NSImage? {
        guard !Self.isCancelled(cancelToken) else { return nil }
        let srcW = baseCGImage.width
        let srcH = baseCGImage.height
        guard srcW > 0, srcH > 0 else { return nil }

        guard let sourceRGBA = loadOrExtractSourceRGBA(from: baseCGImage),
              !Self.isCancelled(cancelToken) else {
            return nil
        }

        guard let (selectedLevel, plannedCoords) = planViewportCoords(
            sourceWidth: UInt32(srcW),
            sourceHeight: UInt32(srcH),
            viewportSize: viewportSize,
            scale: scale,
            offset: offset,
            backingScale: backingScale
        ), !plannedCoords.isEmpty else {
            return nil
        }

        let pipeline = resolveMetalPipeline()
        var extractedTiles: [CachedTileEntry] = []
        extractedTiles.reserveCapacity(plannedCoords.count)

        for coord in plannedCoords {
            if Self.isCancelled(cancelToken) {
                return nil
            }
            guard let entry = fetchOrExtractTile(
                coord: coord,
                sourceRGBA: sourceRGBA,
                sourceWidth: UInt32(srcW),
                sourceHeight: UInt32(srcH),
                pipeline: pipeline
            ) else {
                return nil
            }
            extractedTiles.append(entry)
        }

        guard !Self.isCancelled(cancelToken) else { return nil }
        let executedOnMainThread = Thread.isMainThread
        let viewportImage = compositeViewportTiles(
            tiles: extractedTiles,
            selectedLevel: selectedLevel,
            sourceWidth: srcW,
            sourceHeight: srcH,
            viewportSize: viewportSize,
            scale: scale,
            offset: offset,
            pipeline: pipeline
        )

        lock.withLock {
            lastLevelStorage = selectedLevel
            lastCoordsStorage = plannedCoords
            lastRenderExecutedOnMainThreadStorage = executedOnMainThread
            lastViewportImageStorage = viewportImage
        }

        return viewportImage
    }

    private static func isCancelled(_ token: TTImageDecodeCancelToken?) -> Bool {
        (token?.isCancelled == true) || Task.isCancelled
    }

    private func resolveMetalPipeline() -> MetalTilePipeline? {
        lock.lock()
        if let existing = cachedPipeline {
            lock.unlock()
            return existing
        }
        lock.unlock()

        do {
            let created = try makeMetalPipeline()
            lock.withLock { cachedPipeline = created }
            return created
        } catch {
            return nil
        }
    }

    private func loadOrExtractSourceRGBA(from cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        lock.lock()
        if cachedSourceWidth == width,
           cachedSourceHeight == height,
           cachedSourceRGBA.count == width * height * 4 {
            let copy = cachedSourceRGBA
            lock.unlock()
            return copy
        }
        lock.unlock()

        var rawData = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        lock.withLock {
            if cachedSourceWidth != width || cachedSourceHeight != height {
                tileCache.removeAll()
                cacheOrder.removeAll()
                currentCachedBytesStorage = 0
            }
            cachedSourceWidth = width
            cachedSourceHeight = height
            cachedSourceRGBA = rawData
        }
        return rawData
    }

    private func planViewportCoords(
        sourceWidth: UInt32,
        sourceHeight: UInt32,
        viewportSize: CGSize,
        scale: CGFloat,
        offset: CGSize,
        backingScale: CGFloat
    ) -> (UInt32, [TTTileCoord])? {
        let vw = Float(max(1.0, viewportSize.width))
        let vh = Float(max(1.0, viewportSize.height))
        let sc = Float(max(0.01, scale))
        let ox = Float(offset.width)
        let oy = Float(offset.height)
        let bs = Float(max(1.0, backingScale))

        var selectedLevel: UInt32 = 0
        var requiredCount: Int = 0
        let queryStatus = ttmedia_tile_pyramid_plan_viewport(
            sourceWidth, sourceHeight, tileSize,
            vw, vh, sc, ox, oy, bs,
            &selectedLevel, nil, 0, &requiredCount
        )
        guard queryStatus == TT_MEDIA_DEMUX_OK.rawValue, requiredCount > 0 else {
            return nil
        }

        var cCoords = [TTMediaTileCoord](
            repeating: TTMediaTileCoord(level: 0, x: 0, y: 0),
            count: requiredCount
        )
        let fillStatus = cCoords.withUnsafeMutableBufferPointer { buf in
            ttmedia_tile_pyramid_plan_viewport(
                sourceWidth, sourceHeight, tileSize,
                vw, vh, sc, ox, oy, bs,
                &selectedLevel, buf.baseAddress, buf.count, &requiredCount
            )
        }
        guard fillStatus == TT_MEDIA_DEMUX_OK.rawValue else {
            return nil
        }
        let coords = cCoords.prefix(requiredCount).map {
            TTTileCoord(level: $0.level, x: $0.x, y: $0.y)
        }
        return (selectedLevel, coords)
    }

    private func fetchOrExtractTile(
        coord: TTTileCoord,
        sourceRGBA: [UInt8],
        sourceWidth: UInt32,
        sourceHeight: UInt32,
        pipeline: MetalTilePipeline?
    ) -> CachedTileEntry? {
        lock.lock()
        if var hit = tileCache[coord],
           hit.sourceWidth == sourceWidth,
           hit.sourceHeight == sourceHeight,
           cachedSourceWidth == Int(sourceWidth),
           cachedSourceHeight == Int(sourceHeight) {
            touchCacheOrderLocked(for: coord)
            if hit.texture == nil, let pipeline {
                hit.texture = pipeline.makeTileTexture(
                    width: hit.width,
                    height: hit.height,
                    rgbaBytes: hit.rgbaBytes
                )
                tileCache[coord] = hit
            }
            lock.unlock()
            return hit
        }
        lock.unlock()

        let maxTileBytes = Int(tileSize) * Int(tileSize) * 4
        var tileBuffer = [UInt8](repeating: 0, count: maxTileBytes)
        var outW: UInt32 = 0
        var outH: UInt32 = 0

        let status = sourceRGBA.withUnsafeBufferPointer { srcPtr in
            tileBuffer.withUnsafeMutableBufferPointer { dstPtr in
                ttmedia_tile_pyramid_extract_tile(
                    srcPtr.baseAddress, srcPtr.count,
                    sourceWidth, sourceHeight, tileSize,
                    coord.level, coord.x, coord.y,
                    dstPtr.baseAddress, dstPtr.count,
                    &outW, &outH
                )
            }
        }
        guard status == TT_MEDIA_DEMUX_OK.rawValue, outW > 0, outH > 0 else {
            return nil
        }

        let actualByteCount = Int(outW) * Int(outH) * 4
        let tileData = Data(tileBuffer.prefix(actualByteCount))
        let texture = pipeline?.makeTileTexture(width: Int(outW), height: Int(outH), rgbaBytes: tileData)
        let entry = CachedTileEntry(
            coord: coord,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            width: Int(outW),
            height: Int(outH),
            rgbaBytes: tileData,
            byteCount: actualByteCount,
            texture: texture
        )

        lock.withLock {
            guard cachedSourceWidth == Int(sourceWidth),
                  cachedSourceHeight == Int(sourceHeight) else {
                return
            }
            insertTileIntoCacheLocked(entry)
        }
        return entry
    }

    private func insertTileIntoCacheLocked(_ entry: CachedTileEntry) {
        if let existing = tileCache.removeValue(forKey: entry.coord) {
            currentCachedBytesStorage = max(0, currentCachedBytesStorage - existing.byteCount)
            if let pos = cacheOrder.firstIndex(of: entry.coord) {
                cacheOrder.remove(at: pos)
            }
        }
        guard entry.byteCount <= maxCachedTileBytesStorage else { return }
        evictToFitLocked(additionalBytes: entry.byteCount)
        tileCache[entry.coord] = entry
        cacheOrder.append(entry.coord)
        currentCachedBytesStorage += entry.byteCount
    }

    private func evictToFitLocked(additionalBytes: Int) {
        while currentCachedBytesStorage + additionalBytes > maxCachedTileBytesStorage && !cacheOrder.isEmpty {
            let victim = cacheOrder.removeFirst()
            if let removed = tileCache.removeValue(forKey: victim) {
                currentCachedBytesStorage = max(0, currentCachedBytesStorage - removed.byteCount)
                evictedCountStorage += 1
            }
        }
    }

    private func touchCacheOrderLocked(for coord: TTTileCoord) {
        if let pos = cacheOrder.firstIndex(of: coord) {
            cacheOrder.remove(at: pos)
        }
        cacheOrder.append(coord)
    }

    private struct ViewportTargetLayout {
        let levelW: Int
        let levelH: Int
        let targetW: Int
        let targetH: Int
        let scaledW: CGFloat
        let scaledH: CGFloat
        let imgLeft: CGFloat
        let imgTop: CGFloat
    }

    private static func makeViewportTargetLayout(
        selectedLevel: UInt32,
        sourceWidth: Int,
        sourceHeight: Int,
        viewportSize: CGSize,
        scale: CGFloat,
        offset: CGSize
    ) -> ViewportTargetLayout {
        let viewportW = max(1.0, viewportSize.width)
        let viewportH = max(1.0, viewportSize.height)
        let (levelW, levelH) = levelDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            level: selectedLevel
        )
        let fitScale = min(viewportW / CGFloat(sourceWidth), viewportH / CGFloat(sourceHeight))
        let scaledPointW = max(1.0, CGFloat(sourceWidth) * fitScale * max(0.01, scale))
        let scaledPointH = max(1.0, CGFloat(sourceHeight) * fitScale * max(0.01, scale))
        let imgLeftPoints = (viewportW - scaledPointW) * 0.5 + offset.width
        let imgTopPoints = (viewportH - scaledPointH) * 0.5 + offset.height

        let texelsPerPointX = CGFloat(levelW) / scaledPointW
        let texelsPerPointY = CGFloat(levelH) / scaledPointH
        let rawTargetW = max(1.0, viewportW * texelsPerPointX)
        let rawTargetH = max(1.0, viewportH * texelsPerPointY)
        let clampFactor = min(1.0, 2048.0 / max(rawTargetW, rawTargetH))

        return ViewportTargetLayout(
            levelW: levelW,
            levelH: levelH,
            targetW: max(1, Int(round(rawTargetW * clampFactor))),
            targetH: max(1, Int(round(rawTargetH * clampFactor))),
            scaledW: max(1.0, CGFloat(levelW) * clampFactor),
            scaledH: max(1.0, CGFloat(levelH) * clampFactor),
            imgLeft: round(imgLeftPoints * texelsPerPointX * clampFactor),
            imgTop: round(imgTopPoints * texelsPerPointY * clampFactor)
        )
    }

    private func compositeViewportTiles(
        tiles: [CachedTileEntry],
        selectedLevel: UInt32,
        sourceWidth: Int,
        sourceHeight: Int,
        viewportSize: CGSize,
        scale: CGFloat,
        offset: CGSize,
        pipeline: MetalTilePipeline?
    ) -> NSImage? {
        let layout = Self.makeViewportTargetLayout(
            selectedLevel: selectedLevel,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            viewportSize: viewportSize,
            scale: scale,
            offset: offset
        )

        if let pipeline {
            var placements: [MetalTilePlacement] = []
            placements.reserveCapacity(tiles.count)
            for tile in tiles {
                guard let tex = tile.texture else { continue }
                let rect = Self.tileDestinationRect(
                    tile: tile,
                    tileSize: Int(tileSize),
                    levelWidth: layout.levelW,
                    levelHeight: layout.levelH,
                    imgLeft: layout.imgLeft,
                    imgTop: layout.imgTop,
                    scaledW: layout.scaledW,
                    scaledH: layout.scaledH
                )
                placements.append(
                    MetalTilePlacement(texture: tex, destinationRect: rect, lodLevel: selectedLevel)
                )
            }
            if !placements.isEmpty,
               let cgImage = try? pipeline.renderViewportCGImage(
                   width: layout.targetW,
                   height: layout.targetH,
                   placements: placements
               ) {
                lock.withLock {
                    usedMetalStorage = true
                    didFallbackStorage = false
                }
                return NSImage(cgImage: cgImage, size: NSSize(width: layout.targetW, height: layout.targetH))
            }
        }

        lock.withLock {
            usedMetalStorage = false
            didFallbackStorage = true
        }
        return renderCPUFallbackViewport(
            tiles: tiles,
            levelWidth: layout.levelW,
            levelHeight: layout.levelH,
            targetWidth: layout.targetW,
            targetHeight: layout.targetH,
            imgLeft: layout.imgLeft,
            imgTop: layout.imgTop,
            scaledW: layout.scaledW,
            scaledH: layout.scaledH
        )
    }

    private func renderCPUFallbackViewport(
        tiles: [CachedTileEntry],
        levelWidth: Int,
        levelHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        imgLeft: CGFloat,
        imgTop: CGFloat,
        scaledW: CGFloat,
        scaledH: CGFloat
    ) -> NSImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        for tile in tiles {
            let topDownRect = Self.tileDestinationRect(
                tile: tile,
                tileSize: Int(tileSize),
                levelWidth: levelWidth,
                levelHeight: levelHeight,
                imgLeft: imgLeft,
                imgTop: imgTop,
                scaledW: scaledW,
                scaledH: scaledH
            )
            let cgRect = CGRect(
                x: topDownRect.origin.x,
                y: CGFloat(targetHeight) - topDownRect.origin.y - topDownRect.size.height,
                width: topDownRect.size.width,
                height: topDownRect.size.height
            )
            if let tileCG = Self.makeTileCGImage(tile: tile, colorSpace: colorSpace, bitmapInfo: bitmapInfo) {
                ctx.draw(tileCG, in: cgRect)
            }
        }
        guard let outCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: outCG, size: NSSize(width: targetWidth, height: targetHeight))
    }

    private static func makeTileCGImage(
        tile: CachedTileEntry,
        colorSpace: CGColorSpace,
        bitmapInfo: UInt32
    ) -> CGImage? {
        var bytes = [UInt8](tile.rgbaBytes)
        guard let ctx = CGContext(
            data: &bytes,
            width: tile.width,
            height: tile.height,
            bitsPerComponent: 8,
            bytesPerRow: tile.width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        return ctx.makeImage()
    }

    private static func levelDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        level: UInt32
    ) -> (Int, Int) {
        let shift = min(30, Int(level))
        let scale = 1.0 / Double(1 << shift)
        let lw = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let lh = max(1, Int((Double(sourceHeight) * scale).rounded()))
        return (lw, lh)
    }

    private static func tileDestinationRect(
        tile: CachedTileEntry,
        tileSize: Int,
        levelWidth: Int,
        levelHeight: Int,
        imgLeft: CGFloat,
        imgTop: CGFloat,
        scaledW: CGFloat,
        scaledH: CGFloat
    ) -> CGRect {
        let u0 = CGFloat(Int(tile.coord.x) * tileSize) / CGFloat(max(1, levelWidth))
        let v0 = CGFloat(Int(tile.coord.y) * tileSize) / CGFloat(max(1, levelHeight))
        let uSpan = CGFloat(tile.width) / CGFloat(max(1, levelWidth))
        let vSpan = CGFloat(tile.height) / CGFloat(max(1, levelHeight))
        return CGRect(
            x: imgLeft + u0 * scaledW,
            y: imgTop + v0 * scaledH,
            width: max(1.0, uSpan * scaledW),
            height: max(1.0, vSpan * scaledH)
        )
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
