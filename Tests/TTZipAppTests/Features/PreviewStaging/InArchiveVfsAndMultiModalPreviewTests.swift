// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import os
import XCTest
import WebKit
@testable import TTZipPreviewKit
@testable import TTZipCore
@testable import TTZipApp

final class InArchiveVfsAndMultiModalPreviewTests: XCTestCase {
    
    // MARK: - TTZipArchiveVfsProvider Tests

    @MainActor
    func testWebKitRangeBoundsAndContentRangeMatchServedBytes() async throws {
        let provider = TTZipArchiveVfsProvider()
        let archiveID = provider.registerArchive(archivePath: "/tmp/\(UUID()).zip", password: nil)
        defer { provider.closeSession(archiveId: archiveID) }
        let fileName = "chapter.txt"
        let cap = TTZipArchiveVfsProvider.maxRangeSliceSize
        let bytes = Data(repeating: 0x41, count: cap + 2)
        provider.cacheEntryData(archiveId: archiveID, entryPath: fileName, data: bytes)
        let url = provider.makeVfsURL(archiveId: archiveID, entryPath: fileName)
        let webView = WKWebView()
        let handler = TTZipVfsSchemeHandler(provider: provider)

        let requests: [(String?, Int, String?, Int)] = [
            (nil, 200, nil, bytes.count),
            ("bytes=1-2", 206, "bytes 1-2/\(bytes.count)", 2),
            ("bytes=1-", 206, "bytes 1-\(cap)/\(bytes.count)", cap),
            ("bytes=0-\(Int.max)", 206, "bytes 0-\(cap - 1)/\(bytes.count)", cap),
            ("bytes=\(Int.max)-", 416, "bytes */\(bytes.count)", 0),
        ]
        for (header, statusCode, contentRange, count) in requests {
            var request = URLRequest(url: url)
            request.setValue(header, forHTTPHeaderField: "Range")
            let completed = expectation(description: header ?? "No Range")
            let task = RecordingRangeTask(request: request, completed: completed)
            handler.webView(webView, start: task)
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertNil(task.error)
            XCTAssertEqual(task.response?.statusCode, statusCode)
            XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Content-Range"), contentRange)
            XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Content-Length"), String(count))
            XCTAssertEqual(task.data, bytes.prefix(count))
        }
    }

    @MainActor
    func testHostedReadAccessServesColdRangesAndOrdinaryReads() async throws {
        let provider = TTZipArchiveVfsProvider()
        let archivePath = "/tmp/vfs-fixture.7z.001"
        let bytes = Data([0x31, 0x42, 0x53])
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        provider.installReadAccess(.init(
            readEntry: { path, entry, password in
                XCTAssertEqual(path, archivePath)
                XCTAssertEqual(password, "secret")
                reads.withLock { $0.append(entry) }
                return bytes
            },
            listEntrySizes: { path, password in
                XCTAssertEqual(path, archivePath)
                XCTAssertEqual(password, "secret")
                return [("./folder\\chapter.txt", UInt64(bytes.count))]
            }
        ))
        provider.installReadAccess(.init(
            readEntry: { _, _, _ in
                XCTFail("The first read access must remain installed")
                return nil
            },
            listEntrySizes: { _, _ in
                XCTFail("The first directory access must remain installed")
                return []
            }
        ))
        provider.installMediaCacheExtraction(.init(
            toDisk: { _, _, _, _ in XCTFail("A cold small range must read directly") },
            toMemory: { _, _, _ in
                XCTFail("Media cache fallback must not handle ordinary reads")
                return nil
            }
        ))

        let archiveId = provider.registerArchive(archivePath: archivePath, password: "secret")
        defer { provider.closeSession(archiveId: archiveId) }
        let chapterURI = provider.makeVfsURL(archiveId: archiveId, entryPath: "folder/chapter.txt").absoluteString
        let range = try await provider.loadResourceRange(uri: chapterURI, byteRange: 1...2)
        XCTAssertEqual(range?.data, Data(bytes.dropFirst()))
        XCTAssertEqual(range?.fullSize, Int64(bytes.count))
        let cachedChapter = try await provider.loadResource(uri: chapterURI)
        XCTAssertEqual(cachedChapter?.data, bytes)
        let note = try await provider.readEntryData(archiveId: archiveId, entryPath: "note.txt")
        XCTAssertEqual(note, bytes)
        XCTAssertEqual(reads.withLock { $0 }, ["folder/chapter.txt", "note.txt"])
    }

    @MainActor
    func testHostedLargeMediaRangeUsesTheFirstInstalledExtractor() async throws {
        let marker = Data([0x47, 0xb3, 0x55])
        try await checkLargeMediaRange(
            expected: marker,
            extraction: .init(
                toDisk: { archivePath, entryPath, outputDirectory, password in
                    XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath))
                    XCTAssertEqual(entryPath, "clip.mp4")
                    XCTAssertNil(password)
                    let clip = URL(fileURLWithPath: outputDirectory).appendingPathComponent(entryPath)
                    try marker.write(to: clip)
                },
                toMemory: { _, _, _ in
                    XCTFail("The host disk extractor supplied the range")
                    return nil
                }
            )
        )
    }

    @MainActor
    func testStandaloneLargeMediaRangeExtractsWithoutAppStartup() async throws {
        try await checkLargeMediaRange(expected: Data([0x13, 0x23, 0xa5]))
    }

    @MainActor
    func testLateSolidPreviewServesBytesThroughStandaloneAndHostedAccess() async throws {
        let archive = try solidPreviewFixture("tzip-654-lzma2-probe/native-probe.7z")
        let expected = Data("TTZIP-654 native LZMA2 target\n".utf8)
        for hosted in [false, true] {
            let provider = TTZipArchiveVfsProvider()
            if hosted { provider.installReadAccess(.archiveRuntime) }
            provider.installMediaCacheExtraction(.init(
                toDisk: { _, _, _, _ in XCTFail("Small preview should not use disk extraction") },
                toMemory: { _, _, _ in
                    XCTFail("Small preview should not retry via media cache")
                    return nil
                }
            ))
            for range: ClosedRange<Int>? in [nil, 1...3] {
                let archiveID = provider.registerSession(archiveURL: archive)
                let uri = provider.makeVfsURL(archiveId: archiveID, entryPath: "01-target.bin").absoluteString
                defer { provider.closeSession(archiveId: archiveID) }
                XCTAssertNil(provider.cachedData(for: uri))
                if let range {
                    let result = try await provider.loadResourceRange(uri: uri, byteRange: range)
                    XCTAssertEqual(result?.data, expected.subdata(in: 1..<4))
                    XCTAssertEqual(result?.fullSize, Int64(expected.count))
                } else {
                    let result = try await provider.loadResource(uri: uri)
                    XCTAssertEqual(result?.data, expected)
                }
            }
        }

        do {
            _ = try await ArchiveSelectiveExtractor.shared.extractSingleEntryData(
                archivePath: archive.path, entryPath: "01-target.bin"
            )
            XCTFail("Automatic preview must not populate the generic extraction cache")
        } catch ArchiveError.engineFailure(let code, _) {
            XCTAssertEqual(code, RustTTZipStatusCode.errSecurityViolation.rawValue)
        }

        for name in ["short-header-1025-files.7z", "big-header-701-files.7z"] {
            let path = try solidPreviewFixture("tzip-654-auto-preview/independent-compatibility/" + name).path
            let data = try await ArchiveRuntime.readEntry(archivePath: path, entryPath: "01-target.bin", password: nil)
            XCTAssertEqual(data, Data("ordinary preview".utf8))
        }
    }

    @MainActor
    func testLateSolidPreviewFailuresDoNotRetryThroughMediaCache() async throws {
        try await checkLateSolidPreviewFailure(
            fixture: "tzip-654-lzma2-integration/bad-crc.7z",
            expectedFailure: { $0 == .corruptHeader }
        )
        try await checkLateSolidPreviewFailure(
            fixture: "tzip-654-lzma2-probe/ratio-probe.7z",
            expectedFailure: {
                guard case let .engineFailure(code, _) = $0 else { return false }
                return code == RustTTZipStatusCode.errSecurityViolation.rawValue
            }
        )
    }

    @MainActor
    private func checkLateSolidPreviewFailure(
        fixture: String,
        expectedFailure: (ArchiveError) -> Bool
    ) async throws {
        let archive = try solidPreviewFixture(fixture)
        let provider = TTZipArchiveVfsProvider()
        provider.installReadAccess(.archiveRuntime)
        provider.installMediaCacheExtraction(.init(
            toDisk: { _, _, _, _ in XCTFail("Terminal preview failure should not use disk extraction") },
            toMemory: { _, _, _ in
                XCTFail("Terminal preview failure should not retry via media cache")
                return nil
            }
        ))
        let archiveID = provider.registerSession(archiveURL: archive)
        defer { provider.closeSession(archiveId: archiveID) }
        let uri = provider.makeVfsURL(archiveId: archiveID, entryPath: "01-target.bin").absoluteString
        for range: ClosedRange<Int>? in [nil, 0...1] {
            do {
                if let range {
                    _ = try await provider.loadResourceRange(uri: uri, byteRange: range)
                } else {
                    _ = try await provider.loadResource(uri: uri)
                }
                XCTFail("Expected terminal preview error for \(fixture), range \(String(describing: range))")
            } catch let error as ArchiveError {
                XCTAssertTrue(expectedFailure(error), "Unexpected preview error: \(error)")
                XCTAssertNil(provider.cachedData(for: uri))
            }
        }
    }

    private func solidPreviewFixture(_ path: String) throws -> URL {
        guard let root = ProcessInfo.processInfo.environment["TTZIP_654_OUTPUTS_DIR"] else {
            throw XCTSkip("Requires retained synthetic solid preview fixtures")
        }
        return URL(fileURLWithPath: root).appendingPathComponent(path)
    }

    @MainActor
    func testSolidBudgetFailureDoesNotRetryThroughMediaCache() async throws {
        let root = try makeTemporaryDirectory(prefix: "SolidVfsMedia")
        let prefix = root.appendingPathComponent("a-prefix.mp4")
        try Data().write(to: prefix)
        let handle = try FileHandle(forWritingTo: prefix)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 65 * 1024 * 1024)

        let file = root.appendingPathComponent("z-clip.mp4")
        try Data([0x13, 0x23, 0xa5]).write(to: file)
        let archive = root.appendingPathComponent("solid.7z")
        var options = ArchiveAdvancedOptions.defaultOptions
        options.enableSolidArchive = true
        try await ArchiveWriter().createArchive(
            outputPath: archive.path,
            format: .sevenZip,
            level: .fast,
            inputPaths: [prefix.path, file.path],
            advancedOptions: options
        )

        let provider = TTZipArchiveVfsProvider()
        provider.installMediaCacheExtraction(.init(
            toDisk: { _, _, _, _ in XCTFail("Budget failure must not trigger disk extraction") },
            toMemory: { _, _, _ in
                XCTFail("Budget failure must not trigger a second memory extraction")
                return nil
            }
        ))
        let archiveID = provider.registerSession(archiveURL: archive)
        defer { provider.closeSession(archiveId: archiveID) }
        let uri = provider.makeVfsURL(archiveId: archiveID, entryPath: file.lastPathComponent).absoluteString

        for range: ClosedRange<Int>? in [nil, 0...1] {
            do {
                if let range {
                    _ = try await provider.loadResourceRange(uri: uri, byteRange: range)
                } else {
                    _ = try await provider.loadResource(uri: uri)
                }
                XCTFail("Expected a solid budget error for range \(String(describing: range))")
            } catch ArchiveError.engineFailure(let code, _) {
                XCTAssertTrue([
                    RustTTZipStatusCode.errSecurityViolation.rawValue,
                    RustTTZipStatusCode.errOutOfMemory.rawValue,
                ].contains(code), "Unexpected preview failure code: \(code)")
            }
        }
        XCTAssertNil(provider.cachedData(for: uri))
    }

    @MainActor
    private func checkLargeMediaRange(
        expected: Data,
        extraction: ArchiveMediaCachePool.Extraction? = nil
    ) async throws {
        let root = try makeTemporaryDirectory(prefix: "LargeVfsMedia")
        let entryName = "clip.mp4"
        let entrySize = 8 * 1024 * 1024 + 1
        var data = Data(repeating: 0, count: entrySize)
        data.replaceSubrange(0..<3, with: [0x13, 0x23, 0xa5])
        let file = root.appendingPathComponent(entryName)
        try data.write(to: file)
        let archive = root.appendingPathComponent("fixture.zip")
        try await ArchiveWriter().createArchive(
            outputPath: archive.path,
            format: .zip,
            level: .fast,
            inputPaths: [file.path]
        )
        let provider = TTZipArchiveVfsProvider()
        if let extraction {
            provider.installMediaCacheExtraction(extraction)
            provider.installMediaCacheExtraction(.init(
                toDisk: { _, _, _, _ in XCTFail("A second install cannot replace the host") },
                toMemory: { _, _, _ in nil }
            ))
        }
        let archiveID = provider.registerSession(archiveURL: archive)
        defer { provider.closeSession(archiveId: archiveID) }
        let uri = provider.makeVfsURL(archiveId: archiveID, entryPath: entryName).absoluteString
        let result = try await provider.loadResourceRange(uri: uri, byteRange: 1...2)
        let response = try XCTUnwrap(result)
        XCTAssertEqual(response.data, Data(expected.dropFirst()))
        XCTAssertEqual(response.fullSize, Int64(entrySize))
        XCTAssertEqual(response.mimeType, "video/mp4")

        let wideRange = try await provider.loadResourceRange(uri: uri, byteRange: 2...Int.max)
        XCTAssertEqual(wideRange?.data.first, expected.last)
        XCTAssertEqual(wideRange?.data.count, extraction == nil ? TTZipArchiveVfsProvider.maxRangeSliceSize : 1)
        XCTAssertEqual(wideRange?.fullSize, Int64(entrySize))

        let cached = try await ArchiveMediaCachePool.shared.getOrExtractMedia(
            archivePath: archive.path,
            entryPath: entryName,
            uncompressedSize: Int64(entrySize)
        )
        XCTAssertEqual(Data(try Data(contentsOf: cached).prefix(3)), expected)
        try FileManager.default.removeItem(at: cached.deletingLastPathComponent())
    }
    
    func testVfsUrlGenerationAndParsing() {
        let provider = TTZipArchiveVfsProvider.shared
        let archivePath = "/Users/test/archive.7z"
        let entryPath = "documents/subfolder/readme.txt"
        
        let vfsURL = provider.vfsURL(archivePath: archivePath, password: "secret", entryPath: entryPath)
        XCTAssertEqual(vfsURL.scheme, TTZipVfsSchemeHandler.scheme)
        
        guard let (archiveId, parsedPath) = provider.parseVfsUri(vfsURL.absoluteString) else {
            XCTFail("Failed to parse VFS URI")
            return
        }
        
        XCTAssertFalse(archiveId.isEmpty)
        XCTAssertEqual(parsedPath, "documents/subfolder/readme.txt")
    }
    
    func testPathNormalizationSecurity() {
        XCTAssertEqual(TTZipArchiveVfsProvider.normalizePath("a/b/../c/./d.txt"), "a/c/d.txt")
        XCTAssertEqual(TTZipArchiveVfsProvider.normalizePath("../../../etc/passwd"), "etc/passwd")
        XCTAssertEqual(TTZipArchiveVfsProvider.normalizePath("//var//log//app.log"), "var/log/app.log")
        XCTAssertEqual(TTZipArchiveVfsProvider.normalizePath("folder\\sub\\file.png"), "folder/sub/file.png")
    }
    
    func testMimeTypeResolution() {
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "index.html"), "text/html; charset=utf-8")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "style.css"), "text/css; charset=utf-8")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "app.js"), "application/javascript; charset=utf-8")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "photo.jpg"), "image/jpeg")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "graphic.svg"), "image/svg+xml")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "document.pdf"), "application/pdf")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "book.epub"), "application/epub+zip")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "clip.mp4"), "video/mp4")
        XCTAssertEqual(TTZipArchiveVfsProvider.mimeType(for: "audio.mp3"), "audio/mpeg")
    }
    
    func testInMemoryCachingAndRetrieval() async throws {
        let provider = TTZipArchiveVfsProvider.shared
        let archivePath = "/tmp/test_cache_\(UUID().uuidString).zip"
        let archiveId = provider.registerArchive(archivePath: archivePath, password: nil)
        let sampleData = Data("Hello VFS In-Memory Streaming".utf8)
        
        provider.cacheEntryData(archiveId: archiveId, entryPath: "test.txt", data: sampleData)
        let vfsURL = provider.makeVfsURL(archiveId: archiveId, entryPath: "test.txt")
        
        let cached = provider.cachedData(for: vfsURL.absoluteString)
        XCTAssertEqual(cached, sampleData)
        
        let res = try await provider.loadResource(uri: vfsURL.absoluteString)
        XCTAssertNotNil(res)
        XCTAssertEqual(res?.data, sampleData)
        XCTAssertEqual(res?.mimeType, "text/plain; charset=utf-8")
        
        let rangeRes = try await provider.loadResourceRange(uri: vfsURL.absoluteString, byteRange: 0...4)
        XCTAssertNotNil(rangeRes)
        XCTAssertEqual(rangeRes?.fullSize, Int64(sampleData.count))
        XCTAssertEqual(rangeRes?.data, Data("Hello".utf8))
    }
    
    
    // MARK: - MediaPreviewFactory Extensions Tests
    
    func testOfficeExtensionsInFactory() {
        XCTAssertTrue(MediaPreviewFactory.spreadsheetExtensions.contains("xlsx"))
        XCTAssertTrue(MediaPreviewFactory.spreadsheetExtensions.contains("ods"))
        XCTAssertTrue(MediaPreviewFactory.spreadsheetExtensions.contains("csv"))
        XCTAssertTrue(MediaPreviewFactory.presentationExtensions.contains("pptx"))
        XCTAssertTrue(MediaPreviewFactory.presentationExtensions.contains("odp"))
        XCTAssertTrue(MediaPreviewFactory.docxExtensions.contains("docx"))
    }
    
    func testDetectTypeFromMemory() {
        let csvData = Data("Name,Score\nAlice,100\nBob,95".utf8)
        let type = MediaPreviewFactory.detectTypeFromMemory(data: csvData, suggestedName: "scores.csv")
        switch type {
        case .spreadsheetTable(let content, _):
            XCTAssertTrue(content.contains("Alice"))
        default:
            XCTFail("Expected spreadsheetTable for scores.csv")
        }
        
        let pdfBytes = Data("%PDF-1.4\n%header".utf8)
        let pdfType = MediaPreviewFactory.detectTypeFromMemory(data: pdfBytes, suggestedName: "document.pdf")
        switch pdfType {
        case .pdfData(let d, _):
            XCTAssertEqual(d, pdfBytes)
        default:
            XCTFail("Expected pdfData for document.pdf")
        }
    }
}


private final class RecordingRangeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private let completed: XCTestExpectation
    private(set) var response: HTTPURLResponse?
    private(set) var data = Data()
    private(set) var error: (any Error)?

    init(request: URLRequest, completed: XCTestExpectation) {
        self.request = request
        self.completed = completed
    }

    func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { completed.fulfill() }
    func didFailWithError(_ error: any Error) {
        self.error = error
        completed.fulfill()
    }
}
