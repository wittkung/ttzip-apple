// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import MetalKit
import MetalPerformanceShaders

/// Metal fluid background renderer implementing a 3-stage offscreen pipeline
/// with single-pass R8 cache playback acceleration.
public final class MetalFluidRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue

    public let circlesPipeline: MTLRenderPipelineState
    public let blitPipeline: MTLRenderPipelineState

    public private(set) var extractCoveragePipeline: MTLRenderPipelineState?
    public private(set) var cachedBlitPipeline: MTLRenderPipelineState?

    public var frameCache: FluidFrameCache?

    private var offscreenTexture: MTLTexture?
    private var blurOutputTexture: MTLTexture?
    private var blurKernel: MPSImageGaussianBlur

    private var phase: Float = 0
    private let stateLock = NSLock()

    public var speed: Float = 0.2
    private var color1: SIMD3<Float> = SIMD3(0.176, 0.416, 0.533)
    private var color2: SIMD3<Float> = SIMD3(0.141, 0.333, 0.427)
    private var color3: SIMD3<Float> = SIMD3(0.106, 0.251, 0.322)

    public var targetColor1: SIMD3<Float> = SIMD3(0.176, 0.416, 0.533)
    public var targetColor2: SIMD3<Float> = SIMD3(0.141, 0.333, 0.427)
    public var targetColor3: SIMD3<Float> = SIMD3(0.106, 0.251, 0.322)

    public var focusMode: Float = 0.0
    public var focusProgress: Float = 0.0
    public var breathSeed: Float = 0.0

    public var backgroundColor: SIMD3<Float> = SIMD3(0, 0, 0)
    public var fluidOpacity: Float = 0.6

    public var blurSigma: Float = 45 {
        didSet {
            if blurSigma != oldValue {
                blurKernel = MPSImageGaussianBlur(device: device, sigma: blurSigma)
            }
        }
    }

    public struct FluidUniforms {
        public var phase: Float
        public var _pad: Float = 0
        public var resolution: SIMD2<Float>
        public var color1: SIMD3<Float>
        public var color2: SIMD3<Float>
        public var color3: SIMD3<Float>

        public var focusMode: Float
        public var focusProgress: Float
        public var breathSeed: Float
        public var _pad1: Float = 0.0

        public init(
            phase: Float,
            resolution: SIMD2<Float>,
            color1: SIMD3<Float>,
            color2: SIMD3<Float>,
            color3: SIMD3<Float>,
            focusMode: Float,
            focusProgress: Float,
            breathSeed: Float
        ) {
            self.phase = phase
            self._pad = 0
            self.resolution = resolution
            self.color1 = color1
            self.color2 = color2
            self.color3 = color3
            self.focusMode = focusMode
            self.focusProgress = focusProgress
            self.breathSeed = breathSeed
            self._pad1 = 0.0
        }
    }

    /// Safely locates the TTKit_TTKitFluid resource bundle without triggering
    /// SwiftPM's fatalError in Bundle.module when the bundle is missing at runtime.
    private static func resolveFluidResourceBundle() -> Bundle? {
        let bundleName = "TTKit_TTKitFluid"

        // 1. Check already-loaded bundles in current process
        for bundle in Bundle.allBundles {
            if bundle.bundleURL.lastPathComponent == "\(bundleName).bundle" ||
               bundle.bundleIdentifier?.hasSuffix(bundleName) == true {
                return bundle
            }
        }

        // 2. Probe candidate physical filesystem paths
        var candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.resourceURL?.appendingPathComponent("Resources"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"),
            Bundle(for: MetalFluidRenderer.self).resourceURL,
            Bundle(for: MetalFluidRenderer.self).bundleURL,
            Bundle(for: MetalFluidRenderer.self).bundleURL.deletingLastPathComponent(),
            Bundle(for: MetalFluidRenderer.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        ]

        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] {
            candidates.insert(URL(fileURLWithPath: override), at: 0)
        }
        #endif

        for candidate in candidates {
            guard let candidate = candidate else { continue }
            let bundleURL = candidate.appendingPathComponent("\(bundleName).bundle")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: bundleURL.path, isDirectory: &isDir),
               let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }

        return nil
    }

    private static func resolveMetalLibrary(device: MTLDevice) -> MTLLibrary? {
        if let fluidBundle = Self.resolveFluidResourceBundle(),
           let moduleLib = try? device.makeDefaultLibrary(bundle: fluidBundle),
           moduleLib.makeFunction(name: "fluidVertex") != nil {
            return moduleLib
        }
        if let defaultLib = device.makeDefaultLibrary(),
           defaultLib.makeFunction(name: "fluidVertex") != nil {
            return defaultLib
        }
        return try? device.makeLibrary(source: Self.fallbackShaderSource, options: nil)
    }

    public init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        guard let lib = Self.resolveMetalLibrary(device: device),
              let vertexFn = lib.makeFunction(name: "fluidVertex"),
              let circlesFn = lib.makeFunction(name: "fluidCirclesFragment"),
              let blitFn = lib.makeFunction(name: "blitTextureFragment")
        else { return nil }

        let circlesDesc = MTLRenderPipelineDescriptor()
        circlesDesc.vertexFunction = vertexFn
        circlesDesc.fragmentFunction = circlesFn
        circlesDesc.colorAttachments[0].pixelFormat = .rgba16Float
        circlesDesc.colorAttachments[0].isBlendingEnabled = false

        let blitDesc = MTLRenderPipelineDescriptor()
        blitDesc.vertexFunction = vertexFn
        blitDesc.fragmentFunction = blitFn
        blitDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        blitDesc.colorAttachments[0].isBlendingEnabled = true
        blitDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        blitDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        blitDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        blitDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.circlesPipeline = try device.makeRenderPipelineState(descriptor: circlesDesc)
            self.blitPipeline = try device.makeRenderPipelineState(descriptor: blitDesc)
        } catch {
            return nil
        }

        self.blurKernel = MPSImageGaussianBlur(device: device, sigma: 45)
        super.init()

        if let extractFn = lib.makeFunction(name: "extractCoverageFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = extractFn
            desc.colorAttachments[0].pixelFormat = .r8Unorm
            desc.colorAttachments[0].isBlendingEnabled = false
            self.extractCoveragePipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        if let cachedFn = lib.makeFunction(name: "blitCachedFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = cachedFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.cachedBlitPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }
    }

    public func recreateOffscreenTextures(fullSize: CGSize) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let w = max(1, Int(fullSize.width) / 4)
        let h = max(1, Int(fullSize.height) / 4)

        if let existing = offscreenTexture, existing.width == w, existing.height == h { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .private

        offscreenTexture = device.makeTexture(descriptor: desc)
        blurOutputTexture = device.makeTexture(descriptor: desc)
    }

    public var currentOffscreenTextures: (offscreen: MTLTexture, blurOutput: MTLTexture)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let o = offscreenTexture, let b = blurOutputTexture else { return nil }
        return (o, b)
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        recreateOffscreenTextures(fullSize: size)
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }

        if focusMode == 0.0, let cache = frameCache, cache.isReady {
            renderCachedFrame(drawable: drawable)
            return
        }

        guard let textures = currentOffscreenTextures else { return }
        renderFrame(
            drawable: drawable,
            offscreen: textures.offscreen,
            blurOutput: textures.blurOutput,
            screenPassDescriptor: view.currentRenderPassDescriptor
        )
    }

    public func renderFrame(
        drawable: CAMetalDrawable,
        offscreen: MTLTexture,
        blurOutput: MTLTexture,
        screenPassDescriptor: MTLRenderPassDescriptor?
    ) {
        self.phase = Float(TTKitGlobalFluidState.shared.currentPhase(speed: Double(speed)))

        let lerpFactor: Float = 1.0
        color1 += (targetColor1 - color1) * lerpFactor
        color2 += (targetColor2 - color2) * lerpFactor
        color3 += (targetColor3 - color3) * lerpFactor

        var uniforms = FluidUniforms(
            phase: phase,
            resolution: SIMD2<Float>(Float(offscreen.width), Float(offscreen.height)),
            color1: color1,
            color2: color2,
            color3: color3,
            focusMode: focusMode,
            focusProgress: focusProgress,
            breathSeed: breathSeed
        )

        var compositeParams = SIMD4<Float>(
            backgroundColor.x, backgroundColor.y, backgroundColor.z, fluidOpacity
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Pass 1: Draw circles to offscreen buffer
        let pass1Desc = MTLRenderPassDescriptor()
        pass1Desc.colorAttachments[0].texture = offscreen
        pass1Desc.colorAttachments[0].loadAction = .clear
        pass1Desc.colorAttachments[0].storeAction = .store
        pass1Desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder1 = commandBuffer.makeRenderCommandEncoder(descriptor: pass1Desc) else { return }
        encoder1.setRenderPipelineState(circlesPipeline)
        encoder1.setFragmentBytes(&uniforms, length: MemoryLayout<FluidUniforms>.stride, index: 0)
        encoder1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder1.endEncoding()

        // Pass 2: MPS Gaussian Blur
        blurKernel.encode(commandBuffer: commandBuffer, sourceTexture: offscreen, destinationTexture: blurOutput)

        // Pass 3: Blit to destination drawable
        let screenPass = screenPassDescriptor ?? {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(backgroundColor.x),
                green: Double(backgroundColor.y),
                blue: Double(backgroundColor.z),
                alpha: 1.0
            )
            return pass
        }()

        guard let encoder2 = commandBuffer.makeRenderCommandEncoder(descriptor: screenPass) else { return }
        encoder2.setRenderPipelineState(blitPipeline)
        encoder2.setFragmentTexture(blurOutput, index: 0)
        encoder2.setFragmentBytes(&compositeParams, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder2.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Cache Playback Rendering (Runtime Path)

    /// Plays back a single frame from the pre-rendered R8 cache to the drawable (~0.05ms).
    public func renderCachedFrame(drawable: CAMetalDrawable) {
        guard let cache = frameCache, cache.isReady,
              let pipeline = cachedBlitPipeline
        else { return }

        self.phase = Float(TTKitGlobalFluidState.shared.currentPhase(speed: Double(self.speed)))
        let cachedPhase = self.phase

        let lerpFactor: Float = 1.0
        color1 += (targetColor1 - color1) * lerpFactor
        color2 += (targetColor2 - color2) * lerpFactor
        color3 += (targetColor3 - color3) * lerpFactor

        guard let (frameA, frameB, blend) = cache.getFrames(elapsedPhase: cachedPhase) else { return }

        var params = SIMD4<Float>(blend, color1.x, color1.y, color1.z)
        var compositeParams = SIMD4<Float>(backgroundColor.x, backgroundColor.y, backgroundColor.z, fluidOpacity)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let screenPass = MTLRenderPassDescriptor()
        screenPass.colorAttachments[0].texture = drawable.texture
        screenPass.colorAttachments[0].loadAction = .clear
        screenPass.colorAttachments[0].storeAction = .store
        screenPass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(backgroundColor.x),
            green: Double(backgroundColor.y),
            blue: Double(backgroundColor.z),
            alpha: 1.0
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: screenPass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frameA, index: 0)
        encoder.setFragmentTexture(frameB, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&compositeParams, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static let fallbackShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct FluidUniforms {
        float phase;
        float2 resolution;
        float3 color1;
        float3 color2;
        float3 color3;
        float focusMode;
        float focusProgress;
        float breathSeed;
        float _pad1;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut fluidVertex(uint vid [[vertex_id]]) {
        float2 pos = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(pos.x, 1.0 - pos.y);
        return out;
    }

    float breathProgress(float x, float seed) {
        float base = smoothstep(0.0, 1.0, x);
        float noise = sin(x * 2.0 + seed) * 0.08;
        return clamp(base + noise, 0.0, 1.0);
    }

    fragment float4 fluidCirclesFragment(VertexOut in [[stage_in]], constant FluidUniforms &u [[buffer(0)]]) {
        float2 uv = in.uv;
        float t = u.phase;
        float aspect = u.resolution.x / u.resolution.y;

        float2 c1 = float2(0.5 + cos(t * 0.65) * 0.3,  0.5 + sin(t * 1.05) * 0.2);
        float2 c2 = float2(0.5 + sin(t * 0.45) * 0.4,  0.5 + cos(t * 0.95) * 0.3);
        float2 c3 = float2(0.5 + cos(t * 0.35) * 0.25, 0.5 + sin(t * 0.55) * 0.4);

        float baseRadius = 0.54;
        float breathScale = breathProgress(u.focusProgress, u.breathSeed);
        float r1 = mix(baseRadius, baseRadius + 0.15 * breathScale, 1.0 - u.focusMode);
        float r2 = baseRadius;
        float r3 = baseRadius;

        float2 scale_factor = (aspect > 1.0) ? float2(aspect, 1.0) : float2(1.0, 1.0 / aspect);

        float mask1_idle = step(length((uv - c1) * scale_factor), r1);
        float mask2 = step(length((uv - c2) * scale_factor), r2);
        float mask3 = step(length((uv - c3) * scale_factor), r3);

        float a1 = clamp(mask1_idle, 0.0, 1.0);
        float3 pm1 = u.color1 * a1;

        float a2 = 0.8 * mask2;
        float3 pm2 = u.color2 * a2;
        float3 rgb = pm2 + pm1 * (1.0 - a2);
        float alpha = a2 + a1 * (1.0 - a2);

        float a3 = 0.6 * mask3;
        float3 pm3 = u.color3 * a3;
        rgb = pm3 + rgb * (1.0 - a3);
        alpha = a3 + alpha * (1.0 - a3);

        float3 unmultiplied = rgb / max(alpha, 1e-5);
        return float4(unmultiplied * alpha, alpha);
    }

    fragment float4 blitTextureFragment(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float4 &compositeParams [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        float3 unmultiplied = c.rgb / max(c.a, 1e-5);
        float3 blobColor = max(unmultiplied, 0.0);
        float3 result = mix(compositeParams.xyz, blobColor, c.a * compositeParams.w);
        return float4(result, 1.0);
    }

    fragment float extractCoverageFragment(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return tex.sample(s, in.uv).a;
    }

    fragment float4 blitCachedFragment(VertexOut in [[stage_in]], texture2d<float> frameA [[texture(0)]], texture2d<float> frameB [[texture(1)]], constant float4 &params [[buffer(0)]], constant float4 &compositeParams [[buffer(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float covA = frameA.sample(s, in.uv).r;
        float covB = frameB.sample(s, in.uv).r;
        float coverage = mix(covA, covB, params.x);
        float3 result = mix(compositeParams.xyz, params.yzw, coverage * compositeParams.w);
        return float4(result, 1.0);
    }
    """
}
