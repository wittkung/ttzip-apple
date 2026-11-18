// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import Observation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class RightInspectorSidePanelTests: XCTestCase {
    
    @MainActor
    func testRightInspectorSidePanelUnselectedMount() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "SidePanel")
        let viewModel = AppViewState()
        viewModel.currentDirectory = tempDir
        viewModel.selectedDiskItem = nil
        
        let panel = RightInspectorSidePanel(viewModel: viewModel)
        let hosting = NSHostingView(rootView: panel)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        
        XCTAssertNotNil(hosting)
        XCTAssertNil(viewModel.selectedDiskItem)
    }
    
    @MainActor
    func testRightInspectorSidePanelSelectedItemAndOpenImmersiveMedia() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "SidePanel")
        let testFile = tempDir.appendingPathComponent("sample_document.pdf")
        try "Mock PDF Content".write(to: testFile, atomically: true, encoding: .utf8)
        
        let item = DiskItemInfo(url: testFile)
        let viewModel = AppViewState()
        viewModel.currentDirectory = tempDir
        viewModel.selectedDiskItem = item
        
        let panel = RightInspectorSidePanel(viewModel: viewModel)
        let hosting = NSHostingView(rootView: panel)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        
        XCTAssertNotNil(hosting)
        XCTAssertEqual(viewModel.selectedDiskItem?.path, testFile.path)
        
        // Test convenience openImmersiveMedia(for:)
        viewModel.openImmersiveMedia(for: item)
        XCTAssertTrue(viewModel.overlayState.showImmersiveMediaBrowser)
        XCTAssertEqual(viewModel.overlayState.immersiveMediaItem?.url.path, testFile.path)
        XCTAssertEqual(viewModel.overlayState.immersiveMediaItem?.name, item.displayName)
    }
    
    @MainActor
    func testFileSystemEntryMetadataToDiskItemInfoPreservesPosixPath() throws {
        let samplePath = "/tmp/sample.html"
        let sampleURL = URL(fileURLWithPath: samplePath)
        let originalItem = DiskItemInfo(
            path: samplePath,
            name: "sample.html",
            displayName: "sample.html",
            isDirectory: false,
            isArchive: false,
            sizeText: "1.5 KB",
            rawSizeBytes: 1536,
            kindText: "HTML Document",
            modificationDate: Date()
        )
        
        let metadata = FileSystemEntryMetadata(diskItem: originalItem)
        XCTAssertEqual(metadata.url, sampleURL)
        
        let diskItem = metadata.toDiskItemInfo()
        XCTAssertEqual(diskItem.path, samplePath)
        XCTAssertFalse(diskItem.path.hasPrefix("file://"))
        XCTAssertEqual(diskItem.name, "sample.html")
        XCTAssertEqual(diskItem.displayName, "sample.html")
    }

    @MainActor
    func testDirectoryHeaderDisplaysIdentityWithoutDuplicateAbbreviatedFullPath() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "SidePanelHeaderDeDup")
        let nestedDir = tempDir
            .appendingPathComponent("video_dev")
            .appendingPathComponent("日更")
            .appendingPathComponent("9.25 完美主义，利他")
            .appendingPathComponent("享受别人的成功")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)

        let viewModel = AppViewState()
        viewModel.currentDirectory = nestedDir
        viewModel.selectedDiskItem = nil

        let panel = RightInspectorSidePanel(viewModel: viewModel)
        XCTAssertEqual(
            panel.resolvedDirectoryHeaderTitle,
            "享受别人的成功",
            "Inspector directory header must resolve current folder display title"
        )
        let (window, host) = makeOffscreenHost(rootView: panel)
        defer {
            window.contentView = nil
            window.close()
        }

        let headerTexts = collectHeaderStrings(in: host, maxYFromTop: 60.0)
        let abbreviated = TTZipPathPresentationService.shared.abbreviateWithTilde(nestedDir.path)
        XCTAssertFalse(
            headerTexts.contains(abbreviated),
            "Inspector directory header must not duplicate the full abbreviated path text"
        )
    }

    @MainActor
    func testTopBarSidebarInspectorTogglesDragWidthsAndArchiveContextKeepControlsNonOverlapping() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "TopBarTogglesAndArchive")
        let viewModel = AppViewState()
        viewModel.navigationState.showDirectory(at: tempDir)

        // 1. Sidebar collapsed + Inspector collapsed at 860w, and Sidebar dragged to 280pt at 1080w
        let configs: [(width: CGFloat, leftVisible: Bool, rightVisible: Bool, leftWidth: CGFloat)] = [
            (860.0, false, true, 200.0),
            (860.0, true, false, 200.0),
            (860.0, false, false, 200.0),
            (1080.0, true, true, 280.0)
        ]

        for cfg in configs {
            let metrics = MainLayoutMetrics.compute(
                size: CGSize(width: cfg.width, height: 720.0),
                viewModel: viewModel,
                isLeftVisible: cfg.leftVisible,
                isRightVisible: cfg.rightVisible,
                leftWidth: cfg.leftWidth,
                rightRatio: MainLayoutMetrics.defaultRightInspectorRatio
            )
            let container = HomeExplorerContainerView(
                viewModel: viewModel,
                isRightSidebarVisible: cfg.rightVisible,
                isLeftSidebarVisible: cfg.leftVisible,
                onToggleLeftSidebar: {},
                onToggleRightSidebar: {},
                onOpenArchive: {},
                onNewArchive: {},
                isActive: true
            )
            .frame(width: metrics.centerWidth, height: 720.0)

            let window = NSWindow(
                contentRect: NSRect(x: -16_000, y: -16_000, width: metrics.centerWidth, height: 720.0),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: container)
            host.frame = NSRect(x: 0, y: 0, width: metrics.centerWidth, height: 720.0)
            window.contentView = host
            pumpHostLayout(host)

            // 1. Idle state: search is collapsed as 28pt trigger button (no editable NSTextField mounted)
            viewModel.explorerState.searchQuery = ""
            host.rootView = HomeExplorerContainerView(
                viewModel: viewModel,
                isRightSidebarVisible: cfg.rightVisible,
                isLeftSidebarVisible: cfg.leftVisible,
                onToggleLeftSidebar: {},
                onToggleRightSidebar: {},
                onOpenArchive: {},
                onNewArchive: {},
                isActive: true
            )
            .frame(width: metrics.centerWidth, height: 720.0)
            pumpHostLayout(host)
            XCTAssertTrue(
                findEditableSearchField(in: host) == nil,
                "Idle topbar should keep search collapsed as trigger button for config \(cfg)"
            )

            // 2. Expanded state: search capsule expands and remains strictly within centerWidth
            viewModel.explorerState.searchQuery = "测试"
            host.rootView = HomeExplorerContainerView(
                viewModel: viewModel,
                isRightSidebarVisible: cfg.rightVisible,
                isLeftSidebarVisible: cfg.leftVisible,
                onToggleLeftSidebar: {},
                onToggleRightSidebar: {},
                onOpenArchive: {},
                onNewArchive: {},
                isActive: true
            )
            .frame(width: metrics.centerWidth, height: 720.0)
            pumpHostLayout(host)
            let searchField = try XCTUnwrap(
                findEditableSearchField(in: host),
                "Expanded search field must mount for config \(cfg)"
            )
            let rect = searchField.convert(searchField.bounds, to: host)
            XCTAssertGreaterThanOrEqual(rect.width, 48.0)
            XCTAssertLessThanOrEqual(rect.maxX, metrics.centerWidth + 1.0)

            viewModel.explorerState.searchQuery = ""
            window.contentView = nil
            window.close()
        }
    }

    private func findEditableSearchField(in root: NSView) -> NSTextField? {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if let tf = current as? NSTextField, !tf.isHidden, tf.alphaValue > 0.01, tf.isEditable {
                return tf
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    private func collectHeaderStrings(in root: NSView, maxYFromTop: CGFloat) -> [String] {
        var strings: [String] = []
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            let rectInRoot = current.convert(current.bounds, to: root)
            let distanceFromTop = root.isFlipped ? rectInRoot.minY : (root.bounds.height - rectInRoot.maxY)
            if distanceFromTop <= maxYFromTop {
                if let tf = current as? NSTextField, !tf.isHidden {
                    let s = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { strings.append(s) }
                }
                let axLabel = current.accessibilityLabel() ?? ""
                if !axLabel.isEmpty { strings.append(axLabel) }
                if let axVal = current.accessibilityValue() as? String, !axVal.isEmpty {
                    strings.append(axVal)
                }
            }
            stack.append(contentsOf: current.subviews)
        }
        return strings
    }

    // MARK: - U04 Mounted FolderMediaArtboardView Automatic Analysis and A->B Update

    func testMountedViewAutomaticallyAnalyzesSelectionAndSwitchAToBWithoutClick() async throws {
        let fm = FileManager.default
        let rootTemp = try makeTemporaryDirectory(prefix: "U04HostWiring")
        let dirA = rootTemp.appendingPathComponent("FolderA")
        let dirB = rootTemp.appendingPathComponent("FolderB")
        let nestedB = dirB.appendingPathComponent("Nested")
        try fm.createDirectory(at: dirA, withIntermediateDirectories: true)
        try fm.createDirectory(at: nestedB, withIntermediateDirectories: true)

        try Data("alpha".utf8).write(to: dirA.appendingPathComponent("a.txt"))
        try Data(repeating: 0x61, count: 256).write(to: dirB.appendingPathComponent("main.swift"))
        try Data(repeating: 0x62, count: 128).write(to: nestedB.appendingPathComponent("config.json"))

        var scanCount = 0
        let itemA = DiskItemInfo(url: dirA)
        let itemB = DiskItemInfo(url: dirB)
        let coordinator = FolderSummaryAnalysisCoordinator(
            item: itemA,
            scanner: { identity, box in
                await MainActor.run { scanCount += 1 }
                return try await FolderSummaryAnalysisCoordinator.defaultScanner(identity, box)
            }
        )
        let driver = HostedFolderArtboardDriver(item: itemA)
        let (window, host) = makeOffscreenHost(
            rootView: HostedFolderArtboardContainerView(driver: driver, coordinator: coordinator)
        )
        defer {
            window.contentView = nil
            window.close()
        }

        let mountedA = await waitUntil(in: host) {
            coordinator.viewMountAndChangeCount >= 1 && coordinator.lastMountedItemPath == dirA.path
                && coordinator.hasAnalyzedStats && coordinator.activeScanCount == 0
        }
        await settleHostAndAsyncTasks(host, ticks: 6)
        XCTAssertTrue(mountedA, "Real FolderMediaArtboardView must complete initial mount for FolderA")
        XCTAssertEqual(coordinator.scanCallCount, 1)
        XCTAssertEqual(scanCount, 1)
        XCTAssertTrue(coordinator.hasAnalyzedStats)

        // Updating the mounted selection automatically analyzes B without a button press.
        driver.item = itemB
        let switchedToB = await waitUntil(in: host) {
            coordinator.viewMountAndChangeCount >= 2 && coordinator.lastMountedItemPath == dirB.path
                && coordinator.hasAnalyzedStats && coordinator.activeScanCount == 0
        }
        await settleHostAndAsyncTasks(host, ticks: 6)
        XCTAssertTrue(switchedToB, "Mounted FolderMediaArtboardView must process FolderA -> FolderB update")
        XCTAssertEqual(coordinator.currentItem.path, dirB.path)
        XCTAssertEqual(coordinator.scanCallCount, 2)
        XCTAssertEqual(scanCount, 2)
        XCTAssertTrue(coordinator.hasAnalyzedStats)
        XCTAssertNil(findVisibleNSButton(identifier: "FolderExplicitAnalyzeButton", in: host))
        let artboardB = FolderMediaArtboardView(item: itemB, coordinator: coordinator)
        XCTAssertEqual(coordinator.subfolderCount, 1)
        XCTAssertEqual(coordinator.fileCount, 2)
        XCTAssertGreaterThanOrEqual(coordinator.totalSizeBytes, 384)
        XCTAssertNotEqual(artboardB.formattedFolderSize, "--")
        XCTAssertNotEqual(artboardB.itemsSummaryText, "--")
    }

    // MARK: - U04 Stop / Remount Convergence on Same Directory & Stale Scan Isolation

    func testStopWhileAnalyzingAndSameFolderRemountAutomaticallyRestartsAndRejectsLateScan() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "U04Remount")
        let barrier1 = HostScanBarrier()
        let itemA = DiskItemInfo(url: tempDir)

        let coordinator = makeStaleFirstScanCoordinator(item: itemA, barrier: barrier1)

        let driver = HostedFolderArtboardDriver(item: itemA)
        let (window, host1) = makeOffscreenHost(
            rootView: HostedFolderArtboardContainerView(driver: driver, coordinator: coordinator)
        )
        defer {
            window.contentView = nil
            window.close()
        }

        _ = await waitUntil(in: host1) { coordinator.viewMountAndChangeCount >= 1 }

        let entered1 = await barrier1.waitUntilEntered()
        defer {
            Task { await barrier1.release() }
        }
        let activeDuringScan1 = coordinator.activeScanCount
        let isCalcDuringScan1 = coordinator.isCalculating

        // Dismount view while Scan 1 is in flight -> .onDisappear calls handleViewDisappear() -> stop().
        window.contentView = nil
        let stoppedCleanly = await waitUntil(in: host1) {
            coordinator.isStopped && coordinator.phase == .idleSummary
        }
        let phaseAfterStop = coordinator.phase
        let isStoppedAfterStop = coordinator.isStopped
        let cancelSignalsAfterStop = coordinator.cancelSignalCount
        let activeWhileBlockedAtBarrier = coordinator.activeScanCount

        // Remounting A must automatically restart analysis without a user action.
        let host2 = NSHostingView(
            rootView: HostedFolderArtboardContainerView(driver: driver, coordinator: coordinator)
                .frame(width: 320, height: 560)
        )
        host2.frame = NSRect(x: 0, y: 0, width: 320, height: 560)
        window.contentView = host2
        let remounted = await waitUntil(in: host2) {
            coordinator.viewMountAndChangeCount >= 2 && !coordinator.isStopped
                && coordinator.hasAnalyzedStats
        }
        await settleHostAndAsyncTasks(host2, ticks: 4)
        let hasStatsAfterRemount = coordinator.hasAnalyzedStats
        let initialAnalyzeButton = findVisibleNSButton(identifier: "FolderExplicitAnalyzeButton", in: host2)

        // Let Scan 1 finish late after automatic Scan 2 has already committed.
        await barrier1.release()
        let drained = await waitUntil(in: host2) {
            coordinator.activeScanCount == 0 && coordinator.completedScanReleaseCount == 2
        }

        XCTAssertTrue(entered1)
        XCTAssertTrue(stoppedCleanly)
        XCTAssertEqual(activeDuringScan1, 1)
        XCTAssertTrue(isCalcDuringScan1)
        XCTAssertEqual(phaseAfterStop, .idleSummary, "stop() must converge phase to .idleSummary, never leaving .analyzing")
        XCTAssertTrue(isStoppedAfterStop)
        XCTAssertEqual(cancelSignalsAfterStop, 1)
        XCTAssertEqual(activeWhileBlockedAtBarrier, 1)
        XCTAssertTrue(remounted)
        XCTAssertTrue(hasStatsAfterRemount, "Same-target remount must automatically complete analysis")
        XCTAssertNil(initialAnalyzeButton, "Initial analysis must not require a button")
        XCTAssertTrue(drained)
        XCTAssertEqual(coordinator.scanCallCount, 2)
        XCTAssertEqual(coordinator.cancelSignalCount, 1)
        XCTAssertEqual(coordinator.activeScanCount, 0)
        XCTAssertEqual(coordinator.completedScanReleaseCount, 2)
        XCTAssertEqual(coordinator.rejectedStaleCommitCount, 1)
        XCTAssertEqual(coordinator.totalSizeBytes, 2048, "Late Scan 1 must not overwrite remounted Scan 2")
        XCTAssertEqual(coordinator.fileCount, 2)
    }

    private func makeStaleFirstScanCoordinator(
        item: DiskItemInfo,
        barrier: HostScanBarrier
    ) -> FolderSummaryAnalysisCoordinator {
        var scanIndex = 0
        return FolderSummaryAnalysisCoordinator(
            item: item,
            scanner: { _, _ in
                let idx = await MainActor.run { () -> Int in
                    scanIndex += 1
                    return scanIndex
                }
                if idx == 1 {
                    await barrier.enterAndWaitForRelease()
                    return FolderAnalysisSnapshot(
                        totalSizeBytes: 999_999,
                        subfolderCount: 99,
                        fileCount: 99,
                        distribution: [FolderDistributionEntry(category: "stale", count: 99)]
                    )
                }
                return FolderAnalysisSnapshot(
                    totalSizeBytes: 2048,
                    subfolderCount: 1,
                    fileCount: 2,
                    distribution: [FolderDistributionEntry(category: "swift", count: 2)]
                )
            }
        )
    }

    // MARK: - Offscreen Host Inspection Helpers

    private func makeOffscreenHost<Content: View>(
        rootView: Content,
        width: CGFloat = 320
    ) -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(
            contentRect: NSRect(x: -16_000, y: -16_000, width: width, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(rootView.frame(width: width, height: 560)))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: 560)
        window.contentView = host
        window.setContentSize(NSSize(width: width, height: 560))
        pumpHostLayout(host)
        return (window, host)
    }

    private func pumpHostLayout(_ host: NSView) {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        host.window?.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.008))
    }

    private func settleHostAndAsyncTasks(_ host: NSView, ticks: Int) async {
        for _ in 0..<ticks {
            pumpHostLayout(host)
            await Task.yield()
        }
    }

    private func waitUntil(
        in host: NSView,
        timeoutNanoseconds: UInt64 = 1_500_000_000,
        predicate: () -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !predicate() {
            if DispatchTime.now().uptimeNanoseconds > deadline {
                return false
            }
            pumpHostLayout(host)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    private func findVisibleNSButton(identifier: String, in root: NSView) -> NSButton? {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if let button = current as? NSButton, !button.isHidden, !button.isTransparent {
                let matchesId = button.accessibilityIdentifier() == identifier
                let matchesLabel = button.accessibilityLabel() == "分析文件夹内容"
                    || button.accessibilityLabel() == "Analyze Folder Contents"
                    || button.title.contains("分析文件夹内容")
                    || button.title.contains("Analyze Folder Contents")
                if matchesId || matchesLabel {
                    return button
                }
            }
            if let scroll = current as? NSScrollView, let doc = scroll.documentView {
                stack.append(doc)
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    private func invokeAnalyzeButton(_ button: NSButton, in host: NSView) -> Bool {
        pumpHostLayout(host)
        let centerInWindow = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let pointInHostSuperview = host.superview?.convert(centerInWindow, from: nil) ?? centerInWindow
        guard let hitView = host.hitTest(pointInHostSuperview) else {
            XCTFail("Host hitTest at button center \(pointInHostSuperview) returned nil")
            return false
        }
        guard hitView === button || hitView.isDescendant(of: button) else {
            XCTFail("Host hitTest at button center must resolve the visible NSButton, got \(type(of: hitView))")
            return false
        }
        if let action = button.action {
            return button.sendAction(action, to: button.target)
        }
        return button.accessibilityPerformPress()
    }

    private func findHeaderPopUpButton(in root: NSView) -> NSPopUpButton? {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if let popUp = current as? NSPopUpButton, !popUp.isHidden {
                return popUp
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    @MainActor
    func testForgetArchivePasswordVisibilityOnlyForEncryptedOrPasswordActiveArchives() {
        let archivePath = "/tmp/inspector-unencrypted-\(UUID().uuidString).zip"
        defer { ArchivePasswordStore.shared.removePassword(for: archivePath) }
        let viewModel = AppViewState(fileViewer: NoOpFileViewer())
        viewModel.explorerState.currentArchivePath = archivePath
        viewModel.explorerState.currentEntries = [
            ArchiveEntry(path: "readme.txt", uncompressedSize: 120, isDirectory: false, isEncrypted: false)
        ]
        viewModel.passwordEvidenceState = .notEncrypted
        viewModel.explorerState.activePassword = nil

        XCTAssertFalse(RightInspectorSidePanel.shouldShowForgetArchivePassword(viewModel: viewModel))
        XCTAssertFalse(RightInspectorSidePanel(viewModel: viewModel).showsForgetArchivePassword)

        viewModel.explorerState.currentEntries = [
            ArchiveEntry(path: "secret.txt", uncompressedSize: 120, isDirectory: false, isEncrypted: true)
        ]
        XCTAssertTrue(RightInspectorSidePanel.shouldShowForgetArchivePassword(viewModel: viewModel))
        XCTAssertTrue(RightInspectorSidePanel(viewModel: viewModel).showsForgetArchivePassword)

        viewModel.explorerState.currentEntries = []
        viewModel.passwordEvidenceState = .verified(.fullArchive)
        XCTAssertTrue(RightInspectorSidePanel.shouldShowForgetArchivePassword(viewModel: viewModel))

        viewModel.passwordEvidenceState = .notEncrypted
        ArchivePasswordStore.shared.setPassword("session-secret", for: archivePath)
        XCTAssertTrue(RightInspectorSidePanel.shouldShowForgetArchivePassword(viewModel: viewModel))
    }

    @MainActor
    func testArchiveSelectionUsesFileInspectorInsteadOfFolderAnalysisAndPresentsExtractModal() throws {
        let tempArchive = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-archive-\(UUID().uuidString).zip")
        try Data(repeating: 0x50, count: 2048).write(to: tempArchive)
        defer { try? FileManager.default.removeItem(at: tempArchive) }

        let archiveItem = DiskItemInfo(url: tempArchive)
        XCTAssertTrue(archiveItem.isArchive)
        XCTAssertFalse(archiveItem.isDirectory)
        XCTAssertFalse(ExplorerItemInspectorView.usesFolderArtboard(for: archiveItem))
        XCTAssertEqual(FolderMediaArtboardView.compressFolderShortcut, "⇧⌘N")

        let artboard = FolderMediaArtboardView(item: archiveItem, onCompressPath: { _ in })
        XCTAssertEqual(artboard.formattedFolderSize, archiveItem.sizeText)

        let viewModel = AppViewState(fileViewer: NoOpFileViewer())
        let panel = RightInspectorSidePanel(viewModel: viewModel)
        XCTAssertFalse(viewModel.overlayState.showExtractModal)

        panel.onSelectArchive?(tempArchive.path)
        XCTAssertTrue(viewModel.overlayState.showExtractModal)
        XCTAssertEqual(viewModel.selectionState.selectedDiskItem?.path, tempArchive.path)
    }

    @MainActor
    func testVirtualArchiveEntryPreservesModificationDateOrShowsDashAndRevealsParentArchive() {
        let archivePath = "/tmp/virtual-entry-\(UUID().uuidString).zip"
        let exactDate = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = AppViewState(fileViewer: NoOpFileViewer())
        viewModel.explorerState.currentArchivePath = archivePath
        viewModel.explorerState.currentEntries = [
            ArchiveEntry(
                path: "docs/dated.txt",
                uncompressedSize: 64,
                isDirectory: false,
                modificationDate: exactDate,
                isEncrypted: false
            ),
            ArchiveEntry(
                path: "docs/undated.txt",
                uncompressedSize: 32,
                isDirectory: false,
                modificationDate: nil,
                isEncrypted: false
            )
        ]

        viewModel.selectArchiveEntry(path: "docs/dated.txt", inArchive: archivePath)
        guard let datedItem = RightInspectorSidePanel.resolveEffectiveItem(viewModel: viewModel) else {
            return XCTFail("Expected resolved virtual item for dated.txt")
        }
        let datedMeta = FileSystemEntryMetadata(diskItem: datedItem)
        XCTAssertEqual(datedMeta.modifiedDate, exactDate)
        XCTAssertEqual(datedMeta.toDiskItemInfo().modificationDate, exactDate)
        XCTAssertNotEqual(ExplorerItemInspectorView.formattedModifiedDate(for: datedItem), "--")

        viewModel.selectionState.selectedDiskItem = nil
        viewModel.selectionState.selectedEntryID = "docs/undated.txt"
        guard let undatedItem = RightInspectorSidePanel.resolveEffectiveItem(viewModel: viewModel) else {
            return XCTFail("Expected resolved virtual item for undated.txt")
        }
        let undatedMeta = FileSystemEntryMetadata(diskItem: undatedItem)
        XCTAssertNil(undatedMeta.modifiedDate)
        XCTAssertNil(undatedMeta.toDiskItemInfo().modificationDate)
        XCTAssertEqual(ExplorerItemInspectorView.formattedModifiedDate(for: undatedItem), "--")

        XCTAssertTrue(RightInspectorSidePanel.isVirtualArchiveEntry(undatedItem))
        XCTAssertEqual(
            RightInspectorSidePanel.finderRevealTargetPath(for: undatedItem, activeArchivePath: archivePath),
            archivePath
        )
    }

    @MainActor
    func testInspectorHeaderActionMenusUseRegular13PointPopUpAtMinimumWidth() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "HeaderMenuRegular")
        let fileURL = tempDir.appendingPathComponent("report.txt")
        try Data("hello".utf8).write(to: fileURL)
        let fileItem = DiskItemInfo(url: fileURL)

        for selectedItem in [fileItem, nil] {
            let viewModel = AppViewState()
            viewModel.currentDirectory = tempDir
            viewModel.selectedDiskItem = selectedItem

            let (window, host) = makeOffscreenHost(
                rootView: RightInspectorSidePanel(viewModel: viewModel),
                width: MainLayoutMetrics.minRightSidebarWidth
            )
            defer {
                window.contentView = nil
                window.close()
            }

            let popUp = try XCTUnwrap(findHeaderPopUpButton(in: host))
            XCTAssertEqual(popUp.controlSize, NSControl.ControlSize.regular)
            XCTAssertEqual(popUp.cell?.controlSize, NSControl.ControlSize.regular)
            XCTAssertEqual(popUp.font?.pointSize, 13.0)
            XCTAssertEqual(popUp.menu?.font?.pointSize, 13.0)
            let rectInHost = popUp.convert(popUp.bounds, to: host)
            XCTAssertLessThanOrEqual(rectInHost.maxX, MainLayoutMetrics.minRightSidebarWidth + 1.0)
        }
    }
}

@MainActor
@Observable
private final class HostedFolderArtboardDriver {
    var item: DiskItemInfo

    init(item: DiskItemInfo) {
        self.item = item
    }
}

private struct HostedFolderArtboardContainerView: View {
    var driver: HostedFolderArtboardDriver
    let coordinator: FolderSummaryAnalysisCoordinator

    var body: some View {
        FolderMediaArtboardView(
            item: driver.item,
            coordinator: coordinator
        )
    }
}

private actor HostScanBarrier {
    private var hasEntered = false
    private var isReleased = false
    private var enteredWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var releaseWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func enterAndWaitForRelease() async {
        hasEntered = true
        let waiters = Array(enteredWaiters.values)
        enteredWaiters.removeAll()
        for cont in waiters {
            cont.resume(returning: true)
        }
        if isReleased {
            return
        }
        let releaseID = UUID()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if isReleased {
                cont.resume()
            } else {
                releaseWaiters[releaseID] = cont
            }
        }
    }

    func waitUntilEntered(timeoutNanoseconds: UInt64 = 1_500_000_000) async -> Bool {
        if hasEntered {
            return true
        }
        let waiterID = UUID()
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            self.expireEnteredWaiter(id: waiterID)
        }
        defer { timeoutTask.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if hasEntered {
                    cont.resume(returning: true)
                } else if Task.isCancelled {
                    cont.resume(returning: false)
                } else {
                    enteredWaiters[waiterID] = cont
                }
            }
        } onCancel: {
            Task { await self.expireEnteredWaiter(id: waiterID) }
        }
    }

    private func expireEnteredWaiter(id: UUID) {
        if let cont = enteredWaiters.removeValue(forKey: id) {
            cont.resume(returning: false)
        }
    }

    func release() {
        isReleased = true
        let pendingEntered = Array(enteredWaiters.values)
        enteredWaiters.removeAll()
        for cont in pendingEntered {
            cont.resume(returning: hasEntered)
        }
        let pendingRelease = Array(releaseWaiters.values)
        releaseWaiters.removeAll()
        for cont in pendingRelease {
            cont.resume()
        }
    }
}
