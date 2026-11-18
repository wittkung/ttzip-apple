// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreGraphics
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
    case renderEncodingFailed

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
        case .renderEncodingFailed:
            return "Failed to encode or read back Metal tile render pass."
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

/// Describes a single positioned tile texture draw call within a target viewport canvas.
public struct MetalTilePlacement: @unchecked Sendable {
    public let texture: any MTLTexture
    public let destinationRect: CGRect
    public let lodLevel: UInt32
    public let opacity: Float

    public init(
        texture: any MTLTexture,
        destinationRect: CGRect,
        lodLevel: UInt32 = 0,
        opacity: Float = 1.0
    ) {
        self.texture = texture
        self.destinationRect = destinationRect
        self.lodLevel = lodLevel
        self.opacity = opacity
    }
}

/// Metal hardware rendering pipeline for gigapixel image tiles.
public final class MetalTilePipeline: @unchecked Sendable {
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let pipelineState: any MTLRenderPipelineState
    public let samplerState: any MTLSamplerState

    private static let unitQuadVertices: [MetalTileVertex] = [
        MetalTileVertex(position: SIMD2<Float>(0, 0), uv: SIMD2<Float>(0, 0)),
        MetalTileVertex(position: SIMD2<Float>(1, 0), uv: SIMD2<Float>(1, 0)),
        MetalTileVertex(position: SIMD2<Float>(0, 1), uv: SIMD2<Float>(0, 1)),
        MetalTileVertex(position: SIMD2<Float>(1, 0), uv: SIMD2<Float>(1, 0)),
        MetalTileVertex(position: SIMD2<Float>(1, 1), uv: SIMD2<Float>(1, 1)),
        MetalTileVertex(position: SIMD2<Float>(0, 1), uv: SIMD2<Float>(0, 1))
    ]

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

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw MetalPipelineError.samplerCreationFailed
        }
        self.samplerState = sampler

        let library = try Self.loadShaderLibrary(device: device)
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

    private static func loadShaderLibrary(device: any MTLDevice) throws -> any MTLLibrary {
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
        return library
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

    /// Builds a top-left origin pixel-space orthographic projection matrix for Metal clip coordinates.
    public static func orthographicProjection(width: Float, height: Float) -> simd_float4x4 {
        let safeW = max(1.0, width)
        let safeH = max(1.0, height)
        return simd_float4x4(
            SIMD4<Float>(2.0 / safeW, 0.0, 0.0, 0.0),
            SIMD4<Float>(0.0, -2.0 / safeH, 0.0, 0.0),
            SIMD4<Float>(0.0, 0.0, 1.0, 0.0),
            SIMD4<Float>(-1.0, 1.0, 0.0, 1.0)
        )
    }

    /// Renders positioned tile textures through the Metal shader pipeline into an offscreen `.bgra8Unorm`
    /// target texture and reads back a normalized `CGImage`.
    public func renderViewportCGImage(
        width: Int,
        height: Int,
        placements: [MetalTilePlacement]
    ) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw MetalPipelineError.textureCreationFailed(width: width, height: height)
        }
        let targetDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        targetDesc.usage = [.renderTarget, .shaderRead]
        targetDesc.storageMode = .shared
        guard let targetTexture = device.makeTexture(descriptor: targetDesc) else {
            throw MetalPipelineError.textureCreationFailed(width: width, height: height)
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = targetTexture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            throw MetalPipelineError.renderEncodingFailed
        }

        encodeTilePlacements(encoder: encoder, width: width, height: height, placements: placements)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return try Self.readRGBAImage(fromBGRATexture: targetTexture, width: width, height: height)
    }

    private func encodeTilePlacements(
        encoder: any MTLRenderCommandEncoder,
        width: Int,
        height: Int,
        placements: [MetalTilePlacement]
    ) {
        let viewportF = SIMD2<Float>(Float(width), Float(height))
        let mvp = Self.orthographicProjection(width: viewportF.x, height: viewportF.y)
        var verts = Self.unitQuadVertices

        encoder.setViewport(
            MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(width),
                height: Double(height),
                znear: 0.0,
                zfar: 1.0
            )
        )
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setVertexBytes(
            &verts,
            length: MemoryLayout<MetalTileVertex>.stride * verts.count,
            index: 0
        )

        for placement in placements {
            var uniforms = MetalTileUniforms(
                mvp: mvp,
                viewportSize: viewportF,
                tileOffset: SIMD2<Float>(
                    Float(placement.destinationRect.origin.x),
                    Float(placement.destinationRect.origin.y)
                ),
                tileScale: SIMD2<Float>(
                    Float(max(1.0, placement.destinationRect.size.width)),
                    Float(max(1.0, placement.destinationRect.size.height))
                ),
                opacity: placement.opacity,
                lodLevel: Float(placement.lodLevel)
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalTileUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalTileUniforms>.stride, index: 1)
            encoder.setFragmentTexture(placement.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private static func readRGBAImage(
        fromBGRATexture texture: any MTLTexture,
        width: Int,
        height: Int
    ) throws -> CGImage {
        let bytesPerRow = width * 4
        var bgra = [UInt8](repeating: 0, count: bytesPerRow * height)
        bgra.withUnsafeMutableBytes { rawBuf in
            if let base = rawBuf.baseAddress {
                texture.getBytes(
                    base,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }
        }
        var rgba = [UInt8](repeating: 0, count: bgra.count)
        var idx = 0
        while idx + 3 < bgra.count {
            rgba[idx] = bgra[idx + 2]
            rgba[idx + 1] = bgra[idx + 1]
            rgba[idx + 2] = bgra[idx]
            rgba[idx + 3] = bgra[idx + 3]
            idx += 4
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let cgImage = ctx.makeImage() else {
            throw MetalPipelineError.renderEncodingFailed
        }
        return cgImage
    }

    /// Embedded Metal shading language source code for zero-configuration fallback.
    public static let fallbackShaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct TileVertexIn {
        float2 position;
        float2 uv;
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
