// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Associates playback shortcuts with the real hosting window without taking first responder.
@MainActor
struct MediaKeyboardWindowAnchor: NSViewRepresentable {
    let sessionID: String
    var isPresenter = true

    func makeNSView(context: Context) -> MediaKeyboardAnchorView {
        MediaKeyboardAnchorView()
    }

    func updateNSView(_ view: MediaKeyboardAnchorView, context: Context) {
        view.sessionID = sessionID
        view.isPresenter = isPresenter
        view.bindWindow()
    }
}

@MainActor
final class MediaKeyboardAnchorView: NSView {
    var sessionID = ""
    var isPresenter = true
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bindWindow()
    }

    func bindWindow() {
        guard isPresenter, let window else { return }
        MediaPlaybackCoordinator.shared.bindWindow(id: sessionID, window: window)
    }
}
