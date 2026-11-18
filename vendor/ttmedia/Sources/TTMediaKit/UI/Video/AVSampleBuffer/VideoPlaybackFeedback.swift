// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

public struct VideoPlaybackFeedback: Identifiable, Sendable {
    public enum Change: Sendable {
        case seekForward
        case seekBackward
        case volume(level: Float, isMuted: Bool)
        case muteChanged(isMuted: Bool)
        case rateChanged
    }

    public let id = UUID()
    public let change: Change
}
