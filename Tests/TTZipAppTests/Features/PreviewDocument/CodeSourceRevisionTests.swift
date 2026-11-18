// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit
import XCTest
@testable import TTZipPreviewKit

@MainActor
final class CodeSourceRevisionTests: XCTestCase {
    func testSourceMountReadsCurrentDiskRevisionAndPreservesBOMWhenSaving() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("page.html")
        let fallback = "<p>Detected A</p>\n"
        let current = "<p>Current B 中文</p>\n"
        let edited = "<p>Current B 中文 plus edit</p>\n"
        for bom in [Data(), Data([0xEF, 0xBB, 0xBF])] {
            try Data(fallback.utf8).write(to: url)
            let source = SourceMount(content: fallback, url: url, context: .diskFile(url: url))
            try (bom + Data(current.utf8)).write(to: url)
            let mounted = MountedSource(source)
            defer { mounted.close() }
            let editor = try await mounted.editor()
            XCTAssertEqual(editor.string, current, "Source must show the disk revision used as its save baseline")
            XCTAssertFalse(editor.isEditable)
            try await mounted.allowEditing()
            XCTAssertTrue(editor.isEditable)
            editor.insertText(edited, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            try await mounted.save()
            XCTAssertEqual(try Data(contentsOf: url), bom + Data(edited.utf8))
        }
    }

    func testSourceReentryReadsSavedDiskRevisionWithOriginalDetectorFallback() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("page.html")
        let initial = "<p>Original A</p>\n"
        let saved = "<p>Saved B</p>\n"
        try Data(initial.utf8).write(to: url)
        var source = SourceMount(content: initial, url: url, context: .diskFile(url: url))
        let mounted = MountedSource(source)
        defer { mounted.close() }
        let editor = try await mounted.editor()
        XCTAssertFalse(editor.isEditable)
        try await mounted.allowEditing()
        XCTAssertTrue(editor.isEditable)
        editor.insertText(saved, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await mounted.waitUntil { mounted.findSaveButton() != nil }
        let staleSaveButton = try XCTUnwrap(mounted.findSaveButton() as? TTZipCodeToolNSButton)
        let staleSaveAction = try XCTUnwrap(staleSaveButton.onAction)
        try await mounted.save()
        XCTAssertEqual(try Data(contentsOf: url), Data(saved.utf8))

        source.showsSource = false
        mounted.host.rootView = source
        try await mounted.waitUntil { mounted.find { $0 is NSTextView } == nil }
        source.showsSource = true
        mounted.host.rootView = source
        let reopened = try await mounted.editor()
        XCTAssertEqual(reopened.string, saved, "Reopening Source must not restore stale detector text")
        XCTAssertFalse(reopened.isEditable)
        try await mounted.allowEditing()
        XCTAssertTrue(reopened.isEditable)
        reopened.insertText("<p>Unsaved C</p>\n", replacementRange: NSRange(location: 0, length: reopened.string.utf16.count))
        XCTAssertTrue(staleSaveButton.sendAction(staleSaveButton.action, to: staleSaveButton.target))
        staleSaveAction()
        XCTAssertEqual(try Data(contentsOf: url), Data(saved.utf8), "Stale Save callback from prior session must not commit later session")
        XCTAssertFalse(mounted.window.isVisible)
    }

    func testDirtySessionKeepsItsSnapshotAcrossViewReinitialization() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("page.html")
        let initial = "<p>Original B</p>\n"
        let dirty = "<p>Unsaved edit of B</p>\n"
        let external = Data("<p>External C</p>\n".utf8)
        let initialBytes = Data(initial.utf8)
        try initialBytes.write(to: url)
        var source = SourceMount(content: initial, url: url, context: .diskFile(url: url))
        let mounted = MountedSource(source)
        defer { mounted.close() }
        let editor = try await mounted.editor()
        try await mounted.allowEditing()
        editor.insertText(dirty, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await mounted.waitUntil { mounted.findSaveButton() != nil }
        let staleSaveButton = try XCTUnwrap(mounted.findSaveButton() as? TTZipCodeToolNSButton)
        let staleSaveAction = try XCTUnwrap(staleSaveButton.onAction)

        source.content = "<p>Stale detector A after parent update</p>\n"
        source.context = .diskFile(url: url, fileName: url.lastPathComponent, allowsEditing: false)
        source.isImmersiveFullscreen = true
        source.revision = 1
        mounted.host.rootView = source
        try await mounted.waitUntil {
            mounted.find { $0.identifier?.rawValue == "SourceMount-1" } != nil && !editor.isEditable
        }
        try await mounted.waitUntil {
            mounted.findSaveButton() == nil && mounted.findAllowEditingButton() == nil
        }
        let rebuiltEditor = try await mounted.editor()
        XCTAssertTrue(rebuiltEditor === editor)
        XCTAssertEqual(editor.string, dirty)
        XCTAssertNotNil(
            mounted.find { ($0 as? NSButton)?.accessibilityIdentifier() == "CodeFloatingCopyButton" },
            "Dirty draft must retain floating controls visibility independently of current write eligibility"
        )
        _ = staleSaveButton.accessibilityPerformPress()
        XCTAssertTrue(staleSaveButton.sendAction(staleSaveButton.action, to: staleSaveButton.target))
        staleSaveAction()
        XCTAssertFalse(try mounted.sendCommandS(to: editor))
        try await Task.sleep(for: .milliseconds(20))
        mounted.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            try Data(contentsOf: url),
            initialBytes,
            "Stale Save callback must not overwrite unchanged disk baseline after write policy is revoked"
        )

        source.context = .diskFile(url: url)
        source.isImmersiveFullscreen = false
        source.revision = 2
        mounted.host.rootView = source
        try await mounted.waitUntil {
            mounted.find { $0.identifier?.rawValue == "SourceMount-2" } != nil
                && mounted.findAllowEditingButton() != nil
        }
        XCTAssertFalse(editor.isEditable)
        staleSaveAction()
        XCTAssertEqual(try Data(contentsOf: url), initialBytes)
        try await mounted.allowEditing()
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.string, dirty)
        try external.write(to: url, options: .atomic)
        try await mounted.save()
        XCTAssertEqual(try Data(contentsOf: url), external, "A recreated view must retain its original conflict baseline")
        XCTAssertEqual(editor.string, dirty)
    }

    func testUnavailableOversizeAndInvalidDiskSourcesStayReadOnly() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fallback = "<p>Old detector text</p>\n"
        let cases: [(String, Data?)] = [
            ("missing.html", nil),
            ("oversize.html", Data(repeating: 0x61, count: TTTextPreviewBytePolicy.maxInteractiveTextUTF8Bytes + 1)),
            ("invalid.html", Data(repeating: 0x61, count: 65536) + Data([0xFF]))
        ]
        for (name, bytes) in cases {
            let url = directory.appendingPathComponent(name)
            if let bytes { try bytes.write(to: url) }
            let mounted = MountedSource(SourceMount(content: fallback, url: url, context: .diskFile(url: url)))
            defer { mounted.close() }
            let editor = try await mounted.editor()
            XCTAssertFalse(editor.isEditable, "\(name) must not authorize saving a fallback")
            XCTAssertNil(mounted.findAllowEditingButton())
            XCTAssertNil(mounted.findSaveButton())
            if let bytes { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        }
    }

    func testArchiveAndSVGZKeepTheirReadOnlyFallbackRepresentation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fallback = "<svg><text>Decoded source</text></svg>"
        for name in ["entry.html", "entry.svgz"] {
            let url = directory.appendingPathComponent(name)
            let bytes = Data("Backing bytes must not replace the representation".utf8)
            try bytes.write(to: url)
            let context: TTPreviewResourceContext = name.hasSuffix("svgz")
                ? .diskFile(url: url)
                : .archiveEntry(archivePath: directory.appendingPathComponent("archive.zip").path,
                                entryPath: name, stagedReadURL: url)
            let mounted = MountedSource(SourceMount(content: fallback, url: url, context: context))
            defer { mounted.close() }
            let editor = try await mounted.editor()
            XCTAssertEqual(editor.string, fallback)
            XCTAssertFalse(editor.isEditable)
            XCTAssertNil(mounted.findAllowEditingButton())
            XCTAssertNil(mounted.findSaveButton())
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testArchiveSnapshotRetainsOriginalEncodingAndByteCount() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("entry.html")
        let fallback = "<p>Archived 中文</p>"
        let encoded = try XCTUnwrap(fallback.data(using: .utf16LittleEndian))
        let bytes = Data([0xFF, 0xFE]) + encoded
        try bytes.write(to: url)
        let context = TTPreviewResourceContext.archiveEntry(
            archivePath: directory.appendingPathComponent("archive.zip").path,
            entryPath: "entry.html", stagedReadURL: url
        )
        let snapshot = TTZipCodeSourceSnapshot.load(fallbackText: fallback, fileURL: url, context: context)
        XCTAssertEqual(snapshot.displayText, fallback)
        XCTAssertEqual(snapshot.inspection.byteCount, Int64(bytes.count))
        XCTAssertEqual(snapshot.inspection.encoding, .utf16LE)
        XCTAssertNil(snapshot.saveBaseline)
    }

    func testCleanSessionAcceptsUpdatedDetectorContentAtTheSameURL() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("page.html")
        let initial = "<p>Initial A</p>"
        let updated = "<p>New detector and disk B</p>"
        try Data(initial.utf8).write(to: url)
        var source = SourceMount(content: initial, url: url, context: .diskFile(url: url))
        let mounted = MountedSource(source)
        defer { mounted.close() }
        let initialEditor = try await mounted.editor()
        XCTAssertFalse(initialEditor.isEditable)
        let mountedAllowButton = try await mounted.waitForAllowEditingButton()
        let staleAllowButton = try XCTUnwrap(mountedAllowButton as? TTZipCodeToolNSButton)
        let staleAllowAction = try XCTUnwrap(staleAllowButton.onAction)
        try await mounted.allowEditing()
        XCTAssertTrue(initialEditor.isEditable)
        try Data(updated.utf8).write(to: url, options: .atomic)
        source.content = updated
        source.revision = 1
        mounted.host.rootView = source
        try await mounted.waitUntil {
            guard let textView = mounted.find({ $0 is NSTextView }) as? NSTextView else { return false }
            return textView.string == updated && !textView.isEditable
        }
        let editor = try await mounted.editor()
        XCTAssertEqual(editor.string, updated)
        XCTAssertFalse(editor.isEditable)
        _ = staleAllowButton.accessibilityPerformPress()
        XCTAssertTrue(staleAllowButton.sendAction(staleAllowButton.action, to: staleAllowButton.target))
        staleAllowAction()
        try await Task.sleep(for: .milliseconds(20))
        mounted.host.layoutSubtreeIfNeeded()
        XCTAssertFalse(editor.isEditable, "Stale Allow Editing action from prior revision at same path must not unlock new session")
        editor.insertText(initial, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(editor.string, updated)
        XCTAssertFalse(try mounted.sendCommandS(to: editor))
        try await mounted.allowEditing()
        XCTAssertTrue(editor.isEditable)
    }

    func testSRTReadModeExplicitAllowEditingSourceSwitchAndNegativeRoutes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let srtURL = directory.appendingPathComponent("dialogue.srt")
        let nextURL = directory.appendingPathComponent("next.srt")
        let initialSRT = "1\n00:00:01,000 --> 00:00:03,000\nFirst line\n"
        let savedSRT = "1\n00:00:01,000 --> 00:00:03,000\nEdited line\n"
        let unsavedSRT = "1\n00:00:01,000 --> 00:00:03,000\nUnsaved draft\n"
        let nextSRT = "1\n00:00:04,000 --> 00:00:06,000\nSecond file\n"
        try Data(initialSRT.utf8).write(to: srtURL)
        try Data(nextSRT.utf8).write(to: nextURL)

        var source = SourceMount(content: initialSRT, url: srtURL, context: .diskFile(url: srtURL), usesTextPreviewRoute: true)
        let mounted = MountedSource(source)
        defer { mounted.close() }
        let editor = try await mounted.editor()
        XCTAssertFalse(editor.isEditable)
        editor.insertText(savedSRT, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertFalse(try mounted.sendCommandS(to: editor))
        XCTAssertEqual(editor.string, initialSRT)
        XCTAssertNil(mounted.findSaveButton())

        let allowButton = try await mounted.waitForAllowEditingButton()
        XCTAssertFalse(allowButton.isTransparent)
        XCTAssertFalse(allowButton.isHidden)
        XCTAssertTrue(allowButton.acceptsFirstResponder)
        XCTAssertEqual(allowButton.accessibilityLabel(), TextAndDocumentPreviewLocalization.text(.allowEditingButton))
        XCTAssertTrue(allowButton.accessibilityPerformPress())
        try await mounted.waitUntil { editor.isEditable && mounted.findAllowEditingButton() == nil }
        XCTAssertEqual(try Data(contentsOf: srtURL), Data(initialSRT.utf8), "Allow Editing must not write to disk")

        editor.insertText(savedSRT, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await mounted.waitUntil { mounted.findSaveButton() != nil }
        XCTAssertTrue(try mounted.sendCommandS(to: editor))
        XCTAssertEqual(try Data(contentsOf: srtURL), Data(savedSRT.utf8))

        editor.insertText(unsavedSRT, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        source = SourceMount(
            content: nextSRT, url: nextURL, context: .diskFile(url: nextURL), usesTextPreviewRoute: true, revision: 1
        )
        mounted.host.rootView = source
        try await mounted.waitUntil { (mounted.find { $0 is NSTextView } as? NSTextView)?.string == nextSRT }
        let nextEditor = try await mounted.editor()
        XCTAssertFalse(nextEditor.isEditable, "Switching sources must reset to read mode without autosaving")
        XCTAssertNotNil(mounted.findAllowEditingButton())
        XCTAssertEqual(try Data(contentsOf: srtURL), Data(savedSRT.utf8))

        try await assertBlockedSRTRoutesStayReadOnly(srtURL: srtURL, content: savedSRT, directory: directory)
    }

    private func assertBlockedSRTRoutesStayReadOnly(srtURL: URL, content: String, directory: URL) async throws {
        let contexts: [TTPreviewResourceContext] = [
            .diskFile(url: srtURL, fileName: srtURL.lastPathComponent, allowsEditing: false),
            .archiveEntry(archivePath: directory.appendingPathComponent("subs.zip").path,
                          entryPath: "dialogue.srt", stagedReadURL: srtURL)
        ]
        for context in contexts {
            let mounted = MountedSource(SourceMount(content: content, url: srtURL, context: context, usesTextPreviewRoute: true))
            defer { mounted.close() }
            let editor = try await mounted.editor()
            XCTAssertFalse(editor.isEditable)
            XCTAssertNil(mounted.findAllowEditingButton())
            XCTAssertNil(mounted.findSaveButton())
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CodeSourceRevision-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct SourceMount: View {
    var content: String
    var url: URL
    var context: TTPreviewResourceContext
    var usesTextPreviewRoute = false
    var isImmersiveFullscreen = false
    var showsSource = true
    var revision = 0

    var body: some View {
        Group {
            if showsSource {
                if usesTextPreviewRoute {
                    MediaPreviewView(
                        previewType: .text(content),
                        fileName: url.lastPathComponent,
                        fileURL: url,
                        showsFloatingFullScreenButton: false,
                        resourceContext: context
                    )
                } else {
                    TTZipWebPreviewView(content: content, fileURL: url, fileName: url.lastPathComponent,
                                        resourceContext: context).sourceCodeEditor
                }
            } else {
                Color.clear
            }
        }
        .environment(\.isImmersiveFullscreen, isImmersiveFullscreen)
        .frame(width: 360, height: 260)
        .background(SourceMountMarker(revision: revision))
    }
}

private struct SourceMountMarker: NSViewRepresentable {
    let revision: Int

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier("SourceMount-\(revision)")
    }
}

@MainActor
private final class MountedSource {
    let host: NSHostingView<SourceMount>
    let window: NSWindow

    init(_ source: SourceMount) {
        host = NSHostingView(rootView: source)
        host.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
    }

    func close() {
        XCTAssertFalse(window.isVisible)
        window.contentView = nil
        window.close()
    }

    func editor() async throws -> NSTextView {
        try await waitUntil { find { $0 is NSTextView } != nil }
        return try XCTUnwrap(find { $0 is NSTextView } as? NSTextView)
    }

    func findAllowEditingButton() -> NSButton? {
        find { ($0 as? NSButton)?.accessibilityIdentifier() == "CodeFloatingAllowEditingButton" } as? NSButton
    }

    func waitForAllowEditingButton() async throws -> NSButton {
        try await waitUntil { findAllowEditingButton() != nil }
        return try XCTUnwrap(findAllowEditingButton())
    }

    func allowEditing() async throws {
        let button = try await waitForAllowEditingButton()
        XCTAssertTrue(button.accessibilityPerformPress())
        try await waitUntil { (find { $0 is NSTextView } as? NSTextView)?.isEditable == true }
    }

    func sendCommandS(to editor: NSTextView) throws -> Bool {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
        ))
        return editor.performKeyEquivalent(with: event)
    }

    func findSaveButton() -> NSButton? {
        find { ($0 as? NSButton)?.accessibilityIdentifier() == "CodeFloatingSaveButton" } as? NSButton
    }

    func save() async throws {
        try await waitUntil { findSaveButton() != nil }
        let button = try XCTUnwrap(findSaveButton())
        XCTAssertTrue(button.accessibilityPerformPress())
    }

    func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The hidden source editor did not reach the expected state")
    }

    func find(_ predicate: (NSView) -> Bool) -> NSView? {
        func visit(_ view: NSView) -> NSView? {
            if predicate(view) { return view }
            for child in view.subviews {
                if let match = visit(child) { return match }
            }
            return nil
        }
        return visit(host)
    }
}
