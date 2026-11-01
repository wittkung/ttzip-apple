// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Combine
import SwiftUI

public struct EPUBReaderAnchor: Codable, Equatable, Sendable {
    public var chapterIndex: UInt32
    public var blockIndex: UInt32
    public var characterOffset: UInt32
    public var chapterRatio: Double
    public init(chapterIndex: UInt32, blockIndex: UInt32, characterOffset: UInt32, chapterRatio: Double) {
        self.chapterIndex = chapterIndex
        self.blockIndex = blockIndex
        self.characterOffset = characterOffset
        self.chapterRatio = chapterRatio
    }
}

public struct EPUBReaderPreferences: Codable, Equatable, Sendable {
    public var latinFont: String
    public var cjkFont: String
    public var fontSize: UInt32
    public var theme: String
    public var layout: String
    public init(latinFont: String, cjkFont: String, fontSize: UInt32, theme: String, layout: String) {
        self.latinFont = latinFont; self.cjkFont = cjkFont
        self.fontSize = fontSize; self.theme = theme; self.layout = layout
    }
}

public struct EPUBReaderAnnotation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var anchor: EPUBReaderAnchor
    public var quote: String
    public var note: String
    public var color: String
    public init(id: String = "", anchor: EPUBReaderAnchor, quote: String, note: String = "", color: String = "yellow") {
        self.id = id; self.anchor = anchor; self.quote = quote; self.note = note; self.color = color
    }
}

public struct EPUBReaderDocument: Codable, Sendable {
    public var identity: String
    public var position: EPUBReaderAnchor
    public var preferences: EPUBReaderPreferences
    public var annotations: [EPUBReaderAnnotation]
    public init(identity: String, position: EPUBReaderAnchor, preferences: EPUBReaderPreferences, annotations: [EPUBReaderAnnotation]) {
        self.identity = identity; self.position = position
        self.preferences = preferences; self.annotations = annotations
    }
}

/// The product injects UniFFI calls. TTMediaKit owns no duplicate annotation database.
@MainActor
public struct EPUBReaderPersistence {
    public var hasStoredDocument: ((String) throws -> Bool)?
    public var load: (String) throws -> EPUBReaderDocument
    public var savePosition: (String, EPUBReaderAnchor) throws -> Void
    public var savePreferences: (String, EPUBReaderPreferences) throws -> Void
    public var upsertAnnotation: (String, EPUBReaderAnnotation) throws -> EPUBReaderAnnotation
    public var deleteAnnotation: (String, String) throws -> Void
    public var exportAnnotations: (String, String) throws -> String

    public init(
        load: @escaping (String) throws -> EPUBReaderDocument,
        hasStoredDocument: ((String) throws -> Bool)? = nil,
        savePosition: @escaping (String, EPUBReaderAnchor) throws -> Void,
        savePreferences: @escaping (String, EPUBReaderPreferences) throws -> Void,
        upsertAnnotation: @escaping (String, EPUBReaderAnnotation) throws -> EPUBReaderAnnotation,
        deleteAnnotation: @escaping (String, String) throws -> Void,
        exportAnnotations: @escaping (String, String) throws -> String
    ) {
        self.hasStoredDocument = hasStoredDocument
        self.load = load; self.savePosition = savePosition; self.savePreferences = savePreferences
        self.upsertAnnotation = upsertAnnotation; self.deleteAnnotation = deleteAnnotation
        self.exportAnnotations = exportAnnotations
    }
}

extension Notification.Name {
    static let epubReaderAnnotationsChanged = Notification.Name("TTMedia.EPUB.AnnotationsChanged")
}

private struct EPUBReaderDocumentIdentityKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct EPUBReaderPersistenceKey: EnvironmentKey {
    static let defaultValue: EPUBReaderPersistence? = nil
}

extension EnvironmentValues {
    public var epubReaderDocumentIdentity: String? {
        get { self[EPUBReaderDocumentIdentityKey.self] }
        set { self[EPUBReaderDocumentIdentityKey.self] = newValue }
    }
    public var epubReaderPersistence: EPUBReaderPersistence? {
        get { self[EPUBReaderPersistenceKey.self] }
        set { self[EPUBReaderPersistenceKey.self] = newValue }
    }
}

@MainActor
public final class EPUBReaderAnnotationSession: ObservableObject {
    @Published public var annotations: [EPUBReaderAnnotation] = []
    @Published public var selection: EPUBReaderAnnotation?
    @Published public var errorMessage: String?
    public var onRequestSelection: (() -> Void)?
    public var onRequestHighlightRefresh: (([EPUBReaderAnnotation]) -> Void)?
}
