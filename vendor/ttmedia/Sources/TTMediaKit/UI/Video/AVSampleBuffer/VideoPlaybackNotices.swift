// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Concurrent audio and transient notices for a video viewport.
public struct VideoPlaybackNotices: Sendable {
    public let audioWarning: String?
    public let osdMessage: String?
}
