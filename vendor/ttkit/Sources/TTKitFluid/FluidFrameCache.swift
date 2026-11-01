// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import MetalKit
import MetalPerformanceShaders

// MARK: - Pre-rendered Frame Cache
//
// Core Optimization: Replaces 3-pass real-time rendering (draw -> blur -> blit)
// with one-off pre-rendering + runtime single-pass blit playback (~0.05ms).
//
// Design Invariants:
// 1. Uses n/20 discretized frequencies -> seamless loop when phase in [0, 40pi)
// 2. Pre-renders white circles -> caches coverage only (R8Unorm single channel) -> runtime tinting
// 3. 1/16 resolution + heavy blur leaves virtually no high frequencies -> lossless upsampling
// 4. Persisted to disk after first GPU pass, sub-millisecond load on subsequent boots
// 5. Matches native screen aspect ratio (W/16 x H/16), direct UV mapping

public final class FluidFrameCache: @unchecked Sendable {

    // MARK: - Shared Instance

    nonisolated(unsafe) private static var _shared: FluidFrameCache?
    private static let lock = NSLock()

    /// Retrieves or creates shared cache instance (thread-safe).
    public static func shared(device: MTLDevice) -> FluidFrameCache {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _shared { return existing }
        let cache = FluidFrameCache(device: device)
        _shared = cache
        return cache
    }

    // MARK: - Constants

    /// Total cached frames (1800 frames across 40pi phase period).
    public static let totalFrames: Int = 1800

    /// Phase step per frame = 40pi / 1800.
    public static let phaseStep: Float = Float(40.0 * .pi) / Float(totalFrames)

    /// Total phase range (40pi is the common period across all n/20 frequencies).
    public static let totalPhaseRange: Float = Float(40.0 * .pi)

    /// Disk cache format and rendered-geometry version.
    private static let cacheVersion: UInt32 = 5

    /// Disk cache magic bytes "FCCH".
    private static let cacheMagic: UInt32 = 0x46434348

    // MARK: - State

    public let device: MTLDevice

    private let stateLock = NSLock()

    private var _cacheWidth: Int = 0
    public private(set) var cacheWidth: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _cacheWidth }
        set { stateLock.lock(); defer { stateLock.unlock() }; _cacheWidth = newValue }
    }

    private var _cacheHeight: Int = 0
    public private(set) var cacheHeight: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _cacheHeight }
        set { stateLock.lock(); defer { stateLock.unlock() }; _cacheHeight = newValue }
    }

    private var _frames: [MTLTexture]?
    private var frames: [MTLTexture]? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _frames }
        set { stateLock.lock(); defer { stateLock.unlock() }; _frames = newValue }
    }

    public var isReady: Bool {
        return frames != nil
    }

    private var prerenderWorkItem: DispatchWorkItem?

    // MARK: - Initialization

    private init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Disk Cache Path

    private static func diskCachePath(width: Int, height: Int) -> URL? {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = cacheDir.appendingPathComponent("com.metastudyline.ttkit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fluid_cache_\(width)x\(height).bin")
    }

    private static func cleanupStaleDiskCaches(currentWidth: Int, currentHeight: Int) {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = cacheDir.appendingPathComponent("com.metastudyline.ttkit", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        let currentFileName = "fluid_cache_\(currentWidth)x\(currentHeight).bin"
        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix("fluid_cache_") && name.hasSuffix(".bin") && name != currentFileName {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Pre-rendering (Disk-first)

    public func needsPrerender(for screenSize: CGSize) -> Bool {
        let targetW = max(1, Int(screenSize.width) / 16)
        let targetH = max(1, Int(screenSize.height) / 16)

        if targetW != cacheWidth || targetH != cacheHeight {
            return true
        }
        return !isReady
    }

    public func prerender(
        renderer: MetalFluidRenderer,
        screenSize: CGSize,
        blurSigma: Float,
        completion: @escaping @Sendable () -> Void
    ) {
        let targetW = max(1, Int(screenSize.width) / 16)
        let targetH = max(1, Int(screenSize.height) / 16)

        if targetW == cacheWidth && targetH == cacheHeight && isReady {
            completion()
            return
        }

        self.cacheWidth = targetW
        self.cacheHeight = targetH

        guard let extractPipeline = renderer.extractCoveragePipeline else {
            return
        }

        prerenderWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.performPrerender(
                renderer: renderer,
                extractPipeline: extractPipeline,
                width: targetW,
                height: targetH,
                blurSigma: blurSigma,
                completion: completion
            )
        }

        prerenderWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func performPrerender(
        renderer: MetalFluidRenderer,
        extractPipeline: MTLRenderPipelineState,
        width: Int,
        height: Int,
        blurSigma: Float,
        completion: @escaping @Sendable () -> Void
    ) {
        if self.cacheWidth != width || self.cacheHeight != height { return }

        Self.cleanupStaleDiskCaches(currentWidth: width, currentHeight: height)

        if let diskFrames = loadFromDisk(width: width, height: height) {
            guard self.cacheWidth == width && self.cacheHeight == height else { return }
            self.frames = diskFrames
            DispatchQueue.main.async { completion() }
            return
        }

        guard let renderedFrames = gpuPrerender(
            renderer: renderer,
            extractPipeline: extractPipeline,
            width: width,
            height: height,
            blurSigma: blurSigma
        ) else { return }

        guard self.cacheWidth == width && self.cacheHeight == height else { return }

        self.frames = renderedFrames
        saveToDisk(width: width, height: height, frames: renderedFrames)

        DispatchQueue.main.async { completion() }
    }

    // MARK: - GPU Pre-rendering

    private func gpuPrerender(
        renderer: MetalFluidRenderer,
        extractPipeline: MTLRenderPipelineState,
        width: Int,
        height: Int,
        blurSigma: Float
    ) -> [MTLTexture]? {
        let circleDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        circleDesc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        circleDesc.storageMode = .private

        guard let circleTexture = device.makeTexture(descriptor: circleDesc),
              let blurOutput = device.makeTexture(descriptor: circleDesc)
        else { return nil }

        let cacheDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false
        )
        cacheDesc.usage = [.shaderRead, .renderTarget]
        cacheDesc.storageMode = .shared

        let scaledSigma = max(1.0, blurSigma / 4.0)
        let blurKernel = MPSImageGaussianBlur(device: device, sigma: scaledSigma)
        let white = SIMD3<Float>(1, 1, 1)

        var allFrames: [MTLTexture] = []
        allFrames.reserveCapacity(Self.totalFrames)

        for _ in 0..<Self.totalFrames {
            guard let tex = device.makeTexture(descriptor: cacheDesc) else { return nil }
            allFrames.append(tex)
        }

        let batchSize = 60
        var batchCount = 0

        for batchStart in stride(from: 0, to: Self.totalFrames, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, Self.totalFrames)
            guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { continue }

            for i in batchStart..<batchEnd {
                let phase = Float(i) * Self.phaseStep
                let resolution = SIMD2<Float>(Float(width), Float(height))
                var uniforms = MetalFluidRenderer.FluidUniforms(
                    phase: phase, resolution: resolution,
                    color1: white, color2: white, color3: white,
                    focusMode: 0.0, focusProgress: 0.0, breathSeed: 0.0
                )

                // Pass 1: Draw white circles
                let offscreenPass = MTLRenderPassDescriptor()
                offscreenPass.colorAttachments[0].texture = circleTexture
                offscreenPass.colorAttachments[0].loadAction = .clear
                offscreenPass.colorAttachments[0].storeAction = .store
                offscreenPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

                if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenPass) {
                    encoder.setRenderPipelineState(renderer.circlesPipeline)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalFluidRenderer.FluidUniforms>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    encoder.endEncoding()
                }

                // Pass 2: MPS Blur
                blurKernel.encode(
                    commandBuffer: commandBuffer,
                    sourceTexture: circleTexture,
                    destinationTexture: blurOutput
                )

                // Pass 3: Extract coverage -> R8
                let extractPass = MTLRenderPassDescriptor()
                extractPass.colorAttachments[0].texture = allFrames[i]
                extractPass.colorAttachments[0].loadAction = .dontCare
                extractPass.colorAttachments[0].storeAction = .store

                if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: extractPass) {
                    encoder.setRenderPipelineState(extractPipeline)
                    encoder.setFragmentTexture(blurOutput, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    encoder.endEncoding()
                }
            }

            commandBuffer.commit()
            batchCount += 1

            if batchCount % 5 == 0 || batchEnd >= Self.totalFrames {
                commandBuffer.waitUntilCompleted()
                if commandBuffer.error != nil { return nil }
            }
        }

        return allFrames
    }

    // MARK: - Disk Persistence

    private func saveToDisk(width: Int, height: Int, frames: [MTLTexture]) {
        guard let path = Self.diskCachePath(width: width, height: height) else { return }

        let bytesPerFrame = width * height
        let totalBytes = 24 + bytesPerFrame * Self.totalFrames

        var data = Data(capacity: totalBytes)

        var magic = Self.cacheMagic
        var version = Self.cacheVersion
        var w32 = UInt32(width)
        var h32 = UInt32(height)
        var f32 = UInt32(Self.totalFrames)
        var reserved: UInt32 = 0

        data.append(Data(bytes: &magic, count: 4))
        data.append(Data(bytes: &version, count: 4))
        data.append(Data(bytes: &w32, count: 4))
        data.append(Data(bytes: &h32, count: 4))
        data.append(Data(bytes: &f32, count: 4))
        data.append(Data(bytes: &reserved, count: 4))

        let region = MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                               size: .init(width: width, height: height, depth: 1))
        var rowBytes = [UInt8](repeating: 0, count: bytesPerFrame)

        for frame in frames {
            frame.getBytes(&rowBytes, bytesPerRow: width, from: region, mipmapLevel: 0)
            data.append(Data(bytes: &rowBytes, count: bytesPerFrame))
        }

        try? data.write(to: path, options: .atomic)
    }

    private func loadFromDisk(width: Int, height: Int) -> [MTLTexture]? {
        guard let path = Self.diskCachePath(width: width, height: height),
              FileManager.default.fileExists(atPath: path.path)
        else { return nil }

        guard let data = try? Data(contentsOf: path, options: .mappedIfSafe),
              data.count >= 24
        else { return nil }

        let magic: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let version: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let savedW: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        let savedH: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        let savedFrames: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }

        guard magic == Self.cacheMagic,
              version == Self.cacheVersion,
              savedW == UInt32(width),
              savedH == UInt32(height),
              savedFrames == UInt32(Self.totalFrames)
        else {
            try? FileManager.default.removeItem(at: path)
            return nil
        }

        let bytesPerFrame = width * height
        let expectedSize = 24 + bytesPerFrame * Self.totalFrames
        guard data.count >= expectedSize else {
            try? FileManager.default.removeItem(at: path)
            return nil
        }

        let cacheDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false
        )
        cacheDesc.usage = [.shaderRead]
        cacheDesc.storageMode = .shared

        let region = MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                               size: .init(width: width, height: height, depth: 1))

        var loadedFrames: [MTLTexture] = []
        loadedFrames.reserveCapacity(Self.totalFrames)

        for i in 0..<Self.totalFrames {
            guard let tex = device.makeTexture(descriptor: cacheDesc) else { return nil }
            let offset = 24 + i * bytesPerFrame
            data.withUnsafeBytes { ptr in
                let src = ptr.baseAddress!.advanced(by: offset)
                tex.replace(region: region, mipmapLevel: 0, withBytes: src, bytesPerRow: width)
            }
            loadedFrames.append(tex)
        }

        return loadedFrames
    }

    // MARK: - Frame Query

    /// Retrieves two adjacent cached frames and interpolation factor based on elapsed phase.
    public func getFrames(elapsedPhase: Float) -> (MTLTexture, MTLTexture, Float)? {
        guard let frames = self.frames, frames.count == Self.totalFrames else { return nil }

        let normalizedPhase = elapsedPhase.truncatingRemainder(dividingBy: Self.totalPhaseRange)
        let positivePhase = normalizedPhase < 0 ? normalizedPhase + Self.totalPhaseRange : normalizedPhase

        let exactIndex = positivePhase / Self.phaseStep
        let indexA = Int(exactIndex) % Self.totalFrames
        let indexB = (indexA + 1) % Self.totalFrames
        let blendFactor = exactIndex - Float(Int(exactIndex))

        return (frames[indexA], frames[indexB], blendFactor)
    }
}
