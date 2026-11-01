// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaDemux

internal protocol MediaSubtitleTransport: Sendable {
    func subtitleData(sessionId: String, track: Int64) async throws -> Data
    func subtitleData(sessionId: String, track: Int64, requestID: UInt64) async throws -> Data
    func cancelSubtitleRequest(sessionId: String, requestID: UInt64) async
    func cancelAllSubtitleRequests(sessionId: String) async
}

extension MediaSubtitleTransport {
    func subtitleData(sessionId: String, track: Int64, requestID: UInt64) async throws -> Data {
        defer {
            SubtitleSessionRequestRegistry.shared.finishRequest(sessionId: sessionId, requestID: requestID)
        }
        try SubtitleSessionRequestRegistry.shared.beginRequest(sessionId: sessionId, requestID: requestID)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !SubtitleSessionRequestRegistry.shared.isCancelled(sessionId: sessionId, requestID: requestID) else {
                throw CancellationError()
            }
            return try await subtitleData(sessionId: sessionId, track: track)
        } onCancel: {
            SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sessionId, requestID: requestID)
        }
    }

    func cancelSubtitleRequest(sessionId: String, requestID: UInt64) async {
        SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sessionId, requestID: requestID)
    }

    func cancelAllSubtitleRequests(sessionId: String) async {
        SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: sessionId)
    }
}

/// Strict bit-level codec for negative `Int64` (`track <= -2`) container prewarm requests.
/// Rejects `Int64.min` without negation overflow and refuses unrepresentable track IDs (`<= 0` or `> UInt32.max`).
internal enum SubtitlePrewarmRequestCodec {
    static let maxBudgetMs: UInt64 = 4_000
    static let maxTracks: Int = 8

    static func encode(
        targetTrackID: Int64?,
        maxTracks: Int,
        budgetMs: UInt64
    ) -> Int64? {
        guard maxTracks > 0, budgetMs > 0 else { return nil }
        let encodedTarget: UInt64
        if let targetTrackID {
            guard targetTrackID >= 1, targetTrackID <= Int64(UInt32.max) else {
                return nil
            }
            encodedTarget = UInt64(targetTrackID) << 24
        } else {
            encodedTarget = 0
        }
        let clampedMs = min(budgetMs, maxBudgetMs) & 0xffff
        let clampedTracks = UInt64(min(max(maxTracks, 1), Self.maxTracks)) & 0xff
        let raw = clampedMs | (clampedTracks << 16) | encodedTarget
        guard raw <= UInt64(Int64.max) - 2 else { return nil }
        return -2 - Int64(raw)
    }

    static func encode(
        targetTrackID: UInt64?,
        maxTracks: Int,
        budgetMs: UInt64
    ) -> Int64? {
        if let targetTrackID {
            guard targetTrackID >= 1, targetTrackID <= UInt64(UInt32.max) else {
                return nil
            }
            return encode(targetTrackID: Int64(targetTrackID), maxTracks: maxTracks, budgetMs: budgetMs)
        }
        return encode(targetTrackID: nil as Int64?, maxTracks: maxTracks, budgetMs: budgetMs)
    }

    static func decode(
        _ track: Int64
    ) -> (targetTrackID: UInt64?, maxTracks: Int, budgetMs: UInt64)? {
        if track == 0 {
            return (nil, maxTracks, maxBudgetMs)
        }
        guard track <= -2, track > Int64.min else { return nil }
        let negated = -track
        let raw = UInt64(negated - 2)
        guard (raw >> 56) == 0 else { return nil }
        let budgetMs = raw & 0xffff
        let rawTracks = Int((raw >> 16) & 0xff)
        guard budgetMs >= 1,
              budgetMs <= maxBudgetMs,
              rawTracks >= 1,
              rawTracks <= maxTracks else {
            return nil
        }
        let targetID = (raw >> 24) & 0xffff_ffff
        return (targetID > 0 ? targetID : nil, rawTracks, budgetMs)
    }
}

/// Thread-safe request-scoped subtitle cancellation registry shared across direct and XPC subtitle transports.
/// Registered requests (`runningDepth >= 0`) remain in `liveRequests` until `beginRequest` rejection or `finishRequest`
/// reclamation and are never demoted to evictable tombstones; excess active capacity (`> 4096`) is explicitly rejected.
internal final class SubtitleSessionRequestRegistry: @unchecked Sendable {
    static let shared = SubtitleSessionRequestRegistry()
    static let maxActiveRequests = 4_096
    static let maxPreStartTombstones = 4_096
    static let maxCancelledSessions = 128

    private struct LiveRequest {
        var sessionId: String
        var runningDepth: Int
        var isCancelled: Bool
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var liveRequests: [UInt64: LiveRequest] = [:]
    private var sessionRequests: [String: Set<UInt64>] = [:]
    private var preStartTombstones: Set<UInt64> = []
    private var preStartOrder: [UInt64] = []
    private var cancelledSessions: Set<String> = []
    private var cancelledSessionOrder: [String] = []

    var activeRequestCount: Int {
        lock.withLock { liveRequests.count }
    }

    var trackedSessionCount: Int {
        lock.withLock { sessionRequests.count }
    }

    var preStartTombstoneCount: Int {
        lock.withLock { preStartTombstones.count }
    }

    var cancelledSessionCount: Int {
        lock.withLock { cancelledSessions.count }
    }

    func allocateRequestID(sessionId: String? = nil) -> UInt64 {
        let allocated = lock.withLock { () -> UInt64 in
            let id = nextID
            nextID &+= 1
            if nextID == 0 { nextID = 1 }
            return id
        }
        if let sessionId {
            _ = tryRegisterRequest(sessionId: sessionId, requestID: allocated)
        }
        return allocated
    }

    @discardableResult
    func tryRegisterRequest(sessionId: String, requestID: UInt64) -> Bool {
        guard requestID != 0 else { return false }
        let outcome = lock.withLock { () -> (registered: Bool, preCancelled: Bool) in
            let sessionCancelled = cancelledSessions.contains(sessionId) || preStartTombstones.contains(requestID)
            if var entry = liveRequests[requestID] {
                _ = ttmedia_subtitles_register_request(requestID)
                if sessionCancelled {
                    entry.isCancelled = true
                }
                liveRequests[requestID] = entry
                if preStartTombstones.remove(requestID) != nil {
                    preStartOrder.removeAll { $0 == requestID }
                }
                sessionRequests[sessionId, default: []].insert(requestID)
                return (true, entry.isCancelled)
            }
            guard liveRequests.count < Self.maxActiveRequests,
                  ttmedia_subtitles_register_request(requestID) else {
                return (false, false)
            }
            if preStartTombstones.remove(requestID) != nil {
                preStartOrder.removeAll { $0 == requestID }
            }
            liveRequests[requestID] = LiveRequest(
                sessionId: sessionId,
                runningDepth: 0,
                isCancelled: sessionCancelled
            )
            sessionRequests[sessionId, default: []].insert(requestID)
            return (true, sessionCancelled)
        }
        if outcome.registered && outcome.preCancelled {
            ttmedia_subtitles_cancel_request(requestID)
        }
        return outcome.registered
    }

    @discardableResult
    func registerRequest(sessionId: String, requestID: UInt64) -> Bool {
        tryRegisterRequest(sessionId: sessionId, requestID: requestID)
    }

    private enum BeginDecision {
        case proceed
        case cancelled
        case capacityExceeded
    }

    private func isPreCancelledLocked(sessionId: String, requestID: UInt64) -> Bool {
        if cancelledSessions.contains(sessionId) {
            return true
        }
        guard requestID != 0 else { return false }
        return preStartTombstones.contains(requestID)
            || liveRequests[requestID]?.isCancelled == true
            || ttmedia_subtitles_is_request_cancelled(requestID)
    }

    private func beginRequestLocked(sessionId: String, requestID: UInt64) -> BeginDecision {
        if isPreCancelledLocked(sessionId: sessionId, requestID: requestID) {
            if requestID != 0 {
                reclaimLocked(sessionId: sessionId, requestID: requestID, preserveTombstone: false)
            }
            return .cancelled
        }
        guard requestID != 0 else { return .proceed }
        if var entry = liveRequests[requestID] {
            _ = ttmedia_subtitles_register_request(requestID)
            entry.sessionId = sessionId
            entry.runningDepth += 1
            liveRequests[requestID] = entry
            sessionRequests[sessionId, default: []].insert(requestID)
            return .proceed
        }
        guard liveRequests.count < Self.maxActiveRequests,
              ttmedia_subtitles_register_request(requestID) else {
            return .capacityExceeded
        }
        liveRequests[requestID] = LiveRequest(
            sessionId: sessionId,
            runningDepth: 1,
            isCancelled: false
        )
        sessionRequests[sessionId, default: []].insert(requestID)
        return .proceed
    }

    func beginRequest(sessionId: String, requestID: UInt64) throws {
        let decision = lock.withLock {
            beginRequestLocked(sessionId: sessionId, requestID: requestID)
        }
        switch decision {
        case .proceed:
            return
        case .cancelled:
            if requestID != 0 {
                ttmedia_subtitles_cancel_request(requestID)
                ttmedia_subtitles_reclaim_request(requestID)
            }
            throw CancellationError()
        case .capacityExceeded:
            throw MediaWorkerError.readPacketFailed(
                "Subtitle active request capacity exceeded (\(Self.maxActiveRequests))"
            )
        }
    }

    func finishRequest(sessionId: String, requestID: UInt64) {
        guard requestID != 0 else { return }
        let shouldReclaimNative = lock.withLock { () -> Bool in
            guard var entry = liveRequests[requestID] else {
                reclaimLocked(sessionId: sessionId, requestID: requestID, preserveTombstone: false)
                return true
            }
            if entry.runningDepth > 0 {
                entry.runningDepth -= 1
                if entry.runningDepth > 0 {
                    liveRequests[requestID] = entry
                    return false
                }
            }
            reclaimLocked(sessionId: entry.sessionId, requestID: requestID, preserveTombstone: false)
            if entry.sessionId != sessionId {
                reclaimLocked(sessionId: sessionId, requestID: requestID, preserveTombstone: false)
            }
            return true
        }
        if shouldReclaimNative {
            ttmedia_subtitles_reclaim_request(requestID)
        }
    }

    func isCancelled(sessionId: String? = nil, requestID: UInt64) -> Bool {
        if requestID != 0 && ttmedia_subtitles_is_request_cancelled(requestID) {
            return true
        }
        return lock.withLock {
            if let sessionId, cancelledSessions.contains(sessionId) {
                return true
            }
            if requestID != 0, liveRequests[requestID]?.isCancelled == true {
                return true
            }
            return requestID != 0 && preStartTombstones.contains(requestID)
        }
    }

    func cancelRequest(sessionId: String? = nil, requestID: UInt64) {
        guard requestID != 0 else { return }
        lock.withLock {
            if var entry = liveRequests[requestID] {
                entry.isCancelled = true
                liveRequests[requestID] = entry
            } else {
                insertPreStartTombstoneLocked(requestID)
            }
        }
        ttmedia_subtitles_cancel_request(requestID)
    }

    func cancelSession(sessionId: String) {
        let requestIDs = lock.withLock { () -> Set<UInt64> in
            insertCancelledSessionLocked(sessionId)
            let tracked = sessionRequests[sessionId] ?? []
            for requestID in tracked {
                if var entry = liveRequests[requestID] {
                    entry.isCancelled = true
                    liveRequests[requestID] = entry
                } else {
                    insertPreStartTombstoneLocked(requestID)
                }
            }
            return tracked
        }
        for requestID in requestIDs where requestID != 0 {
            ttmedia_subtitles_cancel_request(requestID)
        }
    }

    func reclaimUnstartedSessionRequests(sessionId: String) {
        let unstartedIDs = lock.withLock { () -> [UInt64] in
            let tracked = sessionRequests[sessionId] ?? []
            var reclaimed: [UInt64] = []
            for requestID in tracked {
                if let entry = liveRequests[requestID], entry.runningDepth == 0 {
                    reclaimLocked(sessionId: sessionId, requestID: requestID, preserveTombstone: false)
                    reclaimed.append(requestID)
                }
            }
            return reclaimed
        }
        for requestID in unstartedIDs where requestID != 0 {
            ttmedia_subtitles_reclaim_request(requestID)
        }
    }

    private func insertPreStartTombstoneLocked(_ requestID: UInt64) {
        guard requestID != 0 else { return }
        if preStartTombstones.insert(requestID).inserted {
            preStartOrder.append(requestID)
            while preStartOrder.count > Self.maxPreStartTombstones {
                let evicted = preStartOrder.removeFirst()
                preStartTombstones.remove(evicted)
            }
        }
    }

    private func insertCancelledSessionLocked(_ sessionId: String) {
        if cancelledSessions.insert(sessionId).inserted {
            cancelledSessionOrder.append(sessionId)
            while cancelledSessionOrder.count > Self.maxCancelledSessions {
                let evicted = cancelledSessionOrder.removeFirst()
                cancelledSessions.remove(evicted)
            }
        }
    }

    private func reclaimLocked(sessionId: String, requestID: UInt64, preserveTombstone: Bool) {
        liveRequests.removeValue(forKey: requestID)
        if !preserveTombstone && preStartTombstones.remove(requestID) != nil {
            preStartOrder.removeAll { $0 == requestID }
        }
        if var set = sessionRequests[sessionId] {
            set.remove(requestID)
            if set.isEmpty {
                sessionRequests.removeValue(forKey: sessionId)
            } else {
                sessionRequests[sessionId] = set
            }
        }
    }
}

/// Worker-side helper executing request-scoped C-ABI container subtitle scans (`ttmedia_subtitles_container_request`).
internal enum SubtitleContainerDirectExecutor {
    static func execute(
        subtitlePath: String,
        sessionId: String,
        track: Int64,
        requestID: UInt64
    ) async throws -> Data {
        defer {
            SubtitleSessionRequestRegistry.shared.finishRequest(sessionId: sessionId, requestID: requestID)
        }
        try SubtitleSessionRequestRegistry.shared.beginRequest(sessionId: sessionId, requestID: requestID)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !SubtitleSessionRequestRegistry.shared.isCancelled(sessionId: sessionId, requestID: requestID) else {
                throw CancellationError()
            }
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: subtitlePath))
            defer { try? file.close() }
            let fdPath = "/dev/fd/\(file.fileDescriptor)"
            let rawPtr = fdPath.withCString {
                ttmedia_subtitles_container_request($0, track, requestID)
            }
            guard let rawPtr else {
                throw MediaWorkerError.readPacketFailed("Subtitle allocation failed")
            }
            defer { ttmedia_subtitles_free(rawPtr) }
            if SubtitleSessionRequestRegistry.shared.isCancelled(sessionId: sessionId, requestID: requestID) {
                throw CancellationError()
            }
            return Data(String(cString: rawPtr).utf8)
        } onCancel: {
            SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sessionId, requestID: requestID)
        }
    }
}

/// Request-scoped XPC subtitle transport adapter that propagates per-request and per-session cancellation
/// across client and worker boundaries, covering both explicit full-track loads (`track > 0`) and bounded prewarm.
internal final class SubtitleXPCTransportBridge: MediaSubtitleTransport, @unchecked Sendable {
    typealias RequestHandler = @Sendable (String, Int64, UInt64) async throws -> Data
    typealias CancelRequestHandler = @Sendable (String, UInt64) async -> Void
    typealias CancelSessionHandler = @Sendable (String) async -> Void

    private let onRequest: RequestHandler
    private let onCancelRequest: CancelRequestHandler
    private let onCancelSession: CancelSessionHandler

    init(
        onRequest: @escaping RequestHandler,
        onCancelRequest: @escaping CancelRequestHandler = { sessionId, requestID in
            SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sessionId, requestID: requestID)
        },
        onCancelSession: @escaping CancelSessionHandler = { sessionId in
            SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: sessionId)
        }
    ) {
        self.onRequest = onRequest
        self.onCancelRequest = onCancelRequest
        self.onCancelSession = onCancelSession
    }

    func subtitleData(sessionId: String, track: Int64) async throws -> Data {
        let requestID = SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: sessionId)
        return try await subtitleData(sessionId: sessionId, track: track, requestID: requestID)
    }

    func subtitleData(sessionId: String, track: Int64, requestID: UInt64) async throws -> Data {
        defer {
            SubtitleSessionRequestRegistry.shared.finishRequest(sessionId: sessionId, requestID: requestID)
        }
        try SubtitleSessionRequestRegistry.shared.beginRequest(sessionId: sessionId, requestID: requestID)
        let cancelHandler = onCancelRequest
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await onRequest(sessionId, track, requestID)
        } onCancel: {
            SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sessionId, requestID: requestID)
            Task { await cancelHandler(sessionId, requestID) }
        }
    }

    func cancelSubtitleRequest(sessionId: String, requestID: UInt64) async {
        SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sessionId, requestID: requestID)
        await onCancelRequest(sessionId, requestID)
    }

    func cancelAllSubtitleRequests(sessionId: String) async {
        SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: sessionId)
        await onCancelSession(sessionId)
    }
}

internal struct EmbeddedSubtitleTrack: Identifiable, Decodable, Sendable {
    let id: Int64
    let title: String
    let language: String
    let codec: String
    let supported: Bool
    let isDefault: Bool?
    let isForced: Bool?

    init(
        id: Int64,
        title: String,
        language: String,
        codec: String,
        supported: Bool,
        isDefault: Bool? = nil,
        isForced: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.language = language
        self.codec = codec
        self.supported = supported
        self.isDefault = isDefault
        self.isForced = isForced
    }

    var displayName: String {
        let localizedLang = Locale.current.localizedString(forLanguageCode: language) ?? language
        let mainTitle = title.isEmpty ? codec : title
        var suffix = ""
        if isForced == true {
            suffix = " (Forced)"
        }
        return "[\(localizedLang)] \(mainTitle)\(suffix)"
    }
}

internal struct MediaSubtitleResponse: Decodable {
    let tracks: [EmbeddedSubtitleTrack]?
    let cues: [ExternalSubtitleTrack.Cue]?
    let bitmapCuesV1: [BitmapSubtitleTrack.Cue]?
    let trackCues: [String: [ExternalSubtitleTrack.Cue]]?
    let complete: Bool?
    let clustersScanned: Int?
    let workerPid: Int32?
    let error: String?

    static func decode(_ data: Data) throws -> Self {
        let response = try JSONDecoder().decode(Self.self, from: data)
        if let error = response.error {
            throw NSError(domain: "TTMediaSubtitles", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
        return response
    }
}

extension VideoPlaybackSession {
    internal nonisolated static func discoverExternalSubtitlesOffMainActor(
        for video: URL,
        loader: @Sendable (URL) async throws -> ExternalSubtitleTrack
    ) async -> ([URL], [URL], (String, ExternalSubtitleTrack)?) {
        guard !Task.isCancelled else { return ([], [], nil) }
        let matched = companions(for: video)
        let others = directorySubtitles(for: video, excluding: matched)
        guard !Task.isCancelled else { return (matched, others, nil) }
        var firstLoaded: (String, ExternalSubtitleTrack)?
        if let firstURL = matched.first,
           let parsed = try? await loader(firstURL),
           !Task.isCancelled {
            firstLoaded = (firstURL.absoluteString, parsed)
        }
        return (matched, others, firstLoaded)
    }

    internal nonisolated static func decodeSubtitleCatalogOffMainActor(
        _ data: Data
    ) async throws -> [EmbeddedSubtitleTrack] {
        try Task.checkCancellation()
        let tracks = try MediaSubtitleResponse.decode(data).tracks ?? []
        try Task.checkCancellation()
        return tracks
    }

    internal nonisolated static func decodeSingleTrackOffMainActor(
        _ data: Data
    ) async throws -> ExternalSubtitleTrack? {
        try Task.checkCancellation()
        guard let cues = try MediaSubtitleResponse.decode(data).cues else { return nil }
        let track = ExternalSubtitleTrack(cues: cues)
        try Task.checkCancellation()
        return track
    }

    internal nonisolated static func decodeBitmapTrackOffMainActor(
        _ data: Data
    ) async throws -> BitmapSubtitleTrack {
        try Task.checkCancellation()
        guard data.count <= 24 * 1024 * 1024,
              let cues = try MediaSubtitleResponse.decode(data).bitmapCuesV1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let track = try BitmapSubtitleTrack(cues: cues)
        try Task.checkCancellation()
        return track
    }

    internal nonisolated static func decodeBatchTracksOffMainActor(
        _ batchData: Data,
        targetIDs: [String],
        deadline: CFAbsoluteTime
    ) async -> [String: ExternalSubtitleTrack] {
        guard !Task.isCancelled,
              CFAbsoluteTimeGetCurrent() < deadline,
              let response = try? MediaSubtitleResponse.decode(batchData),
              response.complete == true,
              let trackCues = response.trackCues else { return [:] }
        var built: [String: ExternalSubtitleTrack] = [:]
        for rawID in targetIDs {
            guard !Task.isCancelled, CFAbsoluteTimeGetCurrent() < deadline else { break }
            if let cues = trackCues[rawID] {
                built["embedded:\(rawID)"] = ExternalSubtitleTrack(cues: cues)
            }
        }
        return built
    }

    private nonisolated static func isCompanionSubtitleFile(_ file: URL, base: String) -> Bool {
        guard ["srt", "vtt"].contains(file.pathExtension.lowercased()),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        let stem = file.deletingPathExtension().lastPathComponent.lowercased()
        return stem == base || [".", "_", "-"].contains { stem.hasPrefix(base + $0) }
    }

    private nonisolated static func compareCompanionSubtitles(_ left: URL, _ right: URL, base: String) -> Bool {
        let leftExact = left.deletingPathExtension().lastPathComponent.lowercased() == base
        let rightExact = right.deletingPathExtension().lastPathComponent.lowercased() == base
        if leftExact != rightExact { return leftExact }
        return left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
    }

    nonisolated static func companions(for video: URL) -> [URL] {
        guard !Task.isCancelled else { return [] }
        let directory = video.deletingLastPathComponent()
        let base = video.deletingPathExtension().lastPathComponent.lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        var matched: [URL] = []
        for file in files {
            if Task.isCancelled { return [] }
            if isCompanionSubtitleFile(file, base: base) {
                matched.append(file)
            }
        }
        return matched.sorted { compareCompanionSubtitles($0, $1, base: base) }
    }

    private nonisolated static func isRelatedStem(_ stem: String, to base: String) -> Bool {
        if stem == base || [".", "_", "-", " "].contains(where: { stem.hasPrefix(base + $0) }) {
            return true
        }
        return base.count >= 3 && stem.count >= 3 && (stem.contains(base) || base.contains(stem))
    }

    private nonisolated static func compareDirectorySubtitles(_ left: URL, _ right: URL, base: String) -> Bool {
        let leftStem = left.deletingPathExtension().lastPathComponent.lowercased()
        let rightStem = right.deletingPathExtension().lastPathComponent.lowercased()
        let leftRelated = isRelatedStem(leftStem, to: base)
        let rightRelated = isRelatedStem(rightStem, to: base)
        if leftRelated != rightRelated { return leftRelated }
        let stemOrder = left.deletingPathExtension().lastPathComponent
            .localizedStandardCompare(right.deletingPathExtension().lastPathComponent)
        if stemOrder != .orderedSame { return stemOrder == .orderedAscending }
        return left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
    }

    private nonisolated static func isDirectorySubtitleFile(_ file: URL, excluded: Set<String>) -> Bool {
        let ext = file.pathExtension.lowercased()
        guard ExternalSubtitleTrack.supportedExtensions.contains(ext),
              !excluded.contains(file.standardizedFileURL.path),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        return true
    }

    nonisolated static func directorySubtitles(for video: URL, excluding matched: [URL] = []) -> [URL] {
        guard !Task.isCancelled else { return [] }
        let directory = video.deletingLastPathComponent()
        let excluded = Set(matched.map { $0.standardizedFileURL.path })
        let base = video.deletingPathExtension().lastPathComponent.lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        var others: [URL] = []
        for file in files {
            if Task.isCancelled { return [] }
            if isDirectorySubtitleFile(file, excluded: excluded) {
                others.append(file)
            }
        }
        return others.sorted { left, right in
            compareDirectorySubtitles(left, right, base: base)
        }
    }
}
