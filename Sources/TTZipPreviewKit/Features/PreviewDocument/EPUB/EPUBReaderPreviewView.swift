// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit
import TTZipUI

// MARK: - EPUB Reader Workspace

/// Product-owned EPUB reader workspace.
///
/// TTMediaKit owns the reading engine and renders the document surface. The workspace chrome
/// belongs to the host product, so the reader speaks TTZip's design language and drives the
/// session through TTMediaKit's public API.
///
/// Switching books is the host's job. The host gives this view a new identity per book —
/// `.id(bookModel.url.absoluteString)` — which rebuilds the workspace, creates a fresh session
/// and resets the panel state this view owns.
struct EPUBReaderPreviewView: View {
    @StateObject private var session: EPUBReaderSession

    @State private var isTypographyPresented = false
    @State private var isNotesPresented = false

    init(bookModel: EPUBBookModel) {
        _session = StateObject(wrappedValue: EPUBReaderSession(bookModel: bookModel))
    }

    var body: some View {
        EPUBReaderFloatingChromeView(
            session: session,
            isTypographyPresented: $isTypographyPresented,
            isNotesPresented: $isNotesPresented
        )
        .onChange(of: isTypographyPresented) { _, isPresented in
            session.notifyToolbarInteraction()
            if !isPresented {
                session.requestReaderFocusRestore()
            }
        }
    }
}
