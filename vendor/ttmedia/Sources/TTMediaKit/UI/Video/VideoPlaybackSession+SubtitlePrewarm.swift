// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

extension VideoPlaybackSession {
    nonisolated static let prewarmBudgetSeconds: TimeInterval = 4.0
    nonisolated static let maxPrewarmTracks: Int = 8

    nonisolated static func encodePrewarmContainerRequest(
        targetTrackID: UInt64?,
        maxTracks: Int,
        budgetMs: UInt64
    ) -> Int64? {
        SubtitlePrewarmRequestCodec.encode(
            targetTrackID: targetTrackID,
            maxTracks: maxTracks,
            budgetMs: budgetMs
        )
    }

    nonisolated static func encodePrewarmContainerRequest(
        targetTrackID: Int64?,
        maxTracks: Int,
        budgetMs: UInt64
    ) -> Int64? {
        SubtitlePrewarmRequestCodec.encode(
            targetTrackID: targetTrackID,
            maxTracks: maxTracks,
            budgetMs: budgetMs
        )
    }

    nonisolated static func decodePrewarmContainerRequest(
        _ track: Int64
    ) -> (targetTrackID: UInt64?, maxTracks: Int, budgetMs: UInt64)? {
        SubtitlePrewarmRequestCodec.decode(track)
    }

    nonisolated static func isPrewarmContainerRequest(_ track: Int64) -> Bool {
        SubtitlePrewarmRequestCodec.decode(track) != nil
    }

    func cancelSubtitlePrewarm() {
        subtitlePrewarmGeneration = UUID()
        let previousPrewarmID = activePrewarmRequestID
        activePrewarmRequestID = nil
        subtitlePrewarmTask?.cancel()
        subtitlePrewarmTask = nil
        cancelSubtitleRequestID(previousPrewarmID)
    }

    func scheduleBackgroundSubtitlePrewarm(
        candidates: [URL],
        others: [URL],
        budgetSeconds: TimeInterval = VideoPlaybackSession.prewarmBudgetSeconds,
        maxTracks: Int = VideoPlaybackSession.maxPrewarmTracks
    ) {
        cancelSubtitlePrewarm()
        let generation = subtitlePrewarmGeneration
        let alreadyCachedIDs = Set(subtitleCache.keys)
        let externalQueue = Array((candidates + others.prefix(4)).filter {
            !alreadyCachedIDs.contains($0.absoluteString)
        }.prefix(maxTracks))
        let uncachedEmbedded = embeddedSubtitles.filter {
            $0.supported && !alreadyCachedIDs.contains("embedded:\($0.id)")
        }
        let embeddedReader = currentEmbeddedSubtitleRequestReader()
        let prewarmSessionID = currentSubtitleSessionID()
        let prewarmRequestID: UInt64? = (!uncachedEmbedded.isEmpty && embeddedReader != nil)
            ? allocateSubtitleRequestID(sessionId: prewarmSessionID)
            : nil
        activePrewarmRequestID = prewarmRequestID

        subtitlePrewarmTask = Task { @MainActor [weak self] in
            defer {
                if let prewarmRequestID {
                    SubtitleSessionRequestRegistry.shared.finishRequest(
                        sessionId: prewarmSessionID,
                        requestID: prewarmRequestID
                    )
                    if self?.activePrewarmRequestID == prewarmRequestID {
                        self?.activePrewarmRequestID = nil
                    }
                }
            }
            guard let self, !isStopped, subtitlePrewarmGeneration == generation else { return }
            let deadline = CFAbsoluteTimeGetCurrent() + budgetSeconds
            let prewarmedCount = await prewarmExternalQueue(
                externalQueue,
                deadline: deadline,
                maxTracks: maxTracks,
                generation: generation
            )
            let remainingSlots = maxTracks - prewarmedCount
            guard !Task.isCancelled,
                  !isStopped,
                  subtitlePrewarmGeneration == generation,
                  remainingSlots > 0,
                  !uncachedEmbedded.isEmpty,
                  let embeddedReader else { return }
            await prewarmEmbeddedBatch(
                uncachedEmbedded,
                reader: embeddedReader,
                requestID: prewarmRequestID ?? allocateSubtitleRequestID(sessionId: prewarmSessionID),
                remainingSlots: remainingSlots,
                deadline: deadline,
                generation: generation
            )
        }
    }

    private func prewarmExternalQueue(
        _ externalQueue: [URL],
        deadline: CFAbsoluteTime,
        maxTracks: Int,
        generation: UUID
    ) async -> Int {
        var prewarmedCount = 0
        let loader = externalSubtitleLoader
        for fileURL in externalQueue {
            guard !Task.isCancelled,
                  !isStopped,
                  subtitlePrewarmGeneration == generation,
                  prewarmedCount < maxTracks,
                  CFAbsoluteTimeGetCurrent() < deadline else { break }
            let id = fileURL.absoluteString
            if subtitleCache[id] != nil { continue }
            let loaded = try? await loader(fileURL)
            guard !Task.isCancelled,
                  !isStopped,
                  subtitlePrewarmGeneration == generation,
                  CFAbsoluteTimeGetCurrent() < deadline else { break }
            if let loaded {
                subtitleCache[id] = loaded
                prewarmedCount += 1
            }
        }
        return prewarmedCount
    }

    private func isPrewarmActive(generation: UUID, deadline: CFAbsoluteTime) -> Bool {
        !Task.isCancelled && !isStopped && subtitlePrewarmGeneration == generation && CFAbsoluteTimeGetCurrent() < deadline
    }

    private func prewarmEmbeddedBatch(
        _ uncachedEmbedded: [EmbeddedSubtitleTrack],
        reader: @Sendable (Int64, UInt64) async throws -> Data,
        requestID: UInt64,
        remainingSlots: Int,
        deadline: CFAbsoluteTime,
        generation: UUID
    ) async {
        let boundedTargets = Array(uncachedEmbedded.prefix(remainingSlots))
        let remainingSeconds = deadline - CFAbsoluteTimeGetCurrent()
        guard !boundedTargets.isEmpty,
              remainingSeconds > 0,
              isPrewarmActive(generation: generation, deadline: deadline) else { return }

        let remainingBudgetMs = max(
            1,
            min(
                UInt64(Self.prewarmBudgetSeconds * 1000.0),
                UInt64((remainingSeconds * 1000.0).rounded(.down))
            )
        )
        let singleTargetID: Int64? = (boundedTargets.count == 1) ? boundedTargets[0].id : nil
        guard boundedTargets.allSatisfy({ $0.id >= 1 && $0.id <= Int64(UInt32.max) }),
              let requestTrack = Self.encodePrewarmContainerRequest(
                  targetTrackID: singleTargetID,
                  maxTracks: boundedTargets.count,
                  budgetMs: remainingBudgetMs
              ) else {
            return
        }
        activePrewarmRequestID = requestID
        defer {
            if activePrewarmRequestID == requestID {
                activePrewarmRequestID = nil
            }
        }

        guard let batchData = try? await reader(requestTrack, requestID),
              isPrewarmActive(generation: generation, deadline: deadline) else { return }

        let targetIDs = boundedTargets.map { String($0.id) }
        let builtTracks = await Self.decodeBatchTracksOffMainActor(
            batchData,
            targetIDs: targetIDs,
            deadline: deadline
        )

        guard !Task.isCancelled, !isStopped, subtitlePrewarmGeneration == generation else { return }
        for (key, track) in builtTracks where subtitleCache[key] == nil {
            subtitleCache[key] = track
        }
    }
}
