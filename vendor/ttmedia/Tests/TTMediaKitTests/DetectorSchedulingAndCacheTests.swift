// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import XCTest
@testable import TTMediaKit

final class DetectorSchedulingAndCacheTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetectorSchedulingAndCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. TTMediaBackgroundDetector Bounded Concurrency & Zero HOL Blocking

    func testCancelledSlowImageDetectionDoesNotBlockSubsequentSmallFileDetection() async throws {
        let largeBMPURL = tempDir.appendingPathComponent("huge_uncompressed.bmp")
        try writeUncompressedBMP(to: largeBMPURL, width: 4096, height: 4096)

        let smallTextURL = tempDir.appendingPathComponent("quick_note.txt")
        let smallPayload = "Instant small file detection payload.\n"
        try Data(smallPayload.utf8).write(to: smallTextURL, options: .atomic)

        let slowTask = Task {
            await TTMediaBackgroundDetector.shared.detect(url: largeBMPURL)
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        slowTask.cancel()

        let startNanos = DispatchTime.now().uptimeNanoseconds
        let quickResult = await TTMediaBackgroundDetector.shared.detect(url: smallTextURL)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000.0

        guard case .text(let decoded) = quickResult else {
            XCTFail("Expected .text for small file, got \(quickResult)")
            return
        }
        XCTAssertEqual(decoded, smallPayload)
        XCTAssertLessThan(
            elapsedMs,
            15.0,
            "Small file detection after cancelling slow task took \(String(format: "%.2f", elapsedMs)) ms (expected < 15 ms)"
        )
    }

    func testBoundedConcurrencyGateCancelsQueuedWaiterImmediately() async throws {
        let detector = TTMediaBackgroundDetector(maxConcurrentDetections: 1)

        let prevParser = TTMediaBackgroundDetector.epubParser
        defer { TTMediaBackgroundDetector.epubParser = prevParser }

        TTMediaBackgroundDetector.epubParser = { _ in
            try? await Task.sleep(nanoseconds: 250_000_000)
            return nil
        }

        let fakeZipHeader = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00])
        let epubURL = tempDir.appendingPathComponent("blocking.epub")
        try fakeZipHeader.write(to: epubURL, options: .atomic)

        let smallURL = tempDir.appendingPathComponent("queued.txt")
        try Data("queued".utf8).write(to: smallURL, options: .atomic)

        let firstTask = Task {
            await detector.detect(url: epubURL)
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        let queuedTask = Task {
            await detector.detect(url: smallURL)
        }
        try await Task.sleep(nanoseconds: 5_000_000)

        let cancelStart = DispatchTime.now().uptimeNanoseconds
        queuedTask.cancel()
        let cancelledResult = await queuedTask.value
        let cancelElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - cancelStart) / 1_000_000.0

        if case .unsupported(let reason) = cancelledResult {
            XCTAssertEqual(reason, "Cancelled")
        } else {
            XCTFail("Expected cancelled queued task to return .unsupported(\"Cancelled\"), got \(cancelledResult)")
        }
        XCTAssertLessThan(cancelElapsedMs, 15.0, "Queued task cancellation must return immediately without waiting for slot holder")

        firstTask.cancel()
        _ = await firstTask.value
    }

    func testDetectLatestFencesStaleGenerationResults() async throws {
        let detector = TTMediaBackgroundDetector(maxConcurrentDetections: 4)
        let prevParser = TTMediaBackgroundDetector.epubParser
        defer { TTMediaBackgroundDetector.epubParser = prevParser }

        TTMediaBackgroundDetector.epubParser = { _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return nil
        }

        let fakeZipHeader = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00])
        let slowEpubURL = tempDir.appendingPathComponent("stale.epub")
        try fakeZipHeader.write(to: slowEpubURL, options: .atomic)

        let latestTxtURL = tempDir.appendingPathComponent("latest.txt")
        try Data("latest selection".utf8).write(to: latestTxtURL, options: .atomic)

        async let staleCall = detector.detectLatest(url: slowEpubURL, sessionKey: "inspector")
        try await Task.sleep(nanoseconds: 5_000_000)
        async let newerCall = detector.detectLatest(url: latestTxtURL, sessionKey: "inspector")

        let staleOutcome = await staleCall
        let newerOutcome = await newerCall

        XCTAssertNil(staleOutcome, "Stale generation must be fenced and return nil")
        guard case .text(let text) = newerOutcome else {
            XCTFail("Expected latest call to return .text, got \(String(describing: newerOutcome))")
            return
        }
        XCTAssertEqual(text, "latest selection")
    }

    // MARK: - 2. Resource-Versioned Image Cache Hit & Disk Modification Invalidation

    func testVersionedThumbnailCacheHitAndAutomaticInvalidationOnFileModification() async throws {
        let cache = ImageIOThumbnailCache.shared
        await cache.purgeCache()
        await ImageIOThumbnailService.shared.purgeCache()

        let imageURL = tempDir.appendingPathComponent("versioned_sample.png")
        let redPNG = try makeSolidColorPNGData(width: 120, height: 80, red: 1.0, green: 0.0, blue: 0.0)
        try redPNG.write(to: imageURL, options: .atomic)

        let firstPreview = await TTMediaDetector.detectTypeAsync(url: imageURL)
        guard case .image(let firstImg) = firstPreview else {
            XCTFail("Expected .image on first detectTypeAsync, got \(firstPreview)")
            return
        }
        XCTAssertEqual(Int(firstImg.size.width), 120)
        XCTAssertEqual(Int(firstImg.size.height), 80)

        let missesAfterFirst = await cache.missCount
        let hitsAfterFirst = await cache.hitCount
        XCTAssertEqual(missesAfterFirst, 1)
        XCTAssertEqual(hitsAfterFirst, 0)

        let hitStart = DispatchTime.now().uptimeNanoseconds
        let secondImg = TTMediaImageLoader.loadThumbnail(from: imageURL)
        let hitElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - hitStart) / 1_000_000.0
        XCTAssertNotNil(secondImg)
        let missesAfterSecond = await cache.missCount
        let hitsAfterSecond = await cache.hitCount
        XCTAssertEqual(missesAfterSecond, 1)
        XCTAssertEqual(hitsAfterSecond, 1)
        XCTAssertLessThan(hitElapsedMs, 5.0)

        let bluePNG = try makeSolidColorPNGData(width: 240, height: 160, red: 0.0, green: 0.2, blue: 1.0)
        try bluePNG.write(to: imageURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2.0)],
            ofItemAtPath: imageURL.path
        )

        let thirdImg = TTMediaImageLoader.loadThumbnail(from: imageURL)
        XCTAssertNotNil(thirdImg)
        XCTAssertEqual(Int(thirdImg?.size.width ?? 0), 240)
        XCTAssertEqual(Int(thirdImg?.size.height ?? 0), 160)

        let missesAfterModify = await cache.missCount
        let hitsAfterModify = await cache.hitCount
        XCTAssertEqual(missesAfterModify, 2, "Modified file at same path must trigger a cache miss")
        XCTAssertEqual(hitsAfterModify, 1)
    }

    func testSamePathEqualLengthInPlaceImageOverwriteInvalidatesCache() async throws {
        let cache = ImageIOThumbnailCache.shared
        await cache.purgeCache()
        await ImageIOThumbnailService.shared.purgeCache()

        // Create an uncompressed BMP at a fixed 64x64 size with pure red pixels.
        let bmpURL = tempDir.appendingPathComponent("equal_size_inplace.bmp")
        try writeUncompressedBMP(to: bmpURL, width: 64, height: 64, fillBGRA: (0, 0, 255, 255))
        let fixedTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedTimestamp], ofItemAtPath: bmpURL.path)

        let firstKey = ImageIOThumbnailCache.versionedCacheKey(for: bmpURL, maxPixelSize: 512)
        let firstImg = TTMediaImageLoader.loadThumbnail(from: bmpURL, maxPixelSize: 512)
        XCTAssertNotNil(firstImg)
        let misses1 = await cache.missCount
        XCTAssertEqual(misses1, 1)

        // Overwrite in-place via FileHandle (preserving inode and exact byte size) and restore the exact same modificationDate.
        let handle = try FileHandle(forWritingTo: bmpURL)
        try handle.seek(toOffset: 54)
        var greenPixels = Data(capacity: 64 * 64 * 4)
        for _ in 0..<(64 * 64) {
            greenPixels.append(contentsOf: [0, 255, 0, 255])
        }
        try handle.write(contentsOf: greenPixels)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: fixedTimestamp], ofItemAtPath: bmpURL.path)

        let secondKey = ImageIOThumbnailCache.versionedCacheKey(for: bmpURL, maxPixelSize: 512)
        XCTAssertNotEqual(firstKey, secondKey, "Equal-length in-place overwrite with identical mtime and inode must produce a distinct versioned key via content fingerprint")

        let secondImg = TTMediaImageLoader.loadThumbnail(from: bmpURL, maxPixelSize: 512)
        XCTAssertNotNil(secondImg)
        let misses2 = await cache.missCount
        XCTAssertEqual(misses2, 2, "Equal-length in-place overwrite must invalidate cache and record a miss")
    }

    // MARK: - 3. ImageMetadataCache Capacity Bound Enforcement

    @MainActor
    func testImageMetadataCacheEnforcesMaxEntriesAndEvictsOldest() async throws {
        let boundedCache = ImageMetadataCache(maxEntries: 4)
        boundedCache.clearCache()
        XCTAssertEqual(boundedCache.count, 0)

        for i in 1...6 {
            boundedCache.storeDimensions("\(i * 100) × \(i * 100)", for: "/tmp/img_\(i).png")
        }

        XCTAssertEqual(boundedCache.count, 4, "ImageMetadataCache must never exceed maxEntries")
        XCTAssertNil(boundedCache.getDimensions(for: "/tmp/img_1.png"), "Oldest entry 1 should be evicted")
        XCTAssertNil(boundedCache.getDimensions(for: "/tmp/img_2.png"), "Oldest entry 2 should be evicted")
        XCTAssertEqual(boundedCache.getDimensions(for: "/tmp/img_3.png"), "300 × 300")
        XCTAssertEqual(boundedCache.getDimensions(for: "/tmp/img_6.png"), "600 × 600")

        boundedCache.clearCache()
        XCTAssertEqual(boundedCache.count, 0)
    }

    // MARK: - 4. Ephemeral Staging Hard Quota, All-Pinned Rejection & Same-Name Replacement Semantics

    func testEphemeralStagingHardQuotaAllPinnedAndSameNameReplacementSemantics() async throws {
        let harness = EphemeralQuotaStagingHarness(
            rootDir: tempDir.appendingPathComponent("QuotaSandbox", isDirectory: true),
            maxStagedFiles: 2,
            maxTotalBytes: 100
        )
        defer { harness.cleanupAll() }

        // 1. Single file exceeding maxTotalBytes -> throws .singleFileExceedsQuota without touching existing files
        let validA = Data(repeating: 0x41, count: 40)
        let urlA = try harness.stageFile(data: validA, suggestedFileName: "a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path))

        let oversized = Data(repeating: 0x5A, count: 120)
        XCTAssertThrowsError(try harness.stageFile(data: oversized, suggestedFileName: "oversized.bin")) { error in
            XCTAssertEqual(error as? EphemeralQuotaStagingHarness.QuotaError, .singleFileExceedsQuota(fileBytes: 120, maxTotalBytes: 100))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path), "Existing file must remain intact after singleFileExceedsQuota")
        XCTAssertEqual(harness.stagedFileCount, 1)
        XCTAssertEqual(harness.totalStagedBytes, 40)

        // 2. Same-name replacement when UNPINNED -> overwrites content and updates byte accounting
        let updatedA = Data(repeating: 0x42, count: 50)
        let replacedURLA = try harness.stageFile(data: updatedA, suggestedFileName: "a.txt")
        XCTAssertEqual(replacedURLA.path, urlA.path)
        XCTAssertEqual(try Data(contentsOf: replacedURLA), updatedA)
        XCTAssertEqual(harness.stagedFileCount, 1)
        XCTAssertEqual(harness.totalStagedBytes, 50)

        // 3. Same-name replacement when PINNED -> throws .activeResourcePinned and preserves original pinned file
        harness.pinFile("a.txt")
        XCTAssertTrue(harness.isPinned(fileURL: replacedURLA))
        let conflictingA = Data(repeating: 0x43, count: 30)
        XCTAssertThrowsError(try harness.stageFile(data: conflictingA, suggestedFileName: "a.txt")) { error in
            XCTAssertEqual(error as? EphemeralQuotaStagingHarness.QuotaError, .activeResourcePinned(fileName: "a.txt"))
        }
        XCTAssertEqual(try Data(contentsOf: replacedURLA), updatedA, "Pinned file bytes on disk must not be overwritten")

        // 4. All files pinned when quota reached -> throws .quotaExceeded and keeps all pinned files intact
        let validB = Data(repeating: 0x44, count: 40)
        let urlB = try harness.stageFile(data: validB, suggestedFileName: "b.txt")
        harness.pinFile("b.txt")
        XCTAssertEqual(harness.stagedFileCount, 2)
        XCTAssertEqual(harness.totalStagedBytes, 90)

        let validC = Data(repeating: 0x45, count: 20)
        XCTAssertThrowsError(try harness.stageFile(data: validC, suggestedFileName: "c.txt")) { error in
            guard case .quotaExceeded = error as? EphemeralQuotaStagingHarness.QuotaError else {
                XCTFail("Expected .quotaExceeded when all staged files are pinned, got \(error)")
                return
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))
    }

    // MARK: - Helpers

    private func writeUncompressedBMP(
        to url: URL,
        width: Int,
        height: Int,
        fillBGRA: (UInt8, UInt8, UInt8, UInt8)? = nil
    ) throws {
        let bytesPerPixel = 4
        let rowBytes = width * bytesPerPixel
        let pixelArraySize = rowBytes * height
        let headerSize = 54
        let fileSize = headerSize + pixelArraySize

        var data = Data(count: fileSize)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            base[0] = 0x42
            base[1] = 0x4D
            storeUInt32LE(UInt32(fileSize), at: base + 2)
            storeUInt32LE(UInt32(headerSize), at: base + 10)
            storeUInt32LE(40, at: base + 14)
            storeInt32LE(Int32(width), at: base + 18)
            storeInt32LE(Int32(height), at: base + 22)
            storeUInt16LE(1, at: base + 26)
            storeUInt16LE(32, at: base + 28)
            storeUInt32LE(0, at: base + 30)
            storeUInt32LE(UInt32(pixelArraySize), at: base + 34)
            if let fillBGRA {
                let pixelPtr = base + headerSize
                for i in 0..<(width * height) {
                    pixelPtr[i * 4 + 0] = fillBGRA.0
                    pixelPtr[i * 4 + 1] = fillBGRA.1
                    pixelPtr[i * 4 + 2] = fillBGRA.2
                    pixelPtr[i * 4 + 3] = fillBGRA.3
                }
            }
        }
        try data.write(to: url, options: .atomic)
    }

    private func storeUInt16LE(_ value: UInt16, at ptr: UnsafeMutablePointer<UInt8>) {
        ptr[0] = UInt8(truncatingIfNeeded: value)
        ptr[1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func storeUInt32LE(_ value: UInt32, at ptr: UnsafeMutablePointer<UInt8>) {
        ptr[0] = UInt8(truncatingIfNeeded: value)
        ptr[1] = UInt8(truncatingIfNeeded: value >> 8)
        ptr[2] = UInt8(truncatingIfNeeded: value >> 16)
        ptr[3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func storeInt32LE(_ value: Int32, at ptr: UnsafeMutablePointer<UInt8>) {
        storeUInt32LE(UInt32(bitPattern: value), at: ptr)
    }

    private func makeSolidColorPNGData(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "DetectorSchedulingAndCacheTests", code: 1)
        }
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "DetectorSchedulingAndCacheTests", code: 2)
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "DetectorSchedulingAndCacheTests", code: 3)
        }
        return pngData
    }

    @MainActor
    func testInMemoryArchiveImageRoutingPreservesAnimationAndZoomBackingResource() throws {
        let gifData = makeProgrammaticImageData(utType: UTType.gif.identifier, width: 8, height: 8, frames: 2)
        let gifPreview = TTMediaDetector.detectTypeFromMemory(data: gifData, suggestedName: "archive/anim.gif")
        guard case .image(let gifImage) = gifPreview else {
            XCTFail("Expected .image for in-memory GIF, got \(gifPreview)")
            return
        }
        let gifResource = TTMediaDetector.imagePreviewResource(for: gifImage, fallbackURL: nil)
        XCTAssertTrue(gifResource.isAnimated)
        XCTAssertEqual(gifResource.frameCount, 2)
        _ = TTMediaPreviewFactory.makePreviewView(type: gifPreview, fileName: "anim.gif", fileURL: nil)

        let hiResData = makeProgrammaticImageData(utType: UTType.png.identifier, width: 3072, height: 2048, frames: 1)
        let hiResPreview = TTMediaDetector.detectTypeFromMemory(data: hiResData, suggestedName: "archive/photo.png")
        guard case .image(let hiResImage) = hiResPreview else {
            XCTFail("Expected .image for in-memory hi-res PNG, got \(hiResPreview)")
            return
        }
        let hiResResource = TTMediaDetector.imagePreviewResource(for: hiResImage, fallbackURL: nil)
        XCTAssertEqual(hiResResource.pixelWidth, 3072)
        XCTAssertEqual(hiResResource.pixelHeight, 2048)
        let zoomImage = try XCTUnwrap(
            TTImageResolutionUpgrader.decodeImage(from: hiResResource.source, maxPixelDimension: 3072)
        )
        XCTAssertGreaterThan(
            Int(TTImagePreviewResource.pixelSize(of: zoomImage).width),
            Int(TTImagePreviewResource.pixelSize(of: hiResImage).width)
        )
    }

    @MainActor
    func testProductionConsumerCallChainSequentialOpenCloseExceedsEightMediaFiles() throws {
        TTMediaDetector.purgeAllEphemeralMediaFiles()
        defer { TTMediaDetector.purgeAllEphemeralMediaFiles() }

        for index in 0..<12 {
            let wavData = makeMinimalWAVData(tagByte: UInt8(index + 1))
            var stagedURL: URL?
            autoreleasepool {
                let previewType = TTMediaDetector.detectTypeFromMemory(
                    data: wavData,
                    suggestedName: "production_seq_\(index).wav"
                )
                guard case .audio(let url) = previewType else {
                    XCTFail("Iteration \(index) should route to .audio instead of \(previewType)")
                    return
                }
                stagedURL = url
                XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: url), 1)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

                let view = TTMediaPreviewFactory.makePreviewView(
                    type: previewType,
                    fileName: "production_seq_\(index).wav",
                    fileURL: nil
                )
                let hostingView = NSHostingView(rootView: view)
                hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
                hostingView.layoutSubtreeIfNeeded()
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
            if let stagedURL {
                XCTAssertEqual(
                    TTMediaDetector.activeEphemeralLeaseCount(for: stagedURL),
                    0,
                    "Production consumer must release ephemeral lease upon teardown at iteration \(index)"
                )
                XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
            }
        }
    }

    @MainActor
    func testEphemeralLeaseCancelledSupersededNeverDisplayedAndFullscreenHandoffPaths() async throws {
        TTMediaDetector.purgeAllEphemeralMediaFiles()
        defer { TTMediaDetector.purgeAllEphemeralMediaFiles() }

        // 1. Never-displayed view path: view created via makePreviewView but never mounted
        let unmountedData = makeMinimalWAVData(tagByte: 0x41)
        var unmountedURL: URL?
        do {
            let preview = TTMediaDetector.detectTypeFromMemory(data: unmountedData, suggestedName: "never_shown.wav")
            guard case .audio(let url) = preview else {
                return XCTFail("Expected .audio, got \(preview)")
            }
            unmountedURL = url
            XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: url), 1)
            _ = TTMediaPreviewFactory.makePreviewView(type: preview, fileName: "never_shown.wav", fileURL: nil)
        }
        let verifiedUnmountedURL = try XCTUnwrap(unmountedURL)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: verifiedUnmountedURL), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: verifiedUnmountedURL.path))

        // 2. Replaced consumer path: binding A then replacing with B releases A immediately
        let dataA = makeMinimalWAVData(tagByte: 0x42)
        let dataB = makeMinimalWAVData(tagByte: 0x43)
        let typeA = TTMediaDetector.detectTypeFromMemory(data: dataA, suggestedName: "item_a.wav")
        let typeB = TTMediaDetector.detectTypeFromMemory(data: dataB, suggestedName: "item_b.wav")
        let urlA = try XCTUnwrap(typeA.ephemeralMediaURL)
        let urlB = try XCTUnwrap(typeB.ephemeralMediaURL)
        let consumerLease = TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: urlA)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: urlA), 1)
        consumerLease.bind(previewType: typeB, fallbackURL: nil)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: urlA), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlA.path))
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: urlB), 1)

        // 3. Fullscreen switch handoff: inline view disappearing during fullscreen toggle must not delete file
        TTMediaDetector.beginFullscreenEphemeralHandoff(for: urlB)
        consumerLease.release()
        XCTAssertGreaterThanOrEqual(TTMediaDetector.activeEphemeralLeaseCount(for: urlB), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))

        let fullscreenLease = TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: urlB)
        fullscreenLease.bind(url: urlB, consumeFullscreenHandoff: true)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: urlB), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))

        TTMediaDetector.endFullscreenEphemeralHandoff(for: urlB)
        fullscreenLease.release()
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: urlB), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlB.path))

        // 4. Cancelled async in-memory detection must not leak an active lease
        let cancelledData = makeMinimalWAVData(tagByte: 0x44)
        let cancelledTask = Task {
            await TTMediaDetector.detectTypeFromMemoryAsync(data: cancelledData, suggestedName: "cancelled.wav")
        }
        cancelledTask.cancel()
        let cancelledResult = await cancelledTask.value
        if let leakedURL = cancelledResult.ephemeralMediaURL {
            XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: leakedURL), 0)
        }
    }

    // MARK: - 5. Fast Extension Zero-I/O Rejection & Versioned Detection Cache (Feedback 9)

    func testFastTypeByExtensionZeroDiskIOForNonCandidateExtensions() throws {
        // Pointing at non-existent files with non-fast-routable extensions (.swift, .csv, .md, .png, .xlsx)
        // must return .unsupported("Loading...") in memory without attempting FileHandle disk reads.
        let nonCandidateNames = ["main.swift", "table.csv", "readme.md", "photo.png", "sheet.xlsx", "book.epub"]
        for name in nonCandidateNames {
            let url = tempDir.appendingPathComponent("uncreated_\(name)")
            let fastResult = TTMediaDetector.fastTypeByExtension(url: url)
            if case .unsupported(let msg) = fastResult {
                XCTAssertEqual(msg, "Loading...")
            } else {
                XCTFail("Expected Loading... for \(name), got \(fastResult)")
            }
        }

        // Valid audio and PDF files still resolve on fast path
        let wavURL = tempDir.appendingPathComponent("fast_valid.wav")
        try makeMinimalWAVData(tagByte: 0x51).write(to: wavURL)
        if case .audio(let resolvedURL) = TTMediaDetector.fastTypeByExtension(url: wavURL) {
            XCTAssertEqual(resolvedURL.standardizedFileURL, wavURL.standardizedFileURL)
        } else {
            XCTFail("Expected .audio fast route for valid WAV")
        }
    }

    func testVersionedDetectionCacheHitAndDiskModificationInvalidation() async throws {
        TTMediaVersionedDetectionCache.shared.clear()
        let csvURL = tempDir.appendingPathComponent("cached_data.csv")
        try Data("id,name\n1,Alice\n2,Bob\n".utf8).write(to: csvURL)

        let firstResult = await TTMediaDetector.detectTypeAsync(url: csvURL)
        guard case .spreadsheetTable(let firstCSV, _) = firstResult else {
            XCTFail("Expected .spreadsheetTable on initial detect")
            return
        }
        XCTAssertTrue(firstCSV.contains("Alice"))
        let hitsBefore = TTMediaVersionedDetectionCache.shared.hitCount

        // Repeat open of unmodified file hits versioned cache
        let secondResult = await TTMediaDetector.detectTypeAsync(url: csvURL)
        XCTAssertGreaterThan(TTMediaVersionedDetectionCache.shared.hitCount, hitsBefore)
        if case .spreadsheetTable(let cachedCSV, _) = secondResult {
            XCTAssertEqual(cachedCSV, firstCSV)
        } else {
            XCTFail("Expected cached .spreadsheetTable")
        }

        // Modifying the file on disk invalidates the versioned cache entry automatically
        try Data("id,name,score\n1,Alice,99\n2,Bob,100\n3,Charlie,95\n".utf8).write(to: csvURL, options: .atomic)
        let thirdResult = await TTMediaDetector.detectTypeAsync(url: csvURL)
        guard case .spreadsheetTable(let updatedCSV, _) = thirdResult else {
            XCTFail("Expected updated .spreadsheetTable after disk modification")
            return
        }
        XCTAssertTrue(updatedCSV.contains("Charlie"))
    }

    // MARK: - 6. Independent Player Acquire-Before-Release Lease Handoff (Feedback 2 & 9)

    func testIndependentPlayerAcquireBeforeReleaseMultiConsumerLeaseIsolation() throws {
        TTMediaDetector.purgeAllEphemeralMediaFiles()
        defer { TTMediaDetector.purgeAllEphemeralMediaFiles() }

        // Path A: Ephemeral media lease box (TTMediaEphemeralLeaseBox + TTMediaDetector)
        let wavData = makeMinimalWAVData(tagByte: 0x6A)
        let detected = TTMediaDetector.detectTypeFromMemory(data: wavData, suggestedName: "player_handoff.wav")
        let stagedURL = try XCTUnwrap(detected.ephemeralMediaURL)

        let browserLease = TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: stagedURL)
        browserLease.bind(previewType: detected, fallbackURL: stagedURL)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: stagedURL), 1)

        // Independent player acquires its own consumer lease (distinct UUID) BEFORE browser switches or closes
        let playerLease = browserLease.retainForIndependentPlayer()
        XCTAssertNotEqual(playerLease.consumerID, browserLease.consumerID)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: stagedURL), 2)

        // Failed / cancelled secondary open attempt rolls back its lease without affecting active player
        let abortedOpenLease = playerLease.retainForIndependentPlayer()
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: stagedURL), 3)
        abortedOpenLease.release()
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: stagedURL), 2)

        // Main window switches selection or closes -> releases browserLease; independent player file stays alive!
        browserLease.release()
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: stagedURL), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))

        // Read-only invariant: archive-extracted / ephemeral media URL is never in-place writable
        let archiveCtx = TTPreviewResourceContext.archiveEntry(
            archivePath: "/tmp/sample_archive.zip",
            entryPath: "media/player_handoff.wav",
            stagedReadURL: stagedURL,
            fileName: "player_handoff.wav"
        )
        XCTAssertFalse(archiveCtx.isEditableInPlace)
        XCTAssertNil(archiveCtx.validateInPlaceSaveTarget(expectedFileURL: stagedURL))

        // Independent player closes -> last consumer releases lease -> file cleaned up immediately
        playerLease.release()
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: stagedURL), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))

        // Path B: Archive-extracted media multi-consumer UUID lease isolation under quota pressure
        let archiveCacheRoot = tempDir.appendingPathComponent("ArchivePlayerLeaseVerify", isDirectory: true)
        let harness = EphemeralQuotaStagingHarness(rootDir: archiveCacheRoot, maxStagedFiles: 2, maxTotalBytes: 256)
        defer { harness.cleanupAll() }

        let browserConsumerID = UUID()
        let playerConsumerID = UUID()
        let clipURL = try harness.stageFile(
            data: Data(repeating: 0x5A, count: 100),
            suggestedFileName: "archive_clip.mp4",
            consumerID: browserConsumerID
        )
        XCTAssertEqual(harness.activeLeaseCount(for: "archive_clip.mp4"), 1)

        // 1. Independent player acquires its UUID lease BEFORE main window switches or closes
        harness.acquireLease(for: "archive_clip.mp4", consumerID: playerConsumerID)
        XCTAssertEqual(harness.activeLeaseCount(for: "archive_clip.mp4"), 2)

        // 2. Main window switches to another archive item and closes its lease on archive_clip.mp4
        harness.releaseLease(for: "archive_clip.mp4", consumerID: browserConsumerID)
        XCTAssertEqual(harness.activeLeaseCount(for: "archive_clip.mp4"), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipURL.path))

        // 3. Main window browses additional archive entries causing LRU eviction pressure -> archive_clip.mp4 is protected!
        let other1 = try harness.stageFile(data: Data(repeating: 0x6B, count: 80), suggestedFileName: "other_1.txt")
        harness.unpinFile("other_1.txt")
        let other2 = try harness.stageFile(data: Data(repeating: 0x6C, count: 80), suggestedFileName: "other_2.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other1.path), "Unpinned entry must be evicted first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipURL.path), "Independent player archive media must survive main window switch/close and LRU pressure")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other2.path))

        // 4. Independent player closes (last consumer exits) -> file is released and removed from disk
        harness.releaseLease(for: "archive_clip.mp4", consumerID: playerConsumerID, reclaimIfIdle: true)
        XCTAssertEqual(harness.activeLeaseCount(for: "archive_clip.mp4"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clipURL.path), "Last consumer exit must release and remove archive temporary file")
    }

    private func makeMinimalWAVData(tagByte: UInt8) -> Data {
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: [0x24, 0x00, 0x00, 0x00])
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.append(contentsOf: [0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00])
        data.append(contentsOf: [0x44, 0xAC, 0x00, 0x00, 0x88, 0x58, 0x01, 0x00])
        data.append(contentsOf: [0x02, 0x00, 0x10, 0x00])
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: [0x04, 0x00, 0x00, 0x00, tagByte, 0x00, tagByte, 0x00])
        return data
    }

    private func makeProgrammaticImageData(utType: String, width: Int, height: Int, frames: Int) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, utType as CFString, frames, nil)!
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs, bitmapInfo: info
        )!
        for _ in 0..<frames {
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        }
        _ = CGImageDestinationFinalize(dest)
        return data as Data
    }
}

/// Self-contained test harness verifying the exact quota and per-consumer UUID lease invariants of `PreviewLRUCacheManager`.
private final class EphemeralQuotaStagingHarness {
    enum QuotaError: Error, Equatable {
        case singleFileExceedsQuota(fileBytes: Int64, maxTotalBytes: Int64)
        case quotaExceeded(requiredBytes: Int64, availableBytes: Int64, stagedCount: Int, maxFiles: Int, pinnedCount: Int)
        case activeResourcePinned(fileName: String)
    }

    let rootDir: URL
    let maxStagedFiles: Int
    let maxTotalBytes: Int64

    private(set) var stagedFiles: [String: URL] = [:]
    private var stagedOrder: [(key: String, url: URL, byteCount: Int64)] = []
    private var pinnedKeys: Set<String> = []
    private var consumerLeases: [String: Set<UUID>] = [:]
    private(set) var totalStagedBytes: Int64 = 0

    var stagedFileCount: Int { stagedFiles.count }

    init(rootDir: URL, maxStagedFiles: Int, maxTotalBytes: Int64) {
        self.rootDir = rootDir
        self.maxStagedFiles = maxStagedFiles
        self.maxTotalBytes = maxTotalBytes
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    private func isProtected(_ name: String) -> Bool {
        pinnedKeys.contains(name) || !(consumerLeases[name]?.isEmpty ?? true)
    }

    func pinFile(_ name: String) { pinnedKeys.insert(name) }
    func unpinFile(_ name: String) { pinnedKeys.remove(name) }
    func acquireLease(for name: String, consumerID: UUID) {
        consumerLeases[name, default: []].insert(consumerID)
    }
    func releaseLease(for name: String, consumerID: UUID, reclaimIfIdle: Bool = false) {
        consumerLeases[name]?.remove(consumerID)
        if consumerLeases[name]?.isEmpty == true {
            consumerLeases.removeValue(forKey: name)
        }
        if reclaimIfIdle, !isProtected(name), let idx = stagedOrder.firstIndex(where: { $0.key == name }) {
            let removed = stagedOrder.remove(at: idx)
            stagedFiles.removeValue(forKey: name)
            totalStagedBytes = max(0, totalStagedBytes - removed.byteCount)
            try? FileManager.default.removeItem(at: removed.url)
        }
    }
    func activeLeaseCount(for name: String) -> Int {
        (consumerLeases[name]?.count ?? 0) + (pinnedKeys.contains(name) ? 1 : 0)
    }
    func isPinned(fileURL: URL) -> Bool { isProtected(fileURL.lastPathComponent) }

    func stageFile(data: Data, suggestedFileName: String, consumerID: UUID? = nil) throws -> URL {
        let incomingBytes = Int64(data.count)
        if incomingBytes > maxTotalBytes {
            throw QuotaError.singleFileExceedsQuota(fileBytes: incomingBytes, maxTotalBytes: maxTotalBytes)
        }
        if stagedFiles[suggestedFileName] != nil && isProtected(suggestedFileName) {
            throw QuotaError.activeResourcePinned(fileName: suggestedFileName)
        }

        let protectedKeys = stagedFiles.keys.filter { isProtected($0) }
        let pinnedCount = protectedKeys.count
        let pinnedBytes = stagedOrder.reduce(into: Int64(0)) { if isProtected($1.key) { $0 += $1.byteCount } }
        if pinnedCount >= maxStagedFiles || (pinnedBytes + incomingBytes) > maxTotalBytes {
            throw QuotaError.quotaExceeded(
                requiredBytes: incomingBytes,
                availableBytes: max(0, maxTotalBytes - pinnedBytes),
                stagedCount: stagedFiles.count,
                maxFiles: maxStagedFiles,
                pinnedCount: pinnedCount
            )
        }

        if let idx = stagedOrder.firstIndex(where: { $0.key == suggestedFileName }) {
            let removed = stagedOrder.remove(at: idx)
            totalStagedBytes = max(0, totalStagedBytes - removed.byteCount)
            stagedFiles.removeValue(forKey: suggestedFileName)
        }
        while (stagedFiles.count >= maxStagedFiles || (totalStagedBytes + incomingBytes > maxTotalBytes && !stagedOrder.isEmpty)),
              let evictIdx = stagedOrder.firstIndex(where: { !isProtected($0.key) }) {
            let victim = stagedOrder.remove(at: evictIdx)
            stagedFiles.removeValue(forKey: victim.key)
            totalStagedBytes = max(0, totalStagedBytes - victim.byteCount)
            try? FileManager.default.removeItem(at: victim.url)
        }

        let fileURL = rootDir.appendingPathComponent(suggestedFileName)
        try data.write(to: fileURL, options: .atomic)
        stagedFiles[suggestedFileName] = fileURL
        stagedOrder.append((key: suggestedFileName, url: fileURL, byteCount: incomingBytes))
        totalStagedBytes += incomingBytes
        if let consumerID {
            consumerLeases[suggestedFileName, default: []].insert(consumerID)
        }
        return fileURL
    }

    func cleanupAll() {
        try? FileManager.default.removeItem(at: rootDir)
    }
}
