// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0
// Doc twin: products/ttzip/docs/twin/preview/video-timeline-thumbnails.md

import AppKit
import Observation
import os

/// The playback session owns this cache; hover views only read it.
@MainActor
@Observable
final class VideoTimelineThumbnailSource {
    private(set) var frames: [VideoTimelineFrame] = []
    private(set) var sourceURL: URL?
    private(set) var isGenerating = false
    private(set) var progress: Double = 0
    private(set) var failureCount = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let cache: VideoTimelineThumbnailCache
    @ObservationIgnored private let makeDecoder: @Sendable (URL) -> any VideoTimelineDecoding
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "TimelineThumbnails")

    init(cache: VideoTimelineThumbnailCache = .shared,
         makeDecoder: @escaping @Sendable (URL) -> any VideoTimelineDecoding = { VideoTimelineThumbnailDecoder(url: $0) }) {
        self.cache = cache
        self.makeDecoder = makeDecoder
    }

    isolated deinit { task?.cancel() }

    static func sampleTimes(duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let count = min(100, max(1, Int(min(100, ceil(duration * 2)))))
        if count == 1 { return [0] }
        let last = max(0, duration - min(0.05, duration / 2))
        return (0..<count).map { Double($0) * last / Double(count - 1) }
    }

    func start(url: URL, duration: Double) {
        guard sourceURL != url || task == nil else { return }
        stop()
        let times = Self.sampleTimes(duration: duration)
        guard url.isFileURL, !times.isEmpty else { return }
        sourceURL = url
        isGenerating = true
        let ticket = generation
        let cache = cache
        let factory = makeDecoder
        task = Task(priority: .utility) { [weak self] in
            let identity = await cache.identity(for: url, duration: duration, sampleCount: times.count)
            if let identity, let cached = await cache.read(identity) {
                guard !Task.isCancelled, let self, self.generation == ticket else { return }
                self.frames = cached
                self.progress = 1
                self.isGenerating = false
                return
            }
            let decoder = factory(url)
            await self?.generate(using: decoder, times: times, duration: duration, ticket: ticket)
            await decoder.close()
            guard !Task.isCancelled, let self, self.generation == ticket else { return }
            // Revalidate the source after the scan; never cache frames for a modified file.
            if self.failureCount == 0, let identity,
               await cache.identity(for: url, duration: duration, sampleCount: times.count) == identity {
                await cache.write(self.frames, identity: identity)
            }
            if self.generation == ticket { self.isGenerating = false }
        }
    }

    private func generate(using decoder: any VideoTimelineDecoding, times: [Double],
                          duration: Double, ticket: UInt64) async {
        for (index, seconds) in times.enumerated() {
            guard !Task.isCancelled, generation == ticket else { return }
            do {
                let frame = try await VideoTimelineThumbnailOperation.frame(using: decoder, at: seconds)
                guard !Task.isCancelled, generation == ticket else { return }
                if frame.seconds.isFinite, frame.seconds >= 0, frame.seconds <= duration + 1 {
                    if !frames.contains(where: { abs($0.seconds - frame.seconds) < 0.001 }) {
                        frames.append(frame)
                        frames.sort { $0.seconds < $1.seconds }
                    }
                } else { failureCount += 1 }
            } catch {
                guard !Task.isCancelled, generation == ticket else { return }
                failureCount += 1
                logger.debug("Timeline sample failed: \(String(describing: error), privacy: .public)")
                // Bound unsupported files and stalled decoders instead of retrying 100 times.
                if frames.isEmpty && failureCount >= 3 { break }
                if case VideoTimelineDecodeError.timedOut = error { break }
            }
            progress = Double(index + 1) / Double(times.count)
        }
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        sourceURL = nil
        frames = []
        progress = 0
        failureCount = 0
        isGenerating = false
    }

    /// Preceding actual PTS, with first/last boundary fallback. Never starts decoding.
    func frame(at seconds: Double) -> VideoTimelineFrame? {
        guard seconds.isFinite, !frames.isEmpty else { return nil }
        var low = 0
        var high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].seconds <= seconds { low = middle + 1 } else { high = middle }
        }
        return frames[max(0, low - 1)]
    }
}
