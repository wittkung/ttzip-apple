// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import os

/// Unified in-app video player view presenting media through the declarative `TTVideoPlayer` architectural paradigm
/// or the hardware-accelerated `AVSampleBuffer` presentation stack.
/// Supports both compact inspector panel embedding and floating full-screen presentation.
@MainActor
public struct UnifiedVideoPlayerView: View {
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "UnifiedVideoPlayerView")

    public enum VideoPlayerEngine: Equatable, Sendable {
        case avSampleBuffer
    }

    public let url: URL
    public let isFullScreen: Bool
    public let autoPlay: Bool
    public let initialEngine: VideoPlayerEngine

    @State private var activeEngine: VideoPlayerEngine?
    @State private var isSecurityScoped: Bool = false

    public var engine: VideoPlayerEngine {
        activeEngine ?? initialEngine
    }
    
    @MainActor
    public init(url: URL, isFullScreen: Bool = false, autoPlay: Bool? = nil) {
        self.url = url
        self.isFullScreen = isFullScreen
        self.autoPlay = autoPlay ?? isFullScreen
        self.initialEngine = Self.resolveEngine(for: url)
    }

    public static func resolveEngine(for url: URL) -> VideoPlayerEngine {
        return .avSampleBuffer
    }
    
    public var body: some View {
        Group {
            AVSampleBufferVideoPlayerView(
                url: url,
                isFullScreen: isFullScreen,
                autoPlay: autoPlay,
                onFallbackToMPV: {
                    logger.info("AVSampleBuffer playback unavailable for \(url.lastPathComponent); fallback to MPV is decommissioned")
                }
            )
        }
        .onChange(of: url) { oldURL, newURL in
            activeEngine = .avSampleBuffer
        }
    }
    
    private func toggleFullScreen() {
        TTMediaDetector.beginFullscreenEphemeralHandoff(for: url)
        let userInfo: [AnyHashable: Any] = ["url": url, "name": url.lastPathComponent]
        NotificationCenter.default.post(
            name: .ttMediaToggleMediaFocusNotification,
            object: url,
            userInfo: userInfo
        )
    }
}
