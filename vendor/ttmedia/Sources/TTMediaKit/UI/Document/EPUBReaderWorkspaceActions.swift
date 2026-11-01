// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

extension InteractiveEPUBReaderView {
    var readerDocumentIdentity: String { stableDocumentIdentity ?? bookModel.url.absoluteString }
    var currentReaderAnchor: EPUBReaderAnchor {
        if !paginationController.isPaginationReady,
           case .preserveAnchor(let ratio, let block, let character) = paginationController.pendingLanding {
            return EPUBReaderAnchor(
                chapterIndex: UInt32(clamping: selectedChapterIndex), blockIndex: UInt32(clamping: block ?? 0),
                characterOffset: UInt32(clamping: character), chapterRatio: ratio
            )
        }
        return EPUBReaderAnchor(
            chapterIndex: UInt32(clamping: selectedChapterIndex),
            blockIndex: UInt32(clamping: paginationController.anchorBlockIndex ?? 0),
            characterOffset: UInt32(clamping: paginationController.anchorCharOffset),
            chapterRatio: paginationController.normalizedProgressInChapter
        )
    }

    var notesButton: some View {
        Button {
            annotationSession.errorMessage = nil
            annotationSession.onRequestSelection?()
            showNotes = true
        } label: {
            Image(systemName: "highlighter").frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.plain)
        .ttButtonHelp(EPUBReaderWorkspaceLocalization.text(.notes))
        .accessibilityLabel(EPUBReaderWorkspaceLocalization.text(.notes))
        .popover(isPresented: $showNotes) {
            EPUBReaderNotesPanel(
                session: annotationSession,
                save: saveReaderAnnotation,
                delete: deleteReaderAnnotation,
                locate: locateReaderAnnotation,
                export: exportReaderAnnotations
            )
        }
    }

    func restoreLegacyReaderPreferences() {
        let defaults = UserDefaults.standard
        fontFamily = defaults.string(forKey: "TTMedia_EPUB_FontFamily") ?? "serif"
        cjkFontFamily = defaults.string(forKey: "TTMedia_EPUB_CJKFontFamily") ?? "serif"
        fontSize = defaults.object(forKey: "TTMedia_EPUB_FontSize") as? Int ?? 17
        themeMode = defaults.string(forKey: "TTMedia_EPUB_ThemeMode") ?? "light"
        layoutMode = defaults.string(forKey: "TTMedia_EPUB_LayoutMode") ?? "paginated"
    }

    func restoreReaderWorkspace() {
        guard let readerPersistence else { return }
        do {
            if let hasStoredDocument = readerPersistence.hasStoredDocument,
               try !hasStoredDocument(readerDocumentIdentity) {
                let migratedAnchor = currentReaderAnchor
                try readerPersistence.savePosition(readerDocumentIdentity, migratedAnchor)
                progressCheckpoint.restore(identity: readerDocumentIdentity, anchor: migratedAnchor)
                persistReaderPreferences()
                return
            }
            let document = try readerPersistence.load(readerDocumentIdentity)
            annotationSession.annotations = document.annotations
            fontFamily = document.preferences.latinFont
            cjkFontFamily = document.preferences.cjkFont
            fontSize = Int(document.preferences.fontSize)
            themeMode = document.preferences.theme
            layoutMode = document.preferences.layout
            let anchor = document.position
            let index = Int(anchor.chapterIndex)
            guard bookModel.chapters.indices.contains(index) else { return }
            progressCheckpoint.restore(identity: readerDocumentIdentity, anchor: anchor)
            selectedChapterIndex = index
            paginationController.restoreReadingPosition(chapterIndex: index, landing: .preserveAnchor(
                progressRatio: anchor.chapterRatio,
                anchorBlockIndex: Int(anchor.blockIndex), anchorCharOffset: Int(anchor.characterOffset)
            ))
        } catch { annotationSession.errorMessage = error.localizedDescription }
    }

    func persistReaderPreferences() {
        guard let readerPersistence else { return }
        let preferences = EPUBReaderPreferences(
            latinFont: fontFamily, cjkFont: cjkFontFamily, fontSize: UInt32(clamping: fontSize),
            theme: themeMode, layout: layoutMode
        )
        do { try readerPersistence.savePreferences(readerDocumentIdentity, preferences) }
        catch { annotationSession.errorMessage = error.localizedDescription }
    }

    func saveReaderAnnotation(_ annotation: EPUBReaderAnnotation) {
        guard let readerPersistence else {
            annotationSession.errorMessage = EPUBReaderWorkspaceLocalization.text(.unavailable)
            return
        }
        do {
            let saved = try readerPersistence.upsertAnnotation(readerDocumentIdentity, annotation)
            annotationSession.selection = saved
            try refreshReaderAnnotations()
            NotificationCenter.default.post(name: .epubReaderAnnotationsChanged, object: readerDocumentIdentity)
        } catch { annotationSession.errorMessage = error.localizedDescription }
    }

    func deleteReaderAnnotation(_ id: String) {
        guard let readerPersistence else { return }
        do {
            try readerPersistence.deleteAnnotation(readerDocumentIdentity, id)
            if annotationSession.selection?.id == id { annotationSession.selection = nil }
            try refreshReaderAnnotations()
            NotificationCenter.default.post(name: .epubReaderAnnotationsChanged, object: readerDocumentIdentity)
        } catch { annotationSession.errorMessage = error.localizedDescription }
    }

    func refreshReaderAnnotations() throws {
        guard let readerPersistence else { return }
        annotationSession.annotations = try readerPersistence.load(readerDocumentIdentity).annotations
        annotationSession.onRequestHighlightRefresh?(annotationSession.annotations)
    }

    func locateReaderAnnotation(_ annotation: EPUBReaderAnnotation) {
        let anchor = annotation.anchor
        let index = Int(anchor.chapterIndex)
        guard bookModel.chapters.indices.contains(index) else { return }
        showNotes = false
        selectedChapterIndex = index
        paginationController.navigateToAnchor(
            chapterIndex: index, blockIndex: Int(anchor.blockIndex),
            characterOffset: Int(anchor.characterOffset), ratio: anchor.chapterRatio
        )
        paginationController.onRequestRestoreReaderFocus?()
    }

    func exportReaderAnnotations(_ format: String) {
        guard let readerPersistence else { return }
        do {
            let contents = try readerPersistence.exportAnnotations(readerDocumentIdentity, format)
            try EPUBReaderNoteExporter.save(contents: contents, format: format)
        } catch { annotationSession.errorMessage = error.localizedDescription }
    }
}
