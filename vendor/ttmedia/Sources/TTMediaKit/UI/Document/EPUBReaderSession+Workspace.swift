// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

// MARK: - Host-Injected Persistence & Annotation Operations

extension EPUBReaderSession {

    // MARK: Workspace restoration

    /// Restores the annotations, preferences and reading position from the host document.
    ///
    /// Module internal: the restore is part of the session's load sequence. Restoring the
    /// stored values neither persists nor reaches the engine — the caller applies the
    /// final layout once the whole restore has settled. The migration branch below is
    /// the exception: it seeds a document that does not exist yet, so it writes the
    /// current preferences out.
    func restoreReaderWorkspace() {
        guard let persistence else { return }
        do {
            if let hasStoredDocument = persistence.hasStoredDocument,
               try !hasStoredDocument(readerDocumentIdentity) {
                let migratedAnchor = currentReaderAnchor
                try persistence.savePosition(readerDocumentIdentity, migratedAnchor)
                progressCheckpoint.restore(identity: readerDocumentIdentity, anchor: migratedAnchor)
                persistReaderPreferences()
                return
            }
            let document = try persistence.load(readerDocumentIdentity)
            annotationSession.annotations = document.annotations
            // The host document holds the authoritative preferences. Restoring them
            // assigns every field in turn, and the host persists the whole set on
            // each write, so the assignments are suspended: a write in between
            // would store a mix of restored and previous values.
            withPreferenceWritesSuspended {
                fontFamily = document.preferences.latinFont
                cjkFontFamily = document.preferences.cjkFont
                fontSize = Int(document.preferences.fontSize)
                themeMode = document.preferences.theme
                layoutMode = document.preferences.layout
            }
            // No write follows the restore: the values just applied are the ones the
            // host document already stores, so writing them back would only repeat
            // the same snapshot.
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

    /// Writes the current preference set to the host persistence contract.
    ///
    /// Module internal: the public setters own the write path, so a host cannot bypass
    /// the pending-write and restore guards by calling this directly.
    func persistReaderPreferences() {
        guard let persistence else { return }
        let preferences = EPUBReaderPreferences(
            latinFont: fontFamily, cjkFont: cjkFontFamily, fontSize: UInt32(clamping: fontSize),
            theme: themeMode, layout: layoutMode
        )
        do { try persistence.savePreferences(readerDocumentIdentity, preferences) }
        catch { annotationSession.errorMessage = error.localizedDescription }
    }

    // MARK: Annotations

    public func saveReaderAnnotation(_ annotation: EPUBReaderAnnotation) {
        guard let persistence else {
            annotationSession.errorMessage = EPUBReaderWorkspaceLocalization.text(.unavailable)
            return
        }
        do {
            let saved = try persistence.upsertAnnotation(readerDocumentIdentity, annotation)
            annotationSession.selection = saved
            try refreshReaderAnnotations()
            NotificationCenter.default.post(name: .epubReaderAnnotationsChanged, object: readerDocumentIdentity)
        } catch { annotationSession.errorMessage = error.localizedDescription }
    }

    public func deleteReaderAnnotation(_ id: String) {
        guard let persistence else { return }
        do {
            try persistence.deleteAnnotation(readerDocumentIdentity, id)
            if annotationSession.selection?.id == id { annotationSession.selection = nil }
            try refreshReaderAnnotations()
            NotificationCenter.default.post(name: .epubReaderAnnotationsChanged, object: readerDocumentIdentity)
        } catch { annotationSession.errorMessage = error.localizedDescription }
    }

    public func refreshReaderAnnotations() throws {
        guard let persistence else { return }
        annotationSession.annotations = try persistence.load(readerDocumentIdentity).annotations
        annotationSession.onRequestHighlightRefresh?(annotationSession.annotations)
    }

    public func locateReaderAnnotation(_ annotation: EPUBReaderAnnotation) {
        guard persistence != nil else { return }
        let anchor = annotation.anchor
        let index = Int(anchor.chapterIndex)
        guard bookModel.chapters.indices.contains(index) else { return }
        selectedChapterIndex = index
        paginationController.navigateToAnchor(
            chapterIndex: index, blockIndex: Int(anchor.blockIndex),
            characterOffset: Int(anchor.characterOffset), ratio: anchor.chapterRatio
        )
        paginationController.onRequestRestoreReaderFocus?()
    }

    /// Returns the exported annotation payload. The host owns writing it to disk.
    public func exportReaderAnnotations(format: String) throws -> String? {
        guard let persistence else { return nil }
        do {
            return try persistence.exportAnnotations(readerDocumentIdentity, format)
        } catch {
            annotationSession.errorMessage = error.localizedDescription
            return nil
        }
    }
}
