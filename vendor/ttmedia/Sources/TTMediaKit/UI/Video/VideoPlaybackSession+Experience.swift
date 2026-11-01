// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreMedia

struct VideoPlaybackCheckpointState {
    var resourceIdentity: String?
    var restoredRecord: PlaybackExperienceRecord?
    var isReady = false
    var lastSavedAt = Date.distantPast
}

extension VideoPlaybackSession {
    func restoreExperienceSettings() {
        checkpointState.resourceIdentity = experienceStore.identity(for: url)
        guard let saved = experienceStore.record(for: url) else { return }
        checkpointState.restoredRecord = saved
        userRotationDegrees = VideoContentGeometry.normalizedRotationDegrees(saved.rotationDegrees)
        volume = saved.volume.isFinite ? min(1, max(0, saved.volume)) : 1
        isMuted = saved.muted
        playbackRate = saved.rate.isFinite ? min(4, max(0.25, saved.rate)) : 1
        selectedSubtitleID = validRestoredSubtitle(saved.primarySubtitle)
        selectedSecondarySubtitleID = validRestoredSubtitle(saved.secondarySubtitle) ?? "off"
        if let style = saved.subtitleStyle { subtitleStyle = style }
    }

    private func validRestoredSubtitle(_ id: String?) -> String? {
        guard let id else { return nil }
        if id == "off" || id.hasPrefix("embedded:") { return id }
        guard let file = URL(string: id), file.isFileURL,
              PlaybackExperienceStore.localIdentity(for: file) != nil,
              FileManager.default.isReadableFile(atPath: file.path) else {
            subtitleError = MediaLocalization.text(.subtitleFailed) + ": " + (URL(string: id)?.lastPathComponent ?? id)
            return "off"
        }
        return id
    }

    func restoredExperienceTime(or requested: CMTime) -> CMTime {
        guard checkpointState.resourceIdentity == experienceStore.identity(for: url) else {
            checkpointState.restoredRecord = nil
            checkpointState.isReady = false
            userRotationDegrees = 0
            volume = 1
            isMuted = false
            playbackRate = 1
            selectedSubtitleID = nil
            selectedSecondarySubtitleID = "off"
            subtitleStyle = SubtitleStyleConfiguration.loadFromDefaults()
            return .zero
        }
        checkpointState.isReady = true
        let requestedSeconds = CMTimeGetSeconds(requested)
        if requestedSeconds.isFinite && requestedSeconds > 0 { return requested }
        guard checkpointState.resourceIdentity == experienceStore.identity(for: url),
              let saved = checkpointState.restoredRecord else { return requested }
        let seconds = PlaybackExperiencePolicy.resumePosition(saved.position, CMTimeGetSeconds(duration))
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }

    func validateRestoredSubtitleAvailability() {
        guard checkpointState.restoredRecord != nil else { return }
        let available = Set(embeddedSubtitles.filter(\.supported).map { "embedded:\($0.id)" })
        if let primary = selectedSubtitleID, primary.hasPrefix("embedded:"), !available.contains(primary),
           !isPrimarySubtitleSelectionPending(primary) {
            selectedSubtitleID = "off"
            subtitleError = MediaLocalization.text(.subtitleFailed)
        }
        let secondaryAvailable = Set(embeddedSubtitles.filter { $0.supported && $0.codec != "S_HDMV/PGS" }
            .map { "embedded:\($0.id)" })
        if selectedSecondarySubtitleID.hasPrefix("embedded:"), !secondaryAvailable.contains(selectedSecondarySubtitleID),
           !isSecondarySubtitleSelectionPending(selectedSecondarySubtitleID) {
            selectedSecondarySubtitleID = "off"
            subtitleError = MediaLocalization.text(.subtitleFailed)
        }
    }

    private func persistableSubtitleID(_ id: String?) -> String? {
        guard let id else { return nil }
        if id == "off" || id.hasPrefix("embedded:") { return id }
        guard let file = URL(string: id), file.isFileURL,
              PlaybackExperienceStore.localIdentity(for: file) != nil else { return "off" }
        return file.absoluteString
    }

    func savePlaybackExperience(force: Bool = false) {
        guard checkpointState.isReady, !isStopped, checkpointState.resourceIdentity != nil,
              CMTimeGetSeconds(duration).isFinite, CMTimeGetSeconds(duration) > 0 else { return }
        let now = Date()
        guard force || now.timeIntervalSince(checkpointState.lastSavedAt) >= 5 else { return }
        checkpointState.lastSavedAt = now
        var record = PlaybackExperienceRecord()
        record.position = max(0, CMTimeGetSeconds(currentTime))
        record.duration = CMTimeGetSeconds(duration)
        record.rotationDegrees = userRotationDegrees
        record.volume = isMuted ? previousVolume : volume
        record.muted = isMuted
        record.rate = playbackRate
        record.primarySubtitle = persistableSubtitleID(selectedSubtitleID)
        record.secondarySubtitle = persistableSubtitleID(selectedSecondarySubtitleID) ?? "off"
        record.subtitleStyle = subtitleStyle
        record.updatedAt = now
        experienceStore.save(record, for: url, matching: checkpointState.resourceIdentity)
    }
}
