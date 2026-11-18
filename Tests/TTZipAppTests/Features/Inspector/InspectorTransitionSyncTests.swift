// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipBenchmarkKit
import TTZipCore
import TTZipPreviewKit
import TTZipUI
import XCTest
@testable import TTZipApp

extension DesignSystemLayoutAlignmentTests {
    @MainActor
    func testAnimatedInspectorExpandCollapseExpandSynchronizesImmediatelyWithoutOverlapOrTruncation() async throws {
        let enhancedUISelector = NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:")
        if NSApplication.shared.responds(to: enhancedUISelector) {
            _ = NSApplication.shared.perform(enhancedUISelector, with: NSNumber(value: true))
        }

        let savedRatio = UserDefaults.standard.object(forKey: "TTZip_UserRightInspectorRatio")
        UserDefaults.standard.set(
            Double(MainLayoutMetrics.defaultRightInspectorRatio),
            forKey: "TTZip_UserRightInspectorRatio"
        )
        defer {
            if let savedRatio {
                UserDefaults.standard.set(savedRatio, forKey: "TTZip_UserRightInspectorRatio")
            } else {
                UserDefaults.standard.removeObject(forKey: "TTZip_UserRightInspectorRatio")
            }
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-inspector-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let longFileNames = [
            "preview_rendering_candidate_archive_2026.png",
            "release_bundle_manifest_configuration.json"
        ]
        for name in longFileNames {
            let fileURL = tempRoot.appendingPathComponent(name, isDirectory: false)
            try Data("inspector transition sync fixture".utf8).write(to: fileURL)
        }

        let harness = makeMountedWindowHarness(
            frame: NSRect(x: 160, y: 180, width: 1080, height: 720),
            initialDirectory: tempRoot
        )
        defer { harness.cleanup() }

        let firstFileURL = tempRoot.appendingPathComponent(longFileNames[0], isDirectory: false)
        harness.viewModel.selectionState.select(DiskItemInfo(url: firstFileURL))
        await waitForMillerColumnFilenames(longFileNames, in: harness)

        let baselineWindowFrame = harness.window.frame
        let baselineCenterWidth = harness.coordinator.lastLiveCenterWidth
        let baselineRightWidth = harness.coordinator.lastLiveRightPaneWidth
        let expectedFootprint = baselineRightWidth + ResizableDividerHandle.gutterWidth

        XCTAssertEqual(baselineCenterWidth, 576.0, accuracy: 0.5)
        XCTAssertEqual(measuredCenterWorkspaceFrame(in: harness.hostingView)?.width ?? -1, 576.0, accuracy: 1.0)
        assertExpandedColumnSeparationAndBaselineStrings(
            in: harness,
            expectedFilenames: longFileNames
        )
        runAnimatedExpandCollapseCycles(
            in: harness,
            baselineWindowFrame: baselineWindowFrame,
            baselineCenterWidth: baselineCenterWidth,
            expectedFootprint: expectedFootprint,
            expectedFilenames: longFileNames
        )
    }

    @MainActor
    private func runAnimatedExpandCollapseCycles(
        in harness: MountedWindowHarness,
        baselineWindowFrame: NSRect,
        baselineCenterWidth: CGFloat,
        expectedFootprint: CGFloat,
        expectedFilenames: [String]
    ) {
        let collapseOutcome = harness.viewModel.toggleInspector(animated: true)
        XCTAssertFalse(harness.viewModel.navigationState.isInspectorVisible)
        XCTAssertEqual(collapseOutcome.disposition, .resizedKeepingLeftEdge)
        XCTAssertEqual(
            collapseOutcome.totalRightFootprint,
            expectedFootprint,
            accuracy: 0.5,
            "Collapse outcome must report rightPaneWidth + dividerGutterWidth"
        )
        assertCollapsedStepInvariants(
            in: harness,
            expectedMinX: baselineWindowFrame.minX,
            expectedWindowWidth: baselineWindowFrame.width - expectedFootprint,
            expectedCenterWidth: baselineCenterWidth,
            expectedFilenames: expectedFilenames
        )

        let expandOutcome = harness.viewModel.toggleInspector(animated: true)
        XCTAssertTrue(harness.viewModel.navigationState.isInspectorVisible)
        XCTAssertEqual(expandOutcome.disposition, .resizedKeepingLeftEdge)
        XCTAssertEqual(expandOutcome.totalRightFootprint, expectedFootprint, accuracy: 0.5)
        assertExpandedStepInvariants(
            in: harness,
            expectedMinX: baselineWindowFrame.minX,
            expectedWindowWidth: baselineWindowFrame.width,
            expectedCenterWidth: baselineCenterWidth,
            expectedFilenames: expectedFilenames
        )

        let secondCollapse = harness.viewModel.setInspectorVisible(false, animated: true)
        XCTAssertFalse(harness.viewModel.navigationState.isInspectorVisible)
        XCTAssertEqual(secondCollapse.disposition, .resizedKeepingLeftEdge)
        assertCollapsedStepInvariants(
            in: harness,
            expectedMinX: baselineWindowFrame.minX,
            expectedWindowWidth: baselineWindowFrame.width - expectedFootprint,
            expectedCenterWidth: baselineCenterWidth,
            expectedFilenames: expectedFilenames
        )

        let secondExpand = harness.viewModel.setInspectorVisible(true, animated: true)
        XCTAssertTrue(harness.viewModel.navigationState.isInspectorVisible)
        XCTAssertEqual(secondExpand.disposition, .resizedKeepingLeftEdge)
        assertExpandedStepInvariants(
            in: harness,
            expectedMinX: baselineWindowFrame.minX,
            expectedWindowWidth: baselineWindowFrame.width,
            expectedCenterWidth: baselineCenterWidth,
            expectedFilenames: expectedFilenames
        )
    }

    @MainActor
    private func waitForMillerColumnFilenames(
        _ filenames: [String],
        in harness: MountedWindowHarness
    ) async {
        for _ in 0..<50 {
            harness.window.contentView?.needsLayout = true
            harness.window.contentView?.layoutSubtreeIfNeeded()
            harness.window.displayIfNeeded()
            let rendered = collectRenderedMillerColumnStrings(in: harness.hostingView)
            if filenames.allSatisfy({ target in rendered.contains(where: { $0.contains(target) }) }) {
                return
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    @MainActor
    private func assertCollapsedStepInvariants(
        in harness: MountedWindowHarness,
        expectedMinX: CGFloat,
        expectedWindowWidth: CGFloat,
        expectedCenterWidth: CGFloat,
        expectedFilenames: [String]
    ) {
        for pass in 1...6 {
            harness.window.contentView?.needsLayout = true
            harness.window.contentView?.layoutSubtreeIfNeeded()
            harness.window.displayIfNeeded()
            if pass > 1 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.015))
            }

            XCTAssertEqual(
                harness.window.frame.minX,
                expectedMinX,
                accuracy: 0.01,
                "Pass \(pass): window.frame.minX must remain stationary on animated collapse"
            )
            XCTAssertEqual(
                harness.window.frame.width,
                expectedWindowWidth,
                accuracy: 0.5,
                "Pass \(pass): window.frame.width must shrink synchronously by rightPaneWidth + dividerGutterWidth"
            )
            XCTAssertEqual(
                harness.coordinator.lastLiveCenterWidth,
                expectedCenterWidth,
                accuracy: 0.5,
                "Pass \(pass): coordinator.lastLiveCenterWidth must stay invariant at 576pt"
            )
            XCTAssertEqual(
                measuredCenterWorkspaceFrame(in: harness.hostingView)?.width ?? -1,
                expectedCenterWidth,
                accuracy: 1.0,
                "Pass \(pass): measuredCenterWorkspaceFrame width must stay invariant at 576pt"
            )
            XCTAssertNil(
                accessibilityFrameInWindow(id: "MainRightInspectorColumn", in: harness.hostingView, window: harness.window),
                "Pass \(pass): MainRightInspectorColumn must be immediately absent on collapse without lingering transition"
            )
            assertNoFilenameTruncation(in: harness.hostingView, expectedFilenames: expectedFilenames, passLabel: "collapse pass \(pass)")
        }
    }

    @MainActor
    private func assertExpandedStepInvariants(
        in harness: MountedWindowHarness,
        expectedMinX: CGFloat,
        expectedWindowWidth: CGFloat,
        expectedCenterWidth: CGFloat,
        expectedFilenames: [String]
    ) {
        for pass in 1...6 {
            harness.window.contentView?.needsLayout = true
            harness.window.contentView?.layoutSubtreeIfNeeded()
            harness.window.displayIfNeeded()
            if pass > 1 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.015))
            }

            XCTAssertEqual(
                harness.window.frame.minX,
                expectedMinX,
                accuracy: 0.01,
                "Pass \(pass): window.frame.minX must remain stationary on animated expand"
            )
            XCTAssertEqual(
                harness.window.frame.width,
                expectedWindowWidth,
                accuracy: 0.5,
                "Pass \(pass): window.frame.width must expand synchronously by rightPaneWidth + dividerGutterWidth"
            )
            XCTAssertEqual(
                harness.coordinator.lastLiveCenterWidth,
                expectedCenterWidth,
                accuracy: 0.5,
                "Pass \(pass): coordinator.lastLiveCenterWidth must stay invariant at 576pt"
            )
            let centerFrame = measuredCenterWorkspaceFrame(in: harness.hostingView)
            XCTAssertEqual(
                centerFrame?.width ?? -1,
                expectedCenterWidth,
                accuracy: 1.0,
                "Pass \(pass): measuredCenterWorkspaceFrame width must stay invariant at 576pt"
            )
            if let centerFrame,
               let inspectorFrame = accessibilityFrameInWindow(
                   id: "MainRightInspectorColumn",
                   in: harness.hostingView,
                   window: harness.window
               ) {
                XCTAssertLessThanOrEqual(
                    centerFrame.maxX,
                    inspectorFrame.minX + 1.0,
                    "Pass \(pass): centerFrame.maxX (\(centerFrame.maxX)) must not overlap inspectorFrame.minX (\(inspectorFrame.minX))"
                )
            } else {
                XCTFail("Pass \(pass): MainRightInspectorColumn and centerFrame must be present when expanded")
            }
            assertNoFilenameTruncation(in: harness.hostingView, expectedFilenames: expectedFilenames, passLabel: "expand pass \(pass)")
        }
    }

    @MainActor
    private func assertExpandedColumnSeparationAndBaselineStrings(
        in harness: MountedWindowHarness,
        expectedFilenames: [String]
    ) {
        let centerFrame = measuredCenterWorkspaceFrame(in: harness.hostingView)
        let inspectorFrame = accessibilityFrameInWindow(
            id: "MainRightInspectorColumn",
            in: harness.hostingView,
            window: harness.window
        )
        XCTAssertNotNil(centerFrame, "Mounted center workspace frame must be measurable")
        XCTAssertNotNil(inspectorFrame, "MainRightInspectorColumn must be present when expanded")
        if let centerFrame, let inspectorFrame {
            XCTAssertLessThanOrEqual(
                centerFrame.maxX,
                inspectorFrame.minX + 1.0,
                "Expanded baseline must have zero column overlap between center workspace and inspector"
            )
        }
        assertNoFilenameTruncation(in: harness.hostingView, expectedFilenames: expectedFilenames, passLabel: "baseline")
    }

    @MainActor
    private func assertNoFilenameTruncation(
        in hostingView: NSView,
        expectedFilenames: [String],
        passLabel: String
    ) {
        let strings = collectRenderedMillerColumnStrings(in: hostingView)
        for expected in expectedFilenames {
            XCTAssertTrue(
                strings.contains(where: { $0.contains(expected) }),
                "[\(passLabel)] Expected untruncated filename '\(expected)' in rendered Miller column strings, found: \(strings)"
            )
        }
        let truncatedCandidates = strings.filter { str in
            (str.contains("…") || str.contains("..."))
                && (str.hasPrefix("preview_") || str.hasPrefix("release_") || str.hasSuffix(".png") || str.hasSuffix(".json"))
        }
        XCTAssertTrue(
            truncatedCandidates.isEmpty,
            "[\(passLabel)] Rendered Miller column filename strings must never exhibit intermediate ellipsis truncation: \(truncatedCandidates)"
        )
        let geometricallyTruncated = collectGeometricallyTruncatedFilenameFields(
            in: hostingView,
            expectedFilenames: expectedFilenames
        )
        XCTAssertTrue(
            geometricallyTruncated.isEmpty,
            "[\(passLabel)] Rendered Miller column filename text fields must have sufficient width for their full glyph bounds: \(geometricallyTruncated)"
        )
    }

    @MainActor
    func testExplorerTruncationOracleAndAutocompletionAndSameParentRevealRegressions() async throws {
        let narrowField = NSTextField(labelWithString: "preview_wide_filename_01.png")
        narrowField.lineBreakMode = .byTruncatingMiddle
        narrowField.frame = NSRect(x: 0, y: 0, width: 42, height: 20)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 42, height: 20))
        container.addSubview(narrowField)
        let detected = collectGeometricallyTruncatedFilenameFields(
            in: container,
            expectedFilenames: ["preview_wide_filename_01.png"]
        )
        XCTAssertFalse(
            detected.isEmpty,
            "Truncation detector must catch an NSTextField whose rendered width is narrower than its glyph width"
        )

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_explorer_regressions_\(UUID().uuidString)", isDirectory: true)
        let dirA = tmpRoot.appendingPathComponent("dirA", isDirectory: true)
        let dirB = tmpRoot.appendingPathComponent("dirB", isDirectory: true)
        let childDir = dirA.appendingPathComponent("subchild", isDirectory: true)
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        let childB = dirB.appendingPathComponent("childB.txt")
        try Data("b".utf8).write(to: childB)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let engine = AsyncPathAutocompletionEngine()
        engine.query(rawInput: dirA.path + "/", baseDirectory: tmpRoot)
        let completedSuggestions = await engine.queryAsync(rawInput: dirB.path + "/", baseDirectory: tmpRoot)
        XCTAssertEqual(
            completedSuggestions.map(\.displayName),
            ["childB.txt"],
            "Cancelled earlier autocompletion query must not overwrite newer query suggestions"
        )
        XCTAssertEqual(engine.suggestions.map(\.displayName), ["childB.txt"])
        engine.clear()
        XCTAssertFalse(engine.isLoading)

        let viewModel = AppViewState()
        viewModel.navigationState.currentDirectory = dirA.standardizedFileURL
        let revealExpectation = expectation(description: "TTZipRevealDescendantInMillerColumns posted")
        let targetWindowID = viewModel.windowID
        let expectedChildPath = childDir.standardizedFileURL.path
        let token = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TTZipRevealDescendantInMillerColumns"),
            object: nil,
            queue: nil
        ) { notif in
            if (notif.object as? String) == expectedChildPath,
               (notif.userInfo?["windowID"] as? UUID) == targetWindowID {
                revealExpectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        viewModel.revealItemInWindow(childDir)
        await fulfillment(of: [revealExpectation], timeout: 0.2)
    }

    @MainActor
    private func collectGeometricallyTruncatedFilenameFields(
        in root: NSView,
        expectedFilenames: [String]
    ) -> [String] {
        var truncated: [String] = []
        var visited = Set<ObjectIdentifier>()

        func visit(_ view: NSView) {
            guard visited.insert(ObjectIdentifier(view)).inserted else { return }
            if let tf = view as? NSTextField,
               !tf.isHidden,
               tf.alphaValue > 0.01,
               expectedFilenames.contains(where: { tf.stringValue.contains($0) }) {
                let renderedWidth = tf.bounds.width
                let requiredWidth = max(tf.intrinsicContentSize.width, tf.attributedStringValue.size().width)
                if renderedWidth > 0 && (renderedWidth + 1.5) < requiredWidth {
                    truncated.append("\(tf.stringValue) (rendered=\(renderedWidth), required=\(requiredWidth))")
                }
            }
            for subview in view.subviews {
                visit(subview)
            }
        }

        visit(root)
        return truncated
    }

    @MainActor
    private func accessibilityFrameInWindow(
        id targetIdentifier: String,
        in root: NSView,
        window: NSWindow
    ) -> NSRect? {
        if targetIdentifier == "MainRightInspectorColumn" {
            if let inspectorScrollFrame = findScrollViewsWithOrigins(in: root)
                .map(\.frameInWindow)
                .first(where: { $0.minX >= 780.0 && $0.width >= 200.0 }) {
                return inspectorScrollFrame
            }
        }

        var visited = Set<ObjectIdentifier>()

        func search(_ node: Any) -> NSRect? {
            let obj = node as AnyObject
            guard visited.insert(ObjectIdentifier(obj)).inserted else { return nil }

            if let view = obj as? NSView {
                if view.accessibilityIdentifier() == targetIdentifier, !view.isHidden, view.alphaValue > 0.01 {
                    return view.convert(view.bounds, to: nil)
                }
            }
            if safeAccessibilityString(obj, selectorName: "accessibilityIdentifier") == targetIdentifier {
                if let ax = obj as? NSAccessibilityProtocol {
                    let screenFrame = ax.accessibilityFrame()
                    if screenFrame.width > 0, screenFrame.height > 0 {
                        return window.convertFromScreen(screenFrame)
                    }
                }
            }
            for child in obj.accessibilityChildren?() ?? [] {
                if let found = search(child) {
                    return found
                }
            }
            if let view = obj as? NSView {
                for subview in view.subviews {
                    if let found = search(subview) {
                        return found
                    }
                }
            }
            return nil
        }

        return search(root)
    }

    @MainActor
    private func collectRenderedMillerColumnStrings(in root: NSView) -> [String] {
        var results: [String] = []
        var visited = Set<ObjectIdentifier>()

        func visit(_ node: Any) {
            let obj = node as AnyObject
            guard visited.insert(ObjectIdentifier(obj)).inserted else { return }

            if let tf = obj as? NSTextField, !tf.isHidden, tf.alphaValue > 0.01, !tf.stringValue.isEmpty {
                results.append(tf.stringValue)
            }
            for selectorName in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let text = safeAccessibilityString(obj, selectorName: selectorName), !text.isEmpty {
                    results.append(text)
                }
            }
            for child in obj.accessibilityChildren?() ?? [] {
                visit(child)
            }
            if let view = obj as? NSView {
                for subview in view.subviews {
                    visit(subview)
                }
            }
        }

        visit(root)
        return results
    }

    @MainActor
    private func safeAccessibilityString(_ obj: AnyObject, selectorName: String) -> String? {
        let sel = NSSelectorFromString(selectorName)
        guard obj.responds(to: sel),
              let unmanaged = obj.perform(sel) else {
            return nil
        }
        let raw = unmanaged.takeUnretainedValue()
        if let attr = raw as? NSAttributedString {
            return attr.string
        }
        if let str = raw as? NSString {
            return str as String
        }
        return nil
    }
}
