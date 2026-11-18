// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipAppComposition
import TTZipSearchKit
import XCTest

final class GlobalSearchOverlayCompositionTests: XCTestCase {
    @MainActor
    func testInstallBindsRoutesAndLifecycleActionsWithoutInvokingThem() throws {
        let panel = RecordingPanel()
        let result = GlobalSearchResultItem(id: "hit", title: "Hit", subtitle: "", hitType: .archiveEntry)
        var hotkey: (@MainActor () -> Void)?
        var termination: (@MainActor () -> Void)?
        var routedResult: GlobalSearchResultItem?
        var openedArchive: String?
        var selectedArchive: String?
        var selectedEntry: String?

        GlobalSearchOverlayComposition.install(
            panel: panel,
            content: EmptyView(),
            routeResult: { routedResult = $0 },
            openArchive: { openedArchive = $0 },
            selectEntry: { archive, entry in
                selectedArchive = archive
                selectedEntry = entry
            },
            registerHotkey: { action in
                panel.events.append("hotkey")
                hotkey = action
            },
            attachTermination: { action in
                panel.events.append("termination")
                termination = action
            }
        )

        XCTAssertEqual(panel.events, ["hosting", "result route", "archive route", "entry route", "hotkey", "termination"])
        let hosting = try XCTUnwrap(panel.contentView as? NSHostingView<EmptyView>)
        XCTAssertEqual(hosting.sizingOptions, [])
        XCTAssertNil(routedResult)
        XCTAssertNil(openedArchive)
        XCTAssertNil(selectedEntry)

        try XCTUnwrap(panel.onActivateItem)(result)
        try XCTUnwrap(panel.onOpenArchive)("/tmp/archive.zip")
        try XCTUnwrap(panel.onSelectEntry)("/tmp/archive.zip", "folder/entry.txt")
        XCTAssertEqual(routedResult, result)
        XCTAssertEqual(openedArchive, "/tmp/archive.zip")
        XCTAssertEqual(selectedArchive, "/tmp/archive.zip")
        XCTAssertEqual(selectedEntry, "folder/entry.txt")

        try XCTUnwrap(hotkey)()
        try XCTUnwrap(termination)()
        XCTAssertEqual(Array(panel.events.suffix(2)), ["toggle", "hide"])
    }
}

@MainActor
private final class RecordingPanel: GlobalSearchOverlayPanel {
    var events: [String] = []
    var contentView: NSView?
    var onActivateItem: ((GlobalSearchResultItem) -> Void)? {
        didSet { events.append("result route") }
    }
    var onOpenArchive: ((String) -> Void)? {
        didSet { events.append("archive route") }
    }
    var onSelectEntry: ((String, String) -> Void)? {
        didSet { events.append("entry route") }
    }

    func setWindowContentView(_ view: NSView) {
        contentView = view
        events.append("hosting")
    }

    func toggle() {
        events.append("toggle")
    }

    func hide() {
        events.append("hide")
    }
}
