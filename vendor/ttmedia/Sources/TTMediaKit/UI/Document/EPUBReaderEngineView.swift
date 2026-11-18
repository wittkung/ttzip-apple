// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

// MARK: - EPUB Document Surface

/// Renders the EPUB document surface for a reading session.
///
/// This view is the engine half of the reader workspace: it owns the WKWebView page layer,
/// the pagination bridge and the reading lifecycle. The workspace chrome around it — toolbar,
/// typography panel, notes panel — belongs to the host product, which observes the session
/// and renders its own controls.
///
/// Switching books is not this view's job. The session's book identity is immutable, so
/// there is no identity change to observe here; the host switches books by giving SwiftUI
/// a new identity for the workspace — `.id(bookModel.url.absoluteString)` — which builds a
/// fresh session and a fresh document surface.
public struct EPUBReaderEngineView<ChapterContent: View, EmptyChapter: View>: View {
    @ObservedObject private var session: EPUBReaderSession
    @ObservedObject private var paginationController: EPUBPaginationController
    private let appearance: EPUBReaderAppearance
    private let presentChapter: (EPUBNativeWKWebView) -> ChapterContent
    private let emptyChapter: () -> EmptyChapter

    @Environment(\.epubReaderDocumentIdentity) private var stableDocumentIdentity
    @Environment(\.epubReaderPersistence) private var readerPersistence

    public init(
        session: EPUBReaderSession,
        appearance: EPUBReaderAppearance = .neutral,
        @ViewBuilder presentChapter: @escaping (EPUBNativeWKWebView) -> ChapterContent,
        @ViewBuilder emptyChapter: @escaping () -> EmptyChapter
    ) {
        self.session = session
        self._paginationController = ObservedObject(wrappedValue: session.paginationController)
        self.appearance = appearance
        self.presentChapter = presentChapter
        self.emptyChapter = emptyChapter
    }

    public var body: some View {
        Group {
            if session.bookModel.chapters.indices.contains(session.selectedChapterIndex) {
                let chapter = EPUBNativeWKWebView(
                    chapterURL: session.bookModel.chapters[session.selectedChapterIndex].fileURL,
                    baseDirectory: session.bookModel.extractDir,
                    fontSize: Double(session.fontSize),
                    fontStyle: session.fontFamily + "|" + session.cjkFontFamily,
                    readerTheme: session.themeMode,
                    chapterIndex: session.selectedChapterIndex,
                    chapters: session.bookModel.chapters,
                    paginationController: session.paginationController,
                    onNavigateToChapterURL: { targetURL in
                        _ = session.selectChapter(matching: targetURL)
                    },
                    layoutMode: session.layoutMode,
                    annotationSession: session.annotationSession,
                    appearance: appearance
                )
                presentChapter(chapter)
            } else {
                emptyChapter()
            }
        }
        .background(EPUBReaderFocusRegionBackground(instanceID: session.paginationController.instanceID))
        .onAppear {
            bindHostContracts()
            session.prepareForReading()
        }
        .onDisappear {
            session.persistReadingProgress()
        }
        .task(id: session.taskIdentityKey) {
            bindHostContracts()
            session.loadEPUBPackage()
        }
        .onChange(of: paginationController.isPaginationReady) { _, isReady in
            if isReady { session.persistReadingProgress() }
        }
        .onChange(of: paginationController.currentPageIndex) { _, _ in
            session.persistReadingProgress()
        }
        .onChange(of: paginationController.anchorBlockIndex) { _, _ in
            session.persistReadingProgress()
        }
        .onChange(of: paginationController.anchorCharOffset) { _, _ in
            session.persistReadingProgress()
        }
        .onReceive(NotificationCenter.default.publisher(for: .epubReaderAnnotationsChanged)) { notification in
            guard notification.object as? String == session.readerDocumentIdentity else { return }
            do { try session.refreshReaderAnnotations() }
            catch { session.annotationSession.errorMessage = error.localizedDescription }
        }
    }

    /// Hands the host-injected persistence contracts to the session.
    private func bindHostContracts() {
        session.persistence = readerPersistence
        session.documentIdentity = stableDocumentIdentity
    }
}
