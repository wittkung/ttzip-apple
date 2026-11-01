// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EPUBReaderNotesPanel: View {
    @ObservedObject var session: EPUBReaderAnnotationSession
    var save: (EPUBReaderAnnotation) -> Void
    var delete: (String) -> Void
    var locate: (EPUBReaderAnnotation) -> Void
    var export: (String) -> Void
    @State private var draftNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text(.notes)).font(.headline)
            if let selection = session.selection {
                Text(selection.quote).font(.callout).lineLimit(5).textSelection(.enabled)
                TextEditor(text: $draftNote).frame(minHeight: 70, maxHeight: 120)
                HStack {
                    Button(text(.saveNote)) {
                        var edited = selection
                        edited.note = draftNote
                        save(edited)
                    }
                    Button(text(.dictionary)) { lookup(selection.quote, web: false) }
                    Button(text(.webSearch)) { lookup(selection.quote, web: true) }
                }
            } else {
                Text(text(.noSelection)).font(.callout).foregroundStyle(.secondary)
            }
            if let error = session.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.annotations) { annotation in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(annotation.quote).lineLimit(3).font(.callout)
                            if !annotation.note.isEmpty { Text(annotation.note).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Button(text(.locate)) { locate(annotation) }
                                Button(text(.note)) { session.selection = annotation }
                                Spacer()
                                Button(text(.delete), role: .destructive) { delete(annotation.id) }
                            }
                        }
                        Divider()
                    }
                }
            }.frame(minHeight: 80, maxHeight: 260)
            HStack {
                Button(text(.exportJSON)) { export("json") }
                Button(text(.exportMarkdown)) { export("markdown") }
            }
        }
        .padding(16)
        .frame(width: 420)
        .onChange(of: session.selection) { _, selection in draftNote = selection?.note ?? "" }
        .onAppear { draftNote = session.selection?.note ?? "" }
    }

    private func text(_ key: EPUBReaderWorkspaceLocaleKey) -> String { EPUBReaderWorkspaceLocalization.text(key) }

    private func lookup(_ quote: String, web: Bool) {
        let query = String(quote.prefix(512))
        if web {
            var components = URLComponents(string: "https://duckduckgo.com/")
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
            if let url = components?.url { NSWorkspace.shared.open(url) }
        } else if let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "dict:///" + encoded) {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
enum EPUBReaderNoteExporter {
    static func save(contents: String, format: String) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format == "json" ? "Reading Notes.json" : "Reading Notes.md"
        panel.allowedContentTypes = format == "json" ? [.json] : [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
