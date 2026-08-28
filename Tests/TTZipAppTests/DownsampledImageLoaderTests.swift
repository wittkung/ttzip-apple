// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import AppKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

@MainActor
final class DownsampledImageLoaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipImageTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    func testDownsampledImageLoadingAndBounding() async throws {
        // Generate a 1000x800 bitmap image
        let imageSize = NSSize(width: 1000, height: 800)
        let offscreenRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(imageSize.width),
            pixelsHigh: Int(imageSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: offscreenRep)
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: imageSize).fill()
        NSGraphicsContext.restoreGraphicsState()
        
        let pngData = offscreenRep.representation(using: .png, properties: [:])!
        let imageURL = tempDir.appendingPathComponent("sample_large.png")
        try pngData.write(to: imageURL)
        
        // Test downsampling to 200px max
        let downsampled = DownsampledImageLoader.loadDownsampledImage(from: imageURL, maxPixelSize: 200)
        XCTAssertNotNil(downsampled)
        if let down = downsampled {
            XCTAssertLessThanOrEqual(down.size.width, 200)
            XCTAssertLessThanOrEqual(down.size.height, 200)
        }
        
        // Test async loading
        let asyncDownsampled = await DownsampledImageLoader.loadDownsampledImageAsync(from: imageURL, maxPixelSize: 400)
        XCTAssertNotNil(asyncDownsampled)
        if let asyncDown = asyncDownsampled {
            XCTAssertLessThanOrEqual(asyncDown.size.width, 400)
            XCTAssertLessThanOrEqual(asyncDown.size.height, 400)
        }
        
        // Test invalid image URL
        let invalidURL = tempDir.appendingPathComponent("non_existent.png")
        let nilImage = DownsampledImageLoader.loadDownsampledImage(from: invalidURL)
        XCTAssertNil(nilImage)
    }
}
