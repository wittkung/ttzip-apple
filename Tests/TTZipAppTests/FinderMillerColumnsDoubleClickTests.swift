// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TTZipUI
@testable import TTZipPreviewKit
@testable import TTZipApp
#if !SWIFT_PACKAGE
@testable import TTZipAppViews
#endif
@testable import TTZipCore
#if canImport(TTZipAppServices)
@testable import TTZipAppServices
#endif
#if canImport(TTZipAppViewModels)
@testable import TTZipAppViewModels
#endif

@MainActor
extension FinderMillerColumnsNavigationTests {

    // MARK: - Production Row & Column Event Wiring + Outgoing System Association Activation

    func testRowSingleClickSelectsWithoutOpeningAndDoubleClickActivatesPhysicalTextAndScriptFilesViaInjectedService() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MillerDoubleClick-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let txtURL = tempDir.appendingPathComponent("harmless_note.txt")
        try Data("harmless text fixture".utf8).write(to: txtURL)
        let cmdURL = tempDir.appendingPathComponent("inspect_only.command")
        try Data("#!/bin/sh\necho should_never_execute\n".utf8).write(to: cmdURL)

        let mockViewer = MockFileViewerHarness()
        let state = AppViewState(fileViewer: mockViewer)
        AppIntentDispatcher.shared.bind(state: state)
        defer {
            AppIntentDispatcher.shared.unregister(windowID: state.windowID)
            BrowserWindowRegistry.shared.unregister(id: state.windowID)
            state.prepareForWindowClose()
        }

        let txtItem = DiskItemInfo(url: txtURL, isDirectory: false)
        let cmdItem = DiskItemInfo(url: cmdURL, isDirectory: false)

        var selectCount = 0
        var activateCount = 0
        let row = MillerColumnItemRowView(
            item: txtItem,
            columnIndex: 0,
            isSelected: false,
            dirURL: tempDir,
            multiSelectedPaths: [],
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onSelectItem: { item, _, _, _, _ in
                selectCount += 1
                state.selectionState.select(item)
            },
            onActivateItem: { item, _, _ in
                activateCount += 1
                Task { @MainActor in
                    _ = await state.activateExplorerItem(item, createAppKitWindow: false)
                }
            },
            onTriggerNewFolder: { _ in },
            onTriggerNewFile: { _ in }
        )

        let (window, host) = makeOffscreenRowHost(for: row)
        defer {
            NativeContextMenuBridgeView.testSimulatedCurrentEvent = nil
            window.contentView = nil
            window.close()
        }

        let centerPoint = NSPoint(x: host.bounds.midX, y: host.bounds.midY)

        // 1. Single-click (clickCount == 1) must NOT be captured by NativeContextMenuBridgeView (preserves SwiftUI tap & drag).
        let singleDown = try makeMouseEvent(type: .leftMouseDown, location: centerPoint, clickCount: 1, windowNumber: window.windowNumber)
        NativeContextMenuBridgeView.testSimulatedCurrentEvent = singleDown
        let singleHit = host.hitTest(centerPoint)
        XCTAssertFalse(singleHit is NativeContextMenuBridgeView, "Single click must pass through to SwiftUI for selection and drag-and-drop")
        XCTAssertTrue(mockViewer.openedURLs.isEmpty, "Single click must never open external file")

        // 2. Cmd+double-click must NOT trigger activation (preserves modifier multi-selection).
        let cmdDoubleDown = try makeMouseEvent(
            type: .leftMouseDown,
            location: centerPoint,
            modifiers: [.command],
            clickCount: 2,
            windowNumber: window.windowNumber
        )
        NativeContextMenuBridgeView.testSimulatedCurrentEvent = cmdDoubleDown
        XCTAssertFalse(host.hitTest(centerPoint) is NativeContextMenuBridgeView, "Cmd-modified click must pass through for multi-selection")
        XCTAssertEqual(activateCount, 0)

        // 3. Unmodified double-click (clickCount == 2) on real row must resolve NativeContextMenuBridgeView and fire activation once.
        let doubleDown = try makeMouseEvent(type: .leftMouseDown, location: centerPoint, clickCount: 2, windowNumber: window.windowNumber)
        NativeContextMenuBridgeView.testSimulatedCurrentEvent = doubleDown
        let doubleHit = try XCTUnwrap(host.hitTest(centerPoint))
        XCTAssertTrue(doubleHit is NativeContextMenuBridgeView, "Red-gate proof: row must capture unmodified clickCount==2 for activation")
        doubleHit.mouseDown(with: doubleDown)

        // 4. Triple-click (clickCount == 3) must NOT fire a duplicate second open.
        let tripleDown = try makeMouseEvent(type: .leftMouseDown, location: centerPoint, clickCount: 3, windowNumber: window.windowNumber)
        NativeContextMenuBridgeView.testSimulatedCurrentEvent = tripleDown
        let tripleHit = try XCTUnwrap(host.hitTest(centerPoint))
        tripleHit.mouseDown(with: tripleDown)

        await Task.yield()
        XCTAssertEqual(activateCount, 1, "Double-click followed by triple-click must activate exactly once")
        XCTAssertEqual(selectCount, 0, "Double-click capture must not re-fire single-click callback")
        XCTAssertEqual(mockViewer.openedURLs.map { $0.standardizedFileURL.path }, [txtURL.standardizedFileURL.path])

        // 5. Harmless .command script activates via injected FileViewerService without executing script content.
        let cmdOpened = await state.activateExplorerItem(cmdItem, createAppKitWindow: false)
        XCTAssertTrue(cmdOpened)
        XCTAssertEqual(mockViewer.openedURLs.last?.standardizedFileURL.path, cmdURL.standardizedFileURL.path)

        // 6. Context menu "Open" on single item also routes through the same injectable FileViewerService.
        let menu = TTZipContextMenuBuilder.shared.buildMenu(
            for: .singleItem(url: txtURL, isDirectory: false, isArchive: false)
        )
        let openItem = try XCTUnwrap(menu.items.first)
        _ = openItem.target?.perform(openItem.action, with: openItem)
        XCTAssertEqual(mockViewer.openedURLs.count, 3)
    }

    func testPhysicalLocalFilesAndRealAppBundleDoubleClickRouteThroughFileViewerServiceOnce() async throws {
        await StandalonePlaybackWindowManager.shared.resetForTesting()
        await StandalonePreviewWindowManager.shared.closeAll()
        defer {
            Task { @MainActor in
                await StandalonePlaybackWindowManager.shared.resetForTesting()
                await StandalonePreviewWindowManager.shared.closeAll()
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MillerLocalDoubleClick-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pngURL = tempDir.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: pngURL)
        let fixtureVideoURL = try locatePreviewFixturesRoot().appendingPathComponent("video/clip.mp4")
        let mp4URL = tempDir.appendingPathComponent("clip.mp4")
        try Data(contentsOf: fixtureVideoURL).write(to: mp4URL)
        let txtURL = tempDir.appendingPathComponent("notes.txt")
        try Data("plain text".utf8).write(to: txtURL)
        let appURL = try createHarmlessAppBundle(in: tempDir, name: "Sample.app")

        // Real DiskItemInfo constructed from on-disk .app bundle directory (NOT faking isDirectory = false)
        let appItem = DiskItemInfo(url: appURL)
        XCTAssertTrue(appItem.isDirectory, ".app bundle is a directory on disk")
        XCTAssertTrue(appItem.isApplicationBundle, ".app bundle must be recognized via real bundle/taxonomy check")
        XCTAssertFalse(appItem.isBrowsableDirectory, ".app bundle must not be treated as a browsable folder in Miller columns")
        XCTAssertEqual(
            FinderMillerColumnsView.nextColumnPaths(currentPaths: [tempDir], columnIndex: 0, item: appItem),
            [tempDir],
            "Selecting or double-clicking a .app bundle must not append a child directory column"
        )

        let mockViewer = MockFileViewerHarness()
        let state = AppViewState(fileViewer: mockViewer)
        defer { state.prepareForWindowClose() }

        let imageOpened = await state.activateExplorerItem(DiskItemInfo(url: pngURL), createAppKitWindow: false)
        let videoOpened = await state.activateExplorerItem(DiskItemInfo(url: mp4URL), createAppKitWindow: false)
        let textOpened = await state.activateExplorerItem(DiskItemInfo(url: txtURL), createAppKitWindow: false)

        // Production row double-click on real .app bundle item
        let appRow = MillerColumnItemRowView(
            item: appItem,
            columnIndex: 0,
            isSelected: false,
            dirURL: tempDir,
            multiSelectedPaths: [],
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onSelectItem: { _, _, _, _, _ in },
            onActivateItem: { item, _, _ in
                Task { @MainActor in
                    _ = await state.activateExplorerItem(item, createAppKitWindow: false)
                }
            },
            onTriggerNewFolder: { _ in },
            onTriggerNewFile: { _ in }
        )
        let (window, host) = makeOffscreenRowHost(for: appRow)
        defer {
            NativeContextMenuBridgeView.testSimulatedCurrentEvent = nil
            window.contentView = nil
            window.close()
        }
        let center = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        let doubleDown = try makeMouseEvent(type: .leftMouseDown, location: center, clickCount: 2, windowNumber: window.windowNumber)
        NativeContextMenuBridgeView.testSimulatedCurrentEvent = doubleDown
        let hitView = try XCTUnwrap(host.hitTest(center))
        hitView.mouseDown(with: doubleDown)
        await Task.yield()

        XCTAssertTrue(imageOpened && videoOpened && textOpened)
        XCTAssertEqual(
            mockViewer.openedURLs.map { $0.standardizedFileURL.path },
            [pngURL, mp4URL, txtURL, appURL].map { $0.standardizedFileURL.path },
            "Image, video, text, and .app bundle double-click must uniformly route through FileViewerService"
        )
        XCTAssertEqual(StandalonePreviewWindowManager.shared.activeWindowCount, 0, "When system default is another app, TTZip must not self-open preview windows")
        XCTAssertFalse(StandalonePlaybackWindowManager.shared.hasActivePlaybackSession, "When system default is another app, TTZip must not self-open playback windows")
    }

    // MARK: - TTZip Incoming System Open Receiver, Anti-Recursion & Deduplication

    func testTTZipIncomingOpenReceiverOpensStandaloneWindowsDeduplicatesAndPreventsSelfRecursion() async throws {
        await StandalonePlaybackWindowManager.shared.resetForTesting()
        await StandalonePreviewWindowManager.shared.resetForTesting()
        BrowserWindowRouter.shared.resetForTesting()
        defer {
            AppErrorReporter.shared.dismiss()
            BrowserWindowRouter.shared.resetForTesting()
            Task { @MainActor in
                await StandalonePlaybackWindowManager.shared.resetForTesting()
                await StandalonePreviewWindowManager.shared.resetForTesting()
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipIncomingOpen-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pngURL = tempDir.appendingPathComponent("received.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: pngURL)
        let txtURL = tempDir.appendingPathComponent("received.txt")
        try Data("hello incoming ttzip".utf8).write(to: txtURL)
        let fixtureVideoURL = try locatePreviewFixturesRoot().appendingPathComponent("video/clip.mp4")
        let mp4URL = tempDir.appendingPathComponent("received.mp4")
        try Data(contentsOf: fixtureVideoURL).write(to: mp4URL)
        let unsupportedURL = tempDir.appendingPathComponent("mystery.unknownfmt")
        try Data("unsupported payload".utf8).write(to: unsupportedURL)

        var playbackPresentations = 0
        var previewPresentations = 0
        StandalonePlaybackWindowManager.shared.windowPresentationHandler = { _, _ in
            playbackPresentations += 1
        }
        StandalonePreviewWindowManager.shared.windowPresentationHandler = { _, _, _ in
            previewPresentations += 1
        }

        // Simulate macOS routing the open request back to TTZip when TTZip is the default application.
        let mockViewer = MockFileViewerHarness { url in
            _ = BrowserWindowRouter.shared.routeExternalOpen(urls: [url])
            return true
        }
        let state = AppViewState(fileViewer: mockViewer)
        BrowserWindowRegistry.shared.register(state)
        BrowserWindowRegistry.shared.activateWindow(id: state.windowID)
        defer { state.prepareForWindowClose() }

        // 1. Double-clicking video -> FileViewerService -> BrowserWindowRouter -> StandalonePlaybackWindowManager (no recursion!)
        let videoOpened = await state.activateExplorerItem(DiskItemInfo(url: mp4URL), createAppKitWindow: false)
        for _ in 0..<10 where !StandalonePlaybackWindowManager.shared.hasActivePlaybackSession {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(videoOpened)
        XCTAssertTrue(StandalonePlaybackWindowManager.shared.hasActivePlaybackSession)
        XCTAssertEqual(StandalonePlaybackWindowManager.shared.createdWindowCount, 1, "Production incoming receiver must request a visible playback host window")
        XCTAssertEqual(playbackPresentations, 1)
        XCTAssertEqual(mockViewer.openedURLs.count, 1, "Receiver must never call openFileWithDefaultApp again (anti-recursion)")

        // 2. Duplicate incoming event within deduplication window is suppressed; repeated receiver call focuses existing session.
        let duplicateRouted = BrowserWindowRouter.shared.routeExternalOpen(urls: [mp4URL])
        XCTAssertFalse(duplicateRouted, "Duplicate external open batch must be suppressed")
        let secondReceive = await state.receiveExternalOpenFile(url: mp4URL)
        XCTAssertTrue(secondReceive)
        XCTAssertEqual(StandalonePlaybackWindowManager.shared.createdWindowCount, 1, "Repeated receive must focus existing window without duplicate creation")
        XCTAssertEqual(playbackPresentations, 2)
        XCTAssertEqual(mockViewer.openedURLs.count, 1, "Direct incoming receiver call must never invoke FileViewerService")

        // 3. Incoming image and text files open in StandalonePreviewWindowManager with visible host handoff.
        let imgReceive = await state.receiveExternalOpenFile(url: pngURL)
        let txtReceive = await state.receiveExternalOpenFile(url: txtURL)
        XCTAssertTrue(imgReceive && txtReceive)
        XCTAssertEqual(StandalonePreviewWindowManager.shared.activeWindowCount, 2)
        XCTAssertEqual(StandalonePreviewWindowManager.shared.createdWindowCount, 2, "Production incoming receiver must create visible preview host windows")
        XCTAssertEqual(previewPresentations, 2)

        // 4. Unsupported format in incoming receiver reports a visible error and never bounces back to FileViewerService.
        AppErrorReporter.shared.dismiss()
        let unsupportedReceive = await state.receiveExternalOpenFile(url: unsupportedURL, createAppKitWindow: false)
        XCTAssertFalse(unsupportedReceive)
        XCTAssertEqual(mockViewer.openedURLs.count, 1, "Unsupported incoming file must never bounce back to FileViewerService")
        XCTAssertTrue(AppErrorReporter.shared.isPresentingError)
        XCTAssertEqual(AppErrorReporter.shared.activeError?.diagnosticCode, "ERR_UNSUPPORTED_INCOMING_FORMAT")
    }

    func testRouteExternalOpenWithExtractPreferenceOpensPlainVideoAndTextInStandaloneHostsWithoutCompressionAndSupportsZeroWindowFallback() async throws {
        await StandalonePlaybackWindowManager.shared.resetForTesting()
        await StandalonePreviewWindowManager.shared.resetForTesting()
        BrowserWindowRegistry.shared.resetForTesting()
        BrowserWindowRouter.shared.resetForTesting()
        let prevDefault = UserDefaults.standard.string(forKey: "ttzip_double_click_action")
        UserDefaults.standard.set("extract", forKey: "ttzip_double_click_action")
        defer {
            if let prevDefault {
                UserDefaults.standard.set(prevDefault, forKey: "ttzip_double_click_action")
            } else {
                UserDefaults.standard.removeObject(forKey: "ttzip_double_click_action")
            }
            AppErrorReporter.shared.dismiss()
            BrowserWindowRegistry.shared.resetForTesting()
            BrowserWindowRouter.shared.resetForTesting()
            Task { @MainActor in
                await StandalonePlaybackWindowManager.shared.resetForTesting()
                await StandalonePreviewWindowManager.shared.resetForTesting()
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipExtractPrefPlain-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let txtURL = tempDir.appendingPathComponent("readme.txt")
        try Data("plain text under extract pref".utf8).write(to: txtURL)
        let pngURL = tempDir.appendingPathComponent("fallback.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: pngURL)
        let fixtureVideoURL = try locatePreviewFixturesRoot().appendingPathComponent("video/clip.mp4")
        let mp4URL = tempDir.appendingPathComponent("movie.mp4")
        try Data(contentsOf: fixtureVideoURL).write(to: mp4URL)

        let state = AppViewState(fileViewer: NoOpFileViewer())
        BrowserWindowRegistry.shared.register(state)
        BrowserWindowRegistry.shared.activateWindow(id: state.windowID)
        defer { state.prepareForWindowClose() }
        XCTAssertNil(BrowserWindowRegistry.shared.nsWindow(for: state.windowID), "Registered test controller has no bound NSWindow")
        XCTAssertNil(StandalonePlaybackWindowManager.shared.windowPresentationHandler, "Must not rely on windowPresentationHandler to enable window creation")
        XCTAssertNil(StandalonePreviewWindowManager.shared.windowPresentationHandler, "Must not rely on windowPresentationHandler to enable window creation")

        // 1. With ttzip_double_click_action == "extract" and a registered controller whose nsWindow is nil (and no presentation handler installed),
        // plain video & text still request visible standalone hosts without activating compression.
        let routed = BrowserWindowRouter.shared.routeExternalOpen(urls: [mp4URL, txtURL], preferredAction: "extract", now: 100.0)
        XCTAssertTrue(routed)
        for _ in 0..<25 where (
            StandalonePlaybackWindowManager.shared.windowPresentationRequestCount < 1
            || StandalonePreviewWindowManager.shared.windowPresentationRequestCount < 1
        ) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(StandalonePlaybackWindowManager.shared.hasActivePlaybackSession)
        XCTAssertEqual(StandalonePlaybackWindowManager.shared.createdWindowCount, 1)
        XCTAssertEqual(StandalonePlaybackWindowManager.shared.windowPresentationRequestCount, 1)
        XCTAssertEqual(StandalonePreviewWindowManager.shared.activeWindowCount, 1)
        XCTAssertEqual(StandalonePreviewWindowManager.shared.createdWindowCount, 1)
        XCTAssertEqual(StandalonePreviewWindowManager.shared.windowPresentationRequestCount, 1)
        XCTAssertFalse(state.navigationState.isCompressWorkspaceActive)
        XCTAssertTrue(state.compressSession.itemsList.isEmpty)

        // 2. Zero-browser-window with async SwiftUI opener (not yet registered) creates visible standalone hosts, deduplicates, and preserves security scope.
        try await verifyZeroWindowAsyncSwiftUIOpenerFallback(
            state: state,
            mp4URL: mp4URL,
            pngURL: pngURL
        )
    }

    private func verifyZeroWindowAsyncSwiftUIOpenerFallback(
        state: AppViewState,
        mp4URL: URL,
        pngURL: URL
    ) async throws {
        state.prepareForWindowClose()
        await StandalonePlaybackWindowManager.shared.resetForTesting()
        await StandalonePreviewWindowManager.shared.resetForTesting()
        BrowserWindowRegistry.shared.resetForTesting()
        for _ in 0..<10 where RootFolderAccessManager.shared.totalActiveLeaseCount > 0 {
            await Task.yield()
        }

        var presentedVideoURLs: [URL] = []
        var presentedPreviewURLs: [URL] = []
        var factoryVideoTitles: [String] = []
        var factoryPreviewNames: [String] = []
        StandalonePlaybackWindowManager.shared.windowFactory = { session in
            factoryVideoTitles.append(session.item.name)
            return StandalonePlaybackWindowManager.makeStandardPlayerWindow(title: session.item.name)
        }
        StandalonePlaybackWindowManager.shared.windowPresentationHandler = { _, session in
            presentedVideoURLs.append(session.item.url)
        }
        StandalonePreviewWindowManager.shared.windowFactory = { item, _ in
            factoryPreviewNames.append(item.name)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            return win
        }
        StandalonePreviewWindowManager.shared.windowPresentationHandler = { _, item, _ in
            presentedPreviewURLs.append(item.url)
        }

        // Simulate SwiftUI's asynchronous scene opener where openWindow(id: "main") returns before registering a controller.
        var asyncSwiftUIOpenerCalls = 0
        BrowserWindowRouter.shared.swiftUIWindowOpener = {
            asyncSwiftUIOpenerCalls += 1
        }
        BrowserWindowRouter.shared.fallbackWindowCreator = nil

        let baselineTotalScope = RootFolderAccessManager.shared.totalActiveLeaseCount

        let zeroWinRouted = BrowserWindowRouter.shared.routeExternalOpen(urls: [mp4URL, pngURL], preferredAction: "extract", now: 200.0)
        XCTAssertTrue(zeroWinRouted)
        XCTAssertEqual(asyncSwiftUIOpenerCalls, 1, "Router attempts to open browser window via SwiftUI opener")
        XCTAssertEqual(BrowserWindowRegistry.shared.windowCount, 0, "SwiftUI opener is asynchronous and has not registered a controller yet")
        XCTAssertGreaterThanOrEqual(RootFolderAccessManager.shared.totalActiveLeaseCount, baselineTotalScope + 2, "External bridge leases must stay alive across async handoff")

        for _ in 0..<25 where (
            presentedVideoURLs.isEmpty
            || presentedPreviewURLs.isEmpty
            || RootFolderAccessManager.shared.totalActiveLeaseCount > baselineTotalScope + 2
        ) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await Task.yield()
        XCTAssertEqual(factoryVideoTitles, [mp4URL.lastPathComponent], "Zero-window fallback must invoke playback window factory")
        XCTAssertEqual(factoryPreviewNames, [pngURL.lastPathComponent], "Zero-window fallback must invoke preview window factory")
        XCTAssertEqual(StandalonePlaybackWindowManager.shared.createdWindowCount, 1, "Zero-window fallback must create visible playback host")
        XCTAssertEqual(StandalonePreviewWindowManager.shared.createdWindowCount, 1, "Zero-window fallback must create visible preview host")
        XCTAssertEqual(RootFolderAccessManager.shared.totalActiveLeaseCount, baselineTotalScope + 2)

        // Duplicate delivery within deduplication window is suppressed; delivery after window focuses existing hosts without creating new windows.
        XCTAssertFalse(BrowserWindowRouter.shared.routeExternalOpen(urls: [mp4URL, pngURL], preferredAction: "extract", now: 200.1))
        XCTAssertTrue(BrowserWindowRouter.shared.routeExternalOpen(urls: [mp4URL, pngURL], preferredAction: "extract", now: 201.0))
        for _ in 0..<25 where (presentedVideoURLs.count < 2 || presentedPreviewURLs.count < 2) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(StandalonePlaybackWindowManager.shared.createdWindowCount, 1, "Repeated delivery must focus existing playback window, not duplicate")
        XCTAssertEqual(StandalonePreviewWindowManager.shared.createdWindowCount, 1, "Repeated delivery must focus existing preview window, not duplicate")
        await StandalonePlaybackWindowManager.shared.resetForTesting()
        await StandalonePreviewWindowManager.shared.resetForTesting()
        XCTAssertEqual(RootFolderAccessManager.shared.totalActiveLeaseCount, baselineTotalScope)
    }

    func testRouteExternalOpenMixedArchiveDirectoryAndPlainFilesDispatchesEachByOwnContractWithoutCompression() async throws {
        await StandalonePlaybackWindowManager.shared.resetForTesting()
        await StandalonePreviewWindowManager.shared.closeAll()
        BrowserWindowRegistry.shared.resetForTesting()
        BrowserWindowRouter.shared.resetForTesting()
        defer {
            AppErrorReporter.shared.dismiss()
            BrowserWindowRegistry.shared.resetForTesting()
            BrowserWindowRouter.shared.resetForTesting()
            Task { @MainActor in
                await StandalonePlaybackWindowManager.shared.resetForTesting()
                await StandalonePreviewWindowManager.shared.closeAll()
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipMixedBatch-" + UUID().uuidString, isDirectory: true)
        let subFolderURL = tempDir.appendingPathComponent("SubFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: subFolderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent("sample.zip")
        let eocd: [UInt8] = [
            0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        try Data(eocd).write(to: archiveURL)
        let txtURL = tempDir.appendingPathComponent("neighbor.txt")
        try Data("neighbor plain text".utf8).write(to: txtURL)
        let fixtureVideoURL = try locatePreviewFixturesRoot().appendingPathComponent("video/clip.mp4")
        let mp4URL = tempDir.appendingPathComponent("neighbor.mp4")
        try Data(contentsOf: fixtureVideoURL).write(to: mp4URL)

        let state = AppViewState(fileViewer: NoOpFileViewer())
        BrowserWindowRegistry.shared.register(state)
        BrowserWindowRegistry.shared.activateWindow(id: state.windowID)
        defer { state.prepareForWindowClose() }

        var seededArchives: [URL] = []
        BrowserWindowRouter.shared.fallbackWindowCreator = { seed in
            if let archive = seed.initialArchiveURL {
                seededArchives.append(archive)
            }
            return nil
        }

        // Mixed batch: directory + archive + plain text + plain video
        let routed = BrowserWindowRouter.shared.routeExternalOpen(
            urls: [subFolderURL, archiveURL, txtURL, mp4URL],
            preferredAction: "browse"
        )
        XCTAssertTrue(routed)
        for _ in 0..<25 where (!StandalonePlaybackWindowManager.shared.hasActivePlaybackSession || StandalonePreviewWindowManager.shared.activeWindowCount < 1) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(state.currentDirectory.standardizedFileURL, subFolderURL.standardizedFileURL, "Directory in mixed batch must navigate browser window")
        XCTAssertEqual(seededArchives.map(\.standardizedFileURL), [archiveURL.standardizedFileURL], "Archive in mixed batch with directory must seed archive window")
        XCTAssertEqual(StandalonePreviewWindowManager.shared.activeWindowCount, 1, "Plain text in mixed batch must still open in standalone preview window")
        XCTAssertTrue(StandalonePlaybackWindowManager.shared.hasActivePlaybackSession, "Plain video in mixed batch must still open in standalone playback window")
        XCTAssertFalse(state.navigationState.isCompressWorkspaceActive, "Mixed batch must never divert plain files into compress workspace")
        XCTAssertTrue(state.compressSession.itemsList.isEmpty)
    }

    // MARK: - Virtual Archive Entries, Password Prompts, and Column Forwarding

    func testVirtualArchiveEntryDoubleClickMaterializesReadOnlyInAppPreviewAndRejectsPseudoURLInWorkspace() async throws {
        await StandalonePreviewWindowManager.shared.closeAll()
        defer {
            Task { @MainActor in
                await StandalonePreviewWindowManager.shared.closeAll()
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MillerVirtualDoubleClick-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = PreviewLRUCacheManager(customCacheDir: tempDir.appendingPathComponent("cache"))
        let archiveURL = tempDir.appendingPathComponent("bundle.zip")
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: archiveURL)

        let mockViewer = MockFileViewerHarness()
        let state = AppViewState(fileViewer: mockViewer)
        defer { state.prepareForWindowClose() }

        let virtualURL = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(
            archivePath: archiveURL.path,
            entrySubpath: "docs/manual.txt"
        ))
        let virtualItem = DiskItemInfo(
            virtualName: "manual.txt",
            virtualURL: virtualURL,
            isDirectory: false,
            isArchive: false,
            sizeText: "16 B",
            rawSizeBytes: 16,
            kindText: "Text"
        )

        // Direct openFileWithDefaultApp must reject virtual URLs and report a visible error.
        AppErrorReporter.shared.dismiss()
        XCTAssertFalse(state.openFileWithDefaultApp(url: virtualURL))
        XCTAssertTrue(mockViewer.openedURLs.isEmpty, "Virtual subpath pseudo-URL must never reach FileViewerService")
        XCTAssertTrue(AppErrorReporter.shared.isPresentingError)
        XCTAssertEqual(AppErrorReporter.shared.activeError?.diagnosticCode, "ERR_VIRTUAL_PATH_REJECTED")
        AppErrorReporter.shared.dismiss()

        // Double-click activation on virtual archive entry materializes via customExtractor even when right inspector is hidden/cold.
        let opened = await state.activateExplorerItem(
            virtualItem,
            createAppKitWindow: false,
            cacheManager: cache,
            customExtractor: { _, entryPath, destDir, _ in
                let targetFile = URL(fileURLWithPath: destDir).appendingPathComponent((entryPath as NSString).lastPathComponent)
                try Data("materialized archive content".utf8).write(to: targetFile)
            }
        )
        XCTAssertTrue(opened)
        XCTAssertTrue(mockViewer.openedURLs.isEmpty, "Virtual archive entry activation must never pass host archive or pseudo-URL to external open")
        XCTAssertEqual(StandalonePreviewWindowManager.shared.activeWindowCount, 1)

        let expectedKey = PreviewLRUCacheManager.deterministicCacheKey(archivePath: archiveURL.path, subpath: "docs/manual.txt")
        let activeLeaseCount = await cache.activeLeaseCount(forKey: expectedKey)
        XCTAssertEqual(activeLeaseCount, 1, "Standalone preview window must hold its own cache lease after activation completes")

        await StandalonePreviewWindowManager.shared.closeAll()
        let countAfterClose = await cache.activeLeaseCount(forKey: expectedKey)
        XCTAssertEqual(countAfterClose, 0)
    }

    func testEncryptedVirtualEntryDoubleClickStagesPasswordPromptAndFailureReportsVisibleError() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MillerActivationErrors-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            AppErrorReporter.shared.dismiss()
            try? FileManager.default.removeItem(at: tempDir)
        }

        let cache = PreviewLRUCacheManager(customCacheDir: tempDir.appendingPathComponent("cache"))
        let mockViewer = MockFileViewerHarness(shouldSucceedOnOpen: false)
        let state = AppViewState(fileViewer: mockViewer)
        defer { state.prepareForWindowClose() }

        // 1. Encrypted virtual entry triggers password prompt without external open.
        let encryptedVirtualURL = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(
            archivePath: tempDir.appendingPathComponent("secret.zip").path,
            entrySubpath: "locked.txt"
        ))
        let encryptedItem = DiskItemInfo(
            virtualName: "locked.txt",
            virtualURL: encryptedVirtualURL,
            isDirectory: false,
            isArchive: false,
            sizeText: "8 B",
            rawSizeBytes: 8,
            kindText: "Text"
        )
        let encryptedResult = await state.activateExplorerItem(
            encryptedItem,
            createAppKitWindow: false,
            cacheManager: cache,
            customExtractor: { _, _, _, _ in
                throw ArchiveError.passwordRequired
            }
        )
        XCTAssertFalse(encryptedResult)
        XCTAssertTrue(state.overlayState.showPasswordPrompt, "Encrypted virtual entry activation must stage password prompt")
        XCTAssertTrue(mockViewer.openedURLs.isEmpty)
        state.cancelPasswordPrompt()

        // 2. Physical file open failure surfaces visible error via AppErrorReporter and statusMessage.
        let existingFile = tempDir.appendingPathComponent("fail_open.txt")
        try Data("test".utf8).write(to: existingFile)
        let failItem = DiskItemInfo(url: existingFile, isDirectory: false)
        AppErrorReporter.shared.dismiss()

        let openResult = await state.activateExplorerItem(failItem, createAppKitWindow: false)
        XCTAssertFalse(openResult)
        XCTAssertEqual(mockViewer.openedURLs.count, 1)
        XCTAssertTrue(AppErrorReporter.shared.isPresentingError, "Failed open must trigger visible error sheet presentation")
        XCTAssertEqual(AppErrorReporter.shared.activeError?.diagnosticCode, "ERR_FILE_OPEN_FAILED")
        XCTAssertFalse(state.taskState.statusMessage.isEmpty)
    }

    // MARK: - Helpers

    func findContextMenuBridges(in view: NSView) -> [NativeContextMenuBridgeView] {
        var found: [NativeContextMenuBridgeView] = []
        if let bridge = view as? NativeContextMenuBridgeView {
            found.append(bridge)
        }
        for subview in view.subviews {
            found.append(contentsOf: findContextMenuBridges(in: subview))
        }
        return found
    }

    private func makeOffscreenRowHost<V: View>(for view: V) -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(view.frame(width: 260, height: 28)))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
        window.contentView = host
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        modifiers: NSEvent.ModifierFlags = [],
        clickCount: Int,
        windowNumber: Int
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: clickCount,
                pressure: 1.0
            )
        )
    }
}
