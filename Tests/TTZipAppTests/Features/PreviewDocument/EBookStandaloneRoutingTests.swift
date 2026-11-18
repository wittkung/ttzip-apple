// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import SwiftUI
@testable import TTZipApp
@testable import TTZipPreviewKit
@testable import TTMediaKit
import TTZipAppCore
import TTZipCore

@MainActor
final class EBookStandaloneRoutingTests: XCTestCase {

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
        XCTAssertTrue(TTPreviewHorizontalKeyPolicy.ownsHorizontalArrowKeys(fileName: "macro_book.xlsm"))
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
}
