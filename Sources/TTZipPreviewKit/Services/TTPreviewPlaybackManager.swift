// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaKit

/// High-level playback management facade for the preview subsystem.
/// Decouples UI and view models from direct MPV/audio engine dependencies.
@MainActor
public enum TTPreviewPlaybackManager {
    /// Returns true if any media player is actively playing.
    public static var isPlaying: Bool {
        MediaPlaybackCoordinator.shared.isPlaying
    }
    
    /// Stops any active playback session across video and audio engines.
    public static func stopAll() {
        MediaPlaybackCoordinator.shared.stopActivePlayback()
    }
    
    /// Toggles play/pause on the active media session.
    public static func togglePlayPause() {
        MediaPlaybackCoordinator.shared.triggerPlayPause()
    }
    
    /// Seeks playback by the given number of seconds.
    public static func seek(by deltaSeconds: Double) {
        MediaPlaybackCoordinator.shared.triggerSeek(by: deltaSeconds)
    }
}
