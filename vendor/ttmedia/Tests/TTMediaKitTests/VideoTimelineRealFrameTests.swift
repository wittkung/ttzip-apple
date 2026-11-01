// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import XCTest
@testable import TTMediaKit

@MainActor
final class VideoTimelineRealFrameTests: XCTestCase {
    func testNativeAndWorkerDecodeRealFramesWithoutPlaybackSession() async throws {
        let fixtures = try XCTUnwrap(locatePreviewFixturesRoot())
        for name in ["clip.mp4", "clip.mkv"] {
            let transport = MediaWorkerDirectTransport()
            let decoder = VideoTimelineThumbnailDecoder(url: fixtures.appendingPathComponent("video/" + name), transport: transport)
            for seconds in [0.0, 0.5] {
                let frame = try await VideoTimelineThumbnailOperation.frame(using: decoder, at: seconds)
                XCTAssertGreaterThan(frame.image.width, 0, name)
                XCTAssertGreaterThan(frame.image.height, 0, name)
                XCTAssertLessThanOrEqual(frame.image.width, 240, name)
                XCTAssertLessThanOrEqual(frame.image.height, 160, name)
                XCTAssertTrue(frame.seconds.isFinite, name)
            }
            await decoder.close()
            XCTAssertFalse(transport.hasActiveDemuxerHandle)
            XCTAssertEqual(transport.openCloseBalanceCount, 0)
        }
    }

    func testRealScanPersistsAndReopensWithoutDecoding() async throws {
        let fixture = try XCTUnwrap(locatePreviewFixturesRoot()).appendingPathComponent("video/clip.mp4")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = VideoTimelineThumbnailCache(directory: folder)
        let source = VideoTimelineThumbnailSource(cache: cache)
        source.start(url: fixture, duration: 1)
        try await waitForScan(source)
        XCTAssertFalse(source.frames.isEmpty)
        XCTAssertEqual(source.failureCount, 0)
        let fake = TimelineCountingDecoder(image: try XCTUnwrap(source.frames.first?.image))
        let reopened = VideoTimelineThumbnailSource(cache: cache, makeDecoder: { _ in fake })
        reopened.start(url: fixture, duration: 1)
        try await waitForScan(reopened)
        let calls = await fake.callCount
        XCTAssertEqual(calls, 0, "A valid persistent cache must bypass decoding")
        XCTAssertEqual(source.frames.count, reopened.frames.count)
        source.stop()
        reopened.stop()
    }

    private func waitForScan(_ source: VideoTimelineThumbnailSource) async throws {
        for _ in 0..<1000 {
            if !source.isGenerating { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        source.stop()
        XCTFail("Thumbnail generation did not complete within 10 seconds")
    }

    private func locatePreviewFixturesRoot() -> URL? {
        if let root = ProcessInfo.processInfo.environment["TEST_SRCDIR"] {
            for path in ["_main/infra/ttmedia/Tests/Fixtures/preview", "infra/ttmedia/Tests/Fixtures/preview"] {
                let candidate = URL(fileURLWithPath: root).appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            for path in ["Tests/Fixtures/preview", "Fixtures/preview"] {
                let candidate = current.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            current.deleteLastPathComponent()
        }
        return nil
    }
}
