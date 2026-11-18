// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI

@MainActor
public struct VideoPlaybackMenus {
    public enum Action {
        case togglePlayPause
        case rotateClockwise
        case rotateCounterClockwise
        case rotate180
        case resetRotation
        case toggleFullScreen
    }

    public struct Playback {
        public let isPlaying: Bool
        public let canResetRotation: Bool
        public let formatSummary: String
        let dispatch: @MainActor (Action) -> Void

        @MainActor
        public func send(_ action: Action) {
            dispatch(action)
        }
    }

    public struct Context {
        public let playback: Playback
        public let videoURL: URL
        public let isFullScreen: Bool
        public let readPlaybackRange: @MainActor () -> (currentTime: Double, duration: Double)
    }

    let makeCanvasMenu: @MainActor (Playback) -> NSMenu
    let renderContextMenu: @MainActor (Context) -> AnyView

    public init(
        makeCanvasMenu: @escaping @MainActor (Playback) -> NSMenu,
        renderContextMenu: @escaping @MainActor (Context) -> AnyView
    ) {
        self.makeCanvasMenu = makeCanvasMenu
        self.renderContextMenu = renderContextMenu
    }
}

extension AVSampleBufferPlayerNSView {
    func performCanvasMenuAction(_ action: VideoPlaybackMenus.Action) {
        switch action {
        case .togglePlayPause:
            if let onCanvasSingleClick {
                onCanvasSingleClick()
            } else {
                togglePlayPause()
            }
        case .rotateClockwise:
            onRotateClockwise?()
        case .rotateCounterClockwise:
            onRotateCounterClockwise?()
        case .rotate180:
            onRotate180?()
        case .resetRotation:
            onResetRotation?()
        case .toggleFullScreen:
            if let onCanvasDoubleClick {
                onCanvasDoubleClick()
            } else {
                onToggleFullScreen?()
            }
        }
    }
}
