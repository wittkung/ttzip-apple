// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TTMediaKit

@MainActor
final class VideoGIFExportIntegrationTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let baseTemp = FileManager.default.temporaryDirectory
        tempDirectoryURL = baseTemp.appendingPathComponent("VideoGIFExportTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)

        let manager = GIFExportManager.shared
        manager.cancelExport()
        manager.savePanelPresenter = nil
        manager.lastErrorMessage = nil
        manager.lastCompletedDestinationURL = nil
        manager.customLoopStart = nil
        manager.customLoopEnd = nil
        manager.selectedOptions = GIFExportOptions()
    }

    override func tearDown() async throws {
        let manager = GIFExportManager.shared
        manager.cancelExport()
        manager.savePanelPresenter = nil
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        try await super.tearDown()
    }

    func testExportMiddleSegmentProducesAnimatedGIFWithExpectedFramesDelaysAndColors() async throws {
        let videoURL = tempDirectoryURL.appendingPathComponent("segmented_colors.mov")
        try await Self.writeColorSegmentedVideo(to: videoURL, fps: 10, width: 320, height: 180)

        let destinationURL = tempDirectoryURL.appendingPathComponent("middle_green.gif")
        let manager = GIFExportManager.shared
        manager.savePanelPresenter = { _ in destinationURL }

        let resolved = manager.resolvedTimeRange(loopA: 1.0, loopB: 2.0, currentTime: 1.0, duration: 3.0)
        XCTAssertEqual(resolved.lowerBound, 1.0, accuracy: 0.001)
        XCTAssertEqual(resolved.upperBound, 2.0, accuracy: 0.001)

        let options = GIFExportOptions(fps: 10, width: 320, dither: false, preferNativeImageIO: true)
        manager.exportCurrentLoopAsGIF(
            loopA: 1.0,
            loopB: 2.0,
            currentTime: 1.0,
            duration: 3.0,
            sourceURL: videoURL,
            options: options
        )
        await manager.waitForCurrentExport()

        XCTAssertFalse(manager.isExporting)
        XCTAssertNil(manager.lastErrorMessage)
        XCTAssertEqual(manager.lastCompletedDestinationURL, destinationURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(destinationURL as CFURL, nil))
        let frameCount = CGImageSourceGetCount(imageSource)
        XCTAssertEqual(frameCount, 10)

        for idx in 0..<frameCount {
            let delay = Self.readFrameDelay(from: imageSource, index: idx)
            XCTAssertEqual(delay, 0.1, accuracy: 0.025)

            let cgImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, idx, nil))
            XCTAssertEqual(cgImage.width, 320)
            XCTAssertEqual(cgImage.height, 180)
            let rgb = try XCTUnwrap(Self.sampleCenterRGB(from: cgImage))
            XCTAssertGreaterThan(rgb.g, 160, "Frame \(idx) in middle segment [1.0, 2.0] should be green")
            XCTAssertLessThan(rgb.r, 90, "Frame \(idx) red channel should stay low")
            XCTAssertLessThan(rgb.b, 90, "Frame \(idx) blue channel should stay low")
        }

        let transitionDestURL = tempDirectoryURL.appendingPathComponent("red_to_green.gif")
        manager.savePanelPresenter = { _ in transitionDestURL }
        manager.exportCurrentLoopAsGIF(
            loopA: 0.5,
            loopB: 1.5,
            currentTime: 0.5,
            duration: 3.0,
            sourceURL: videoURL,
            options: options
        )
        await manager.waitForCurrentExport()

        let transitionSource = try XCTUnwrap(CGImageSourceCreateWithURL(transitionDestURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(transitionSource), 10)
        let firstRGB = try XCTUnwrap(Self.sampleCenterRGB(from: try XCTUnwrap(CGImageSourceCreateImageAtIndex(transitionSource, 1, nil))))
        let lastRGB = try XCTUnwrap(Self.sampleCenterRGB(from: try XCTUnwrap(CGImageSourceCreateImageAtIndex(transitionSource, 8, nil))))
        XCTAssertGreaterThan(firstRGB.r, 160, "Early frame in [0.5, 1.5] must be red")
        XCTAssertLessThan(firstRGB.g, 90)
        XCTAssertGreaterThan(lastRGB.g, 160, "Late frame in [0.5, 1.5] must be green")
        XCTAssertLessThan(lastRGB.r, 90)
    }

    func testSourceCompatibilityRejectsMissingEmptyAndNonFileURLs() async throws {
        let manager = GIFExportManager.shared
        let pipeline = GIFExportPipeline.shared

        XCTAssertNotNil(manager.compatibilityIssue(for: nil))

        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/live/stream.m3u8"))
        if case .success = pipeline.validateSourceCompatibility(remoteURL) {
            XCTFail("Expected non-file URL to be rejected")
        }
        XCTAssertNotNil(manager.compatibilityIssue(for: remoteURL))

        let missingURL = tempDirectoryURL.appendingPathComponent("missing_video.mp4")
        if case .success = pipeline.validateSourceCompatibility(missingURL) {
            XCTFail("Expected missing file URL to be rejected")
        }
        XCTAssertNotNil(manager.compatibilityIssue(for: missingURL))

        let emptyURL = tempDirectoryURL.appendingPathComponent("empty_video.mp4")
        FileManager.default.createFile(atPath: emptyURL.path, contents: Data())
        if case .success = pipeline.validateSourceCompatibility(emptyURL) {
            XCTFail("Expected empty 0-byte file URL to be rejected")
        }
        XCTAssertNotNil(manager.compatibilityIssue(for: emptyURL))

        let validURL = tempDirectoryURL.appendingPathComponent("valid_video.mov")
        try await Self.writeColorSegmentedVideo(to: validURL, fps: 10, width: 320, height: 180)
        if case .failure(let error) = pipeline.validateSourceCompatibility(validURL) {
            XCTFail("Expected valid video file to pass compatibility validation, got \(error)")
        }
        XCTAssertNil(manager.compatibilityIssue(for: validURL))
    }

    func testOutputFailureSetsErrorResetsStateAndCleansUpPartialFile() async throws {
        let videoURL = tempDirectoryURL.appendingPathComponent("source_for_failure.mov")
        try await Self.writeColorSegmentedVideo(to: videoURL, fps: 10, width: 320, height: 180)

        let manager = GIFExportManager.shared
        let unwritableDestURL = tempDirectoryURL
            .appendingPathComponent("nonexistent_subdir_\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("failed_output.gif")

        manager.savePanelPresenter = { _ in unwritableDestURL }
        manager.exportCurrentLoopAsGIF(
            loopA: 0.5,
            loopB: 1.5,
            currentTime: 0.5,
            duration: 3.0,
            sourceURL: videoURL,
            options: GIFExportOptions(fps: 10, width: 320, dither: false, preferNativeImageIO: true)
        )
        await manager.waitForCurrentExport()

        XCTAssertFalse(manager.isExporting)
        XCTAssertNotNil(manager.lastErrorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unwritableDestURL.path))

        let invalidRangeDestURL = tempDirectoryURL.appendingPathComponent("invalid_range_existing.gif")
        let preservedBytes = Data("existing-user-gif".utf8)
        try preservedBytes.write(to: invalidRangeDestURL)
        manager.lastErrorMessage = nil
        manager.savePanelPresenter = { _ in invalidRangeDestURL }
        manager.exportCurrentLoopAsGIF(
            loopA: 2.5,
            loopB: 1.0,
            currentTime: 1.0,
            duration: 3.0,
            sourceURL: videoURL,
            options: GIFExportOptions(fps: 10, width: 320, dither: false, preferNativeImageIO: true)
        )
        await manager.waitForCurrentExport()

        XCTAssertFalse(manager.isExporting)
        XCTAssertNotNil(manager.lastErrorMessage)
        XCTAssertEqual(try Data(contentsOf: invalidRangeDestURL), preservedBytes)
    }

    func testCancellationAndPreviewCloseTerminateExportAndRemovePartialOutput() async throws {
        let videoURL = tempDirectoryURL.appendingPathComponent("cancel_source.mov")
        try await Self.writeColorSegmentedVideo(to: videoURL, fps: 10, width: 320, height: 180)
        let manager = GIFExportManager.shared

        let cancelDestURL = tempDirectoryURL.appendingPathComponent("cancelled_export.gif")
        manager.savePanelPresenter = { _ in
            try? await Task.sleep(nanoseconds: 40_000_000)
            return cancelDestURL
        }

        manager.exportCurrentLoopAsGIF(
            loopA: 0.0,
            loopB: 3.0,
            currentTime: 0.0,
            duration: 3.0,
            sourceURL: videoURL,
            options: GIFExportOptions(fps: 20, width: 320, dither: false, preferNativeImageIO: true)
        )
        XCTAssertTrue(manager.isExporting)
        try await Task.sleep(nanoseconds: 60_000_000)
        manager.cancelExport()
        await manager.waitForCurrentExport()

        XCTAssertFalse(manager.isExporting)
        XCTAssertEqual(manager.exportProgress, 0.0, accuracy: 0.001)
        XCTAssertNil(manager.activeSourceURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelDestURL.path))

        let previewCloseDestURL = tempDirectoryURL.appendingPathComponent("preview_closed_export.gif")
        let preservedBytes = Data("existing-user-gif".utf8)
        try preservedBytes.write(to: previewCloseDestURL)
        manager.savePanelPresenter = { _ in
            try? await Task.sleep(nanoseconds: 40_000_000)
            return previewCloseDestURL
        }

        manager.exportCurrentLoopAsGIF(
            loopA: 0.0,
            loopB: 3.0,
            currentTime: 0.0,
            duration: 3.0,
            sourceURL: videoURL,
            options: GIFExportOptions(fps: 20, width: 320, dither: false, preferNativeImageIO: true)
        )
        XCTAssertTrue(manager.isExporting)
        let otherURL = tempDirectoryURL.appendingPathComponent("other_video.mov")
        manager.handlePreviewClosed(for: otherURL)
        XCTAssertTrue(manager.isExporting, "Closing an unrelated preview must not cancel active export")

        try await Task.sleep(nanoseconds: 60_000_000)
        manager.handlePreviewClosed(for: videoURL)
        await manager.waitForCurrentExport()

        XCTAssertFalse(manager.isExporting)
        XCTAssertNil(manager.activeSourceURL)
        XCTAssertEqual(try Data(contentsOf: previewCloseDestURL), preservedBytes)
        let remainingFiles = (try? FileManager.default.contentsOfDirectory(atPath: tempDirectoryURL.path)) ?? []
        XCTAssertFalse(remainingFiles.contains(where: { $0.contains(".ttmedia-gif-staging-") }))
    }

    func testTTMediaVideoAndServicesTests_GIFExportOptionsAndTimeRangeContract() {
        let options = GIFExportOptions(fps: 15, width: 480, dither: true, preferNativeImageIO: true)
        XCTAssertEqual(options.fps, 15)
        XCTAssertEqual(options.width, 480)
        XCTAssertTrue(options.dither)
        XCTAssertTrue(options.preferNativeImageIO)

        let fallbackRange = GIFExportManager.shared.resolvedTimeRange(
            loopA: nil,
            loopB: nil,
            currentTime: 5.0,
            duration: 12.0
        )
        XCTAssertEqual(fallbackRange.lowerBound, 2.0, accuracy: 0.001)
        XCTAssertEqual(fallbackRange.upperBound, 8.0, accuracy: 0.001)
    }

    // MARK: - Video Fixture & Image Inspection Helpers

    private static func writeColorSegmentedVideo(
        to outputURL: URL,
        fps: Int32,
        width: Int,
        height: Int
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let sourcePixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelAttributes
        )

        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(fps) * 3
        for frameIdx in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let secondBucket = frameIdx / Int(fps)
            let color: (UInt8, UInt8, UInt8)
            switch secondBucket {
            case 0:
                color = (255, 0, 0)
            case 1:
                color = (0, 255, 0)
            default:
                color = (0, 0, 255)
            }
            let pixelBuffer = try makeSolidPixelBuffer(width: width, height: height, rgb: color)
            let presentationTime = CMTime(value: CMTimeValue(frameIdx), timescale: fps)
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: presentationTime))
        }

        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error {
            throw error
        }
    }

    private static func makeSolidPixelBuffer(
        width: Int,
        height: Int,
        rgb: (UInt8, UInt8, UInt8)
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw NSError(domain: "VideoGIFExportIntegrationTests", code: Int(status))
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = ptr + y * bytesPerRow
                for x in 0..<width {
                    let px = row + x * 4
                    px[0] = 255
                    px[1] = rgb.0
                    px[2] = rgb.1
                    px[3] = rgb.2
                }
            }
        }
        return buffer
    }

    private static func readFrameDelay(from source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifDict = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.0
        }
        if let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
            return unclamped
        }
        if let clamped = gifDict[kCGImagePropertyGIFDelayTime] as? Double, clamped > 0 {
            return clamped
        }
        return 0.0
    }

    private static func sampleCenterRGB(from image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixel,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            return nil
        }
        let centerX = CGFloat(image.width) / 2.0
        let centerY = CGFloat(image.height) / 2.0
        context.draw(
            image,
            in: CGRect(
                x: -centerX,
                y: -centerY,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        return (pixel[0], pixel[1], pixel[2])
    }
}
