// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit

@MainActor
enum TTZipVideoPlaybackMenus {
    static let presentation = VideoPlaybackMenus(
        makeCanvasMenu: makeCanvasMenu,
        renderContextMenu: { AnyView(TTZipVideoContextMenu(context: $0)) }
    )

    private static func makeCanvasMenu(_ playback: VideoPlaybackMenus.Playback) -> NSMenu {
        let menu = NSMenu(title: "VideoContextMenu")
        menu.addItem(command(
            MediaLocalization.text(playback.isPlaying ? .pause : .play),
            keyEquivalent: " ",
            playback: playback,
            action: .togglePlayPause
        ))
        menu.addItem(.separator())

        let rotation = NSMenuItem(title: TTZipVideoInteractionLocalization.text(.rotationMenu), action: nil, keyEquivalent: "")
        rotation.submenu = makeRotationMenu(playback)
        menu.addItem(rotation)
        menu.addItem(.separator())

        menu.addItem(command(
            MediaLocalization.text(.fullscreen),
            keyEquivalent: "f",
            playback: playback,
            action: .toggleFullScreen
        ))
        if !playback.formatSummary.isEmpty {
            menu.addItem(.separator())
            let summary = NSMenuItem(title: playback.formatSummary, action: nil, keyEquivalent: "")
            summary.isEnabled = false
            menu.addItem(summary)
        }
        return menu
    }

    private static func makeRotationMenu(_ playback: VideoPlaybackMenus.Playback) -> NSMenu {
        let menu = NSMenu(title: "Rotation")
        menu.addItem(command(
            TTZipVideoInteractionLocalization.text(.rotateClockwise), playback: playback, action: .rotateClockwise
        ))
        menu.addItem(command(
            TTZipVideoInteractionLocalization.text(.rotateCounterClockwise), playback: playback, action: .rotateCounterClockwise
        ))
        menu.addItem(command(
            TTZipVideoInteractionLocalization.text(.rotate180), playback: playback, action: .rotate180
        ))
        menu.addItem(.separator())
        menu.addItem(command(
            TTZipVideoInteractionLocalization.text(.resetOrientation),
            isEnabled: playback.canResetRotation,
            playback: playback,
            action: .resetRotation
        ))
        return menu
    }

    private static func command(
        _ title: String,
        keyEquivalent: String = "",
        isEnabled: Bool = true,
        playback: VideoPlaybackMenus.Playback,
        action: VideoPlaybackMenus.Action
    ) -> NSMenuItem {
        let target = MenuAction(isEnabled: isEnabled) { playback.send(action) }
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke(_:)), keyEquivalent: keyEquivalent)
        item.representedObject = target
        item.target = target
        item.isEnabled = isEnabled
        return item
    }

    @MainActor
    private final class MenuAction: NSObject, NSMenuItemValidation {
        let isEnabled: Bool
        let action: @MainActor () -> Void

        init(isEnabled: Bool, action: @escaping @MainActor () -> Void) {
            self.isEnabled = isEnabled
            self.action = action
        }

        @objc func invoke(_ sender: NSMenuItem) {
            action()
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            isEnabled
        }
    }
}

@MainActor
private struct TTZipVideoContextMenu: View {
    let context: VideoPlaybackMenus.Context

    var body: some View {
        Button(context.playback.isPlaying ? MediaLocalization.text(.pause) : MediaLocalization.text(.play)) {
            context.playback.send(.togglePlayPause)
        }
        Divider()
        Menu(TTZipVideoInteractionLocalization.text(.rotationMenu)) {
            Button(TTZipVideoInteractionLocalization.text(.rotateClockwise)) {
                context.playback.send(.rotateClockwise)
            }
            Button(TTZipVideoInteractionLocalization.text(.rotateCounterClockwise)) {
                context.playback.send(.rotateCounterClockwise)
            }
            Button(TTZipVideoInteractionLocalization.text(.rotate180)) {
                context.playback.send(.rotate180)
            }
            Divider()
            Button(TTZipVideoInteractionLocalization.text(.resetOrientation)) {
                context.playback.send(.resetRotation)
            }
            .disabled(!context.playback.canResetRotation)
        }
        Divider()
        Button("Export GIF…") {
            let manager = GIFExportManager.shared
            let range = context.readPlaybackRange()
            manager.exportCurrentLoopAsGIF(
                loopA: manager.customLoopStart,
                loopB: manager.customLoopEnd,
                currentTime: range.currentTime,
                duration: range.duration,
                sourceURL: context.videoURL,
                options: manager.selectedOptions
            )
        }
        .disabled(GIFExportManager.shared.compatibilityIssue(for: context.videoURL) != nil || GIFExportManager.shared.isExporting)
        Button("Lossless Trim…") {
            let manager = VideoLosslessTrimManager.shared
            let range = context.readPlaybackRange()
            manager.trimCurrentRange(
                trimStart: manager.customTrimStart,
                trimEnd: manager.customTrimEnd,
                currentTime: range.currentTime,
                duration: range.duration,
                sourceURL: context.videoURL
            )
        }
        .disabled(VideoLosslessTrimManager.shared.compatibilityIssue(for: context.videoURL) != nil || VideoLosslessTrimManager.shared.isTrimming)
        Button("Remux Container…") {
            let manager = MediaContainerRemuxManager.shared
            manager.remuxCurrentMedia(sourceURL: context.videoURL, options: manager.selectedOptions)
        }
        .disabled(MediaContainerRemuxManager.shared.compatibilityIssue(for: context.videoURL) != nil || MediaContainerRemuxManager.shared.isRemuxing)
        Button("Extract Audio…") {
            let manager = MediaAudioExtractManager.shared
            manager.extractCurrentAudio(sourceURL: context.videoURL, options: manager.selectedOptions)
        }
        .disabled(MediaAudioExtractManager.shared.compatibilityIssue(for: context.videoURL) != nil || MediaAudioExtractManager.shared.isExtracting)
        Divider()
        Button(MediaLocalization.text(context.isFullScreen ? .exitFullscreen : .fullscreen)) {
            context.playback.send(.toggleFullScreen)
        }
        Divider()
        Text(context.playback.formatSummary)
    }
}
