// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreMedia
import Foundation
import TTMediaDemux

public struct SubtitleMenuOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let enabled: Bool
    public let supportsSecondary: Bool

    public init(id: String, title: String, enabled: Bool, supportsSecondary: Bool = true) {
        self.id = id
        self.title = title
        self.enabled = enabled
        self.supportsSecondary = supportsSecondary
    }
}

extension VideoPlaybackSession {
    var subtitleOptions: [SubtitleMenuOption] {
        let embedded = embeddedSubtitles.enumerated().map { index, track in
            SubtitleMenuOption(
                id: "embedded:\(track.id)",
                title: "#\(index + 1) \(track.displayName)",
                enabled: track.supported,
                supportsSecondary: track.codec != "S_HDMV/PGS"
            )
        }
        let external = companionSubtitles.map {
            SubtitleMenuOption(id: $0.absoluteString, title: $0.lastPathComponent, enabled: true)
        }
        let companionSet = Set(companionSubtitles.map(\.absoluteString))
        let directoryOther = directorySubtitles
            .filter { !companionSet.contains($0.absoluteString) }
            .map {
                SubtitleMenuOption(id: $0.absoluteString, title: $0.lastPathComponent, enabled: true)
            }
        return embedded + external + directoryOther
    }

    func refreshActiveSubtitleTexts() {
        let seconds = CMTimeGetSeconds(currentTime)
        let validSeconds = seconds.isFinite ? max(0.0, seconds) : 0.0
        let delay = subtitleStyle.delay

        let nextPrimary = subtitleTrack?.text(at: validSeconds, delay: delay) ?? ""
        if nextPrimary != activeSubtitleText {
            activeSubtitleText = nextPrimary
        }

        let nextSecondary = secondarySubtitleTrack?.text(at: validSeconds, delay: delay) ?? ""
        if nextSecondary != activeSecondarySubtitleText {
            activeSecondarySubtitleText = nextSecondary
        }
    }

    func updateSubtitleStyle(_ updated: SubtitleStyleConfiguration) {
        let previous = subtitleStyle
        subtitleStyle = updated
        refreshActiveSubtitleTexts()
        updated.saveToDefaults()
        if abs(updated.delay - previous.delay) > 0.01 {
            showOSD("\(MediaLocalization.text(.subtitleDelay)): \(String(format: "%+.1fs", updated.delay))")
        } else if abs(updated.scale - previous.scale) > 0.01 {
            showOSD("\(MediaLocalization.text(.subtitleScale)): \(String(format: "%.1fx", updated.scale))")
        }
    }

    func showOSD(_ text: String) {
        osdDismissTask?.cancel()
        osdMessage = text
        osdDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard let self, !Task.isCancelled else { return }
            self.osdMessage = nil
        }
    }

    func currentSubtitleSessionID() -> String {
        if case .worker(let controller) = activeController,
           let workerSession = controller.client.activeSessionId {
            return workerSession
        }
        return sessionID.uuidString
    }

    func allocateSubtitleRequestID(sessionId: String? = nil) -> UInt64 {
        let sid = sessionId ?? currentSubtitleSessionID()
        return SubtitleSessionRequestRegistry.shared.allocateRequestID(sessionId: sid)
    }

    func cancelSubtitleRequestID(_ requestID: UInt64?) {
        guard let requestID, requestID != 0 else { return }
        let sid = currentSubtitleSessionID()
        embeddedSubtitleRequestCanceller?(requestID)
        if case .worker(let controller) = activeController {
            controller.client.cancelSubtitleRequest(requestID)
        }
        if let transport = subtitleTransportOverride {
            if let xpc = transport as? MediaWorkerXPCTransport {
                xpc.markClientRequestCancelled(sessionId: sid, requestID: requestID)
            } else {
                SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sid, requestID: requestID)
            }
            Task { await transport.cancelSubtitleRequest(sessionId: sid, requestID: requestID) }
        } else if activeController == nil {
            SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sid, requestID: requestID)
        }
    }

    func cancelAllSessionSubtitleRequests() {
        cancelSubtitlePrewarm()
        let activeIDs = [
            activePrewarmRequestID,
            activePrimaryRequestID,
            activeSecondaryRequestID,
            activeDefaultEmbeddedRequestID,
        ].compactMap { $0 }
        activePrewarmRequestID = nil
        activePrimaryRequestID = nil
        activeSecondaryRequestID = nil
        activeDefaultEmbeddedRequestID = nil
        let localSid = sessionID.uuidString
        let currentSid = currentSubtitleSessionID()
        SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: localSid)
        if currentSid != localSid {
            SubtitleSessionRequestRegistry.shared.cancelSession(sessionId: currentSid)
        }
        for reqID in activeIDs where reqID != 0 {
            cancelSubtitleRequestID(reqID)
        }
        SubtitleSessionRequestRegistry.shared.reclaimUnstartedSessionRequests(sessionId: localSid)
        if currentSid != localSid {
            SubtitleSessionRequestRegistry.shared.reclaimUnstartedSessionRequests(sessionId: currentSid)
        }
        if case .worker(let controller) = activeController {
            controller.client.cancelAllSubtitleRequestsForActiveSession()
        }
        if let transport = subtitleTransportOverride {
            Task { await transport.cancelAllSubtitleRequests(sessionId: currentSid) }
        }
    }

    @discardableResult
    private func beginPrimarySubtitleSelection() -> UUID {
        let generation = UUID()
        subtitleLoadGeneration = generation
        pendingPrimarySubtitleSelection = nil
        let previousPrimaryID = activePrimaryRequestID
        activePrimaryRequestID = nil
        let previousDefaultID = activeDefaultEmbeddedRequestID
        activeDefaultEmbeddedRequestID = nil
        subtitleLoadTask?.cancel()
        subtitleLoadTask = nil
        cancelSubtitleRequestID(previousPrimaryID)
        cancelSubtitleRequestID(previousDefaultID)
        cancelSubtitlePrewarm()
        isSubtitleLoading = false
        subtitleError = nil
        return generation
    }

    @discardableResult
    private func beginSecondarySubtitleSelection() -> UUID {
        let generation = UUID()
        secondarySubtitleLoadGeneration = generation
        pendingSecondarySubtitleSelection = nil
        let previousSecondaryID = activeSecondaryRequestID
        activeSecondaryRequestID = nil
        secondarySubtitleLoadTask?.cancel()
        secondarySubtitleLoadTask = nil
        cancelSubtitleRequestID(previousSecondaryID)
        cancelSubtitlePrewarm()
        return generation
    }

    nonisolated static func loadExternalTrackOffMainActor(from url: URL) async throws -> ExternalSubtitleTrack {
        try Task.checkCancellation()
        let parsed = try ExternalSubtitleTrack.load(from: url)
        try Task.checkCancellation()
        return parsed
    }

    func currentEmbeddedSubtitleRequestReader() -> (@Sendable (Int64, UInt64) async throws -> Data)? {
        if let embeddedSubtitleRequestLoader {
            return embeddedSubtitleRequestLoader
        }
        if let subtitleTransportOverride {
            let sid = currentSubtitleSessionID()
            return { track, requestID in
                try await subtitleTransportOverride.subtitleData(sessionId: sid, track: track, requestID: requestID)
            }
        }
        if let embeddedSubtitleLoader {
            let sid = currentSubtitleSessionID()
            return { track, requestID in
                defer {
                    SubtitleSessionRequestRegistry.shared.finishRequest(sessionId: sid, requestID: requestID)
                }
                try SubtitleSessionRequestRegistry.shared.beginRequest(sessionId: sid, requestID: requestID)
                return try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    guard !SubtitleSessionRequestRegistry.shared.isCancelled(sessionId: sid, requestID: requestID) else {
                        throw CancellationError()
                    }
                    return try await embeddedSubtitleLoader(track)
                } onCancel: {
                    SubtitleSessionRequestRegistry.shared.cancelRequest(sessionId: sid, requestID: requestID)
                }
            }
        }
        if case .worker(let controller) = activeController {
            let client = controller.client
            return { track, requestID in
                try await client.subtitleData(track: track, requestID: requestID)
            }
        }
        return nil
    }

    func discoverSubtitles() {
        subtitleDiscoveryTask?.cancel()
        cancelSubtitlePrewarm()
        let loader = externalSubtitleLoader
        subtitleDiscoveryTask = Task { @MainActor [weak self] in
            guard let self, !isStopped else { return }
            let video = url
            let (candidates, otherDirectorySubs, firstCompanionTrack) =
                await Self.discoverExternalSubtitlesOffMainActor(for: video, loader: loader)
            guard !Task.isCancelled, !isStopped else { return }
            companionSubtitles = candidates
            directorySubtitles = otherDirectorySubs
            if let (key, track) = firstCompanionTrack {
                subtitleCache[key] = track
            }
            await activateInitialDefaultSubtitle(candidates: candidates)
            guard !Task.isCancelled, !isStopped else { return }
            scheduleBackgroundSubtitlePrewarm(candidates: candidates, others: otherDirectorySubs)
        }
    }

    private func activateInitialDefaultSubtitle(candidates: [URL]) async {
        if selectedSubtitleID == nil, let first = candidates.first, subtitleCache[first.absoluteString] != nil {
            selectSubtitle(first.absoluteString, showFeedback: false)
        }
        await discoverEmbeddedSubtitlesCatalog()
        guard !Task.isCancelled, !isStopped, selectedSubtitleID == nil else { return }
        if let first = candidates.first {
            selectSubtitle(first.absoluteString, showFeedback: false)
        } else if let preferred = preferredEmbeddedTrack() {
            await activateDefaultEmbeddedTrack(preferred)
        }
    }

    private func discoverEmbeddedSubtitlesCatalog() async {
        guard let reader = currentEmbeddedSubtitleRequestReader() else { return }
        let catalogSessionID = currentSubtitleSessionID()
        let requestID = allocateSubtitleRequestID(sessionId: catalogSessionID)
        defer {
            SubtitleSessionRequestRegistry.shared.finishRequest(
                sessionId: catalogSessionID,
                requestID: requestID
            )
        }
        do {
            let catalogData = try await reader(-1, requestID)
            let tracks = try await Self.decodeSubtitleCatalogOffMainActor(catalogData)
            guard !Task.isCancelled, !isStopped else { return }
            embeddedSubtitles = tracks
        } catch {
            if !Task.isCancelled, !isStopped {
                embeddedSubtitles = []
            }
        }
    }

    private func activateDefaultEmbeddedTrack(_ track: EmbeddedSubtitleTrack) async {
        let key = "embedded:\(track.id)"
        if subtitleCache[key] != nil || bitmapSubtitleCache[key] != nil {
            if selectedSubtitleID == nil {
                selectSubtitle(key, showFeedback: false)
            }
            return
        }
        guard let reader = currentEmbeddedSubtitleRequestReader() else { return }
        let defaultSessionID = currentSubtitleSessionID()
        let requestID = allocateSubtitleRequestID(sessionId: defaultSessionID)
        activeDefaultEmbeddedRequestID = requestID
        defer {
            SubtitleSessionRequestRegistry.shared.finishRequest(
                sessionId: defaultSessionID,
                requestID: requestID
            )
            if activeDefaultEmbeddedRequestID == requestID {
                activeDefaultEmbeddedRequestID = nil
            }
        }
        do {
            let rawData = try await reader(track.id, requestID)
            if track.codec == "S_HDMV/PGS" {
                let parsed = try await Self.decodeBitmapTrackOffMainActor(rawData)
                guard !Task.isCancelled, !isStopped else { return }
                bitmapSubtitleCache[key] = parsed
            } else {
                guard let parsed = try await Self.decodeSingleTrackOffMainActor(rawData),
                      !Task.isCancelled, !isStopped else { return }
                subtitleCache[key] = parsed
            }
            if selectedSubtitleID == nil {
                selectSubtitle(key, showFeedback: false)
            }
        } catch {
            // Retain unloaded state; background prewarm or explicit selection can retry.
        }
    }

    private func preferredEmbeddedTrack() -> EmbeddedSubtitleTrack? {
        let supported = embeddedSubtitles.filter(\.supported)
        let nonForced = supported.filter { $0.isForced != true }
        let pool = nonForced.isEmpty ? supported : nonForced
        for locale in Locale.preferredLanguages {
            let base = locale.lowercased().split(separator: "-").first.map(String.init) ?? locale
            if let track = pool.first(where: { Self.matchesPreferredLanguage($0.language, base: base) }) {
                return track
            }
        }
        return pool.first(where: { $0.isDefault != false }) ?? pool.first
    }

    private nonisolated static func matchesPreferredLanguage(_ trackLanguage: String, base: String) -> Bool {
        let lowered = trackLanguage.lowercased()
        if lowered.hasPrefix(base) { return true }
        return base == "zh" && ["chi", "zho"].contains(lowered)
    }

    func loadExternalSubtitle(_ selected: URL, showFeedback: Bool = true) {
        let id = selected.absoluteString
        let previousID = selectedSubtitleID
        let generation = beginPrimarySubtitleSelection()

        if let cached = subtitleCache[id] {
            selectedSubtitleID = id
            subtitleTrack = cached
            bitmapSubtitleTrack = nil
            subtitleName = selected.lastPathComponent
            refreshActiveSubtitleTexts()
            if !companionSubtitles.contains(selected) && !directorySubtitles.contains(selected) {
                companionSubtitles.append(selected)
            }
            if showFeedback {
                showOSD("\(MediaLocalization.text(.subtitles)): \(selected.lastPathComponent)")
            }
            return
        }

        selectedSubtitleID = id
        let loader = externalSubtitleLoader
        pendingPrimarySubtitleSelection = PendingSubtitleSelection(id: id, generation: generation)
        subtitleLoadTask = Task { @MainActor [weak self] in
            guard let self, !isStopped else { return }
            defer { finishPrimarySubtitleSelection(id: id, generation: generation) }
            do {
                let track = try await loader(selected)
                guard !Task.isCancelled, !isStopped, subtitleLoadGeneration == generation else { return }
                subtitleCache[id] = track
                subtitleTrack = track
                bitmapSubtitleTrack = nil
                subtitleName = selected.lastPathComponent
                refreshActiveSubtitleTexts()
                if !companionSubtitles.contains(selected) && !directorySubtitles.contains(selected) {
                    companionSubtitles.append(selected)
                }
                if showFeedback {
                    showOSD("\(MediaLocalization.text(.subtitles)): \(selected.lastPathComponent)")
                }
            } catch {
                if !Task.isCancelled, !isStopped, subtitleLoadGeneration == generation {
                    selectedSubtitleID = previousID
                    subtitleError = error.localizedDescription
                }
            }
        }
    }

    func selectSubtitle(_ id: String, showFeedback: Bool = true) {
        let previousID = selectedSubtitleID
        let generation = beginPrimarySubtitleSelection()

        if id == "off" {
            selectedSubtitleID = id
            subtitleTrack = nil
            bitmapSubtitleTrack = nil
            subtitleName = nil
            refreshActiveSubtitleTexts()
            if showFeedback {
                showOSD("\(MediaLocalization.text(.subtitles)): \(MediaLocalization.text(.off))")
            }
            return
        }

        if let cached = subtitleCache[id] {
            selectedSubtitleID = id
            subtitleTrack = cached
            bitmapSubtitleTrack = nil
            let resolved = resolvedSubtitleTitle(for: id)
            subtitleName = resolved
            refreshActiveSubtitleTexts()
            if showFeedback, let resolved {
                showOSD("\(MediaLocalization.text(.subtitles)): \(resolved)")
            }
            return
        }

        if let cached = bitmapSubtitleCache[id] {
            selectedSubtitleID = id
            bitmapSubtitleTrack = cached
            subtitleTrack = nil
            subtitleName = resolvedSubtitleTitle(for: id)
            return
        }

        if let track = embeddedSubtitles.first(where: { "embedded:\($0.id)" == id }),
           let reader = currentEmbeddedSubtitleRequestReader() {
            loadEmbeddedPrimarySubtitle(
                track,
                reader: reader,
                id: id,
                previousID: previousID,
                generation: generation,
                showFeedback: showFeedback
            )
        } else if let selected = (companionSubtitles + directorySubtitles).first(where: { $0.absoluteString == id }) {
            loadExternalSubtitle(selected, showFeedback: showFeedback)
        }
    }

    private func loadEmbeddedPrimarySubtitle(
        _ track: EmbeddedSubtitleTrack,
        reader: @escaping @Sendable (Int64, UInt64) async throws -> Data,
        id: String,
        previousID: String?,
        generation: UUID,
        showFeedback: Bool
    ) {
        selectedSubtitleID = id
        let primarySessionID = currentSubtitleSessionID()
        let requestID = allocateSubtitleRequestID(sessionId: primarySessionID)
        activePrimaryRequestID = requestID
        pendingPrimarySubtitleSelection = PendingSubtitleSelection(id: id, generation: generation)
        subtitleLoadTask = Task { @MainActor [weak self] in
            defer {
                self?.finishPrimarySubtitleSelection(id: id, generation: generation)
                SubtitleSessionRequestRegistry.shared.finishRequest(
                    sessionId: primarySessionID,
                    requestID: requestID
                )
                if self?.activePrimaryRequestID == requestID {
                    self?.activePrimaryRequestID = nil
                }
            }
            guard let self, !isStopped else { return }
            do {
                let rawData = try await reader(track.id, requestID)
                if track.codec == "S_HDMV/PGS" {
                    let parsed = try await Self.decodeBitmapTrackOffMainActor(rawData)
                    guard !Task.isCancelled, !isStopped, subtitleLoadGeneration == generation else { return }
                    bitmapSubtitleCache[id] = parsed
                    bitmapSubtitleTrack = parsed
                    subtitleTrack = nil
                } else {
                    guard let parsed = try await Self.decodeSingleTrackOffMainActor(rawData),
                          !Task.isCancelled, !isStopped, subtitleLoadGeneration == generation else { return }
                    subtitleCache[id] = parsed
                    subtitleTrack = parsed
                    bitmapSubtitleTrack = nil
                }
                subtitleName = track.displayName
                refreshActiveSubtitleTexts()
                if showFeedback {
                    showOSD("\(MediaLocalization.text(.subtitles)): \(track.displayName)")
                }
            } catch {
                if !Task.isCancelled, !isStopped, subtitleLoadGeneration == generation {
                    selectedSubtitleID = previousID
                    subtitleError = error.localizedDescription
                }
            }
        }
    }

    func selectSecondarySubtitle(_ id: String) {
        if embeddedSubtitles.contains(where: { "embedded:\($0.id)" == id && $0.codec == "S_HDMV/PGS" }) {
            subtitleError = MediaLocalization.text(.subtitleFailed)
            return
        }
        let previousID = selectedSecondarySubtitleID
        let generation = beginSecondarySubtitleSelection()

        if id == "off" {
            selectedSecondarySubtitleID = "off"
            secondarySubtitleTrack = nil
            secondarySubtitleName = nil
            refreshActiveSubtitleTexts()
            showOSD("\(MediaLocalization.text(.secondarySubtitle)): \(MediaLocalization.text(.off))")
            return
        }
        if let cached = subtitleCache[id] {
            selectedSecondarySubtitleID = id
            secondarySubtitleTrack = cached
            let resolved = resolvedSubtitleTitle(for: id)
            secondarySubtitleName = resolved
            refreshActiveSubtitleTexts()
            if let resolved {
                showOSD("\(MediaLocalization.text(.secondarySubtitle)): \(resolved)")
            }
            return
        }
        loadSecondarySubtitleAsync(id, previousID: previousID, generation: generation)
    }

    private func applyLoadedSecondarySubtitle(
        _ parsed: ExternalSubtitleTrack,
        id: String,
        displayName: String,
        generation: UUID
    ) {
        guard !Task.isCancelled, !isStopped, secondarySubtitleLoadGeneration == generation else { return }
        subtitleCache[id] = parsed
        guard selectedSecondarySubtitleID == id else { return }
        secondarySubtitleTrack = parsed
        secondarySubtitleName = displayName
        refreshActiveSubtitleTexts()
        showOSD("\(MediaLocalization.text(.secondarySubtitle)): \(displayName)")
    }

    private func loadSecondarySubtitleAsync(_ id: String, previousID: String, generation: UUID) {
        if let track = embeddedSubtitles.first(where: { "embedded:\($0.id)" == id }),
           let reader = currentEmbeddedSubtitleRequestReader() {
            loadEmbeddedSecondarySubtitle(
                track,
                reader: reader,
                id: id,
                previousID: previousID,
                generation: generation
            )
        } else if let selected = (companionSubtitles + directorySubtitles).first(where: { $0.absoluteString == id }) {
            loadExternalSecondarySubtitle(
                selected,
                id: id,
                previousID: previousID,
                generation: generation
            )
        }
    }

    private func loadEmbeddedSecondarySubtitle(
        _ track: EmbeddedSubtitleTrack,
        reader: @escaping @Sendable (Int64, UInt64) async throws -> Data,
        id: String,
        previousID: String,
        generation: UUID
    ) {
        selectedSecondarySubtitleID = id
        let secondarySessionID = currentSubtitleSessionID()
        let requestID = allocateSubtitleRequestID(sessionId: secondarySessionID)
        activeSecondaryRequestID = requestID
        pendingSecondarySubtitleSelection = PendingSubtitleSelection(id: id, generation: generation)
        secondarySubtitleLoadTask = Task { @MainActor [weak self] in
            defer {
                self?.finishSecondarySubtitleSelection(id: id, generation: generation)
                SubtitleSessionRequestRegistry.shared.finishRequest(
                    sessionId: secondarySessionID,
                    requestID: requestID
                )
                if self?.activeSecondaryRequestID == requestID {
                    self?.activeSecondaryRequestID = nil
                }
            }
            guard let self, !isStopped else { return }
            guard let rawData = try? await reader(track.id, requestID),
                  let parsed = try? await Self.decodeSingleTrackOffMainActor(rawData) else {
                if !Task.isCancelled, !isStopped, secondarySubtitleLoadGeneration == generation {
                    selectedSecondarySubtitleID = previousID
                }
                return
            }
            guard !Task.isCancelled, !isStopped, secondarySubtitleLoadGeneration == generation else { return }
            applyLoadedSecondarySubtitle(parsed, id: id, displayName: track.displayName, generation: generation)
        }
    }

    private func loadExternalSecondarySubtitle(
        _ selected: URL,
        id: String,
        previousID: String,
        generation: UUID
    ) {
        selectedSecondarySubtitleID = id
        let loader = externalSubtitleLoader
        pendingSecondarySubtitleSelection = PendingSubtitleSelection(id: id, generation: generation)
        secondarySubtitleLoadTask = Task { @MainActor [weak self] in
            guard let self, !isStopped else { return }
            defer { finishSecondarySubtitleSelection(id: id, generation: generation) }
            guard let parsed = try? await loader(selected) else {
                if !Task.isCancelled, !isStopped, secondarySubtitleLoadGeneration == generation {
                    selectedSecondarySubtitleID = previousID
                }
                return
            }
            guard !Task.isCancelled, !isStopped, secondarySubtitleLoadGeneration == generation else { return }
            applyLoadedSecondarySubtitle(parsed, id: id, displayName: selected.lastPathComponent, generation: generation)
        }
    }

    private func resolvedSubtitleTitle(for id: String) -> String? {
        if let option = subtitleOptions.first(where: { $0.id == id }) {
            return option.title
        }
        if let embedded = embeddedSubtitles.first(where: { "embedded:\($0.id)" == id }) {
            return embedded.displayName
        }
        if let external = (companionSubtitles + directorySubtitles).first(where: { $0.absoluteString == id }) {
            return external.lastPathComponent
        }
        return nil
    }
}

