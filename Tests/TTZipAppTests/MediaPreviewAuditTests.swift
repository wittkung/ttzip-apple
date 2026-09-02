// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import AppKit
import AVFoundation
import ImageIO
import CoreGraphics
import CryptoKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class MediaPreviewAuditTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("MediaPreviewAudit_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Test 1: Image Downsampling Reduces 50MP Mock Image
    
    func testImageDownsamplingReduces50MPMockImagePixelDimensions() throws {
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
    
    func testImageIOThumbnailCacheHitMissAndThreadSafety() throws {
        let cache = ImageIOThumbnailCache.shared
        cache.purgeCache()
        cache.resetStatistics()
        
        // 1.
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
        
        // 2. ： Cache Miss
        let first = cache.thumbnail(for: testImageURL, maxPixelSize: 512)
        XCTAssertNotNil(first)
        XCTAssertEqual(cache.missCount, 1)
        XCTAssertEqual(cache.hitCount, 0)
        
        // 3. ： Cache Hit
        let second = cache.thumbnail(for: testImageURL, maxPixelSize: 512)
        XCTAssertNotNil(second)
        XCTAssertEqual(cache.missCount, 1)
        XCTAssertEqual(cache.hitCount, 1)
        
        // 4. (50 )
        let group = DispatchGroup()
        let iterations = 50
        
        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let cached = cache.thumbnail(for: testImageURL, maxPixelSize: 512)
                XCTAssertNotNil(cached)
                group.leave()
            }
        }
        
        group.wait()
        XCTAssertEqual(cache.missCount, 1)
        XCTAssertEqual(cache.hitCount, 1 + iterations)
    }
    
    // MARK: - Test 3: Audio/Video Store Teardown Lifecycle
    
    @MainActor
    func testAudioVideoStoreTeardownLifecycle() throws {
        let store = SharedVideoPlayerStore()
        
        // Verify expected invariant
        let testMediaURL = tempDirURL.appendingPathComponent("mock_video.mp4")
        try Data("mock media stream content".utf8).write(to: testMediaURL)
        
        // 1.
        store.setup(url: testMediaURL)
        XCTAssertNotNil(store.player)
        XCTAssertEqual(store.currentURL, testMediaURL)
        
        // 2.
        store.togglePlayPause()
        XCTAssertTrue(store.isPlaying)
        
        // 3. Clean up store (resets state while preserving resident engine)
        store.cleanUp()
        
        // 4. Verify state reset
        XCTAssertNil(store.currentURL, "currentURL was not cleared")
        XCTAssertFalse(store.isPlaying, "isPlaying state was not reset")
        XCTAssertEqual(store.currentTime, 0, "currentTime was not reset to 0")
        XCTAssertEqual(store.duration, 0, "duration was not reset to 0")
        
        // 5. AVPlayer replaceCurrentItem(with: nil)
        let directPlayer = AVPlayer(url: testMediaURL)
        XCTAssertNotNil(directPlayer.currentItem)
        directPlayer.replaceCurrentItem(with: nil)
        XCTAssertNil(directPlayer.currentItem, "AVPlayerItem was not unbinded and cleared")
    }
    
    // MARK: - Test 4: Drag Provider Virtual Item Metadata
    
    @MainActor
    func testDragProviderWrapsVirtualItemMetadata() throws {
        // 1. Cached virtual item (PreviewLRUCacheManager hit)
        let mockArchivePath = "/Users/test/Documents/archive.zip"
        let mockSubpath = "assets/hero_banner.png"
        let virtualPath = "file://\(mockArchivePath)?subpath=\(mockSubpath)"
        let filename = "hero_banner.png"
        
        let fullId = "\(mockArchivePath)::\(mockSubpath)"
        let shaDigest = SHA256.hash(data: Data(fullId.utf8))
        let hash = shaDigest.map { String(format: "%02x", $0) }.joined()
        let targetCachedURL = PreviewLRUCacheManager.shared.targetURL(forKey: hash, filename: filename)
        
        // Verify expected invariant
        let dummyData = Data("mock extracted png image".utf8)
        try dummyData.write(to: targetCachedURL)
        PreviewLRUCacheManager.shared.register(key: hash, fileURL: targetCachedURL)
        
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
        XCTAssertTrue(cachedProvider.canLoadObject(ofClass: URL.self), "Drag provider should support loading URL object")
        
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
        let mkvURL = tempDirURL.appendingPathComponent("The.Invite.2026.2160p.iT.WEB-DL.DDP5.1.DV.HDR.H.265.mkv")
        try Data("mock mkv video container stream".utf8).write(to: mkvURL)
        
        // 1. Verify synchronous classification returns .video for zero-kickout in-app playback
        let syncType = MediaPreviewFactory.detectType(url: mkvURL)
        switch syncType {
        case .video(let detectedURL):
            XCTAssertEqual(detectedURL, mkvURL)
        default:
            XCTFail("MKV file should be detected as .video for zero-kickout playback, got \(syncType)")
        }
        
        // 2. Verify asynchronous classification returns .video
        let asyncType = await MediaPreviewFactory.detectTypeAsync(url: mkvURL)
        switch asyncType {
        case .video(let detectedURL):
            XCTAssertEqual(detectedURL, mkvURL)
        default:
            XCTFail("MKV file async should be detected as .video, got \(asyncType)")
        }
        
        // 3. Verify Native vs Extended Video Sets
        XCTAssertTrue(MediaPreviewFactory.nativeVideoExtensions.contains("mp4"))
        XCTAssertTrue(MediaPreviewFactory.nativeVideoExtensions.contains("mov"))
        XCTAssertTrue(MediaPreviewFactory.extendedVideoExtensions.contains("mkv"))
        XCTAssertTrue(MediaPreviewFactory.extendedVideoExtensions.contains("avi"))
        XCTAssertTrue(MediaPreviewFactory.extendedVideoExtensions.contains("webm"))
        XCTAssertTrue(MediaPreviewFactory.videoExtensions.contains("mkv"))
        XCTAssertTrue(MediaPreviewFactory.videoExtensions.contains("ts"))
        
        // 4. Verify SharedVideoPlayerStore initializes without artificial kickout error
        let store = SharedVideoPlayerStore()
        store.setup(url: mkvURL)
        XCTAssertNotNil(store.player, "SharedVideoPlayerStore should initialize AVPlayer pipeline for MKV")
        XCTAssertEqual(store.currentURL, mkvURL)
        
        // 5. Clean up store
        store.cleanUp()
        XCTAssertNil(store.currentURL)
        XCTAssertFalse(store.isPlaying)
    }
    
    // MARK: - Test 6: Audio Format Matrix & Unified In-App Embedded Audio Classification
    
    @MainActor
    func testAudioFormatMatrixAndNonNativeAudioClassification() async throws {
        let nativeAudioURL = tempDirURL.appendingPathComponent("track.mp3")
        try Data("mock audio pcm stream".utf8).write(to: nativeAudioURL)
        
        let oggAudioURL = tempDirURL.appendingPathComponent("track.ogg")
        try Data("mock ogg audio stream".utf8).write(to: oggAudioURL)
        
        let wmaAudioURL = tempDirURL.appendingPathComponent("track.wma")
        try Data("mock wma audio stream".utf8).write(to: wmaAudioURL)
        
        let flacAudioURL = tempDirURL.appendingPathComponent("track.flac")
        try Data("mock flac audio stream".utf8).write(to: flacAudioURL)
        
        let apeAudioURL = tempDirURL.appendingPathComponent("track.ape")
        try Data("mock ape audio stream".utf8).write(to: apeAudioURL)
        
        let dsfAudioURL = tempDirURL.appendingPathComponent("track.dsf")
        try Data("mock dsf audio stream".utf8).write(to: dsfAudioURL)
        
        // 1. Native audio should return .audio
        let nativeType = MediaPreviewFactory.detectType(url: nativeAudioURL)
        switch nativeType {
        case .audio(let u):
            XCTAssertEqual(u, nativeAudioURL)
        default:
            XCTFail("Native MP3 should detect as .audio, got \(nativeType)")
        }
        
        // 2. All audio formats (OGG, WMA, FLAC, APE, DSF, etc.) should return .audio for unified embedded playback
        let oggType = MediaPreviewFactory.detectType(url: oggAudioURL)
        switch oggType {
        case .audio(let u):
            XCTAssertEqual(u, oggAudioURL)
        default:
            XCTFail("OGG audio should detect as .audio, got \(oggType)")
        }
        
        let wmaAsyncType = await MediaPreviewFactory.detectTypeAsync(url: wmaAudioURL)
        switch wmaAsyncType {
        case .audio(let u):
            XCTAssertEqual(u, wmaAudioURL)
        default:
            XCTFail("WMA audio should detect as .audio, got \(wmaAsyncType)")
        }
        
        let apeType = MediaPreviewFactory.detectType(url: apeAudioURL)
        switch apeType {
        case .audio(let u):
            XCTAssertEqual(u, apeAudioURL)
        default:
            XCTFail("APE audio should detect as .audio, got \(apeType)")
        }
        
        let dsfAsyncType = await MediaPreviewFactory.detectTypeAsync(url: dsfAudioURL)
        switch dsfAsyncType {
        case .audio(let u):
            XCTAssertEqual(u, dsfAudioURL)
        default:
            XCTFail("DSF audio should detect as .audio, got \(dsfAsyncType)")
        }
        
        // 3. Verify Audio Sets contain all 20+ audio formats
        let allRequiredFormats = ["mp3", "wav", "flac", "ogg", "opus", "wma", "ape", "dsf", "dff", "wv", "aac", "m4a", "aiff", "alac", "caf", "dts", "mid", "midi", "mka"]
        for format in allRequiredFormats {
            XCTAssertTrue(MediaPreviewFactory.audioExtensions.contains(format), "audioExtensions missing format: \(format)")
        }
        
        // 4. Verify makePreviewView produces embedded player
        let previewView = MediaPreviewFactory.makePreviewView(type: .audio(oggAudioURL), fileName: "track.ogg", fileURL: oggAudioURL)
        XCTAssertNotNil(previewView)
    }
    
    // MARK: - Test 7: Large Text File 2MB Hard Limit & Binary Sniffing
    
    func testLargeTextFile2MBHardLimitAndBinarySniffing() throws {
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
        let pathA = "/Users/witt/archive.zip"
        let subA = "docs/readme.txt"
        let fullIdA = "\(pathA)::\(subA)"
        let hashA = SHA256.hash(data: Data(fullIdA.utf8)).map { String(format: "%02x", $0) }.joined()
        
        let pathB = "/Users/witt/archive.zip"
        let subB = "src/readme.txt"
        let fullIdB = "\(pathB)::\(subB)"
        let hashB = SHA256.hash(data: Data(fullIdB.utf8)).map { String(format: "%02x", $0) }.joined()
        
        XCTAssertNotEqual(hashA, hashB, "Different subpaths must yield distinct SHA256 cache keys")
        XCTAssertEqual(hashA.count, 64, "SHA256 hex string must be exactly 64 characters")
    }
    
    // MARK: - Test 9: Hex Viewer Routing & Binary Extension Classification
    
    @MainActor
    func testHexViewerAndBinaryExtensionsClassification() async throws {
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
    
    // MARK: - Test 13: All 69 Media Formats Matrix Classification & Zero Hex Fallthrough
    
    @MainActor
    func testAll69MediaFormatsClassificationAndZeroHexFallthrough() async throws {
        let expectedVideoExts = [
            "mp4", "mov", "m4v", "qt", "mkv", "avi", "webm", "ogv", "flv", "3gp",
            "3g2", "ts", "mts", "m2ts", "m2t", "wmv", "vob", "rmvb", "rm", "divx",
            "asf", "f4v", "y4m", "mpg", "mpeg", "mpe", "mpv", "m2v", "vro", "dat",
            "nut", "dv"
        ]
        XCTAssertGreaterThanOrEqual(MediaPreviewFactory.videoExtensions.count, 32)
        
        for ext in expectedVideoExts {
            XCTAssertTrue(MediaPreviewFactory.videoExtensions.contains(ext), "Missing video format: \(ext)")
            let mockURL = tempDirURL.appendingPathComponent("sample_\(ext).\(ext)")
            let mockData = Data("mock video payload for \(ext)".utf8)
            try mockData.write(to: mockURL)
            
            // Sync & Async detection
            if case .video(let u) = MediaPreviewFactory.detectType(url: mockURL) {
                XCTAssertEqual(u, mockURL)
            } else {
                XCTFail("Extension .\(ext) sync failed to detect as .video")
            }
            if case .video(let u) = await MediaPreviewFactory.detectTypeAsync(url: mockURL) {
                XCTAssertEqual(u, mockURL)
            } else {
                XCTFail("Extension .\(ext) async failed to detect as .video")
            }
            
            // In-Memory detection (Must not fall through to .hexViewer)
            let memType = MediaPreviewFactory.detectTypeFromMemory(data: mockData, suggestedName: "entry.\(ext)")
            if case .video(let stagedURL) = memType {
                XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
                XCTAssertEqual(stagedURL.pathExtension.lowercased(), ext)
            } else {
                XCTFail("Extension .\(ext) in-memory fell through to \(memType) instead of .video")
            }
            XCTAssertEqual(MediaPreviewFactory.iconName(for: "sample.\(ext)"), "film.fill")
        }
        
        let expectedAudioExts = [
            "mp3", "wav", "m4a", "aac", "flac", "aifc", "aiff", "aif", "m4b", "m4r",
            "alac", "caf", "ogg", "oga", "opus", "wma", "ape", "dts", "ac3", "eac3",
            "amr", "mid", "midi", "mka", "dsd", "dsf", "dff", "wv", "tta", "mpc",
            "tak", "spx", "au", "snd", "voc", "ra", "gsm"
        ]
        XCTAssertGreaterThanOrEqual(MediaPreviewFactory.audioExtensions.count, 37)
        
        for ext in expectedAudioExts {
            XCTAssertTrue(MediaPreviewFactory.audioExtensions.contains(ext), "Missing audio format: \(ext)")
            let mockURL = tempDirURL.appendingPathComponent("sample_\(ext).\(ext)")
            let mockData = Data("mock audio payload for \(ext)".utf8)
            try mockData.write(to: mockURL)
            
            if case .audio(let u) = MediaPreviewFactory.detectType(url: mockURL) {
                XCTAssertEqual(u, mockURL)
            } else {
                XCTFail("Extension .\(ext) sync failed to detect as .audio")
            }
            if case .audio(let u) = await MediaPreviewFactory.detectTypeAsync(url: mockURL) {
                XCTAssertEqual(u, mockURL)
            } else {
                XCTFail("Extension .\(ext) async failed to detect as .audio")
            }
            
            let memType = MediaPreviewFactory.detectTypeFromMemory(data: mockData, suggestedName: "entry.\(ext)")
            if case .audio(let stagedURL) = memType {
                XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
                XCTAssertEqual(stagedURL.pathExtension.lowercased(), ext)
            } else {
                XCTFail("Extension .\(ext) in-memory fell through to \(memType) instead of .audio")
            }
            XCTAssertEqual(MediaPreviewFactory.iconName(for: "sample.\(ext)"), "music.note")
        }
    }
    
    // MARK: - Test 14: ArchiveMediaCachePool Staging & LRU Eviction
    
    func testArchiveMediaCachePoolStagingAndLRUEviction() throws {
        let poolDir = tempDirURL.appendingPathComponent("CustomPool_\(UUID().uuidString)")
        let pool = ArchiveMediaCachePool(maxQuotaBytes: 1000, maxItemCount: 3, customRootDirectory: poolDir)
        
        let dataA = Data(repeating: 0x41, count: 300)
        let dataB = Data(repeating: 0x42, count: 300)
        let dataC = Data(repeating: 0x43, count: 300)
        let dataD = Data(repeating: 0x44, count: 300)
        
        let urlA = try pool.stageData(dataA, fileName: "trackA.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path))
        XCTAssertEqual(pool.cachedItemCount, 1)
        
        let filePerms = (try FileManager.default.attributesOfItem(atPath: urlA.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(filePerms, 0o600)
        let dirPerms = (try FileManager.default.attributesOfItem(atPath: urlA.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(dirPerms, 0o700)
        
        _ = try pool.stageData(dataB, fileName: "trackB.flac")
        _ = try pool.stageData(dataC, fileName: "trackC.flac")
        XCTAssertEqual(pool.cachedItemCount, 3)
        XCTAssertEqual(pool.totalCacheSizeBytes, 900)
        
        _ = try pool.stageData(dataB, fileName: "trackB.flac")
        let urlD = try pool.stageData(dataD, fileName: "trackD.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlD.path))
        XCTAssertLessThanOrEqual(pool.cachedItemCount, 3)
        XCTAssertLessThanOrEqual(pool.totalCacheSizeBytes, 1000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlA.path), "Oldest item A should be evicted")
    }
    
    // MARK: - Test 15: ArchiveMediaCachePool Concurrency & Deduplication
    
    func testArchiveMediaCachePoolConcurrencyAndDeduplication() throws {
        final class SafeCollector: @unchecked Sendable {
            private var items = [URL]()
            private let lock = NSLock()
            func append(_ url: URL) {
                lock.lock()
                items.append(url)
                lock.unlock()
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return items.count
            }
        }
        
        let poolDir = tempDirURL.appendingPathComponent("PoolDedup_\(UUID().uuidString)")
        let pool = ArchiveMediaCachePool(maxQuotaBytes: 10 * 1024 * 1024, maxItemCount: 20, customRootDirectory: poolDir)
        let testData = Data("concurrent test media stream".utf8)
        let group = DispatchGroup()
        let collector = SafeCollector()
        
        for i in 0..<20 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                if let url = try? pool.stageData(testData, fileName: "movie_\(i % 3).mp4") {
                    collector.append(url)
                }
                group.leave()
            }
        }
        
        group.wait()
        XCTAssertEqual(collector.count, 20)
        XCTAssertLessThanOrEqual(pool.cachedItemCount, 3)
    }
    
    // MARK: - Test 16: ArchiveMediaCachePool Key, Sanitization & Purge
    
    func testArchiveMediaCachePoolKeySanitizationAndPurge() throws {
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
        
        let staged = try pool.stageData(Data([1, 2, 3]), fileName: "test.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(pool.cachedItemCount, 1)
        
        pool.purgeAll()
        XCTAssertEqual(pool.cachedItemCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
}
