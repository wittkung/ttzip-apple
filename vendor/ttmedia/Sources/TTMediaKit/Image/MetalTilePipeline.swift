// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Metal
import simd

/// Structured error representations for the hardware-accelerated Metal pipeline.
public enum MetalPipelineError: Error, LocalizedError, Sendable {
    case deviceUnavailable
    case commandQueueCreationFailed
    case samplerCreationFailed
    case shaderLibraryNotFound(underlyingError: String?)
    case functionNotFound(name: String)
    case pipelineCreationFailed(underlyingError: String)
    case textureCreationFailed(width: Int, height: Int)

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "Metal system default device is unavailable on this hardware."
        case .commandQueueCreationFailed:
            return "Failed to allocate Metal command queue from GPU device."
        case .samplerCreationFailed:
            return "Failed to create Metal texture sampler state descriptor."
        case .shaderLibraryNotFound(let underlying):
            return "Metal shader library could not be loaded from Bundle.module or default library. \(underlying ?? "")"
        case .functionNotFound(let name):
            return "Required Metal shader function '\(name)' was not found in shader library."
        case .pipelineCreationFailed(let underlying):
            return "Failed to compile Metal render pipeline state: \(underlying)"
        case .textureCreationFailed(let width, let height):
            return "Failed to allocate 2D Metal texture with dimensions \(width)x\(height)."
        }
    }
}

/// Textured quad vertex structure matching Metal shader layout.
public struct MetalTileVertex: Sendable {
    public var position: SIMD2<Float>
    public var uv: SIMD2<Float>

    public init(position: SIMD2<Float>, uv: SIMD2<Float>) {
        self.position = position
        self.uv = uv
    }
}

/// Uniforms buffer structure matching Metal shader layout.
public struct MetalTileUniforms: Sendable {
    public var mvp: simd_float4x4
    public var viewportSize: SIMD2<Float>
    public var tileOffset: SIMD2<Float>
    public var tileScale: SIMD2<Float>
    public var opacity: Float
    public var lodLevel: Float
    public var padding: SIMD2<Float>

    public init(
        mvp: simd_float4x4 = matrix_identity_float4x4,
        viewportSize: SIMD2<Float> = SIMD2<Float>(1920, 1080),
        tileOffset: SIMD2<Float> = .zero,
        tileScale: SIMD2<Float> = SIMD2<Float>(1, 1),
        opacity: Float = 1.0,
        lodLevel: Float = 0.0
    ) {
        self.mvp = mvp
        self.viewportSize = viewportSize
        self.tileOffset = tileOffset
        self.tileScale = tileScale
        self.opacity = opacity
        self.lodLevel = lodLevel
        self.padding = .zero
    }
}

/// Metal hardware rendering pipeline for gigapixel image tiles.
public final class MetalTilePipeline: @unchecked Sendable {
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let pipelineState: any MTLRenderPipelineState
    public let samplerState: any MTLSamplerState

    /// Initializes the Metal pipeline, throwing structured errors on any GPU resource failure.
    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw MetalPipelineError.deviceUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalPipelineError.commandQueueCreationFailed
        }
        self.device = device
        self.commandQueue = commandQueue

        // Build texture sampler descriptor
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw MetalPipelineError.samplerCreationFailed
        }
        self.samplerState = sampler

        // Compile pipeline state with robust Bundle.module fallback
        var library: (any MTLLibrary)?
        var lastLibraryError: (any Error)?

        #if SWIFT_PACKAGE
        do {
            library = try device.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            lastLibraryError = error
        }
        #endif

        if library == nil {
            library = device.makeDefaultLibrary()
        }

        // Fallback: compile from inlined Metal shader source if precompiled metallib is unavailable
        if library == nil {
            do {
                library = try device.makeLibrary(source: Self.fallbackShaderSource, options: nil)
            } catch {
                lastLibraryError = error
            }
        }

        guard let library else {
            throw MetalPipelineError.shaderLibraryNotFound(underlyingError: lastLibraryError?.localizedDescription)
        }

        guard let vertexFunc = library.makeFunction(name: "tileVertexShader") else {
            throw MetalPipelineError.functionNotFound(name: "tileVertexShader")
        }
        guard let fragFunc = library.makeFunction(name: "tileFragmentShader") else {
            throw MetalPipelineError.functionNotFound(name: "tileFragmentShader")
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragFunc
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDesc.colorAttachments[0].isBlendingEnabled = true
        pipelineDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            throw MetalPipelineError.pipelineCreationFailed(underlyingError: error.localizedDescription)
        }
    }

    /// Uploads an RGBA8 tile pixel buffer to a Metal texture with explicit error reporting.
    public func createTileTexture(width: Int, height: Int, rgbaBytes: Data) throws -> any MTLTexture {
        guard width > 0, height > 0 else {
            throw MetalPipelineError.textureCreationFailed(width: width, height: height)
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw MetalPipelineError.textureCreationFailed(width: width, height: height)
        }

        rgbaBytes.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                let region = MTLRegionMake2D(0, 0, width, height)
                texture.replace(
                    region: region,
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: width * 4
                )
            }
        }

        return texture
    }

    /// Convenience failable helper uploading tile pixel buffers without throwing.
    public func makeTileTexture(width: Int, height: Int, rgbaBytes: Data) -> (any MTLTexture)? {
        try? createTileTexture(width: width, height: height, rgbaBytes: rgbaBytes)
    }

    /// Embedded Metal shading language source code for zero-configuration fallback.
    public static let fallbackShaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct TileVertexIn {
        float2 position [[attribute(0)]];
        float2 uv [[attribute(1)]];
    };

    struct TileVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct TileUniforms {
        float4x4 mvp;
        float2 viewportSize;
        float2 tileOffset;
        float2 tileScale;
        float opacity;
        float lodLevel;
        float2 _padding;
    };

    vertex TileVertexOut tileVertexShader(
        uint vertexID [[vertex_id]],
        constant TileVertexIn* vertices [[buffer(0)]],
        constant TileUniforms& uniforms [[buffer(1)]]
    ) {
        TileVertexOut out;
        TileVertexIn in = vertices[vertexID];
        float2 localPos = in.position * uniforms.tileScale + uniforms.tileOffset;
        out.position = uniforms.mvp * float4(localPos, 0.0, 1.0);
        out.uv = in.uv;
        return out;
    }

    fragment float4 tileFragmentShader(
        TileVertexOut in [[stage_in]],
        texture2d<float> tileTexture [[texture(0)]],
        sampler tileSampler [[sampler(0)]],
        constant TileUniforms& uniforms [[buffer(1)]]
    ) {
        float4 color = tileTexture.sample(tileSampler, in.uv);
        color.a *= uniforms.opacity;
        return color;
    }
    """
}
