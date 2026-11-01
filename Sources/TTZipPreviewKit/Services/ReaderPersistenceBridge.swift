// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaKit
import TTZipAppCore
import TTZipUI

/// Owns one Rust library so independent reader windows serialize mutations through the same core.
@MainActor
public final class ReaderPersistenceBridge {
    public static let shared: Result<ReaderPersistenceBridge, Error> = Result {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask, appropriateFor: nil, create: true)
        return try ReaderPersistenceBridge(directory: base.appendingPathComponent("com.metastudyline.ttzip/Reader"))
    }
    private let library: ReaderLibrary

    public init(directory: URL) throws {
        library = try ReaderLibrary(directory: directory.path)
    }

    public var adapter: EPUBReaderPersistence {
        EPUBReaderPersistence(
            load: { [library] identity in Self.present(try library.loadDocument(identity: identity)) },
            hasStoredDocument: { [library] identity in try library.hasDocument(identity: identity) },
            savePosition: { [library] identity, position in
                try library.savePosition(identity: identity, position: Self.core(position))
            },
            savePreferences: { [library] identity, preferences in
                try library.savePreferences(identity: identity, preferences: Self.core(preferences))
            },
            upsertAnnotation: { [library] identity, annotation in
                Self.present(try library.upsertAnnotation(identity: identity, annotation: Self.core(annotation)))
            },
            deleteAnnotation: { [library] identity, id in
                try library.deleteAnnotation(identity: identity, annotationId: id)
            },
            exportAnnotations: { [library] identity, format in
                try library.exportAnnotations(identity: identity, format: format)
            }
        )
    }

    /// Keep storage errors observable in the reader instead of silently switching to a second store.
    public static var applicationAdapter: EPUBReaderPersistence {
        switch shared {
        case .success(let bridge): return bridge.adapter
        case .failure(let error):
            return EPUBReaderPersistence(
                load: { _ in throw error }, hasStoredDocument: { _ in throw error },
                savePosition: { _, _ in throw error }, savePreferences: { _, _ in throw error },
                upsertAnnotation: { _, _ in throw error }, deleteAnnotation: { _, _ in throw error },
                exportAnnotations: { _, _ in throw error }
            )
        }
    }

    public static var unidentifiedSourceAdapter: EPUBReaderPersistence {
        let message = AppLocalizationState.shared.uiString(
            zh: "无法确认原始文件，阅读进度和笔记暂不能保存。",
            en: "The original file cannot be identified. Reading progress and notes cannot be saved.")
        let error = NSError(domain: "TTZip.ReaderIdentity", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: message])
        return EPUBReaderPersistence(
            load: { _ in throw error }, hasStoredDocument: { _ in throw error },
            savePosition: { _, _ in throw error }, savePreferences: { _, _ in throw error },
            upsertAnnotation: { _, _ in throw error }, deleteAnnotation: { _, _ in throw error },
            exportAnnotations: { _, _ in throw error }
        )
    }

    private static func core(_ value: EPUBReaderAnchor) -> ReaderAnchor {
        ReaderAnchor(chapterIndex: value.chapterIndex, blockIndex: value.blockIndex,
                     characterOffset: value.characterOffset, chapterRatio: value.chapterRatio)
    }

    private static func core(_ value: EPUBReaderPreferences) -> ReaderPreferences {
        ReaderPreferences(latinFont: value.latinFont, cjkFont: value.cjkFont, fontSize: value.fontSize,
                          theme: value.theme, layout: value.layout)
    }

    private static func core(_ value: EPUBReaderAnnotation) -> ReaderAnnotation {
        ReaderAnnotation(id: value.id, anchor: core(value.anchor), quote: value.quote,
                         note: value.note, color: value.color)
    }

    private static func present(_ value: ReaderAnchor) -> EPUBReaderAnchor {
        EPUBReaderAnchor(chapterIndex: value.chapterIndex, blockIndex: value.blockIndex,
                         characterOffset: value.characterOffset, chapterRatio: value.chapterRatio)
    }

    private static func present(_ value: ReaderAnnotation) -> EPUBReaderAnnotation {
        EPUBReaderAnnotation(id: value.id, anchor: present(value.anchor), quote: value.quote,
                             note: value.note, color: value.color)
    }

    private static func present(_ value: ReaderDocument) -> EPUBReaderDocument {
        let preferences = value.preferences
        return EPUBReaderDocument(identity: value.identity, position: present(value.position),
            preferences: EPUBReaderPreferences(latinFont: preferences.latinFont, cjkFont: preferences.cjkFont,
                fontSize: preferences.fontSize, theme: preferences.theme, layout: preferences.layout),
            annotations: value.annotations.map(present))
    }
}
