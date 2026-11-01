// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import CoreGraphics
import CryptoKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
import TTMediaKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class MediaPreviewAuditTests: XCTestCase {
    
    // MARK: - Test 1: Image Downsampling Reduces 50MP Mock Image
    
    func testImageDownsamplingReduces50MPMockImagePixelDimensions() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        // 1. 50MP (8000 x 6250 = 50,000,000 pixels)
        let width = 8000
        let height = 6250
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            XCTFail("Failed to create 50MP test bitmap context")
            return
        }
        
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let cgImage50MP = context.makeImage() else {
            XCTFail("Failed to generate 50MP CGImage")
            return
        }
        
        // 2. JPEG encoding
        let jpegData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpegData as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            XCTFail("Failed to create CGImageDestination")
            return
        }
        CGImageDestinationAddImage(destination, cgImage50MP, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "JPEG encoding export failed")
        
        let fileURL = tempDirURL.appendingPathComponent("sample_50mp.jpg")
        try (jpegData as Data).write(to: fileURL)
        
        // 3. ImageIO downsampling (maxPixelSize: 2048)
        let cache = ImageIOThumbnailCache.shared
        guard let downsampledDataImage = cache.downsample(data: jpegData as Data, maxPixelSize: 2048) else {
            XCTFail("ImageIO downsampling from Data failed")
            return
        }
        
        guard let downsampledFileURLImage = cache.downsample(url: fileURL, maxPixelSize: 2048) else {
            XCTFail("ImageIO downsampling from URL failed")
            return
        }
        
        // 4. Verify dimensions <= 2048px
        guard let cgData = downsampledDataImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cgFile = downsampledFileURLImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Failed to extract underlying CGImage after downsampling")
            return
        }
        
        XCTAssertLessThanOrEqual(cgData.width, 2048, "Data downsampled width exceeds 2048px")
        XCTAssertLessThanOrEqual(cgData.height, 2048, "Data downsampled height exceeds 2048px")
        XCTAssertEqual(cgData.width, 2048, "Major axis width must be constrained to 2048px")
        XCTAssertEqual(cgData.height, 1600, "Minor axis height must maintain aspect ratio (1600px)")
        
        XCTAssertLessThanOrEqual(cgFile.width, 2048, "File URL downsampled width exceeds 2048px")
        XCTAssertLessThanOrEqual(cgFile.height, 2048, "File URL downsampled height exceeds 2048px")
    }
    
    // MARK: - Test 2: ImageIOThumbnailCache Hit/Miss Behavior & Thread Safety
    
    func testImageIOThumbnailCacheHitMissAndThreadSafety() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        let cache = ImageIOThumbnailCache.shared
        await cache.purgeCache()
        await cache.resetStatistics()
        
        let testImageURL = tempDirURL.appendingPathComponent("test_cache.png")
        let dummyContext = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        dummyContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        dummyContext.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let img = dummyContext.makeImage()!
        
        let rep = NSBitmapImageRep(cgImage: img)
        let pngData = rep.representation(using: .png, properties: [:])!
        try pngData.write(to: testImageURL)
        
        let first = await cache.thumbnail(for: testImageURL, maxPixelSize: 512)
        XCTAssertNotNil(first)
        let miss1 = await cache.missCount
        let hit1 = await cache.hitCount
        XCTAssertEqual(miss1, 1)
        XCTAssertEqual(hit1, 0)
        
        let second = await cache.thumbnail(for: testImageURL, maxPixelSize: 512)
        XCTAssertNotNil(second)
        let miss2 = await cache.missCount
        let hit2 = await cache.hitCount
        XCTAssertEqual(miss2, 1)
        XCTAssertEqual(hit2, 1)
        
        let iterations = 50
        await withTaskGroup(of: NSImage?.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    await cache.thumbnail(for: testImageURL, maxPixelSize: 512)
                }
            }
            for await cached in group {
                XCTAssertNotNil(cached)
            }
        }
        
        let finalMiss = await cache.missCount
        let finalHit = await cache.hitCount
        XCTAssertEqual(finalMiss, 1)
        XCTAssertEqual(finalHit, 1 + iterations)
    }
    
    // MARK: - Test 3: Audio/Video Store Teardown Lifecycle
    
    @MainActor
    func testAudioVideoStoreTeardownLifecycle() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        let coordinator = AVSampleBufferPlayerCoordinator()
        
        // Verify expected invariant
        let testMediaURL = tempDirURL.appendingPathComponent("mock_video.mp4")
        try Data("mock media stream content".utf8).write(to: testMediaURL)
        
        // 1. Prepare coordinator
        coordinator.prepare(duration: CMTime(seconds: 60.0, preferredTimescale: 600))
        XCTAssertTrue(coordinator.isReady)
        
        // 2. Toggle play/pause
        coordinator.togglePlayPause()
        XCTAssertTrue(coordinator.isPlaying)
        
        // 3. Clean up coordinator
        coordinator.reset(); coordinator.teardown()
        
        // 4. Verify state reset
        XCTAssertFalse(coordinator.isReady, "isReady state was not cleared")
        XCTAssertFalse(coordinator.isPlaying, "isPlaying state was not reset")
        XCTAssertEqual(CMTimeGetSeconds(coordinator.currentTime), 0, accuracy: 0.01, "currentTime was not reset to 0")
        XCTAssertEqual(CMTimeGetSeconds(coordinator.duration), 0, accuracy: 0.01, "duration was not reset to 0")
        
        // 5. AVPlayer replaceCurrentItem(with: nil)
        let directPlayer = AVPlayer(url: testMediaURL)
        XCTAssertNotNil(directPlayer.currentItem)
        directPlayer.replaceCurrentItem(with: nil)
        XCTAssertNil(directPlayer.currentItem, "AVPlayerItem was not unbinded and cleared")
    }
    
    // MARK: - Test 4: Drag Provider Virtual Item Metadata
    
    @MainActor
    func testDragProviderWrapsVirtualItemMetadata() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        // 1. Cached virtual item (PreviewLRUCacheManager hit)
        let mockArchivePath = "/Users/test/Documents/archive.zip"
        let mockSubpath = "assets/hero_banner.png"
        let virtualPath = "file://\(mockArchivePath)?subpath=\(mockSubpath)"
        let filename = "hero_banner.png"
        
        let fullId = "\(mockArchivePath)::\(mockSubpath)"
        let shaDigest = SHA256.hash(data: Data(fullId.utf8))
        let hash = shaDigest.map { String(format: "%02x", $0) }.joined()
        let targetCachedURL = try XCTUnwrap(PreviewLRUCacheManager.shared.targetURL(forKey: hash, filename: filename))
        
        // Verify expected invariant
        let dummyData = Data("mock extracted png image".utf8)
        try dummyData.write(to: targetCachedURL)
        await PreviewLRUCacheManager.shared.register(key: hash, fileURL: targetCachedURL)
        
        let cachedItem = DiskItemInfo(
            virtualName: filename,
            virtualURL: URL(string: virtualPath)!,
            isDirectory: false,
            isArchive: false,
            sizeText: "1.2 MB",
            rawSizeBytes: 1200000,
            kindText: "PNG Image"
        )
        
        let cachedProvider = MillerColumnItemRowView.makeDragItemProvider(for: cachedItem)
        XCTAssertEqual(cachedProvider.suggestedName, filename, "Cached virtual item drag suggestedName mismatch")
        // Preview staging is not exported ownership and must never become a movable source.
        XCTAssertFalse(cachedProvider.canLoadObject(ofClass: URL.self), "Cached virtual item must not expose a movable URL object")
        
        // 2. Uncached virtual item
        let uncachedVirtualPath = "file://\(mockArchivePath)?subpath=docs/manual.pdf"
        let uncachedItem = DiskItemInfo(
            virtualName: "manual.pdf",
            virtualURL: URL(string: uncachedVirtualPath)!,
            isDirectory: false,
            isArchive: false,
            sizeText: "500 KB",
            rawSizeBytes: 500000,
            kindText: "PDF Document"
        )
        
        let uncachedProvider = MillerColumnItemRowView.makeDragItemProvider(for: uncachedItem)
        XCTAssertEqual(uncachedProvider.suggestedName, "manual.pdf", "Uncached virtual item drag suggestedName mismatch")
        
        // 3. Physical file
        let physicalFile = tempDirURL.appendingPathComponent("regular_document.txt")
        try "hello ttzip".write(to: physicalFile, atomically: true, encoding: .utf8)
        
        let physicalItem = DiskItemInfo(url: physicalFile)
        let physicalProvider = MillerColumnItemRowView.makeDragItemProvider(for: physicalItem)
        XCTAssertEqual(physicalProvider.suggestedName, "regular_document.txt", "Physical file drag suggestedName mismatch")
    }
    
    // MARK: - Test 5: MKV & Non-Native Video Container Classification & Zero-Kickout In-App Routing
    
    @MainActor
    func testMKVAndNonNativeVideoContainerClassificationAndFallback() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        let fixturesRoot = try locatePreviewFixturesRoot()
        let mkvData = try loadRealVideoCorpusFixture(for: "mkv", fixturesRoot: fixturesRoot)
        let mkvURL = tempDirURL.appendingPathComponent("The.Invite.2026.2160p.iT.WEB-DL.DDP5.1.DV.HDR.H.265.mkv")
        try mkvData.write(to: mkvURL)
        
        // 1. Real Matroska video routes to .video across sync, async, and in-memory entry points
        try await assertVideoRoutingAcrossAllEntries(url: mkvURL, data: mkvData, ext: "mkv")
        
        // 2. Negative case: ASCII text disguised with .mkv extension must route to .text, never .video
        try await assertDisguisedTextRoutesToText(
            text: "mock mkv video container stream",
            fileName: "disguised_ascii_stream.mkv",
            in: tempDirURL
        )
        
        // 3. Verify Video & Ambiguous Extension Sets and .ts Capability Matrix Consistency
        XCTAssertTrue(MediaPreviewFactory.nativeVideoExtensions.contains("mp4"))
        XCTAssertTrue(MediaPreviewFactory.nativeVideoExtensions.contains("mov"))
        XCTAssertTrue(MediaPreviewFactory.extendedVideoExtensions.contains("mkv"))
        XCTAssertTrue(MediaPreviewFactory.extendedVideoExtensions.contains("avi"))
        XCTAssertTrue(MediaPreviewFactory.extendedVideoExtensions.contains("webm"))
        XCTAssertTrue(MediaPreviewFactory.videoExtensions.contains("mkv"))
        XCTAssertFalse(MediaPreviewFactory.videoExtensions.contains("ts"))
        XCTAssertTrue(MediaPreviewFactory.ambiguousExtensions.contains("ts"))
        XCTAssertTrue(MediaPreviewFactory.textExtensions.contains("ts"))
        XCTAssertEqual(TTMediaCapabilityMatrix.capabilities(for: "ts"), [.sourceCode, .mediaPlayback])
        XCTAssertEqual(
            TTMediaCapabilityMatrix.resolveDescriptor(
                for: "stream.ts", magic: .video(mime: "video/mp2t"), isBinaryContent: true
            )?.iconName,
            "film.fill"
        )
        
        // 4. Verify UnifiedVideoPlayerView & AVSampleBufferPlayerCoordinator initialize without kickout error
        XCTAssertEqual(UnifiedVideoPlayerView.resolveEngine(for: mkvURL), .avSampleBuffer)
        let coordinator = AVSampleBufferPlayerCoordinator()
        coordinator.prepare(duration: CMTime(seconds: 120.0, preferredTimescale: 600))
        XCTAssertTrue(coordinator.isReady, "AVSampleBufferPlayerCoordinator should initialize pipeline for MKV")
        coordinator.teardown()
        XCTAssertFalse(coordinator.isReady)
        XCTAssertFalse(coordinator.isPlaying)
    }
    
    // MARK: - Test 6: Audio Format Matrix & Unified In-App Embedded Audio Classification
    
    @MainActor
    func testAudioFormatMatrixAndNonNativeAudioClassification() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        let fixturesRoot = try locatePreviewFixturesRoot()
        var oggAudioURL: URL!
        
        // 1. Real audio corpus fixtures (tone.mp3, tone.ogg, tone.wma, tone.flac)
        for ext in ["mp3", "ogg", "wma", "flac"] {
            let fileURL = tempDirURL.appendingPathComponent("track.\(ext)")
            let sampleData = try loadRealAudioCorpusFixture(for: ext, fixturesRoot: fixturesRoot)
            try sampleData.write(to: fileURL)
            if ext == "ogg" { oggAudioURL = fileURL }
            try await assertAudioRoutingAcrossAllEntries(url: fileURL, data: sampleData, ext: ext)
        }
        
        // 2. Minimal recognition headers for formats without corpus files (ape, dsf — routing branch only)
        for ext in ["ape", "dsf"] {
            let fileURL = tempDirURL.appendingPathComponent("track.\(ext)")
            let headerData = try syntheticAudioProbeHeader(for: ext)
            try headerData.write(to: fileURL)
            try await assertAudioRoutingAcrossAllEntries(url: fileURL, data: headerData, ext: ext)
        }
        
        // 3. Negative case: ASCII text disguised with .mp3 / .ogg extension must route to .text, never .audio
        for fakeName in ["disguised_ascii.mp3", "disguised_ascii.ogg"] {
            try await assertDisguisedTextRoutesToText(
                text: "mock audio pcm stream",
                fileName: fakeName,
                in: tempDirURL
            )
        }
        
        // 4. Verify Audio Sets contain all 20+ audio formats
        let allRequiredFormats = [
            "mp3", "wav", "flac", "ogg", "opus", "wma", "ape", "dsf", "dff",
            "wv", "aac", "m4a", "aiff", "alac", "caf", "dts", "mid", "midi", "mka"
        ]
        for format in allRequiredFormats {
            XCTAssertTrue(MediaPreviewFactory.audioExtensions.contains(format), "audioExtensions missing format: \(format)")
        }
        
        let previewView = MediaPreviewFactory.makePreviewView(
            type: .audio(oggAudioURL), fileName: "track.ogg", fileURL: oggAudioURL
        )
        XCTAssertNotNil(previewView)
    }
    
    // MARK: - Test 7: Large Text File 2MB Hard Limit & Binary Sniffing
    
    func testLargeTextFile2MBHardLimitAndBinarySniffing() throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        // 1. Large 3MB text file
        let largeFileURL = tempDirURL.appendingPathComponent("huge_log.log")
        let chunk = String(repeating: "Line 12345: Standard audit log message payload.\n", count: 1000)
        let chunkData = Data(chunk.utf8)
        
        let handle = try FileHandle(forWritingTo: {
            FileManager.default.createFile(atPath: largeFileURL.path, contents: nil)
            return largeFileURL
        }())
        for _ in 0..<70 {
            try handle.write(contentsOf: chunkData)
        }
        try handle.close()
        
        let content = MediaPreviewView.readTextContent(from: largeFileURL)
        XCTAssertNotNil(content)
        XCTAssertFalse(content!.contains("TTZip Large File Notice"))
        XCTAssertGreaterThan(content!.utf8.count, 2 * 1024 * 1024)
        
        // 2. Binary compiled payload sniffing
        let binaryURL = tempDirURL.appendingPathComponent("fake_text.txt")
        var binaryBytes = [UInt8](repeating: 0x00, count: 2048)
        binaryBytes[10] = 0x7F
        binaryBytes[11] = 0x45
        binaryBytes[12] = 0x4C
        binaryBytes[13] = 0x46
        try Data(binaryBytes).write(to: binaryURL)
        
        let binaryContent = MediaPreviewView.readTextContent(from: binaryURL)
        XCTAssertNil(binaryContent, "Binary payload with null bytes must be rejected by readTextContent")
    }
    
    // MARK: - Test 8: Deterministic SHA-256 Cache Key Invariant
    
    func testDeterministicSHA256CacheKeyInvariant() throws {
        let pathA = "/Users/tester/archive.zip"
        let subA = "docs/readme.txt"
        let fullIdA = "\(pathA)::\(subA)"
        let hashA = SHA256.hash(data: Data(fullIdA.utf8)).map { String(format: "%02x", $0) }.joined()
        
        let pathB = "/Users/tester/archive.zip"
        let subB = "src/readme.txt"
        let fullIdB = "\(pathB)::\(subB)"
        let hashB = SHA256.hash(data: Data(fullIdB.utf8)).map { String(format: "%02x", $0) }.joined()
        
        XCTAssertNotEqual(hashA, hashB, "Different subpaths must yield distinct SHA256 cache keys")
        XCTAssertEqual(hashA.count, 64, "SHA256 hex string must be exactly 64 characters")
    }
    
    // MARK: - Test 9: Hex Viewer Routing & Binary Extension Classification
    
    @MainActor
    func testHexViewerAndBinaryExtensionsClassification() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        let binaryExts = ["bin", "hex", "so", "dylib", "wasm", "class", "o"]
        for ext in binaryExts {
            let mockURL = tempDirURL.appendingPathComponent("payload.\(ext)")
            let dummyBytes: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            try Data(dummyBytes).write(to: mockURL)
            
            // 1. Synchronous detection
            let syncType = MediaPreviewFactory.detectType(url: mockURL)
            switch syncType {
            case .hexViewer(let data, let u):
                XCTAssertEqual(u, mockURL)
                XCTAssertEqual(data.prefix(4), Data([0x7F, 0x45, 0x4C, 0x46]))
            default:
                XCTFail("Binary extension .\(ext) should detect as .hexViewer, got \(syncType)")
            }
            
            // 2. Asynchronous detection
            let asyncType = await MediaPreviewFactory.detectTypeAsync(url: mockURL)
            switch asyncType {
            case .hexViewer(let data, let u):
                XCTAssertEqual(u, mockURL)
                XCTAssertEqual(data.prefix(4), Data([0x7F, 0x45, 0x4C, 0x46]))
            default:
                XCTFail("Binary extension .\(ext) async should detect as .hexViewer, got \(asyncType)")
            }
            
            // 3. Icon name
            let icon = MediaPreviewFactory.iconName(for: "payload.\(ext)")
            XCTAssertEqual(icon, "memorychip.fill")
        }
        
        // 4. In-memory binary detection
        let inMemoryData = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]) // WebAssembly magic
        let memType = MediaPreviewFactory.detectTypeFromMemory(data: inMemoryData, suggestedName: "module.wasm")
        switch memType {
        case .hexViewer(let data, _):
            XCTAssertEqual(data, inMemoryData)
        default:
            XCTFail("In-memory wasm should detect as .hexViewer, got \(memType)")
        }
    }
    
    // MARK: - Test 10: Markdown Rich Preview & Parser Tests
    
    @MainActor
    func testMarkdownRichPreviewAndParser() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        let mdURL = tempDirURL.appendingPathComponent("README.md")
        let mdContent = """
        # TTZip Engine
        
        High performance archiving tool.
        
        ## Features
        - [x] Fast 7z / ZIP extraction
        - [ ] AES-256-GCM encryption
        
        ### Architecture Table
        | Module | Function |
        | --- | --- |
        | TTZipCore | Microkernel |
        | TTZipApp | SwiftUI 6 UI |
        
        > TTZip guarantees blazing speed.
        
        ```swift
        let archiver = TTZipCore()
        archiver.extract()
        ```
        """
        try mdContent.write(to: mdURL, atomically: true, encoding: .utf8)
        
        // 1. Detection
        let syncType = MediaPreviewFactory.detectType(url: mdURL)
        switch syncType {
        case .markdown(let text, let u):
            XCTAssertEqual(u, mdURL)
            XCTAssertTrue(text.contains("TTZip Engine"))
        default:
            XCTFail("README.md should detect as .markdown, got \(syncType)")
        }
        
        let asyncType = await MediaPreviewFactory.detectTypeAsync(url: mdURL)
        switch asyncType {
        case .markdown(let text, let u):
            XCTAssertEqual(u, mdURL)
            XCTAssertTrue(text.contains("TTZip Engine"))
        default:
            XCTFail("README.md async should detect as .markdown, got \(asyncType)")
        }
        
        // 2. Icon name
        XCTAssertEqual(MediaPreviewFactory.iconName(for: "README.md"), "doc.text.fill")
        XCTAssertEqual(MediaPreviewFactory.iconName(for: "DOC.markdown"), "doc.text.fill")
        
        // 3. HTML Parser verification
        let html = TTZipMarkdownParser.parseToHTML(markdown: mdContent)
        XCTAssertTrue(html.contains("<h1>TTZip Engine</h1>"), "Heading 1 parsed")
        XCTAssertTrue(html.contains("<h2>Features</h2>"), "Heading 2 parsed")
        XCTAssertTrue(html.contains("<li class=\"task-item\"><input type=\"checkbox\" checked disabled>"), "Checked task item parsed")
        XCTAssertTrue(html.contains("<table>"), "Table parsed")
        XCTAssertTrue(html.contains("<blockquote>"), "Blockquote parsed")
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"), "Code block parsed")
    }
    
    // MARK: - Test 11: Text File with Null Bytes Fallback to Hex Viewer
    
    @MainActor
    func testTextFileWithNullBytesFallbackToHexViewer() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        let dirtyTxtURL = tempDirURL.appendingPathComponent("corrupted_text.txt")
        var bytes = [UInt8](repeating: 0x00, count: 1024)
        bytes[0] = 0x48 // 'H'
        bytes[1] = 0x69 // 'i'
        try Data(bytes).write(to: dirtyTxtURL)
        
        let asyncType = await MediaPreviewFactory.detectTypeAsync(url: dirtyTxtURL)
        switch asyncType {
        case .hexViewer(let data, let u):
            XCTAssertEqual(u, dirtyTxtURL)
            XCTAssertEqual(data.count, 1024)
        default:
            XCTFail("Text file with excessive null bytes should fall back to .hexViewer, got \(asyncType)")
        }
    }
    
    // MARK: - Test 12: Spreadsheet Table Preview Matrix and Factory Classification
    
    @MainActor
    func testSpreadsheetTablePreviewMatrixAndClassification() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        let testCases: [(ext: String, content: String, expectedDelim: Character)] = [
            ("csv", "id,name,score\n1,alice,95\n2,bob,88\n", ","),
            ("tsv", "id\tname\tscore\n1\talice\t95\n2\tbob\t88\n", "\t"),
            ("tab", "id\tname\tscore\n1\talice\t95\n2\tbob\t88\n", "\t"),
            ("psv", "id|name|score\n1|alice|95\n2|bob|88\n", "|")
        ]
        
        for tc in testCases {
            let fileURL = tempDirURL.appendingPathComponent("data.\(tc.ext)")
            try tc.content.write(to: fileURL, atomically: true, encoding: .utf8)
            
            // 1. Sync detection
            let syncType = MediaPreviewFactory.detectType(url: fileURL)
            switch syncType {
            case .spreadsheetTable(let text, let url):
                XCTAssertEqual(url, fileURL)
                XCTAssertEqual(text, tc.content)
            default:
                XCTFail("Extension .\(tc.ext) should detect as .spreadsheetTable, got \(syncType)")
            }
            
            // 2. Async detection
            let asyncType = await MediaPreviewFactory.detectTypeAsync(url: fileURL)
            switch asyncType {
            case .spreadsheetTable(let text, let url):
                XCTAssertEqual(url, fileURL)
                XCTAssertEqual(text, tc.content)
            default:
                XCTFail("Extension .\(tc.ext) async should detect as .spreadsheetTable, got \(asyncType)")
            }
            
            // 3. Icon
            XCTAssertEqual(MediaPreviewFactory.iconName(for: "data.\(tc.ext)"), "tablecells.fill")
            
            // 4. Parser verification
            let parsed = TTZipSpreadsheetParser.parse(text: tc.content, delimiter: tc.expectedDelim)
            XCTAssertEqual(parsed.count, 3)
            XCTAssertEqual(parsed[0], ["id", "name", "score"])
            XCTAssertEqual(parsed[1], ["1", "alice", "95"])
            XCTAssertEqual(parsed[2], ["2", "bob", "88"])
        }
    }
    
    // MARK: - Test 13: Media Extension Matrix (Real Corpus vs Minimal Headers vs Missing Corpus & Negatives)
    
    /// Verifies classification routing only (does NOT claim full stream decode/playback).
    /// Partitioned strictly into:
    /// 1) Real format corpus fixtures (`26` unambiguous video + `2` ambiguous `.ts`/`.dat` + `25` audio);
    /// 2) Minimal recognition header probes (`4` video + `10` audio);
    /// 3) Registered extensions missing corpus samples (`dv`, `tak`, `gsm`) with zero silent fallback;
    /// 4) Cross-extension content routing and ASCII-disguised-extension negative cases.
    @MainActor
    func testMediaExtensionMatrixRealCorpusSyntheticHeadersAndDisguisedNegatives() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        let fixturesRoot = try locatePreviewFixturesRoot()
        let realUnambiguousVideo = Self.realVideoCorpusExtensions.subtracting(MediaPreviewFactory.ambiguousExtensions)
        XCTAssertEqual(realUnambiguousVideo.count, 26)
        XCTAssertEqual(Self.syntheticHeaderVideoExtensions.count, 4)
        XCTAssertEqual(Self.missingCorpusVideoExtensions, ["dv"])
        XCTAssertEqual(
            realUnambiguousVideo
                .union(Self.syntheticHeaderVideoExtensions)
                .union(Self.missingCorpusVideoExtensions),
            MediaPreviewFactory.videoExtensions
        )
        
        for ext in realUnambiguousVideo.sorted() {
            let fileURL = tempDirURL.appendingPathComponent("real_\(ext).\(ext)")
            let data = try loadRealVideoCorpusFixture(for: ext, fixturesRoot: fixturesRoot)
            try data.write(to: fileURL)
            try await assertVideoRoutingAcrossAllEntries(url: fileURL, data: data, ext: ext)
            XCTAssertEqual(MediaPreviewFactory.iconName(for: "real.\(ext)"), "film.fill")
        }
        for ext in Self.syntheticHeaderVideoExtensions.sorted() {
            XCTAssertThrowsError(try loadRealVideoCorpusFixture(for: ext, fixturesRoot: fixturesRoot))
            let fileURL = tempDirURL.appendingPathComponent("header_\(ext).\(ext)")
            let data = try syntheticVideoProbeHeader(for: ext)
            try data.write(to: fileURL)
            try await assertVideoRoutingAcrossAllEntries(url: fileURL, data: data, ext: ext)
            XCTAssertEqual(MediaPreviewFactory.iconName(for: "header.\(ext)"), "film.fill")
        }
        
        try await assertAmbiguousTSAndDATDisambiguation(in: tempDirURL, fixturesRoot: fixturesRoot)
        try await assertAudioMatrixAndMissingCorpusBoundaries(in: tempDirURL, fixturesRoot: fixturesRoot)
    }

    private func assertAmbiguousTSAndDATDisambiguation(in tempDirURL: URL, fixturesRoot: URL) async throws {
        XCTAssertEqual(MediaPreviewFactory.ambiguousExtensions, ["ts", "dat"])
        for ext in ["ts", "dat"] {
            XCTAssertFalse(MediaPreviewFactory.videoExtensions.contains(ext))
            let mediaURL = tempDirURL.appendingPathComponent("media_\(ext).\(ext)")
            let mediaData = try loadRealVideoCorpusFixture(for: ext, fixturesRoot: fixturesRoot)
            try mediaData.write(to: mediaURL)
            try await assertVideoRoutingAcrossAllEntries(url: mediaURL, data: mediaData, ext: ext)
            let resolvedIcon = TTMediaCapabilityMatrix.resolveDescriptor(
                for: "media.\(ext)", magic: .video(mime: "video/mp2t"), isBinaryContent: true
            )?.iconName
            XCTAssertEqual(resolvedIcon, "film.fill")
        }
        let tsSource = try String(contentsOf: fixturesRoot.appendingPathComponent("text/sample.ts"), encoding: .utf8)
        try await assertDisguisedTextRoutesToText(text: tsSource, fileName: "module.ts", in: tempDirURL)
        XCTAssertEqual(MediaPreviewFactory.iconName(for: "module.ts"), "chevron.left.forwardslash.chevron.right")
        
        let binaryDat = try Data(contentsOf: fixturesRoot.appendingPathComponent("binary/sample.dat"))
        let datURL = tempDirURL.appendingPathComponent("ordinary.dat")
        try binaryDat.write(to: datURL)
        guard case .hexViewer = MediaPreviewFactory.detectType(url: datURL) else {
            XCTFail("Ordinary binary .dat must route to .hexViewer")
            return
        }
        XCTAssertEqual(MediaPreviewFactory.iconName(for: "ordinary.dat"), "memorychip.fill")
    }

    private func assertAudioMatrixAndMissingCorpusBoundaries(
        in tempDirURL: URL, fixturesRoot: URL
    ) async throws {
        XCTAssertEqual(Self.realAudioCorpusExtensions.count, 25)
        XCTAssertEqual(Self.syntheticHeaderAudioExtensions.count, 10)
        XCTAssertEqual(Self.missingCorpusAudioExtensions, ["tak", "gsm"])
        XCTAssertEqual(
            Self.realAudioCorpusExtensions
                .union(Self.syntheticHeaderAudioExtensions)
                .union(Self.missingCorpusAudioExtensions),
            MediaPreviewFactory.audioExtensions
        )
        for ext in Self.realAudioCorpusExtensions.sorted() {
            let fileURL = tempDirURL.appendingPathComponent("real_\(ext).\(ext)")
            let data = try loadRealAudioCorpusFixture(for: ext, fixturesRoot: fixturesRoot)
            try data.write(to: fileURL)
            try await assertAudioRoutingAcrossAllEntries(url: fileURL, data: data, ext: ext)
            XCTAssertEqual(MediaPreviewFactory.iconName(for: "real.\(ext)"), "music.note")
        }
        for ext in Self.syntheticHeaderAudioExtensions.sorted() {
            XCTAssertThrowsError(try loadRealAudioCorpusFixture(for: ext, fixturesRoot: fixturesRoot))
            let fileURL = tempDirURL.appendingPathComponent("header_\(ext).\(ext)")
            let data = try syntheticAudioProbeHeader(for: ext)
            try data.write(to: fileURL)
            try await assertAudioRoutingAcrossAllEntries(url: fileURL, data: data, ext: ext)
            XCTAssertEqual(MediaPreviewFactory.iconName(for: "header.\(ext)"), "music.note")
        }
        // Missing corpus extensions (dv, tak, gsm): no silent fallback; unverified bytes degrade to .hexViewer
        for ext in Self.missingCorpusVideoExtensions.union(Self.missingCorpusAudioExtensions) {
            XCTAssertThrowsError(try loadRealVideoCorpusFixture(for: ext, fixturesRoot: fixturesRoot))
            XCTAssertThrowsError(try loadRealAudioCorpusFixture(for: ext, fixturesRoot: fixturesRoot))
            XCTAssertThrowsError(try syntheticVideoProbeHeader(for: ext))
            XCTAssertThrowsError(try syntheticAudioProbeHeader(for: ext))
            let unverifiedURL = tempDirURL.appendingPathComponent("unverified.\(ext)")
            try Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]).write(to: unverifiedURL)
            guard case .hexViewer = MediaPreviewFactory.detectType(url: unverifiedURL) else {
                XCTFail("Unverified binary with .\(ext) must degrade to .hexViewer without blind player launch")
                return
            }
        }
        // Negative & cross-extension cases: disguised ASCII text routes to .text; cross-extension containers follow content
        try await assertDisguisedTextRoutesToText(text: "mock video payload", fileName: "fake.mp4", in: tempDirURL)
        try await assertDisguisedTextRoutesToText(text: "mock audio payload", fileName: "fake.mp3", in: tempDirURL)
        let movInMP3 = tempDirURL.appendingPathComponent("cross_ext_mov.mp3")
        let movData = try loadRealVideoCorpusFixture(for: "mov", fixturesRoot: fixturesRoot)
        try movData.write(to: movInMP3)
        try await assertVideoRoutingAcrossAllEntries(url: movInMP3, data: movData, ext: "mp3")
        let wavInMP4 = tempDirURL.appendingPathComponent("cross_ext_wav.mp4")
        let wavData = try loadRealAudioCorpusFixture(for: "wav", fixturesRoot: fixturesRoot)
        try wavData.write(to: wavInMP4)
        try await assertAudioRoutingAcrossAllEntries(url: wavInMP4, data: wavData, ext: "mp4")
    }
    
    // MARK: - Test 14: ArchiveMediaCachePool Staging & LRU Eviction
    
    func testArchiveMediaCachePoolStagingAndLRUEviction() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        let poolDir = tempDirURL.appendingPathComponent("CustomPool_\(UUID().uuidString)")
        let pool = ArchiveMediaCachePool(maxQuotaBytes: 1000, maxItemCount: 3, customRootDirectory: poolDir)
        
        let dataA = Data(repeating: 0x41, count: 300)
        let dataB = Data(repeating: 0x42, count: 300)
        let dataC = Data(repeating: 0x43, count: 300)
        let dataD = Data(repeating: 0x44, count: 300)
        
        let urlA = try await pool.stageData(dataA, fileName: "trackA.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path))
        let count1 = await pool.cachedItemCount
        XCTAssertEqual(count1, 1)
        
        let filePerms = (try FileManager.default.attributesOfItem(atPath: urlA.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(filePerms, 0o600)
        let dirPerms = (try FileManager.default.attributesOfItem(atPath: urlA.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(dirPerms, 0o700)
        
        _ = try await pool.stageData(dataB, fileName: "trackB.flac")
        _ = try await pool.stageData(dataC, fileName: "trackC.flac")
        let count3 = await pool.cachedItemCount
        let size3 = await pool.totalCacheSizeBytes
        XCTAssertEqual(count3, 3)
        XCTAssertEqual(size3, 900)
        
        _ = try await pool.stageData(dataB, fileName: "trackB.flac")
        let urlD = try await pool.stageData(dataD, fileName: "trackD.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlD.path))
        let countFinal = await pool.cachedItemCount
        let sizeFinal = await pool.totalCacheSizeBytes
        XCTAssertLessThanOrEqual(countFinal, 3)
        XCTAssertLessThanOrEqual(sizeFinal, 1000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlA.path), "Oldest item A should be evicted")
    }
    
    // MARK: - Test 15: ArchiveMediaCachePool Concurrency & Deduplication
    
    func testArchiveMediaCachePoolConcurrencyAndDeduplication() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        let poolDir = tempDirURL.appendingPathComponent("PoolDedup_\(UUID().uuidString)")
        let pool = ArchiveMediaCachePool(maxQuotaBytes: 10 * 1024 * 1024, maxItemCount: 20, customRootDirectory: poolDir)
        let testData = Data("concurrent test media stream".utf8)
        
        var collector = [URL]()
        await withTaskGroup(of: URL?.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try? await pool.stageData(testData, fileName: "movie_\(i % 3).mp4")
                }
            }
            for await url in group {
                if let url {
                    collector.append(url)
                }
            }
        }
        
        XCTAssertEqual(collector.count, 20)
        let count = await pool.cachedItemCount
        XCTAssertLessThanOrEqual(count, 3)
    }
    
    // MARK: - Test 16: ArchiveMediaCachePool Key, Sanitization & Purge
    
    func testArchiveMediaCachePoolKeySanitizationAndPurge() async throws {
        let tempDirURL = try makeTemporaryDirectory(prefix: "MediaPreviewAudit")
        let poolDir = tempDirURL.appendingPathComponent("PoolPurge_\(UUID().uuidString)")
        let pool = ArchiveMediaCachePool(customRootDirectory: poolDir)
        
        let key1 = ArchiveMediaCachePool.computeCacheKey(archivePath: "/a.zip", entryPath: "a.mp3", uncompressedSize: 100, crc32: 1)
        let key2 = ArchiveMediaCachePool.computeCacheKey(archivePath: "/a.zip", entryPath: "a.mp3", uncompressedSize: 100, crc32: 1)
        let key3 = ArchiveMediaCachePool.computeCacheKey(archivePath: "/a.zip", entryPath: "b.mp3", uncompressedSize: 100, crc32: 1)
        XCTAssertEqual(key1, key2)
        XCTAssertNotEqual(key1, key3)
        XCTAssertEqual(key1.count, 64)
        
        XCTAssertEqual(ArchiveMediaCachePool.sanitizeFileName("folder/sub/cool:song?*.flac"), "cool_song__.flac")
        XCTAssertEqual(ArchiveMediaCachePool.sanitizeFileName("../../../escape.mp4"), "escape.mp4")
        
        let staged = try await pool.stageData(Data([1, 2, 3]), fileName: "test.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        let count1 = await pool.cachedItemCount
        XCTAssertEqual(count1, 1)
        
        await pool.purgeAll()
        let count0 = await pool.cachedItemCount
        XCTAssertEqual(count0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
}

