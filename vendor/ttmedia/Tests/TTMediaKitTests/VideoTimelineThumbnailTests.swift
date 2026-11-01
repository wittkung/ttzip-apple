// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import XCTest
@testable import TTMediaKit

actor TimelineCountingDecoder: VideoTimelineDecoding {
    let image: CGImage
    let delay: Duration
    private(set) var callCount = 0
    private(set) var closed = false
    init(image: CGImage, delay: Duration = .zero) { self.image = image; self.delay = delay }
    func frame(at seconds: Double) async throws -> VideoTimelineFrame {
        callCount += 1
        try await Task.sleep(for: delay)
        return VideoTimelineFrame(image: image, seconds: seconds)
    }
    func close() { closed = true }
    nonisolated func interrupt() {}
}

/// Deliberately ignores cancellation to exercise a real late native callback.
actor TimelineLateDecoder: VideoTimelineDecoding {
    let image: CGImage
    private(set) var started = false
    private var pending: CheckedContinuation<VideoTimelineFrame, Never>?
    init(image: CGImage) { self.image = image }
    func frame(at seconds: Double) async throws -> VideoTimelineFrame {
        started = true
        return await withCheckedContinuation { pending = $0 }
    }
    func complete() { pending?.resume(returning: VideoTimelineFrame(image: image, seconds: 99)); pending = nil }
    func close() {}
    nonisolated func interrupt() {}
}

@MainActor
final class VideoTimelineThumbnailTests: XCTestCase {
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8,
                                            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        return try XCTUnwrap(context.makeImage())
    }

    func testContinuousHoverOnlyReadsPreparedFramesAndStopClears() async throws {
        let decoder = TimelineCountingDecoder(image: try image())
        let source = VideoTimelineThumbnailSource(makeDecoder: { _ in decoder })
        source.start(url: URL(fileURLWithPath: "/nonexistent/timeline-test.mp4"), duration: 2)
        try await waitForScan(source)
        let before = await decoder.callCount
        XCTAssertEqual(before, 4)
        for index in 0..<1000 {
            let seconds = Double(index) / 500
            let frame = try XCTUnwrap(source.frame(at: seconds))
            XCTAssertLessThanOrEqual(frame.seconds, seconds)
        }
        let after = await decoder.callCount
        XCTAssertEqual(after, before)
        XCTAssertEqual(source.frame(at: -1)?.seconds, 0)
        XCTAssertEqual(source.frame(at: 99)?.seconds, 1.95)
        XCTAssertNil(source.frame(at: .nan))
        source.stop()
        XCTAssertNil(source.frame(at: 0))
    }

    func testSwitchingFilesCannotPublishCancelledGeneration() async throws {
        let decoder = TimelineCountingDecoder(image: try image(), delay: .milliseconds(80))
        let source = VideoTimelineThumbnailSource(makeDecoder: { _ in decoder })
        source.start(url: URL(fileURLWithPath: "/old.mp4"), duration: 1)
        try await Task.sleep(for: .milliseconds(20))
        source.stop()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(source.sourceURL)
        XCTAssertTrue(source.frames.isEmpty)
        let closed = await decoder.closed
        XCTAssertTrue(closed)
    }

    func testLateFrameCannotReplaceNewFileCache() async throws {
        let late = TimelineLateDecoder(image: try image())
        let current = TimelineCountingDecoder(image: try image())
        let source = VideoTimelineThumbnailSource(makeDecoder: { url in
            if url.lastPathComponent == "old.mp4" { return late }
            return current
        })
        source.start(url: URL(fileURLWithPath: "/old.mp4"), duration: 100)
        for _ in 0..<200 {
            if await late.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await late.started
        XCTAssertTrue(started)
        let newURL = URL(fileURLWithPath: "/new.mp4")
        source.start(url: newURL, duration: 1)
        try await waitForScan(source)
        await late.complete()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(source.sourceURL, newURL)
        XCTAssertEqual(source.frames.count, 2)
        XCTAssertTrue(source.frames.allSatisfy { $0.seconds < 1 })
        source.stop()
    }

    func testViewportHandoffRetainsThumbnailOwnerWithoutSeekingPlayback() {
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/handoff.mp4"))
        let owner = session.timelineThumbnails
        let beforeTime = session.currentTime
        let beforeGeneration = session.seekGeneration
        session.acquireViewport(UUID(), isFullScreen: false)
        session.acquireViewport(UUID(), isFullScreen: true)
        XCTAssertTrue(session.timelineThumbnails === owner)
        XCTAssertEqual(session.currentTime, beforeTime)
        XCTAssertEqual(session.seekGeneration, beforeGeneration)
        session.stop(reason: "Thumbnail ownership regression")
        XCTAssertTrue(owner.frames.isEmpty)
    }

    func testTimeoutReturnsWithoutWaitingForDecoderDelay() async throws {
        let decoder = TimelineCountingDecoder(image: try image(), delay: .seconds(30))
        let start = ContinuousClock.now
        do {
            _ = try await VideoTimelineThumbnailOperation.frame(using: decoder, at: 0, timeout: .milliseconds(20))
            XCTFail("Expected timeout")
        } catch VideoTimelineDecodeError.timedOut {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testDiskIdentityInvalidationAndCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.mp4")
        try Data([1]).write(to: file)
        let folder = directory.appendingPathComponent("cache")
        let cache = VideoTimelineThumbnailCache(directory: folder)
        let candidate = await cache.identity(for: file, duration: 10, sampleCount: 20)
        let identity = try XCTUnwrap(candidate)
        await cache.write([VideoTimelineFrame(image: try image(), seconds: 0)], identity: identity)
        let loaded = await cache.read(identity)
        XCTAssertEqual(loaded?.count, 1)
        try Data([1, 2]).write(to: file)
        let changed = await cache.identity(for: file, duration: 10, sampleCount: 20)
        XCTAssertNotEqual(identity, changed)
        let stale = await cache.read(try XCTUnwrap(changed))
        XCTAssertNil(stale)
        try Data("broken".utf8).write(to: folder.appendingPathComponent(identity.key + ".json"))
        let corrupt = await cache.read(identity)
        XCTAssertNil(corrupt)
    }

    func testSamplingBoundsAndPreviewPlacement() {
        XCTAssertTrue(VideoTimelineThumbnailSource.sampleTimes(duration: .infinity).isEmpty)
        XCTAssertTrue(VideoTimelineThumbnailSource.sampleTimes(duration: 0).isEmpty)
        XCTAssertEqual(VideoTimelineThumbnailSource.sampleTimes(duration: 7200).count, 100)
        XCTAssertEqual(VideoTimelineThumbnailSource.sampleTimes(duration: 0.1), [0])
        let size = CGSize(width: 156, height: 128)
        let viewport = CGSize(width: 400, height: 300)
        let top = VideoTimelinePreviewLayout.center(track: CGRect(x: 10, y: 10, width: 380, height: 28),
                                                  pointerX: 0, preview: size, viewport: viewport)
        XCTAssertGreaterThan(top.y - 64, 38)
        XCTAssertGreaterThanOrEqual(top.x - 78, 8)
        let bottom = VideoTimelinePreviewLayout.center(track: CGRect(x: 10, y: 250, width: 380, height: 28),
                                                     pointerX: 380, preview: size, viewport: viewport)
        XCTAssertLessThan(bottom.y + 64, 250)
        XCTAssertLessThanOrEqual(bottom.x + 78, 392)
    }

    private func waitForScan(_ source: VideoTimelineThumbnailSource) async throws {
        for _ in 0..<200 {
            if !source.isGenerating { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        source.stop()
        XCTFail("Scan did not finish")
    }
}
