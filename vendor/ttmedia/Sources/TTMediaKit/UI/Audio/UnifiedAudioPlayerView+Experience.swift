// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

struct AudioPlaybackCheckpointState {
    var resourceIdentity: String?
    var restoredURL: URL?
    var lastSavedAt = Date.distantPast
}

extension UnifiedAudioPlayerView {
    @MainActor
    func restoreAudioExperienceIfNeeded() {
        guard audioEngine.currentURL == url, audioEngine.duration > 0,
              experienceState.restoredURL != url else { return }
        experienceState.restoredURL = url
        experienceState.resourceIdentity = PlaybackExperienceStore.shared.identity(for: url)
        guard audioEngine.currentTime <= 0,
              let record = PlaybackExperienceStore.shared.record(for: url) else { return }
        audioEngine.setVolume(Double(record.volume.isFinite ? min(1, max(0, record.volume)) : 1))
        audioEngine.setPlaybackSpeed(Double(record.rate.isFinite ? min(4, max(0.25, record.rate)) : 1))
        if record.muted != audioEngine.isMuted { audioEngine.toggleMute() }
        audioEngine.seek(to: PlaybackExperiencePolicy.resumePosition(record.position, audioEngine.duration))
    }

    @MainActor
    func saveAudioExperience(force: Bool = false) {
        guard audioEngine.currentURL == url, audioEngine.duration > 0,
              experienceState.restoredURL == url, experienceState.resourceIdentity != nil else { return }
        let now = Date()
        guard force || now.timeIntervalSince(experienceState.lastSavedAt) >= 5 else { return }
        experienceState.lastSavedAt = now
        var record = PlaybackExperienceRecord()
        record.position = audioEngine.currentTime
        record.duration = audioEngine.duration
        record.volume = Float(audioEngine.volume)
        record.muted = audioEngine.isMuted
        record.rate = Float(audioEngine.playbackSpeed)
        record.updatedAt = now
        PlaybackExperienceStore.shared.save(record, for: url, matching: experienceState.resourceIdentity)
    }
}
