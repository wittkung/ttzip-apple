// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import CoreMedia

@MainActor
struct AVSampleBufferHostRepresentable: NSViewRepresentable {
    let controller: VideoPlaybackController
    let sessionID: UUID
    let viewportID: UUID
    let isPresenting: Bool
    let hasControlBar: Bool
    let isControlBarVisible: Bool
    let controlsVisibility: MediaControlsVisibility
    let videoContentRect: CGRect?
    let userRotationDegrees: Int
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void
    let onDropFiles: ([URL]) -> Void
    let onMouseMovedAtPoint: (CGPoint) -> Void
    let onMouseHoverChanged: (Bool) -> Void
    let onWindowFocusLost: () -> Void
    let onRotateClockwise: () -> Void
    let onRotateCounterClockwise: () -> Void
    let onRotate180: () -> Void
    let onResetRotation: () -> Void
    let onHostScreenObservationChanged: (VideoHostScreenObservation?, UUID?) -> Void
    let formatDetailsSummary: String?
    let makeCanvasMenu: (@MainActor (VideoPlaybackMenus.Playback) -> NSMenu)?

    func makeNSView(context: Context) -> AVSampleBufferPlayerNSView {
        let view = AVSampleBufferPlayerNSView(
            frame: .zero,
            renderer: AVSampleBufferRenderer(displayLayer: controller.displayLayer),
            synchronizer: controller.synchronizer,
            audioRenderer: controller.audioRenderer,
            attachesDisplayLayerImmediately: isPresenting
        )
        view.hasControlBar = hasControlBar
        view.isControlBarVisible = isControlBarVisible
        view.controlsVisibility = controlsVisibility
        view.videoContentRect = videoContentRect
        view.userRotationDegrees = userRotationDegrees
        view.formatDetailsSummary = formatDetailsSummary
        view.makeCanvasMenu = makeCanvasMenu
        view.onHostScreenObservationChanged = onHostScreenObservationChanged
        view.updatePresentationOwnership(
            sessionID: sessionID,
            viewportID: viewportID,
            isPresenting: isPresenting,
            reason: "makeNSView"
        )
        view.onTogglePlayPause = { [controller] in
            controller.togglePlayPause()
        }
        view.onSeek = { [controller] targetTime in
            controller.seek(to: targetTime)
        }
        view.onCanvasSingleClick = onSingleClick
        view.onCanvasDoubleClick = onDoubleClick
        view.onVolumeChange = onVolumeChange
        view.onMuteToggle = onMuteToggle
        view.onDropFiles = onDropFiles
        view.onMouseMovedAtPoint = onMouseMovedAtPoint
        view.onHoverChanged = onMouseHoverChanged
        view.onWindowFocusLost = onWindowFocusLost
        view.onRotateClockwise = onRotateClockwise
        view.onRotateCounterClockwise = onRotateCounterClockwise
        view.onRotate180 = onRotate180
        view.onResetRotation = onResetRotation
        return view
    }

    func updateNSView(_ nsView: AVSampleBufferPlayerNSView, context: Context) {
        nsView.hasControlBar = hasControlBar
        nsView.controlsVisibility = controlsVisibility
        if nsView.isControlBarVisible != isControlBarVisible {
            nsView.isControlBarVisible = isControlBarVisible
            if isControlBarVisible {
                nsView.cancelPendingCanvasSingleClick()
            }
        }
        nsView.videoContentRect = videoContentRect
        nsView.userRotationDegrees = userRotationDegrees
        nsView.formatDetailsSummary = formatDetailsSummary
        nsView.makeCanvasMenu = makeCanvasMenu
        nsView.onHostScreenObservationChanged = onHostScreenObservationChanged
        nsView.updatePresentationOwnership(
            sessionID: sessionID,
            viewportID: viewportID,
            isPresenting: isPresenting,
            reason: "updateNSView"
        )
        nsView.onDropFiles = onDropFiles
        nsView.onMouseMovedAtPoint = onMouseMovedAtPoint
        nsView.onHoverChanged = onMouseHoverChanged
        nsView.onWindowFocusLost = onWindowFocusLost
        nsView.onRotateClockwise = onRotateClockwise
        nsView.onRotateCounterClockwise = onRotateCounterClockwise
        nsView.onRotate180 = onRotate180
        nsView.onResetRotation = onResetRotation
    }
}
