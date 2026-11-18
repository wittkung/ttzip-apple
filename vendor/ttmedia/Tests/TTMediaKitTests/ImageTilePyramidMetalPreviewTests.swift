// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import TTMediaDemux
@testable import TTMediaKit

@MainActor
final class ImageTilePyramidMetalPreviewTests: XCTestCase {

    private struct RGBAPixel: Equatable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
    }

    private func samplePixel(in image: NSImage, x: Int, y: Int) -> RGBAPixel? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return samplePixel(in: cgImage, x: x, y: y)
    }

    private func samplePixel(in cgImage: CGImage, x: Int, y: Int) -> RGBAPixel? {
        let width = cgImage.width
        let height = cgImage.height
        guard x >= 0, x < width, y >= 0, y < height else { return nil }

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
        let offset = (y * width + x) * 4
        return RGBAPixel(
            r: rawData[offset],
            g: rawData[offset + 1],
            b: rawData[offset + 2],
            a: rawData[offset + 3]
        )
    }

    private func makeFourQuadrantRGBABytes(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let halfW = width / 2
        let halfH = height / 2
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let isLeft = x < halfW
                let isTop = y < halfH
                if isTop && isLeft {
                    pixels[idx] = 255
                    pixels[idx + 1] = 0
                    pixels[idx + 2] = 0
                    pixels[idx + 3] = 255
                } else if isTop && !isLeft {
                    pixels[idx] = 0
                    pixels[idx + 1] = 255
                    pixels[idx + 2] = 0
                    pixels[idx + 3] = 255
                } else if !isTop && isLeft {
                    pixels[idx] = 0
                    pixels[idx + 1] = 0
                    pixels[idx + 2] = 255
                    pixels[idx + 3] = 255
                } else {
                    pixels[idx] = 255
                    pixels[idx + 1] = 255
                    pixels[idx + 2] = 0
                    pixels[idx + 3] = 255
                }
            }
        }
        return pixels
    }

    private func makeFourQuadrantPNGData(width: Int = 2048, height: Int = 1536) -> Data {
        var pixels = makeFourQuadrantRGBABytes(width: width, height: height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        let cgImage = ctx.makeImage()!
        let outData = NSMutableData()
        let dest = CGImageDestinationCreateWithData(outData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return outData as Data
    }

    func testRustCABITilePyramidPlanViewportAcrossLevelsAndOffsets() {
        let srcW: UInt32 = 1024
        let srcH: UInt32 = 768
        let tileSize: UInt32 = 256

        var level1: UInt32 = 0
        var count1: Int = 0
        let statusQuery1 = ttmedia_tile_pyramid_plan_viewport(
            srcW, srcH, tileSize,
            512, 384, 1.0, 0, 0, 1.0,
            &level1, nil, 0, &count1
        )
        XCTAssertEqual(statusQuery1, TT_MEDIA_DEMUX_OK.rawValue)
        XCTAssertEqual(level1, 1)
        XCTAssertGreaterThan(count1, 0)

        var topLeftLevel: UInt32 = 99
        var topLeftCount: Int = 0
        var topLeftCoords = [TTMediaTileCoord](
            repeating: TTMediaTileCoord(level: 0, x: 0, y: 0),
            count: 16
        )
        let statusTL = topLeftCoords.withUnsafeMutableBufferPointer { buf in
            ttmedia_tile_pyramid_plan_viewport(
                srcW, srcH, tileSize,
                512, 384, 3.0, 512, 384, 1.0,
                &topLeftLevel, buf.baseAddress, buf.count, &topLeftCount
            )
        }
        XCTAssertEqual(statusTL, TT_MEDIA_DEMUX_OK.rawValue)
        XCTAssertEqual(topLeftLevel, 0)
        let tlSet = Set(topLeftCoords.prefix(topLeftCount).map { TTTileCoord(level: $0.level, x: $0.x, y: $0.y) })
        XCTAssertTrue(tlSet.contains(TTTileCoord(level: 0, x: 0, y: 0)))
        XCTAssertFalse(tlSet.contains(TTTileCoord(level: 0, x: 3, y: 2)))

        var bottomRightLevel: UInt32 = 99
        var bottomRightCount: Int = 0
        var bottomRightCoords = [TTMediaTileCoord](
            repeating: TTMediaTileCoord(level: 0, x: 0, y: 0),
            count: 16
        )
        let statusBR = bottomRightCoords.withUnsafeMutableBufferPointer { buf in
            ttmedia_tile_pyramid_plan_viewport(
                srcW, srcH, tileSize,
                512, 384, 3.0, -512, -384, 1.0,
                &bottomRightLevel, buf.baseAddress, buf.count, &bottomRightCount
            )
        }
        XCTAssertEqual(statusBR, TT_MEDIA_DEMUX_OK.rawValue)
        XCTAssertEqual(bottomRightLevel, 0)
        let brSet = Set(bottomRightCoords.prefix(bottomRightCount).map { TTTileCoord(level: $0.level, x: $0.x, y: $0.y) })
        XCTAssertTrue(brSet.contains(TTTileCoord(level: 0, x: 3, y: 2)))
        XCTAssertFalse(brSet.contains(TTTileCoord(level: 0, x: 0, y: 0)))
    }

    func testRustCABITilePyramidExtractTileAndInvalidInputValidation() {
        let srcW: UInt32 = 1024
        let srcH: UInt32 = 768
        let tileSize: UInt32 = 256
        let rgba = makeFourQuadrantRGBABytes(width: Int(srcW), height: Int(srcH))
        var tileBuf = [UInt8](repeating: 0, count: Int(tileSize * tileSize * 4))
        var outW: UInt32 = 0
        var outH: UInt32 = 0

        let extractL0Status = rgba.withUnsafeBufferPointer { srcPtr in
            tileBuf.withUnsafeMutableBufferPointer { dstPtr in
                ttmedia_tile_pyramid_extract_tile(
                    srcPtr.baseAddress, srcPtr.count,
                    srcW, srcH, tileSize,
                    0, 3, 2,
                    dstPtr.baseAddress, dstPtr.count,
                    &outW, &outH
                )
            }
        }
        XCTAssertEqual(extractL0Status, TT_MEDIA_DEMUX_OK.rawValue)
        XCTAssertEqual(outW, 256)
        XCTAssertEqual(outH, 256)
        XCTAssertEqual(tileBuf[0], 255)
        XCTAssertEqual(tileBuf[1], 255)
        XCTAssertEqual(tileBuf[2], 0)
        XCTAssertEqual(tileBuf[3], 255)

        let extractL1Status = rgba.withUnsafeBufferPointer { srcPtr in
            tileBuf.withUnsafeMutableBufferPointer { dstPtr in
                ttmedia_tile_pyramid_extract_tile(
                    srcPtr.baseAddress, srcPtr.count,
                    srcW, srcH, tileSize,
                    1, 1, 0,
                    dstPtr.baseAddress, dstPtr.count,
                    &outW, &outH
                )
            }
        }
        XCTAssertEqual(extractL1Status, TT_MEDIA_DEMUX_OK.rawValue)
        XCTAssertEqual(outW, 256)
        XCTAssertEqual(outH, 256)
        XCTAssertEqual(tileBuf[0], 0)
        XCTAssertEqual(tileBuf[1], 255)
        XCTAssertEqual(tileBuf[2], 0)
        XCTAssertEqual(tileBuf[3], 255)

        let truncatedStatus = rgba.withUnsafeBufferPointer { srcPtr in
            tileBuf.withUnsafeMutableBufferPointer { dstPtr in
                ttmedia_tile_pyramid_extract_tile(
                    srcPtr.baseAddress, 1024,
                    srcW, srcH, tileSize,
                    0, 0, 0,
                    dstPtr.baseAddress, dstPtr.count,
                    &outW, &outH
                )
            }
        }
        XCTAssertEqual(truncatedStatus, TT_MEDIA_DEMUX_ERR_INVALID_ARGUMENT.rawValue)

        let smallCapStatus = rgba.withUnsafeBufferPointer { srcPtr in
            tileBuf.withUnsafeMutableBufferPointer { dstPtr in
                ttmedia_tile_pyramid_extract_tile(
                    srcPtr.baseAddress, srcPtr.count,
                    srcW, srcH, tileSize,
                    0, 0, 0,
                    dstPtr.baseAddress, 64,
                    &outW, &outH
                )
            }
        }
        XCTAssertEqual(smallCapStatus, TT_MEDIA_DEMUX_ERR_OUT_OF_MEMORY.rawValue)
    }

    func testImagePreviewControllerMetalTilePipelinePanAndPixelFidelity() async throws {
        let pngData = makeFourQuadrantPNGData(width: 2048, height: 1536)
        let resource = try XCTUnwrap(
            TTImagePreviewResource.load(from: pngData, suggestedName: "quadrants.png", baseMaxPixelSize: 1024)
        )
        let controller = TTImagePreviewController(resource: resource)
        let viewport = CGSize(width: 800, height: 600)

        let topLeftTask = controller.updateViewport(
            viewportSize: viewport,
            backingScale: 2.0,
            scale: 3.0,
            offset: CGSize(width: 800, height: 600)
        )
        await topLeftTask?.value

        XCTAssertTrue(controller.isHighResLoaded)
        XCTAssertTrue(controller.tileRenderer.usedMetalTilePipeline)
        XCTAssertFalse(controller.tileRenderer.didFallbackToCPU)
        XCTAssertFalse(
            controller.tileRenderer.lastRenderExecutedOnMainThread,
            "Tile extraction and Metal viewport compositing must run off @MainActor"
        )
        XCTAssertEqual(controller.tileRenderer.lastSelectedLevel, 0)
        let topLeftCoords = Set(controller.tileRenderer.lastRenderedTileCoords)
        XCTAssertTrue(topLeftCoords.contains(TTTileCoord(level: 0, x: 0, y: 0)))
        XCTAssertFalse(topLeftCoords.contains(TTTileCoord(level: 0, x: 7, y: 5)))

        let tlViewportImg = try XCTUnwrap(controller.tileRenderer.lastViewportImage)
        XCTAssertEqual(
            TTImagePreviewResource.pixelSize(of: controller.displayedImage),
            TTImagePreviewResource.pixelSize(of: tlViewportImg),
            "controller.displayedImage must be the composited viewport image, not the full unpanned source image"
        )
        let tlDisplayedPixel = try XCTUnwrap(
            samplePixel(
                in: controller.displayedImage,
                x: Int(controller.displayedImage.size.width / 2),
                y: Int(controller.displayedImage.size.height / 2)
            )
        )
        XCTAssertGreaterThan(tlDisplayedPixel.r, 200)
        XCTAssertLessThan(tlDisplayedPixel.g, 40)
        XCTAssertLessThan(tlDisplayedPixel.b, 40)
        let tlPixel = try XCTUnwrap(
            samplePixel(in: tlViewportImg, x: Int(tlViewportImg.size.width / 2), y: Int(tlViewportImg.size.height / 2))
        )
        XCTAssertGreaterThan(tlPixel.r, 200)
        XCTAssertLessThan(tlPixel.g, 40)
        XCTAssertLessThan(tlPixel.b, 40)

        let bottomRightTask = controller.updateViewport(
            viewportSize: viewport,
            backingScale: 2.0,
            scale: 3.0,
            offset: CGSize(width: -800, height: -600)
        )
        await bottomRightTask?.value

        let bottomRightCoords = Set(controller.tileRenderer.lastRenderedTileCoords)
        XCTAssertNotEqual(topLeftCoords, bottomRightCoords)
        XCTAssertTrue(bottomRightCoords.contains(TTTileCoord(level: 0, x: 7, y: 5)))
        XCTAssertFalse(bottomRightCoords.contains(TTTileCoord(level: 0, x: 0, y: 0)))

        let brViewportImg = try XCTUnwrap(controller.tileRenderer.lastViewportImage)
        let brDisplayedPixel = try XCTUnwrap(
            samplePixel(
                in: controller.displayedImage,
                x: Int(controller.displayedImage.size.width / 2),
                y: Int(controller.displayedImage.size.height / 2)
            )
        )
        XCTAssertGreaterThan(brDisplayedPixel.r, 200)
        XCTAssertGreaterThan(brDisplayedPixel.g, 200)
        XCTAssertLessThan(brDisplayedPixel.b, 40)
        let brPixel = try XCTUnwrap(
            samplePixel(in: brViewportImg, x: Int(brViewportImg.size.width / 2), y: Int(brViewportImg.size.height / 2))
        )
        XCTAssertGreaterThan(brPixel.r, 200)
        XCTAssertGreaterThan(brPixel.g, 200)
        XCTAssertLessThan(brPixel.b, 40)
    }

    func testTileCacheByteBudgetEvictionCancellationAndDismantleCleanup() async throws {
        let pngData = makeFourQuadrantPNGData(width: 2048, height: 1536)
        let resource = try XCTUnwrap(
            TTImagePreviewResource.load(from: pngData, suggestedName: "budget.png", baseMaxPixelSize: 1024)
        )
        let tightTileBudget = 2 * 256 * 256 * 4
        let renderer = TTMetalTileViewportRenderer(maxCachedTileBytes: tightTileBudget)
        let controller = TTImagePreviewController(resource: resource, tileRenderer: renderer)
        let viewport = CGSize(width: 800, height: 600)

        let task1 = controller.updateViewport(
            viewportSize: viewport,
            backingScale: 2.0,
            scale: 3.0,
            offset: CGSize(width: 800, height: 600)
        )
        await task1?.value

        XCTAssertLessThanOrEqual(renderer.currentCachedTileBytes, tightTileBudget)
        XCTAssertLessThanOrEqual(renderer.cachedTileCount, 2)
        XCTAssertGreaterThan(renderer.evictedTileCount, 0)

        controller.simulatedDecodeDelayNanoseconds = 20_000_000
        for step in 0..<12 {
            let offsetVal = CGFloat(step * 60 - 360)
            controller.updateViewport(
                viewportSize: viewport,
                backingScale: 2.0,
                scale: 2.5 + CGFloat(step) * 0.1,
                offset: CGSize(width: offsetVal, height: offsetVal)
            )
        }

        controller.dismantle()
        await controller.scheduler.waitForIdle()

        XCTAssertGreaterThan(controller.cancelledDecodeCount, 0)
        XCTAssertLessThanOrEqual(controller.peakConcurrentDecodeCount, controller.budget.maxConcurrentDecodes)
        XCTAssertEqual(renderer.currentCachedTileBytes, 0)
        XCTAssertEqual(renderer.cachedTileCount, 0)
        XCTAssertFalse(controller.isHighResLoaded)
    }

    func testGracefulCPUFallbackWhenMetalPipelineUnavailable() async throws {
        let pngData = makeFourQuadrantPNGData(width: 2048, height: 1536)
        let resource = try XCTUnwrap(
            TTImagePreviewResource.load(from: pngData, suggestedName: "fallback.png", baseMaxPixelSize: 1024)
        )
        let fallbackRenderer = TTMetalTileViewportRenderer(
            makeMetalPipeline: { throw MetalPipelineError.deviceUnavailable }
        )
        let controller = TTImagePreviewController(resource: resource, tileRenderer: fallbackRenderer)
        let viewport = CGSize(width: 800, height: 600)

        let task = controller.updateViewport(
            viewportSize: viewport,
            backingScale: 2.0,
            scale: 3.0,
            offset: CGSize(width: 800, height: 600)
        )
        await task?.value

        XCTAssertFalse(fallbackRenderer.usedMetalTilePipeline)
        XCTAssertTrue(fallbackRenderer.didFallbackToCPU)
        XCTAssertTrue(controller.isHighResLoaded)
        XCTAssertEqual(controller.currentDisplayedPixelSize, CGSize(width: 2048, height: 1536))

        let fallbackViewport = try XCTUnwrap(fallbackRenderer.lastViewportImage)
        let px = try XCTUnwrap(
            samplePixel(
                in: fallbackViewport,
                x: Int(fallbackViewport.size.width / 2),
                y: Int(fallbackViewport.size.height / 2)
            )
        )
        XCTAssertGreaterThan(px.r, 200)
        XCTAssertLessThan(px.g, 40)
        XCTAssertLessThan(px.b, 40)
    }

    func testZoomViewportRecompositesWhenViewportGeometryChangesWithoutDecodeIncrease() async throws {
        let pngData = makeFourQuadrantPNGData(width: 1600, height: 1200)
        let resource = try XCTUnwrap(
            TTImagePreviewResource.load(from: pngData, suggestedName: "resize.png", baseMaxPixelSize: 800)
        )
        let renderer = TTMetalTileViewportRenderer()
        let controller = TTImagePreviewController(resource: resource, tileRenderer: renderer)

        let initialViewport = CGSize(width: 400, height: 300)
        let initialTask = controller.updateViewport(
            viewportSize: initialViewport,
            backingScale: 2.0,
            scale: 2.5,
            offset: .zero
        )
        await initialTask?.value
        XCTAssertTrue(controller.isHighResLoaded)
        XCTAssertEqual(controller.currentViewportSize, initialViewport)
        XCTAssertEqual(controller.displayedImage.size, CGSize(width: 640, height: 480))

        // Resize the viewport wider while keeping the same scale/offset and already having full 1600px decoded
        let resizedViewport = CGSize(width: 800, height: 300)
        let resizeTask = controller.updateViewport(
            viewportSize: resizedViewport,
            backingScale: 2.0,
            scale: 2.5,
            offset: .zero
        )
        XCTAssertNotNil(resizeTask, "Changing viewport geometry while zoomed must trigger a viewport recomposition")
        await resizeTask?.value
        XCTAssertEqual(controller.currentViewportSize, resizedViewport)
        XCTAssertEqual(controller.displayedImage.size, CGSize(width: 1280, height: 480))
        XCTAssertTrue(renderer.allCachedTilesMatchCurrentSourceDimensions)
    }
}
