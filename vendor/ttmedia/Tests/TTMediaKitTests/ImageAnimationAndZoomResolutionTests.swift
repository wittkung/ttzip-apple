// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import TTMediaKit

@MainActor
final class ImageAnimationAndZoomResolutionTests: XCTestCase {

    // MARK: - Pixel Sampling Helper

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

    // MARK: - Programmatic Multi-Frame Fixtures (GIF, APNG, Animated WebP)

    /// Creates a 4x4 CGImage where the left half (x: 0..<splitX) has `leftColor` and right half has `rightColor`.
    private func makeSplitFrameCGImage(
        width: Int = 4,
        height: Int = 4,
        splitX: Int = 4,
        leftRGBA: (UInt8, UInt8, UInt8, UInt8),
        rightRGBA: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    ) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let color = x < splitX ? leftRGBA : rightRGBA
                pixels[idx] = color.0
                pixels[idx + 1] = color.1
                pixels[idx + 2] = color.2
                pixels[idx + 3] = color.3
            }
        }
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
        return ctx.makeImage()!
    }

    private func makeAnimatedGIFData(
        frame0Delay: TimeInterval = 0.04,
        frame1Delay: TimeInterval = 0.06,
        loopCount: Int = 0
    ) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil)!
        let containerProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loopCount
            ]
        ]
        CGImageDestinationSetProperties(dest, containerProps as CFDictionary)

        // Frame 0: Full Red (#FF0000FF)
        let frame0 = makeSplitFrameCGImage(width: 4, height: 4, splitX: 4, leftRGBA: (255, 0, 0, 255))
        let frame0Props: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frame0Delay,
                kCGImagePropertyGIFUnclampedDelayTime: frame0Delay
            ]
        ]
        CGImageDestinationAddImage(dest, frame0, frame0Props as CFDictionary)

        // Frame 1: Left half Green (#00FF00FF), Right half Transparent (0, 0, 0, 0)
        let frame1 = makeSplitFrameCGImage(
            width: 4,
            height: 4,
            splitX: 2,
            leftRGBA: (0, 255, 0, 255),
            rightRGBA: (0, 0, 0, 0)
        )
        let frame1Props: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frame1Delay,
                kCGImagePropertyGIFUnclampedDelayTime: frame1Delay
            ]
        ]
        CGImageDestinationAddImage(dest, frame1, frame1Props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func makeAnimatedAPNGData(
        frame0Delay: TimeInterval = 0.05,
        frame1Delay: TimeInterval = 0.08,
        loopCount: Int = 2
    ) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 2, nil)!
        let containerProps: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyAPNGLoopCount: loopCount
            ]
        ]
        CGImageDestinationSetProperties(dest, containerProps as CFDictionary)

        // Frame 0: Full Red (#FF0000FF)
        let frame0 = makeSplitFrameCGImage(width: 4, height: 4, splitX: 4, leftRGBA: (255, 0, 0, 255))
        let frame0Props: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyAPNGDelayTime: frame0Delay,
                kCGImagePropertyAPNGUnclampedDelayTime: frame0Delay
            ]
        ]
        CGImageDestinationAddImage(dest, frame0, frame0Props as CFDictionary)

        // Frame 1: Left half Green (#00FF00FF), Right half Transparent (0, 0, 0, 0)
        let frame1 = makeSplitFrameCGImage(
            width: 4,
            height: 4,
            splitX: 2,
            leftRGBA: (0, 255, 0, 255),
            rightRGBA: (0, 0, 0, 0)
        )
        let frame1Props: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyAPNGDelayTime: frame1Delay,
                kCGImagePropertyAPNGUnclampedDelayTime: frame1Delay
            ]
        ]
        CGImageDestinationAddImage(dest, frame1, frame1Props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// Constructs a valid Animated WebP (`RIFF WEBP VP8X + ANIM + ANMF + ANMF`) with two visually distinct frames:
    /// Frame 0: 4x4 Red (#FF0000FF), disposed to transparent background.
    /// Frame 1: 4x4 where left half (x=0..1) is Green (#00FF00FF) and right half (x=2..3) is Transparent (#00000000).
    private func u32LE(_ val: UInt32) -> [UInt8] {
        [
            UInt8(val & 0xFF),
            UInt8((val >> 8) & 0xFF),
            UInt8((val >> 16) & 0xFF),
            UInt8((val >> 24) & 0xFF)
        ]
    }

    private func u24LE(_ val: Int) -> [UInt8] {
        [
            UInt8(val & 0xFF),
            UInt8((val >> 8) & 0xFF),
            UInt8((val >> 16) & 0xFF)
        ]
    }

    private func makeRIFFChunk(fourCC: String, payload: Data) -> Data {
        var out = Data(fourCC.utf8)
        out.append(contentsOf: u32LE(UInt32(payload.count)))
        out.append(payload)
        if payload.count % 2 != 0 {
            out.append(0)
        }
        return out
    }

    private func makeWebPANMFChunk(
        width: Int,
        height: Int,
        durationMs: Int,
        disposeToBackground: Bool,
        doNotBlend: Bool,
        vp8lPayload: Data
    ) -> Data {
        var header = Data()
        header.append(contentsOf: u24LE(0))
        header.append(contentsOf: u24LE(0))
        header.append(contentsOf: u24LE(width - 1))
        header.append(contentsOf: u24LE(height - 1))
        header.append(contentsOf: u24LE(durationMs))
        var flags: UInt8 = 0
        if disposeToBackground { flags |= 0x01 }
        if doNotBlend { flags |= 0x02 }
        header.append(flags)
        header.append(makeRIFFChunk(fourCC: "VP8L", payload: vp8lPayload))
        return makeRIFFChunk(fourCC: "ANMF", payload: header)
    }

    private func makeAnimatedWebPData(
        frame0DelayMs: Int = 50,
        frame1DelayMs: Int = 70,
        loopCount: UInt16 = 3
    ) -> Data {
        var vp8xPayload = Data([0x12, 0x00, 0x00, 0x00])
        vp8xPayload.append(contentsOf: u24LE(4 - 1))
        vp8xPayload.append(contentsOf: u24LE(4 - 1))
        let vp8xChunk = makeRIFFChunk(fourCC: "VP8X", payload: vp8xPayload)

        var animPayload = Data([0x00, 0x00, 0x00, 0x00])
        animPayload.append(UInt8(loopCount & 0xFF))
        animPayload.append(UInt8((loopCount >> 8) & 0xFF))
        let animChunk = makeRIFFChunk(fourCC: "ANIM", payload: animPayload)

        let vp8l0 = Data([47, 3, 192, 0, 0, 7, 16, 253, 143, 254, 7, 34, 162, 255, 1])
        let anmf0 = makeWebPANMFChunk(
            width: 4, height: 4, durationMs: frame0DelayMs,
            disposeToBackground: true, doNotBlend: true, vp8lPayload: vp8l0
        )

        let vp8l1 = Data([47, 1, 192, 0, 0, 7, 208, 255, 136, 254, 7, 34, 162, 255, 1])
        let anmf1 = makeWebPANMFChunk(
            width: 2, height: 4, durationMs: frame1DelayMs,
            disposeToBackground: false, doNotBlend: false, vp8lPayload: vp8l1
        )

        var webpBody = Data("WEBP".utf8)
        webpBody.append(vp8xChunk)
        webpBody.append(animChunk)
        webpBody.append(anmf0)
        webpBody.append(anmf1)

        var riff = Data("RIFF".utf8)
        riff.append(contentsOf: u32LE(UInt32(webpBody.count)))
        riff.append(webpBody)
        return riff
    }

    // MARK: - 1. Multi-Frame GIF, APNG & Animated WebP Verification

    private func loadRequiredFrame(_ anim: TTAnimatedImageController, at index: Int) async throws -> NSImage {
        let img = await anim.loadFrameImage(at: index)
        return try XCTUnwrap(img)
    }

    func testAnimatedGIFDistinctFramesDelaysAndPlaybackLifecycle() async throws {
        let gifData = makeAnimatedGIFData(frame0Delay: 0.04, frame1Delay: 0.06, loopCount: 0)
        guard let resource = TTImagePreviewResource.load(from: gifData, suggestedName: "anim.gif") else {
            XCTFail("Failed to load animated GIF resource")
            return
        }

        XCTAssertEqual(resource.frameCount, 2)
        XCTAssertTrue(resource.isAnimated)
        XCTAssertEqual(resource.loopCount, 0)
        XCTAssertEqual(resource.frameDurations.count, 2)
        XCTAssertEqual(resource.frameDurations[0], 0.04, accuracy: 0.015)
        XCTAssertEqual(resource.frameDurations[1], 0.06, accuracy: 0.015)

        let view = InteractiveZoomImageView(resource: resource)
        let controller = view.controller
        guard let anim = controller.animationController else {
            XCTFail("Expected non-nil TTAnimatedImageController for 2-frame GIF")
            return
        }

        // Verify Frame 0 vs Frame 1 pixels are visually distinct + Frame 1 right half is transparent
        let frame0Img = try await loadRequiredFrame(anim, at: 0)
        let frame1Img = try await loadRequiredFrame(anim, at: 1)
        let f0Left = samplePixel(in: frame0Img, x: 0, y: 2)
        let f1Left = samplePixel(in: frame1Img, x: 0, y: 2)
        let f1RightTransparent = samplePixel(in: frame1Img, x: 3, y: 2)

        XCTAssertNotNil(f0Left)
        XCTAssertNotNil(f1Left)
        XCTAssertNotEqual(f0Left, f1Left, "Frame 0 and Frame 1 must have distinct pixel colors")
        XCTAssertGreaterThan(f0Left?.r ?? 0, 200, "Frame 0 left pixel should be red")
        XCTAssertLessThan(f0Left?.g ?? 255, 40)
        XCTAssertGreaterThan(f1Left?.g ?? 0, 200, "Frame 1 left pixel should be green")
        XCTAssertLessThan(f1Left?.r ?? 255, 40)
        XCTAssertEqual(f1RightTransparent?.a, 0, "Frame 1 right pixel should be transparent")

        // Verify playback advances currentFrameIndex from 0 to 1 and stopPlayback stops timer
        XCTAssertEqual(view.currentFrameIndex, 0)
        controller.startPlaybackIfNeeded()
        XCTAssertTrue(view.isPlayingAnimation)

        try await Task.sleep(nanoseconds: 55_000_000)
        XCTAssertEqual(view.currentFrameIndex, 1)

        controller.stopPlayback()
        XCTAssertFalse(view.isPlayingAnimation)
    }

    func testAnimatedAPNGDistinctFramesFiniteLoopAndPlaybackLifecycle() async throws {
        let apngData = makeAnimatedAPNGData(frame0Delay: 0.05, frame1Delay: 0.08, loopCount: 2)
        guard let resource = TTImagePreviewResource.load(from: apngData, suggestedName: "anim.png") else {
            XCTFail("Failed to load animated APNG resource")
            return
        }

        XCTAssertEqual(resource.frameCount, 2)
        XCTAssertTrue(resource.isAnimated)
        XCTAssertEqual(resource.loopCount, 2)
        XCTAssertEqual(resource.frameDurations.count, 2)
        XCTAssertEqual(resource.frameDurations[0], 0.05, accuracy: 0.015)
        XCTAssertEqual(resource.frameDurations[1], 0.08, accuracy: 0.015)

        let view = InteractiveZoomImageView(resource: resource)
        let controller = view.controller
        guard let anim = controller.animationController else {
            XCTFail("Expected non-nil TTAnimatedImageController for 2-frame APNG")
            return
        }

        // Verify Frame 0 (Red) vs Frame 1 (Green + Transparent)
        let frame0Img = try await loadRequiredFrame(anim, at: 0)
        let frame1Img = try await loadRequiredFrame(anim, at: 1)
        let f0Left = samplePixel(in: frame0Img, x: 0, y: 2)
        let f1Left = samplePixel(in: frame1Img, x: 0, y: 2)
        let f1RightTransparent = samplePixel(in: frame1Img, x: 3, y: 2)

        XCTAssertNotEqual(f0Left, f1Left)
        XCTAssertGreaterThan(f0Left?.r ?? 0, 200)
        XCTAssertGreaterThan(f1Left?.g ?? 0, 200)
        XCTAssertEqual(f1RightTransparent?.a, 0)

        // Verify finite loop count termination (loopCount == 2)
        controller.startPlaybackIfNeeded()
        XCTAssertTrue(controller.isPlayingAnimation)
        await anim.advanceFrameAsync() // 0 -> 1
        XCTAssertEqual(controller.currentFrameIndex, 1)
        await anim.advanceFrameAsync() // 1 -> 0 (completedLoops = 1)
        XCTAssertEqual(controller.currentFrameIndex, 0)
        XCTAssertTrue(controller.isPlayingAnimation)
        await anim.advanceFrameAsync() // 0 -> 1
        await anim.advanceFrameAsync() // 1 -> end (completedLoops = 2 -> stops)
        XCTAssertEqual(anim.completedLoops, 2)
        XCTAssertFalse(controller.isPlayingAnimation)
    }

    func testAnimatedWebPDistinctFramesAlphaAndPlaybackLifecycle() async throws {
        let webpData = makeAnimatedWebPData(frame0DelayMs: 50, frame1DelayMs: 70, loopCount: 3)
        guard let resource = TTImagePreviewResource.load(from: webpData, suggestedName: "anim.webp") else {
            XCTFail("Failed to load animated WebP resource via ImageIO")
            return
        }

        XCTAssertEqual(resource.frameCount, 2)
        XCTAssertTrue(resource.isAnimated)
        XCTAssertEqual(resource.loopCount, 3)
        XCTAssertEqual(resource.frameDurations.count, 2)
        XCTAssertEqual(resource.frameDurations[0], 0.05, accuracy: 0.015)
        XCTAssertEqual(resource.frameDurations[1], 0.07, accuracy: 0.015)

        let view = InteractiveZoomImageView(resource: resource)
        let controller = view.controller
        guard let anim = controller.animationController else {
            XCTFail("Expected non-nil TTAnimatedImageController for 2-frame Animated WebP")
            return
        }

        let frame0Img = try await loadRequiredFrame(anim, at: 0)
        let frame1Img = try await loadRequiredFrame(anim, at: 1)
        let f0Left = samplePixel(in: frame0Img, x: 0, y: 2)
        let f1Left = samplePixel(in: frame1Img, x: 0, y: 2)
        let f1RightTransparent = samplePixel(in: frame1Img, x: 3, y: 2)

        XCTAssertNotEqual(f0Left, f1Left)
        XCTAssertGreaterThan(f0Left?.r ?? 0, 200, "WebP Frame 0 left pixel should be red")
        XCTAssertGreaterThan(f1Left?.g ?? 0, 200, "WebP Frame 1 left pixel should be green")
        XCTAssertEqual(f1RightTransparent?.a, 0, "WebP Frame 1 right pixel should be transparent after disposal")

        controller.startPlaybackIfNeeded()
        XCTAssertTrue(view.isPlayingAnimation)
        await anim.advanceFrameAsync()
        XCTAssertEqual(view.currentFrameIndex, 1)
        controller.stopPlayback()
        XCTAssertFalse(view.isPlayingAnimation)
    }

    func testMinimumFrameDelayClampingFollowsBrowserStandard() {
        // Delays < 0.011s must clamp to 0.100s
        XCTAssertEqual(TTImageSourceProbe.clampFrameDelay(0.0), 0.100, accuracy: 0.0001)
        XCTAssertEqual(TTImageSourceProbe.clampFrameDelay(0.005), 0.100, accuracy: 0.0001)
        XCTAssertEqual(TTImageSourceProbe.clampFrameDelay(0.010), 0.100, accuracy: 0.0001)
        XCTAssertEqual(TTImageSourceProbe.clampFrameDelay(0.020), 0.020, accuracy: 0.0001)
    }

    // MARK: - 2. High-Res Zoom Upgrade, Budget & Stale Generation Isolation

    /// Generates a 4096x3072 PNG image with a 1-pixel alternating high-frequency checkerboard pattern.
    private func makeHighFrequencyCheckerboardPNGData(width: Int = 4096, height: Int = 3072) -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let rowOffset = y * width * 4
            for x in 0..<width {
                let isWhite = ((x + y) & 1) == 0
                let v: UInt8 = isWhite ? 255 : 0
                let idx = rowOffset + x * 4
                pixels[idx] = v
                pixels[idx + 1] = v
                pixels[idx + 2] = v
                pixels[idx + 3] = 255
            }
        }
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

    func testHighResZoomUpgradeAndRevertForDiskURLAndInMemoryData() async throws {
        let pngData = makeHighFrequencyCheckerboardPNGData(width: 4096, height: 3072)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia_zoom_\(UUID().uuidString).png")
        try pngData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let viewport = CGSize(width: 800, height: 600)

        // Test both on-disk URL and in-memory Data (archive entry)
        let diskResource = try XCTUnwrap(TTImagePreviewResource.load(from: tempURL, baseMaxPixelSize: 2048))
        let memoryResource = try XCTUnwrap(
            TTImagePreviewResource.load(from: pngData, suggestedName: "checker.png", baseMaxPixelSize: 2048)
        )

        for resource in [diskResource, memoryResource] {
            XCTAssertEqual(resource.pixelWidth, 4096)
            XCTAssertEqual(resource.pixelHeight, 3072)
            XCTAssertFalse(resource.isAnimated)

            let view = InteractiveZoomImageView(resource: resource)
            let controller = view.controller

            // 1. At scale = 1.0, displayed image is bounded to 2048x1536
            XCTAssertEqual(view.currentDisplayedPixelSize, CGSize(width: 2048, height: 1536))
            XCTAssertFalse(controller.isHighResLoaded)

            // 2. At scale = 3.0 on 800x600 viewport (backingScale 2.0), upgrades to 4096x3072
            let upgradeTask = controller.updateZoom(scale: 3.0, viewportSize: viewport, backingScale: 2.0)
            await upgradeTask?.value

            XCTAssertEqual(view.currentDisplayedPixelSize, CGSize(width: 4096, height: 3072))
            XCTAssertTrue(controller.isHighResLoaded)

            // Verify high-frequency 1px checkerboard contrast is preserved at 4096x3072
            let p00 = try XCTUnwrap(samplePixel(in: controller.displayedImage, x: 100, y: 100))
            let p01 = try XCTUnwrap(samplePixel(in: controller.displayedImage, x: 101, y: 100))
            XCTAssertGreaterThan(abs(Int(p00.r) - Int(p01.r)), 200, "1px checkerboard contrast must be sharp at 4096x3072")

            // 3. Resetting scale to 1.0 (<= 1.05) releases high-res image and reverts to 2048x1536
            controller.updateZoom(scale: 1.0, viewportSize: viewport, backingScale: 2.0)
            XCTAssertEqual(view.currentDisplayedPixelSize, CGSize(width: 2048, height: 1536))
            XCTAssertFalse(controller.isHighResLoaded)
        }
    }

    func testPixelAndMemoryBudgetCapsGigapixelDimensions() {
        let viewport = CGSize(width: 1600, height: 1200)
        // Gigapixel input (24000 x 18000) zoomed to 8.0x must never exceed 8192px cap
        let cappedDim = TTImageResolutionUpgrader.targetMaxPixelDimension(
            originalWidth: 24000,
            originalHeight: 18000,
            viewportSize: viewport,
            backingScale: 2.0,
            scale: 8.0
        )
        XCTAssertEqual(cappedDim, 8192)

        // Strict RGBA byte budget cap (e.g., 16 MB = 4,194,304 pixels max -> 2048x2048 for square image)
        let byteCappedDim = TTImageResolutionUpgrader.targetMaxPixelDimension(
            originalWidth: 8192,
            originalHeight: 8192,
            viewportSize: viewport,
            backingScale: 2.0,
            scale: 4.0,
            maxPixelDimensionCap: 8192,
            maxDecodedBytes: 16 * 1024 * 1024
        )
        XCTAssertEqual(byteCappedDim, 2048)
    }

    func testStaleGenerationIsolationOnRapidZoomReset() async throws {
        let pngData = makeHighFrequencyCheckerboardPNGData(width: 4096, height: 3072)
        let resource = try XCTUnwrap(
            TTImagePreviewResource.load(from: pngData, suggestedName: "stale_test.png", baseMaxPixelSize: 2048)
        )
        let controller = TTImagePreviewController(resource: resource)
        controller.simulatedDecodeDelayNanoseconds = 60_000_000 // 60ms slow decode

        let viewport = CGSize(width: 800, height: 600)

        // Fire slow scale = 4.0 request (generation 1)
        let slowTask4x = controller.updateZoom(scale: 4.0, viewportSize: viewport, backingScale: 2.0)
        let gen4x = controller.generation

        // Immediately reset to scale = 1.0 (generation 2)
        controller.updateZoom(scale: 1.0, viewportSize: viewport, backingScale: 2.0)
        let gen1x = controller.generation
        XCTAssertGreaterThan(gen1x, gen4x)

        // Wait for the slow 4.0x task to finish
        await slowTask4x?.value

        // Even if a stale result attempts to commit with old generation, it must be rejected
        let fakeHighRes = NSImage(size: NSSize(width: 4096, height: 3072))
        controller.commitUpgradedImageIfCurrent(fakeHighRes, forGeneration: gen4x)

        XCTAssertEqual(controller.currentDisplayedPixelSize, CGSize(width: 2048, height: 1536))
        XCTAssertFalse(controller.isHighResLoaded)
    }

    // MARK: - 3. Total Frame Memory Budget, LRU Eviction, Bounded Concurrency & Dismantle Cleanup

    private func makeEightFrame256x256APNGData() -> Data {
        let data = NSMutableData()
        let frameCount = 8
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, frameCount, nil)!
        let containerProps: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, containerProps as CFDictionary)

        for idx in 0..<frameCount {
            let r = UInt8((idx * 31 + 17) & 0xFF)
            let g = UInt8((255 - idx * 29) & 0xFF)
            let b = UInt8((idx * 53 + 40) & 0xFF)
            let frame = makeSplitFrameCGImage(
                width: 256,
                height: 256,
                splitX: 256,
                leftRGBA: (r, g, b, 255)
            )
            let frameProps: [CFString: Any] = [
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyAPNGDelayTime: 0.03,
                    kCGImagePropertyAPNGUnclampedDelayTime: 0.03
                ]
            ]
            CGImageDestinationAddImage(dest, frame, frameProps as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func testMultiFrameLargeAnimationTotalMemoryBudgetAndLRUEvictionOnDismantle() async throws {
        // 8 frames of 256x256 RGBA = 256 KB (262,144 bytes) per frame, 2 MB total if all decoded
        let apngData = makeEightFrame256x256APNGData()
        let resource = try XCTUnwrap(
            TTImagePreviewResource.load(from: apngData, suggestedName: "eight_frames_256.png")
        )
        XCTAssertEqual(resource.frameCount, 8)
        XCTAssertEqual(resource.pixelWidth, 256)
        XCTAssertEqual(resource.pixelHeight, 256)

        // Tight budget: 768 KB (786,432 bytes) -> holds at most 3 frames of 256x256 RGBA
        let maxBudgetBytes = 768 * 1024
        let tightBudget = TTImageDecodeBudget(
            maxAnimatedFrameDimension: 1024,
            maxTotalAnimationMemoryBytes: maxBudgetBytes,
            maxConcurrentDecodes: 2
        )

        let view = InteractiveZoomImageView(resource: resource, budget: tightBudget)
        let controller = view.controller
        let anim = try XCTUnwrap(controller.animationController)

        // 1. Initialization on @MainActor must NEVER decode all 8 frames upfront
        XCTAssertLessThanOrEqual(anim.cachedFrameCount, 1)
        XCTAssertEqual(anim.currentCachedMemoryBytes, 0)

        // 2. Step through all 8 frames and verify strict total memory cap and LRU/FIFO eviction
        controller.startPlaybackIfNeeded()
        XCTAssertTrue(anim.isPlaying)

        for _ in 0..<8 {
            await anim.advanceFrameAsync()
            XCTAssertLessThanOrEqual(
                anim.currentCachedMemoryBytes,
                maxBudgetBytes,
                "Cached animation memory must never exceed 768 KB budget"
            )
            XCTAssertLessThanOrEqual(anim.cachedFrameCount, 3)
        }
        XCTAssertGreaterThan(anim.evictedFrameCount, 0, "Stepping 8 frames under a 3-frame budget must evict old frames")

        // 3. Dismantle on view exit stops playback, cancels tasks, and reclaims all cached frame memory
        controller.dismantle()
        XCTAssertFalse(anim.isPlaying)
        XCTAssertEqual(anim.currentCachedMemoryBytes, 0)
        XCTAssertEqual(anim.cachedFrameCount, 0)
    }

    func testRapidContinuousZoomBoundedConcurrencyCancellationAndDismantleCleanup() async throws {
        let pngData = makeHighFrequencyCheckerboardPNGData(width: 4096, height: 3072)
        let resource = try XCTUnwrap(
            TTImagePreviewResource.load(from: pngData, suggestedName: "rapid_zoom.png", baseMaxPixelSize: 2048)
        )
        let budget = TTImageDecodeBudget(
            maxStaticZoomDimension: 8192,
            maxStaticZoomMemoryBytes: 256 * 1024 * 1024,
            maxConcurrentDecodes: 2
        )
        let scheduler = TTImageDecodeScheduler(maxConcurrentDecodes: budget.maxConcurrentDecodes)
        let controller = TTImagePreviewController(resource: resource, budget: budget, scheduler: scheduler)
        controller.simulatedDecodeDelayNanoseconds = 25_000_000 // 25ms per decode to force overlap

        let viewport = CGSize(width: 800, height: 600)

        // Rapidly issue 16 consecutive zoom requests from 1.2x to 4.0x
        for i in 0..<16 {
            let scale = 1.2 + CGFloat(i) * (2.8 / 15.0)
            controller.updateViewport(viewportSize: viewport, backingScale: 2.0, scale: scale)
        }

        // Immediately dismantle / reset to base image while decodes are in flight / queued
        controller.dismantle()
        await scheduler.waitForIdle()

        XCTAssertLessThanOrEqual(
            controller.peakConcurrentDecodeCount,
            budget.maxConcurrentDecodes,
            "Peak concurrent decodes must never exceed budget.maxConcurrentDecodes (2)"
        )
        XCTAssertGreaterThan(
            controller.cancelledDecodeCount,
            0,
            "Superseded intermediate zoom requests must be cooperatively cancelled"
        )
        XCTAssertEqual(controller.activeDecodeCount, 0)
        XCTAssertFalse(controller.isHighResLoaded)
        XCTAssertEqual(controller.currentDisplayedPixelSize, CGSize(width: 2048, height: 1536))
    }

    func testSingleFrameLargerThanTotalCacheBudgetNeverElevatesBudget() async throws {
        // Each native 256x256 RGBA frame is 262,144 bytes (256 KiB).
        // Set total animation cache budget to 64 KiB (65,536 bytes) — 1/4 of a single native frame!
        let apngData = makeEightFrame256x256APNGData()
        let resource = try XCTUnwrap(
            TTImagePreviewResource.load(from: apngData, suggestedName: "oversized_frame.png")
        )
        let smallTotalBudget = 64 * 1024 // 65,536 bytes

        // 1. Policy .downsampleToFitBudget (default): downsamples 256x256 -> 128x128 (65,536 bytes) so it fits budget
        let downsampleBudget = TTImageDecodeBudget(
            maxAnimatedFrameDimension: 1024,
            maxTotalAnimationMemoryBytes: smallTotalBudget,
            oversizedAnimatedFramePolicy: .downsampleToFitBudget
        )
        let animDownsample = try XCTUnwrap(TTAnimatedImageController(resource: resource, budget: downsampleBudget))
        let downsampledImg = try await loadRequiredFrame(animDownsample, at: 0)
        let downsampledSize = TTImagePreviewResource.pixelSize(of: downsampledImg)
        XCTAssertEqual(downsampledSize, CGSize(width: 128, height: 128))
        XCTAssertLessThanOrEqual(animDownsample.currentCachedMemoryBytes, smallTotalBudget)
        XCTAssertEqual(animDownsample.cachedFrameCount, 1)

        // 2. Policy .bypassCache: decodes at 256x256 (262,144 bytes > 65,536 budget) and refuses to cache
        let bypassBudget = TTImageDecodeBudget(
            maxAnimatedFrameDimension: 1024,
            maxTotalAnimationMemoryBytes: smallTotalBudget,
            oversizedAnimatedFramePolicy: .bypassCache
        )
        let animBypass = try XCTUnwrap(TTAnimatedImageController(resource: resource, budget: bypassBudget))
        let bypassedImg = try await loadRequiredFrame(animBypass, at: 0)
        XCTAssertEqual(TTImagePreviewResource.pixelSize(of: bypassedImg), CGSize(width: 256, height: 256))
        XCTAssertEqual(animBypass.currentCachedMemoryBytes, 0, "Oversized frame must not enter cache or raise budget")
        XCTAssertEqual(animBypass.cachedFrameCount, 0)
        XCTAssertEqual(animBypass.oversizedUncachedFrameCount, 1)

        // 3. Policy .rejectFrame: rejects oversized frame outright and keeps cached memory at 0
        let rejectBudget = TTImageDecodeBudget(
            maxAnimatedFrameDimension: 1024,
            maxTotalAnimationMemoryBytes: smallTotalBudget,
            oversizedAnimatedFramePolicy: .rejectFrame
        )
        let animReject = try XCTUnwrap(TTAnimatedImageController(resource: resource, budget: rejectBudget))
        let rejectedImg = await animReject.loadFrameImage(at: 0)
        XCTAssertNil(rejectedImg)
        XCTAssertEqual(animReject.currentCachedMemoryBytes, 0)
        XCTAssertEqual(animReject.cachedFrameCount, 0)
        XCTAssertEqual(animReject.rejectedOversizedFrameCount, 1)
    }
}
