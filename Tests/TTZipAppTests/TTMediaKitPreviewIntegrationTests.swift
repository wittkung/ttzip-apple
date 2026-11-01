// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import TTMediaKit
import TTZipUI
import TTZipPreviewKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class TTMediaKitPreviewIntegrationTests: XCTestCase {

    // MARK: - 1. Factory Declarative Builders

    func testMediaPreviewFactoryTTMediaKitDelegates() throws {
        let tempDir = try makeTemporaryDirectory()
        let sampleURL = tempDir.appendingPathComponent("sample_video.mp4")

        // 1. Universal Media Preview
        let mediaPreview = MediaPreviewFactory.makeMediaKitPreview(url: sampleURL, title: "Sample Video")
        XCTAssertEqual(mediaPreview.url, sampleURL)
        XCTAssertEqual(mediaPreview.customTitle, "Sample Video")

        // 2. Declarative Spreadsheet View
        let headers = ["ID", "Name", "Score"]
        let rows = [["1", "Alice", "98.5"], ["2", "Bob", "87.0"]]
        let spreadsheetView = MediaPreviewFactory.makeSpreadsheetView(headers: headers, rows: rows)
        XCTAssertEqual(spreadsheetView.headers, headers)
        XCTAssertEqual(spreadsheetView.rows.count, 2)

        // 3. Declarative Rich Document View
        let markdown = "# Title\n\nSample content with code:\n```swift\nlet x = 1\n```"
        let richDocView = MediaPreviewFactory.makeRichDocumentView(markdown: markdown, title: "Doc Title")
        XCTAssertEqual(richDocView.blocks.count > 0, true)
        XCTAssertEqual(richDocView.metadata?.title, "Doc Title")

        // 4. makePreviewView with useMediaKit flag
        let directView = MediaPreviewFactory.makePreviewView(
            type: .video(sampleURL),
            fileName: "sample_video.mp4",
            fileURL: sampleURL,
            isFullScreenActive: false,
            useMediaKit: true
        )
        XCTAssertNotNil(directView)
    }

    // MARK: - 2. MediaPreviewView Direct Connection

    func testMediaPreviewViewMediaKitConnection() throws {
        let tempDir = try makeTemporaryDirectory()
        let audioURL = tempDir.appendingPathComponent("tune.mp3")

        // Standard Preview View
        let standardView = MediaPreviewView(fileURL: audioURL, fileName: "tune.mp3")
        XCTAssertFalse(standardView.usesMediaKitPreview ?? false)

        // Direct TTMediaPreview View
        let directView = MediaPreviewView(fileURL: audioURL, fileName: "tune.mp3", usesMediaKitPreview: true)
        XCTAssertTrue(directView.usesMediaKitPreview ?? false)

        // View Modifier
        let modifiedView = standardView.usesMediaKitPreview(true)
        XCTAssertNotNil(modifiedView)
    }

    // MARK: - 3. AudioWaveformVisualizerView with TTWaveformView

    func testAudioWaveformVisualizerViewWithTTWaveform() throws {
        let tempDir = try makeTemporaryDirectory()
        let audioURL = tempDir.appendingPathComponent("speech.wav")
        var seekCalled = false
        var seekedValue: Double = 0.0

        let visualizer = AudioWaveformVisualizerView(
            url: audioURL,
            audioEngine: nil,
            isPlaying: false,
            currentTime: 10.0,
            duration: 60.0,
            sampleCount: 1600,
            onSeek: { target in
                seekCalled = true
                seekedValue = target
            }
        )

        XCTAssertEqual(visualizer.duration, 60.0)
        XCTAssertEqual(visualizer.currentTime, 10.0)
        XCTAssertEqual(visualizer.sampleCount, 1600)
        XCTAssertFalse(visualizer.isPlaying)

        visualizer.onSeek?(30.0)
        XCTAssertTrue(seekCalled)
        XCTAssertEqual(seekedValue, 30.0)
    }

    // MARK: - 4. SpreadsheetGridView with TTSpreadsheetView

    func testSpreadsheetGridViewInstantiation() {
        let rowItems = [
            SpreadsheetRowItem(id: 0, originalIndex: 1, cells: ["ColA", "ColB"]),
            SpreadsheetRowItem(id: 1, originalIndex: 2, cells: ["Val1", "Val2"])
        ]
        var selectedCoord: SpreadsheetCellCoordinate? = nil

        let gridView = SpreadsheetGridView(
            paginatedDataRows: rowItems,
            headerNames: ["A", "B"],
            maxColumnCount: 2,
            useFirstRowAsHeader: false,
            searchQuery: "",
            selectedCoordinate: Binding(get: { selectedCoord }, set: { selectedCoord = $0 }),
            columnWidths: [0: 100, 1: 100],
            selectedDelimiter: .comma,
            onCopyText: { _, _ in },
            onFilterQuery: { _ in }
        )

        XCTAssertEqual(gridView.headerNames, ["A", "B"])
        XCTAssertEqual(gridView.maxColumnCount, 2)
        XCTAssertEqual(gridView.paginatedDataRows.count, 2)
    }

    // MARK: - 5. Production Ephemeral Lease Ownership & Fullscreen Handoff

    func testMediaPreviewViewSequentialEphemeralLeaseReleaseAndFullscreenHandoff() throws {
        TTMediaDetector.purgeAllEphemeralMediaFiles()
        defer { TTMediaDetector.purgeAllEphemeralMediaFiles() }

        for index in 0..<12 {
            let wavData = makeMinimalWAVData(tagByte: UInt8(index + 1))
            var stagedURL: URL?
            autoreleasepool {
                let detected = MediaPreviewFactory.detectTypeFromMemory(
                    data: wavData,
                    suggestedName: "downstream_\(index).wav"
                )
                stagedURL = detected.ephemeralMediaURL
                XCTAssertNotNil(stagedURL, "Iteration \(index) must stage ephemeral audio file")
                let view = MediaPreviewView(
                    previewType: detected,
                    fileName: "downstream_\(index).wav"
                )
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 240, height: 180)
                host.layoutSubtreeIfNeeded()
                if let url = stagedURL {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                }
            }
            if let url = stagedURL {
                XCTAssertEqual(
                    TTMediaDetector.activeEphemeralLeaseCount(for: url),
                    0,
                    "MediaPreviewView teardown must release ephemeral lease at iteration \(index)"
                )
            }
        }

        // Verify fullscreen transition via MediaPreviewView.toggleFullScreen() -> AppViewState.openImmersiveMedia()
        let fullscreenData = makeMinimalWAVData(tagByte: 0x7F)
        let appState = AppViewState()
        var fullscreenStagedURL: URL?
        autoreleasepool {
            let detected = MediaPreviewFactory.detectTypeFromMemory(
                data: fullscreenData,
                suggestedName: "fullscreen_handoff.wav"
            )
            fullscreenStagedURL = detected.ephemeralMediaURL
            let previewView = MediaPreviewView(
                previewType: detected,
                fileName: "fullscreen_handoff.wav"
            )
            previewView.toggleFullScreen()
            if let url = fullscreenStagedURL {
                appState.openImmersiveMedia(url: url, name: "fullscreen_handoff.wav")
            }
        }
        let handoffURL = try XCTUnwrap(fullscreenStagedURL)
        XCTAssertGreaterThanOrEqual(
            TTMediaDetector.activeEphemeralLeaseCount(for: handoffURL),
            1,
            "Fullscreen transition must keep ephemeral media lease active after inline view teardown"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: handoffURL.path))

        appState.closeImmersiveMedia()
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: handoffURL), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffURL.path))
    }

    // MARK: - 6. Archive Media Independent Player Multi-Consumer Lease & Last-Consumer Cleanup

    func testArchiveMediaIndependentPlayerMultiConsumerLeaseIsolationAndLastConsumerCleanup() async throws {
        let sandboxDir = try makeTemporaryDirectory()
        let cache = PreviewLRUCacheManager(
            customCacheDir: sandboxDir,
            maxStagedFiles: 1,
            maxCacheSizeBytesOverride: 64
        )
        let keyA = PreviewLRUCacheManager.deterministicCacheKey(
            archivePath: "/Volumes/Archive/bundle.zip",
            subpath: "media/clipA.mp4"
        )
        let urlA = try XCTUnwrap(cache.targetURL(forKey: keyA, filename: "clipA.mp4"))
        try FileManager.default.createDirectory(
            at: urlA.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 48).write(to: urlA)
        await cache.register(key: keyA, fileURL: urlA)

        // 1. Main window acquires lease
        let mainWindowConsumerID = UUID()
        let mainLease = await cache.acquireLease(forKey: keyA, consumerID: mainWindowConsumerID)
        let countAfterMain = await cache.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(countAfterMain, 1)

        // 2. Failed standalone player open acquires then immediately rolls back without affecting main window
        let failedPlayerConsumerID = UUID()
        let rawFailedPlayerLease = await cache.acquireIndependentPlayerLease(
            forFileURL: urlA,
            consumerID: failedPlayerConsumerID
        )
        let failedPlayerLease = try XCTUnwrap(rawFailedPlayerLease)
        let countDuringFailedAttempt = await cache.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(countDuringFailedAttempt, 2)
        await cache.releaseLease(failedPlayerLease)
        let countAfterRollback = await cache.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(countAfterRollback, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path))

        // 3. Standalone player acquires independent consumer lease before main window switches/closes
        let standalonePlayerConsumerID = UUID()
        let standaloneLease = await cache.cloneLease(from: mainLease, newConsumerID: standalonePlayerConsumerID)
        let countWithBoth = await cache.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(countWithBoth, 2)

        // 4. Main window switches selection / closes and stages another entry under strict quota (maxStagedFiles: 1)
        await cache.releaseLease(mainLease, reclaimImmediatelyIfIdle: true)
        let countAfterMainRelease = await cache.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(countAfterMainRelease, 1)

        let keyB = PreviewLRUCacheManager.deterministicCacheKey(
            archivePath: "/Volumes/Archive/bundle.zip",
            subpath: "media/clipB.mp4"
        )
        let urlB = try XCTUnwrap(cache.targetURL(forKey: keyB, filename: "clipB.mp4"))
        try FileManager.default.createDirectory(
            at: urlB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x42, count: 48).write(to: urlB)
        await cache.register(key: keyB, fileURL: urlB)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: urlA.path),
            "Active standalone player lease must protect archive-extracted media file from eviction and main window release"
        )

        // 5. Last consumer (standalone player) closes and triggers immediate reclamation
        await cache.releaseLease(standaloneLease, reclaimImmediatelyIfIdle: true)
        let finalCount = await cache.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(finalCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: urlA.path),
            "Last consumer exit with reclaimImmediatelyIfIdle must delete the archive-extracted temporary file"
        )
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
}
