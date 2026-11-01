// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import SwiftUI
@testable import TTZipApp
@testable import TTZipPreviewKit
@testable import TTMediaKit
import TTZipCore

@MainActor
final class StandalonePlaybackAndEBookRoutingTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await StandalonePlaybackWindowManager.shared.resetForTesting()
    }

    override func tearDown() async throws {
        await StandalonePlaybackWindowManager.shared.resetForTesting()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeKeyEvent(
        keyCode: UInt16,
        windowNumber: Int = 0,
        modifiers: NSEvent.ModifierFlags = [],
        characters: String = ""
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func stageTestVideoInCache(
        key: String,
        filename: String,
        subpath: String,
        archivePath: String = "/tmp/archive.zip",
        byteCount: Int = 256,
        cacheManager: PreviewLRUCacheManager = .shared
    ) async throws -> (item: ImmersiveMediaItem, url: URL, lease: PreviewCacheLease) {
        let consumerID = UUID()
        let reservation = try await cacheManager.acquireStagingReservation(
            forKey: key, filename: filename, estimatedBytes: Int64(byteCount),
            consumerID: consumerID, pinActive: true
        )
        try Data(repeating: 0x42, count: byteCount).write(to: reservation.targetURL)
        let verifiedURL = try await cacheManager.resolveAndRegisterExtractedPreview(
            forKey: key, filename: filename, subpath: subpath,
            pinActive: true, consumerID: consumerID, reservationID: reservation.id
        )
        let resolvedURL = try XCTUnwrap(verifiedURL)
        let lease = await cacheManager.acquireLease(forKey: key, consumerID: consumerID)
        let item = ImmersiveMediaItem(
            url: resolvedURL, name: filename,
            sourceArchivePath: archivePath, archiveSubpath: subpath, resourceCacheKey: key
        )
        return (item, resolvedURL, lease)
    }

    private func makeEPUBController(windowNumber: Int, totalPagesInChapter: Int = 4) -> EPUBPaginationController {
        let controller = EPUBPaginationController(initialChapterIndex: 0, totalChapters: 2, readingDirection: .leftToRight)
        controller.didSynchronizeWebViewPagination(
            chapterIndex: 0, pageIndex: 0, totalPages: totalPagesInChapter,
            anchorBlockIndex: 0, anchorCharOffset: 0, readingDirectionRaw: "ltr"
        )
        let instanceID = controller.instanceID
        controller.onRequestRestoreReaderFocus = {
            TTPreviewKeyboardOwnershipCoordinator.shared.markSessionFocused(instanceID: instanceID)
        }
        TTPreviewKeyboardOwnershipCoordinator.shared.registerOrUpdateSession(
            instanceID: instanceID, windowNumber: windowNumber,
            ownsHorizontalArrowKeys: true, isDOMTextInputOrIMEActive: false, markFocused: true,
            onHorizontalArrowKey: { [weak controller] isRightArrow in
                guard let controller else { return false }
                _ = controller.handleHorizontalArrow(isRightArrow: isRightArrow)
                return true
            }
        )
        return controller
    }

    // MARK: - Priority 1 (Feedback ⑩): E-Book Keyboard Ownership & Focus Handoff

    func testEBookHorizontalKeyPolicyNeverUsesLegacyNotVideoRule() {
        let dummyEPUB = EPUBBookModel(
            url: URL(fileURLWithPath: "/tmp/book.epub"), title: "Book", chapters: [], extractDir: URL(fileURLWithPath: "/tmp")
        )
        let dummyEBook = EBookMetadata(
            url: URL(fileURLWithPath: "/tmp/book.mobi"), title: "Book", formatName: "MOBI",
            fileSizeDescription: "1 KB", excerptText: "", coverImage: nil
        )
        XCTAssertTrue(TTMediaPreviewType.epubBook(dummyEPUB).ownsHorizontalNavigationKeys)
        XCTAssertTrue(TTMediaPreviewType.ebook(dummyEBook).ownsHorizontalNavigationKeys)
        XCTAssertTrue(TTMediaPreviewType.video(URL(fileURLWithPath: "/tmp/clip.mp4")).ownsHorizontalNavigationKeys)
        XCTAssertFalse(TTMediaPreviewType.image(NSImage()).ownsHorizontalNavigationKeys)

        XCTAssertTrue(TTPreviewHorizontalKeyPolicy.ownsHorizontalArrowKeys(fileName: "book.epub"))
        XCTAssertTrue(TTPreviewHorizontalKeyPolicy.ownsHorizontalArrowKeys(fileName: "novel.mobi"))
        XCTAssertTrue(TTPreviewHorizontalKeyPolicy.ownsHorizontalArrowKeys(fileName: "kindle.azw3"))
        XCTAssertFalse(TTPreviewHorizontalKeyPolicy.ownsHorizontalArrowKeys(fileName: "photo.png"))
        XCTAssertTrue(TTPreviewHorizontalKeyPolicy.ownsHorizontalArrowKeys(fileName: "clip.mp4"))
    }

    func testEPUBOpenRoutesLeftRightArrowsToInBookPaginationInsteadOfFileSwitching() {
        let windowNumber = 9100
        let controller = makeEPUBController(windowNumber: windowNumber, totalPagesInChapter: 4)
        defer {
            TTPreviewKeyboardOwnershipCoordinator.shared.unregisterSession(instanceID: controller.instanceID)
        }

        XCTAssertFalse(
            TTPreviewHorizontalKeyPolicy.shouldOuterBrowserInterceptHorizontalArrow(
                keyCode: 124,
                eventWindowNumber: windowNumber,
                hostWindowNumber: windowNumber,
                previewType: nil,
                fileName: "philosophy.epub"
            )
        )

        let rightDisposition = TTPreviewKeyboardOwnershipCoordinator.shared.performHorizontalArrowStepIfOwned(
            isRightArrow: true,
            windowNumber: windowNumber
        )
        XCTAssertEqual(rightDisposition, .consumedByPreviewOwner)
        XCTAssertEqual(controller.currentPageIndex, 1)

        var outerFileSwitchCount = 0
        if let rightEvent = makeKeyEvent(keyCode: 124, windowNumber: windowNumber) {
            let disposition = TTPreviewKeyboardOwnershipCoordinator.shared.handleOrBlockOuterHorizontalArrow(
                event: rightEvent
            )
            if disposition == .passThrough {
                outerFileSwitchCount += 1
            }
        }
        XCTAssertEqual(controller.currentPageIndex, 2)
        XCTAssertEqual(outerFileSwitchCount, 0)

        let leftDisposition = TTPreviewKeyboardOwnershipCoordinator.shared.performHorizontalArrowStepIfOwned(
            isRightArrow: false, windowNumber: windowNumber
        )
        XCTAssertEqual(leftDisposition, .consumedByPreviewOwner)
        XCTAssertEqual(controller.currentPageIndex, 1)
        XCTAssertEqual(outerFileSwitchCount, 0)
    }

    func testClickingFileListReturnsHorizontalArrowsToFileNavigation() {
        let windowNumber = 9101
        let controller = makeEPUBController(windowNumber: windowNumber, totalPagesInChapter: 5)
        defer {
            TTPreviewKeyboardOwnershipCoordinator.shared.unregisterSession(instanceID: controller.instanceID)
            TTPreviewHorizontalKeyPolicy.releaseFileListKeyboardFocus(windowNumber: windowNumber)
        }

        let initialDisposition = TTPreviewKeyboardOwnershipCoordinator.shared.performHorizontalArrowStepIfOwned(
            isRightArrow: true, windowNumber: windowNumber
        )
        XCTAssertEqual(initialDisposition, .consumedByPreviewOwner)
        XCTAssertEqual(controller.currentPageIndex, 1)

        FinderMillerColumnsView.returnKeyboardFocusToFileList(windowNumber: windowNumber)

        let ownershipAfterListClick = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(windowNumber: windowNumber)
        XCTAssertFalse(ownershipAfterListClick.ownsHorizontalArrowKeys, "Clicking the file list must return horizontal arrow ownership to file navigation")
        XCTAssertEqual(ownershipAfterListClick.focusSource, .none)

        let listArrowDisposition = TTPreviewKeyboardOwnershipCoordinator.shared.performHorizontalArrowStepIfOwned(
            isRightArrow: true, windowNumber: windowNumber
        )
        XCTAssertEqual(listArrowDisposition, .passThrough)
        let outerFileNavigationSteps = (listArrowDisposition == .passThrough) ? 1 : 0
        XCTAssertEqual(outerFileNavigationSteps, 1)
        XCTAssertEqual(controller.currentPageIndex, 1, "EPUB page index must not advance while file list holds keyboard focus")
    }

    func testReaderToolbarOperationsRestoreInBookPageTurningAfterFileListClick() {
        let windowNumber = 9102
        let controller = makeEPUBController(windowNumber: windowNumber, totalPagesInChapter: 5)
        defer {
            TTPreviewKeyboardOwnershipCoordinator.shared.unregisterSession(instanceID: controller.instanceID)
            TTPreviewHorizontalKeyPolicy.releaseFileListKeyboardFocus(windowNumber: windowNumber)
        }

        FinderMillerColumnsView.returnKeyboardFocusToFileList(windowNumber: windowNumber)
        XCTAssertFalse(TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(windowNumber: windowNumber).ownsHorizontalArrowKeys)

        TTPreviewKeyboardOwnershipCoordinator.shared.notifyToolbarInteraction(instanceID: controller.instanceID)
        let ownershipAfterToolbarOpen = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(windowNumber: windowNumber)
        XCTAssertTrue(ownershipAfterToolbarOpen.ownsHorizontalArrowKeys)
        XCTAssertEqual(ownershipAfterToolbarOpen.focusSource, .toolbarOrPopover)

        FinderMillerColumnsView.returnKeyboardFocusToFileList(windowNumber: windowNumber)
        XCTAssertFalse(TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(windowNumber: windowNumber).ownsHorizontalArrowKeys)
        controller.onRequestRestoreReaderFocus?()

        let ownershipAfterRestore = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(windowNumber: windowNumber)
        XCTAssertTrue(ownershipAfterRestore.ownsHorizontalArrowKeys, "Reader toolbar operation must restore horizontal arrow ownership to the EPUB reader")
        XCTAssertEqual(ownershipAfterRestore.focusSource, .readingArea)
        XCTAssertEqual(ownershipAfterRestore.ownerInstanceID, controller.instanceID)

        let stepDisposition = TTPreviewKeyboardOwnershipCoordinator.shared.performHorizontalArrowStepIfOwned(
            isRightArrow: true, windowNumber: windowNumber
        )
        XCTAssertEqual(stepDisposition, .consumedByPreviewOwner)
        XCTAssertEqual(controller.currentPageIndex, 1)

        FinderMillerColumnsView.returnKeyboardFocusToFileList(windowNumber: windowNumber)
        XCTAssertFalse(TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(windowNumber: windowNumber).ownsHorizontalArrowKeys)
        TTPreviewHorizontalKeyPolicy.releaseFileListKeyboardFocus(windowNumber: windowNumber)
        XCTAssertTrue(TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(windowNumber: windowNumber).ownsHorizontalArrowKeys)
    }

    func testTextInputIMEAndCommandModifiersYieldHorizontalArrowInterception() {
        let windowNumber = 9103
        let controller = makeEPUBController(windowNumber: windowNumber, totalPagesInChapter: 3)
        defer { TTPreviewKeyboardOwnershipCoordinator.shared.unregisterSession(instanceID: controller.instanceID) }

        XCTAssertFalse(
            TTPreviewHorizontalKeyPolicy.shouldOuterBrowserInterceptHorizontalArrow(
                keyCode: 124, modifiers: [.command], eventWindowNumber: windowNumber,
                hostWindowNumber: windowNumber, previewType: nil, fileName: "book.epub"
            )
        )

        TTPreviewKeyboardOwnershipCoordinator.shared.updateSessionTextInputState(
            instanceID: controller.instanceID, isDOMTextInputOrIMEActive: true
        )
        let imeDisposition = TTPreviewKeyboardOwnershipCoordinator.shared.performHorizontalArrowStepIfOwned(
            isRightArrow: true, windowNumber: windowNumber
        )
        XCTAssertEqual(imeDisposition, .yieldToTextInput)
        XCTAssertEqual(controller.currentPageIndex, 0)
    }

    func testMultiWindowEBookAndImageGalleryKeyboardIsolation() {
        let epubWindow = 9201
        let imageWindow = 9202
        let controller = makeEPUBController(windowNumber: epubWindow, totalPagesInChapter: 4)
        defer { TTPreviewKeyboardOwnershipCoordinator.shared.unregisterSession(instanceID: controller.instanceID) }

        let epubDisposition = TTPreviewKeyboardOwnershipCoordinator.shared.performHorizontalArrowStepIfOwned(
            isRightArrow: true, windowNumber: epubWindow
        )
        let imageShouldIntercept = TTPreviewHorizontalKeyPolicy.shouldOuterBrowserInterceptHorizontalArrow(
            keyCode: 124, eventWindowNumber: imageWindow, hostWindowNumber: imageWindow,
            previewType: .image(NSImage()), fileName: "windowB.png"
        )
        XCTAssertEqual(epubDisposition, .consumedByPreviewOwner)
        XCTAssertEqual(controller.currentPageIndex, 1)
        XCTAssertTrue(imageShouldIntercept)
    }

    // MARK: - Priority 2 (Feedback ②): Standalone Playback Window & 5 Lifecycles

    @discardableResult
    private func openHeadlessSession(
        _ item: ImmersiveMediaItem,
        originWindowID: UUID = UUID(),
        selectedItem: DiskItemInfo? = nil,
        cacheManager: PreviewLRUCacheManager = .shared
    ) async -> StandalonePlaybackSessionState? {
        await StandalonePlaybackWindowManager.shared.openOrFocus(
            item: item,
            originBrowserWindowID: originWindowID,
            originSelectedItem: selectedItem,
            createAppKitWindow: false,
            cacheManager: cacheManager
        )
    }

    func testRepeatedFullWindowTriggerFocusesExistingStandaloneWindowWithoutDuplicateOrRestart() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let item = ImmersiveMediaItem(url: URL(fileURLWithPath: "/tmp/lecture.mp4"), name: "lecture.mp4")
        let originWindowID = UUID()

        let firstOpt = await openHeadlessSession(item, originWindowID: originWindowID)
        let first = try XCTUnwrap(firstOpt)
        XCTAssertEqual(manager.lastLifecycleEvent, .openedNewWindow)

        let secondOpt = await openHeadlessSession(item, originWindowID: originWindowID)
        let second = try XCTUnwrap(secondOpt)
        XCTAssertEqual(manager.lastLifecycleEvent, .focusedExistingWindow)
        XCTAssertEqual(first.sessionID, second.sessionID)
        XCTAssertEqual(second.focusRequestCount, 2)
    }

    func testStandalonePlaybackLifecycle1ClosePlayerStopsAndReleasesLeases() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let stagedKey = "movie_cache_key_\(UUID().uuidString)"
        let staged = try await stageTestVideoInCache(
            key: stagedKey,
            filename: "movie.mp4",
            subpath: "clips/movie.mp4"
        )

        let opened = await openHeadlessSession(staged.item)
        XCTAssertNotNil(opened)
        await PreviewLRUCacheManager.shared.releaseLease(staged.lease)

        let activeLeasesDuringPlay = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: stagedKey)
        XCTAssertEqual(activeLeasesDuringPlay, 1)
        XCTAssertTrue(manager.hasActivePlaybackSession)
        XCTAssertNotNil(manager.standaloneCacheLease)

        await manager.closeStandaloneWindowAsync(stopPlayback: true)

        let activeLeasesAfterClose = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: stagedKey)
        XCTAssertEqual(activeLeasesAfterClose, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
        XCTAssertFalse(manager.hasActivePlaybackSession)
        XCTAssertNil(manager.activeSession)
        XCTAssertNil(manager.standaloneCacheLease)
        XCTAssertEqual(manager.lastLifecycleEvent, .closedStandalonePlayer)
    }

    private func makeDiskItem(name: String, path: String) -> DiskItemInfo {
        DiskItemInfo(
            path: path, name: name, displayName: name,
            isDirectory: false, isArchive: false, sizeText: "1 KB", rawSizeBytes: 1024, kindText: "File"
        )
    }

    func testStandalonePlaybackLifecycle2ReturnToOriginPreviewRestoresWithoutRestart() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let originVM = AppViewState()
        BrowserWindowRegistry.shared.register(originVM)
        defer { BrowserWindowRegistry.shared.unregister(id: originVM.windowID) }

        let videoDiskItem = makeDiskItem(name: "seminar.mp4", path: "/tmp/seminar.mp4")
        let otherDiskItem = makeDiskItem(name: "notes.txt", path: "/tmp/notes.txt")
        originVM.selectionState.select(videoDiskItem)

        let mediaItem = ImmersiveMediaItem(url: URL(fileURLWithPath: "/tmp/seminar.mp4"), name: "seminar.mp4")
        await openHeadlessSession(mediaItem, originWindowID: originVM.windowID, selectedItem: videoDiskItem)

        originVM.selectionState.select(otherDiskItem)
        XCTAssertEqual(originVM.selectionState.selectedDiskItem?.path, otherDiskItem.path)
        XCTAssertTrue(manager.hasActivePlaybackSession)

        let returned = await manager.returnToOriginPreview()
        XCTAssertTrue(returned)
        XCTAssertEqual(originVM.selectionState.selectedDiskItem?.path, videoDiskItem.path)
        XCTAssertFalse(originVM.overlayState.showImmersiveMediaBrowser)
        XCTAssertFalse(manager.hasActivePlaybackSession)
        XCTAssertEqual(manager.pendingHandoffCount, 0)
        XCTAssertEqual(manager.lastLifecycleEvent, .returnedToOriginPreview)
    }

    func testStandalonePlaybackLifecycle3And4OriginWindowCloseAndSelectionChangePreservePlayback() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let stagedKey = "virtual_video_hash_\(UUID().uuidString)"
        let staged = try await stageTestVideoInCache(
            key: stagedKey,
            filename: "archive_clip.mp4",
            subpath: "clips/archive_clip.mp4"
        )

        let originVM = AppViewState()
        BrowserWindowRegistry.shared.register(originVM)
        let videoDiskItem = makeDiskItem(
            name: "archive_clip.mp4",
            path: "ttzip:///tmp/test.zip?subpath=clips/archive_clip.mp4"
        )
        originVM.selectionState.select(videoDiskItem)

        let opened = await openHeadlessSession(
            staged.item,
            originWindowID: originVM.windowID,
            selectedItem: videoDiskItem
        )
        XCTAssertNotNil(opened)

        // Lifecycle 4: Origin preview switches to another file and releases its inspector lease.
        let secondItem = makeDiskItem(name: "readme.md", path: "/tmp/readme.md")
        originVM.selectionState.select(secondItem)
        await PreviewLRUCacheManager.shared.releaseLease(staged.lease)

        let countAfterInspectorRelease = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: stagedKey)
        XCTAssertEqual(countAfterInspectorRelease, 1)
        XCTAssertTrue(manager.hasActivePlaybackSession)
        XCTAssertEqual(manager.activeSession?.hasOriginSelectionChanged, true)
        XCTAssertEqual(manager.lastLifecycleEvent, .originSelectionChanged)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staged.url.path),
            "Acquire-Before-Release standalone lease must keep extracted archive video alive after inspector switches file"
        )

        // Lifecycle 3: Origin browser window closes completely.
        originVM.prepareForWindowClose()
        BrowserWindowRegistry.shared.unregister(id: originVM.windowID)

        XCTAssertTrue(manager.hasActivePlaybackSession)
        XCTAssertEqual(manager.activeSession?.isOriginWindowClosed, true)
        XCTAssertEqual(manager.lastLifecycleEvent, .originBrowserWindowClosed)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staged.url.path),
            "Standalone player lease must survive origin browser window close"
        )

        await manager.closeStandaloneWindowAsync(stopPlayback: true)
        let countAfterStandaloneClose = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: stagedKey)
        XCTAssertEqual(countAfterStandaloneClose, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
    }

    func testStandalonePlaybackLifecycle5SystemFullScreenActsOnStandaloneWindowInPlace() async {
        let manager = StandalonePlaybackWindowManager.shared
        let item = ImmersiveMediaItem(url: URL(fileURLWithPath: "/tmp/keynote.mp4"), name: "keynote.mp4")
        await openHeadlessSession(item)

        manager.toggleSystemFullScreen()
        XCTAssertEqual(manager.lastLifecycleEvent, .enteredSystemFullScreen)
        XCTAssertEqual(manager.activeSession?.isInSystemFullScreen, true)

        manager.toggleSystemFullScreen()
        XCTAssertEqual(manager.lastLifecycleEvent, .exitedSystemFullScreen)
        XCTAssertEqual(manager.activeSession?.isInSystemFullScreen, false)
        XCTAssertTrue(manager.hasActivePlaybackSession)
    }

    // MARK: - Requirement ③: Stress & Edge-Case Lifecycle Scenarios

    func testRapidOpenThenCloseRollsBackLeaseAndDoesNotCommitWindowState() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let stagedKey = "rapid_open_close_\(UUID().uuidString)"
        let staged = try await stageTestVideoInCache(
            key: stagedKey,
            filename: "rapid.mp4",
            subpath: "clips/rapid.mp4"
        )

        manager.onWillCommitAcquiredLeaseHook = {
            manager.closeStandaloneWindow(stopPlayback: true)
        }
        let result = await openHeadlessSession(staged.item)
        manager.onWillCommitAcquiredLeaseHook = nil

        XCTAssertNil(result, "Expired open request must not commit activeSession")
        XCTAssertNil(manager.activeSession)
        XCTAssertNil(manager.standaloneCacheLease)

        await PreviewLRUCacheManager.shared.releaseLease(staged.lease, reclaimImmediatelyIfIdle: true)
        let remainingLeases = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: stagedKey)
        XCTAssertEqual(remainingLeases, 0, "Rolled-back open request must release its acquired cache lease")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
    }

    func testReturnToOriginThenImmediateReopenAnotherVideoReleasesOldHandoffLeaseWithoutDroppingNewLease() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let originVM = AppViewState()
        BrowserWindowRegistry.shared.register(originVM)
        defer { BrowserWindowRegistry.shared.unregister(id: originVM.windowID) }

        let keyA = "handoff_video_a_\(UUID().uuidString)"
        let keyB = "handoff_video_b_\(UUID().uuidString)"
        let stagedA = try await stageTestVideoInCache(key: keyA, filename: "a.mp4", subpath: "a.mp4")
        let stagedB = try await stageTestVideoInCache(key: keyB, filename: "b.mp4", subpath: "b.mp4")

        let diskItemA = makeDiskItem(name: "a.mp4", path: "ttzip:///tmp/ab.zip?subpath=a.mp4")
        originVM.selectionState.select(diskItemA)

        await openHeadlessSession(stagedA.item, originWindowID: originVM.windowID, selectedItem: diskItemA)
        await PreviewLRUCacheManager.shared.releaseLease(stagedA.lease)
        let countABeforeReturn = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: keyA)
        XCTAssertEqual(countABeforeReturn, 1)

        // Return video A to origin preview and immediately open video B in standalone window.
        let returnedA = await manager.returnToOriginPreview()
        XCTAssertTrue(returnedA)
        let openedB = await openHeadlessSession(stagedB.item, originWindowID: originVM.windowID)
        XCTAssertNotNil(openedB)
        await PreviewLRUCacheManager.shared.releaseLease(stagedB.lease)

        // Video A's old standalone lease was released by handoff completion; only origin bridge lease holds keyA.
        let countADuringB = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: keyA)
        let countBDuringB = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: keyB)
        XCTAssertEqual(countADuringB, 1, "Origin browser restored lease holds keyA while old standalone lease is released")
        XCTAssertEqual(countBDuringB, 1, "New standalone session on keyB must keep its lease intact")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedA.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedB.url.path))

        // Consume origin bridge lease for (originVM.windowID, keyA) and close standalone player for keyB.
        let consumed = await manager.consumeOriginRestoredLease(
            forWindowID: originVM.windowID,
            key: keyA,
            reclaimImmediatelyIfIdle: true
        )
        XCTAssertTrue(consumed)
        await manager.closeStandaloneWindowAsync(stopPlayback: true)

        let finalCountA = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: keyA)
        let finalCountB = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: keyB)
        XCTAssertEqual(finalCountA, 0)
        XCTAssertEqual(finalCountB, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedA.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedB.url.path))
    }

    func testFailedLeaseAcquisitionAndFailedHandoffReleaseResourcesAndDoNotCommitWindowState() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let missingKey = "missing_or_evicted_key_\(UUID().uuidString)"
        let missingItem = ImmersiveMediaItem(
            url: URL(fileURLWithPath: "/tmp/nonexistent_\(missingKey).mp4"),
            name: "missing.mp4",
            sourceArchivePath: "/tmp/missing.zip",
            archiveSubpath: "missing.mp4",
            resourceCacheKey: missingKey
        )

        let failedOpen = await openHeadlessSession(missingItem)
        XCTAssertNil(failedOpen, "Failed cache lease acquisition must not commit standalone window state")
        XCTAssertNil(manager.activeSession)
        XCTAssertEqual(manager.lastLifecycleEvent, .leaseAcquisitionFailed)
        let missingLeaseCount = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: missingKey)
        XCTAssertEqual(missingLeaseCount, 0)

        // Now test explicit handoff failure path: begin handoff and fail takeover -> must release standalone lease.
        let stagedKey = "handoff_fail_key_\(UUID().uuidString)"
        let staged = try await stageTestVideoInCache(key: stagedKey, filename: "fail.mp4", subpath: "fail.mp4")
        await openHeadlessSession(staged.item)
        await PreviewLRUCacheManager.shared.releaseLease(staged.lease)

        let handoffSession = try XCTUnwrap(manager.beginOriginPreviewHandoff())
        let handoffID = try XCTUnwrap(handoffSession.handoffID)
        XCTAssertEqual(manager.pendingHandoffCount, 1)
        await manager.failOriginPreviewHandoff(handoffID: handoffID)

        XCTAssertEqual(manager.pendingHandoffCount, 0)
        XCTAssertEqual(manager.lastLifecycleEvent, .handoffFailed)
        let countAfterFailedHandoff = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: stagedKey)
        XCTAssertEqual(countAfterFailedHandoff, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
    }

    func testCacheEvictionPressureProtectsStandaloneVideoAndReclaimsAfterClose() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipW1EvictionStress_\(UUID().uuidString)", isDirectory: true)
        let customCache = PreviewLRUCacheManager(
            customCacheDir: tempCacheDir, maxStagedFiles: 2, maxCacheSizeBytesOverride: 2_048
        )
        let videoKey = "eviction_protected_video"
        let stagedVideo = try await stageTestVideoInCache(
            key: videoKey, filename: "protected.mp4", subpath: "protected.mp4",
            byteCount: 900, cacheManager: customCache
        )

        let opened = await openHeadlessSession(stagedVideo.item, cacheManager: customCache)
        XCTAssertNotNil(opened)
        await customCache.releaseLease(stagedVideo.lease)

        // Stage 3 unleased entries exceeding both maxEntries (2) and maxBytes (2048).
        for idx in 1...3 {
            let stagedPressure = try await stageTestVideoInCache(
                key: "pressure_item_\(idx)", filename: "other_\(idx).bin",
                subpath: "other_\(idx).bin", byteCount: 900, cacheManager: customCache
            )
            await customCache.releaseLease(stagedPressure.lease)
        }

        let activeLeasesUnderPressure = await customCache.activeLeaseCount(forKey: videoKey)
        XCTAssertEqual(activeLeasesUnderPressure, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stagedVideo.url.path),
            "Standalone video lease must prevent LRU cache eviction under byte and entry count pressure"
        )

        await manager.closeStandaloneWindowAsync(stopPlayback: true)
        let activeLeasesAfterClose = await customCache.activeLeaseCount(forKey: videoKey)
        XCTAssertEqual(activeLeasesAfterClose, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedVideo.url.path))
        await customCache.purgeAll()
    }

    func testCrossWindowBridgeLeaseIsolationAndMidAcquisitionWindowCloseRollback() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let windowA = AppViewState()
        let windowB = AppViewState()
        let windowC = AppViewState()
        for vm in [windowA, windowB, windowC] { BrowserWindowRegistry.shared.register(vm) }
        defer { for vm in [windowA, windowB, windowC] { BrowserWindowRegistry.shared.unregister(id: vm.windowID) } }

        let sharedKey = "shared_cross_window_video_\(UUID().uuidString)"
        let staged = try await stageTestVideoInCache(key: sharedKey, filename: "shared.mp4", subpath: "shared.mp4")
        let diskItem = makeDiskItem(name: "shared.mp4", path: "ttzip:///tmp/archive.zip?subpath=shared.mp4")

        // 1. Both windowA and windowB return the same video and hold independent bridge leases for sharedKey.
        for targetVM in [windowA, windowB] {
            await openHeadlessSession(staged.item, originWindowID: targetVM.windowID, selectedItem: diskItem)
            let returned = await manager.returnToOriginPreview()
            XCTAssertTrue(returned)
        }
        await PreviewLRUCacheManager.shared.releaseLease(staged.lease)

        XCTAssertTrue(manager.hasOriginRestoredLease(forWindowID: windowA.windowID, key: sharedKey))
        XCTAssertTrue(manager.hasOriginRestoredLease(forWindowID: windowB.windowID, key: sharedKey))
        let countBothHolding = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: sharedKey)
        XCTAssertEqual(countBothHolding, 2, "Both browser windows must hold their own bridge leases")

        // 2. Window A completes takeover -> ONLY Window A's bridge lease is released; Window B remains protected.
        let consumedA = await manager.consumeOriginRestoredLease(
            forWindowID: windowA.windowID, key: sharedKey, reclaimImmediatelyIfIdle: true
        )
        XCTAssertTrue(consumedA)
        XCTAssertFalse(manager.hasOriginRestoredLease(forWindowID: windowA.windowID, key: sharedKey))
        XCTAssertTrue(manager.hasOriginRestoredLease(forWindowID: windowB.windowID, key: sharedKey))
        let countAfterATakeover = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: sharedKey)
        XCTAssertEqual(countAfterATakeover, 1, "Window B's bridge lease must remain active after Window A takes over")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))

        // 3. Window C closing during bridge lease acquisition rolls back the late lease and leaves no orphan.
        await openHeadlessSession(staged.item, originWindowID: windowC.windowID, selectedItem: diskItem)
        manager.onWillCommitOriginBridgeLeaseHook = { targetWindowID, _ in
            BrowserWindowRegistry.shared.unregister(id: targetWindowID)
        }
        let returnedC = await manager.returnToOriginPreview()
        manager.onWillCommitOriginBridgeLeaseHook = nil
        XCTAssertFalse(returnedC, "Return handoff must fail when target window closes during bridge lease acquisition")
        XCTAssertFalse(manager.hasOriginRestoredLease(forWindowID: windowC.windowID))
        let countAfterCRollback = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: sharedKey)
        XCTAssertEqual(countAfterCRollback, 1, "Rolled-back Window C handoff must not leave an orphaned lease")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))

        // 4. Window B closes -> its bridge lease is released and the temporary file is reclaimed.
        await manager.notifyOriginBrowserWindowClosedAsync(windowID: windowB.windowID)
        XCTAssertFalse(manager.hasOriginRestoredLease(forWindowID: windowB.windowID))
        let finalCount = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: sharedKey)
        XCTAssertEqual(finalCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
    }

    func testReplacingExistingOriginBridgeLeaseWhileWindowClosesReleasesNewLeaseWithoutOrphan() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let windowD = AppViewState()
        BrowserWindowRegistry.shared.register(windowD)
        defer { BrowserWindowRegistry.shared.unregister(id: windowD.windowID) }

        let oldKey = "old_bridge_video_\(UUID().uuidString)"
        let newKey = "new_bridge_video_\(UUID().uuidString)"
        let stagedOld = try await stageTestVideoInCache(key: oldKey, filename: "old.mp4", subpath: "old.mp4")
        let stagedNew = try await stageTestVideoInCache(key: newKey, filename: "new.mp4", subpath: "new.mp4")
        let oldDiskItem = makeDiskItem(name: "old.mp4", path: "ttzip:///tmp/archive.zip?subpath=old.mp4")
        let newDiskItem = makeDiskItem(name: "new.mp4", path: "ttzip:///tmp/archive.zip?subpath=new.mp4")

        // 1. Seed windowD with an active previous bridge lease record for oldKey.
        await openHeadlessSession(stagedOld.item, originWindowID: windowD.windowID, selectedItem: oldDiskItem)
        let firstReturned = await manager.returnToOriginPreview()
        XCTAssertTrue(firstReturned)
        await PreviewLRUCacheManager.shared.releaseLease(stagedOld.lease)
        XCTAssertTrue(manager.hasOriginRestoredLease(forWindowID: windowD.windowID, key: oldKey))
        let oldCountBeforeReplace = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: oldKey)
        XCTAssertEqual(oldCountBeforeReplace, 1)

        // 2. Open newKey from windowD and return to origin preview; close windowD while replacing & releasing oldKey's bridge lease.
        await openHeadlessSession(stagedNew.item, originWindowID: windowD.windowID, selectedItem: newDiskItem)
        await PreviewLRUCacheManager.shared.releaseLease(stagedNew.lease)

        var didCloseDuringOldLeaseRelease = false
        manager.onDidReleasePreviousOriginBridgeLeaseHook = { targetWindowID, _ in
            didCloseDuringOldLeaseRelease = true
            BrowserWindowRegistry.shared.unregister(id: targetWindowID)
        }
        let secondReturned = await manager.returnToOriginPreview()
        manager.onDidReleasePreviousOriginBridgeLeaseHook = nil

        XCTAssertTrue(didCloseDuringOldLeaseRelease, "Hook must fire during replacement release of previous bridge lease")
        XCTAssertFalse(secondReturned, "Handoff must abort when window closes while releasing previous bridge lease")
        XCTAssertFalse(manager.hasOriginRestoredLease(forWindowID: windowD.windowID), "Closed window must not receive new bridge lease")

        let finalOldCount = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: oldKey)
        let finalNewCount = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: newKey)
        XCTAssertEqual(finalOldCount, 0, "Previous bridge lease must be released and reclaimed")
        XCTAssertEqual(finalNewCount, 0, "New bridge lease and standalone lease must be rolled back to 0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedOld.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedNew.url.path))
    }

    func testConsecutiveStandaloneWindowHandoffAndStatePreservation() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let originVM = AppViewState()
        BrowserWindowRegistry.shared.register(originVM)
        defer { BrowserWindowRegistry.shared.unregister(id: originVM.windowID) }

        let videoKey = "consecutive_video_\(UUID().uuidString)"
        let staged = try await stageTestVideoInCache(key: videoKey, filename: "round.mp4", subpath: "round.mp4")
        let videoDiskItem = makeDiskItem(name: "round.mp4", path: staged.url.path)
        originVM.selectionState.select(videoDiskItem)

        // 3 consecutive rounds of "open standalone -> focus/verify -> close/return -> sidebar resumes"
        for round in 1...3 {
            let opened = await openHeadlessSession(staged.item, originWindowID: originVM.windowID, selectedItem: videoDiskItem)
            XCTAssertNotNil(opened, "Round \(round) must open standalone session")
            XCTAssertTrue(manager.hasActivePlaybackSession)

            var receivedHandoffSession: StandalonePlaybackSessionState?
            manager.onReturnToOriginPreview = { session in receivedHandoffSession = session }
            let returned = await manager.returnToOriginPreview()
            XCTAssertTrue(returned, "Round \(round) returnToOriginPreview must succeed")
            XCTAssertFalse(manager.hasActivePlaybackSession)

            let handedOff = try XCTUnwrap(receivedHandoffSession)
            XCTAssertEqual(handedOff.originSelectedItem?.path, videoDiskItem.path)
            XCTAssertEqual(handedOff.originBrowserWindowID, originVM.windowID)
            XCTAssertEqual(originVM.selectionState.selectedDiskItem?.path, videoDiskItem.path)
            XCTAssertTrue(originVM.navigationState.isInspectorVisible)

            let consumed = await manager.consumeOriginRestoredLease(
                forWindowID: originVM.windowID, key: videoKey, reclaimImmediatelyIfIdle: false
            )
            XCTAssertTrue(consumed)
        }

        await PreviewLRUCacheManager.shared.releaseLease(staged.lease)
        await manager.closeStandaloneWindowAsync(stopPlayback: true)
    }

    func testStandalonePlayerHandoffRejectsClosedWindowAndRestoresSwitchedSidebar() async throws {
        let manager = StandalonePlaybackWindowManager.shared
        let originVM = AppViewState()
        BrowserWindowRegistry.shared.register(originVM)
        defer { BrowserWindowRegistry.shared.unregister(id: originVM.windowID) }

        let videoKey = "edgecase_video_\(UUID().uuidString)"
        let staged = try await stageTestVideoInCache(key: videoKey, filename: "edge.mp4", subpath: "edge.mp4")
        let videoDiskItem = makeDiskItem(name: "edge.mp4", path: staged.url.path)
        originVM.selectionState.select(videoDiskItem)

        // 1. Origin window closes while standalone player is active -> return must fail without hijacking unrelated window
        let openedForClose = await openHeadlessSession(staged.item, originWindowID: originVM.windowID, selectedItem: videoDiskItem)
        XCTAssertNotNil(openedForClose)
        originVM.prepareForWindowClose()
        BrowserWindowRegistry.shared.unregister(id: originVM.windowID)
        await manager.notifyOriginBrowserWindowClosedAsync(windowID: originVM.windowID)

        let unrelatedVM = AppViewState()
        BrowserWindowRegistry.shared.register(unrelatedVM)
        defer { BrowserWindowRegistry.shared.unregister(id: unrelatedVM.windowID) }

        let returnedOnClosedOrigin = await manager.returnToOriginPreview()
        XCTAssertFalse(returnedOnClosedOrigin, "Return handoff must fail when origin window was closed")
        XCTAssertNil(unrelatedVM.selectionState.selectedDiskItem, "Unrelated window must not be hijacked")
        XCTAssertFalse(manager.hasActivePlaybackSession)

        // 2. Sidebar switched file while player was active -> return restores video without corrupting selection
        let freshOriginVM = AppViewState()
        BrowserWindowRegistry.shared.register(freshOriginVM)
        defer { BrowserWindowRegistry.shared.unregister(id: freshOriginVM.windowID) }

        let openedForSwitch = await openHeadlessSession(staged.item, originWindowID: freshOriginVM.windowID, selectedItem: videoDiskItem)
        XCTAssertNotNil(openedForSwitch)

        let otherFile = makeDiskItem(name: "different.pdf", path: "/tmp/different.pdf")
        freshOriginVM.selectionState.select(otherFile)
        manager.notifyOriginSelectionChanged(windowID: freshOriginVM.windowID, newSelectedItem: otherFile)
        XCTAssertEqual(manager.activeSession?.hasOriginSelectionChanged, true)

        var switchHandoffSession: StandalonePlaybackSessionState?
        manager.onReturnToOriginPreview = { session in switchHandoffSession = session }
        let returnedOnSwitchedSidebar = await manager.returnToOriginPreview()
        XCTAssertTrue(returnedOnSwitchedSidebar)
        XCTAssertEqual(switchHandoffSession?.originSelectedItem?.path, videoDiskItem.path)
        XCTAssertEqual(freshOriginVM.selectionState.selectedDiskItem?.path, videoDiskItem.path)
        XCTAssertFalse(manager.hasActivePlaybackSession)

        await PreviewLRUCacheManager.shared.releaseLease(staged.lease)
        await manager.closeStandaloneWindowAsync(stopPlayback: true)
    }
}
