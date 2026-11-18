// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit
import TTZipUI

@MainActor
final class AudioMiniPlayerPresenter: NSObject, NSWindowDelegate {
    static let shared = AudioMiniPlayerPresenter()

    private struct Presentation {
        let panel: AudioMiniPlayerPanel
        let parentCloseObserver: (any NSObjectProtocol)?
    }

    private var presentation: Presentation?
    private let showPanel: @MainActor (NSPanel) -> Void

    init(showPanel: @escaping @MainActor (NSPanel) -> Void = { $0.orderFrontRegardless() }) {
        self.showPanel = showPanel
    }

    func present(
        store: MPVAudioEngine,
        title: String,
        artist: String?,
        artwork: NSImage?,
        parentWindow: NSWindow?
    ) {
        dismiss()

        let panel = AudioMiniPlayerPanel()
        panel.delegate = self
        let content = CompactAudioMiniPlayerView(
            store: store,
            title: title,
            artist: artist,
            artwork: artwork,
            onRestore: { [weak self, weak panel] in
                guard let panel, self?.presentation?.panel === panel else { return }
                self?.dismiss()
            }
        )
        panel.host(content, relativeTo: parentWindow)

        let parentCloseObserver = parentWindow.map { parent in
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: parent,
                queue: .main
            ) { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    guard let panel, self?.presentation?.panel === panel else { return }
                    self?.dismiss()
                }
            }
        }
        presentation = Presentation(panel: panel, parentCloseObserver: parentCloseObserver)
        showPanel(panel)
    }

    func dismiss() {
        guard let presentation else { return }
        self.presentation = nil
        if let observer = presentation.parentCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        presentation.panel.delegate = nil
        presentation.panel.orderOut(nil)
        presentation.panel.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let panel = notification.object as? NSWindow, presentation?.panel === panel {
            dismiss()
        }
    }
}

private final class AudioMiniPlayerPanel: NSPanel {
    private static let size = CGSize(width: 380, height: 72)

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        minSize = Self.size
        maxSize = Self.size
        level = .floating
        isFloatingPanel = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func host(_ content: CompactAudioMiniPlayerView, relativeTo parentWindow: NSWindow?) {
        let screen = parentWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(
            x: visibleFrame.maxX - Self.size.width - TTZipTheme.Spacing.xl,
            y: visibleFrame.minY + TTZipTheme.Spacing.xl
        )
        setFrame(CGRect(origin: origin, size: Self.size), display: true)

        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.cornerRadius = TTZipTheme.Radius.lg
        host.layer?.masksToBounds = true
        contentView = host
    }
}
