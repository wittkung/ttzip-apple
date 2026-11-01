// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0
// Doc twin: products/ttzip/docs/twin/preview/video-timeline-thumbnails.md

import Foundation

/// Resolves completion, cancellation and timeout exactly once, including pre-install races.
private final class TimelineCompletionGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if finished, let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        self.result = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return true
    }
}

enum VideoTimelineThumbnailOperation {
    static func frame(using decoder: any VideoTimelineDecoding, at seconds: Double,
                      timeout: Duration = .seconds(5)) async throws -> VideoTimelineFrame {
        let gate = TimelineCompletionGate<VideoTimelineFrame>()
        let work = Task {
            do { gate.finish(.success(try await decoder.frame(at: seconds))) }
            catch { gate.finish(.failure(error)) }
        }
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            guard gate.finish(.failure(VideoTimelineDecodeError.timedOut)) else { return }
            work.cancel()
            decoder.interrupt()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { gate.install($0) }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
            work.cancel()
            decoder.interrupt()
        }
    }
}
