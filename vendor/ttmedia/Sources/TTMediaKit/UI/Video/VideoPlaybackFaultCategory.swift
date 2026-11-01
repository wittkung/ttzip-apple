// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Explicit four-category classification for video playback and audio isolation faults.
public enum VideoPlaybackFaultCategory: String, Sendable, Equatable {
    case unsupportedAudioTrack
    case audioInitializationFailed
    case containerCorrupted
    case workerCrashed
}

