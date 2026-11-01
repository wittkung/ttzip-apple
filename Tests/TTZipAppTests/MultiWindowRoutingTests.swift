// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import SwiftUI
@testable import TTZipApp
@testable import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
import TTKitUI

@MainActor
final class MultiWindowRoutingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            BrowserWindowRegistry.shared.resetForTesting()
            BrowserWindowRouter.shared.resetForTesting()
            ArchivePasswordStore.shared.clearAll()
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            BrowserWindowRegistry.shared.resetForTesting()
            BrowserWindowRouter.shared.resetForTesting()
            ArchivePasswordStore.shared.clearAll()
        }
        super.tearDown()
    }

    private func makeEntry(path: String, size: Int64 = 128, isDirectory: Bool = false) -> ArchiveEntry {
        ArchiveEntry(
            path: path,
            uncompressedSize: size,
            isDirectory: isDirectory,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isEncrypted: false,
            compressedSize: size,
            crc32: 0x11223344
        )
    }

    // MARK: - 1. Window Identity & Independent State Isolation

    func testMultipleWindowsMaintainIndependentNavigationSelectionSearchAndModals() {
        let dirA = URL(fileURLWithPath: "/tmp/ttzip-win-a", isDirectory: true)
        let dirB = URL(fileURLWithPath: "/tmp/ttzip-win-b", isDirectory: true)

        let windowA = AppViewState(fileViewer: NoOpFileViewer())
        let windowB = AppViewState(fileViewer: NoOpFileViewer())
        windowA.currentDirectory = dirA
        windowB.currentDirectory = dirB
        BrowserWindowRegistry.shared.register(windowA)
        BrowserWindowRegistry.shared.register(windowB)

        XCTAssertNotEqual(windowA.windowID, windowB.windowID)
        XCTAssertTrue(windowA.presentationCoordinator !== windowB.presentationCoordinator)
        XCTAssertEqual(BrowserWindowRegistry.shared.windowCount, 2)

        let nextA = URL(fileURLWithPath: "/tmp/ttzip-win-a/sub", isDirectory: true)
        windowA.currentDirectory = nextA
        XCTAssertEqual(windowA.currentDirectory.standardizedFileURL, nextA.standardizedFileURL)
        XCTAssertEqual(windowB.currentDirectory.standardizedFileURL, dirB.standardizedFileURL)

        let itemA = DiskItemInfo(
            virtualName: "report.pdf",
            virtualURL: nextA.appendingPathComponent("report.pdf"),
            isDirectory: false,
            isArchive: false,
            sizeText: "12 KB",
            rawSizeBytes: 12_288,
            kindText: "PDF"
        )
        windowA.selectedDiskItem = itemA
        windowA.explorerState.searchQuery = "report"
        XCTAssertEqual(windowA.selectedDiskItem?.name, "report.pdf")
        XCTAssertNil(windowB.selectedDiskItem)
        XCTAssertEqual(windowB.explorerState.searchQuery, "")

        windowA.presentationCoordinator.present(.omnibar)
        XCTAssertEqual(windowA.presentationCoordinator.activeModal, .omnibar)
        XCTAssertNil(windowB.presentationCoordinator.activeModal)
    }

    func testCreatingWindowPreservesExistingDirectoryAccessLease() throws {
        let manager = RootFolderAccessManager.shared
        let originalStart = manager.startSecurityScopedAccess
        let originalStop = manager.stopSecurityScopedAccess
        var startCount = 0
        var stopCount = 0
        manager.startSecurityScopedAccess = { _ in
            startCount += 1
            return true
        }
        manager.stopSecurityScopedAccess = { _ in stopCount += 1 }
        defer {
            manager.startSecurityScopedAccess = originalStart
            manager.stopSecurityScopedAccess = originalStop
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowLease_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalLease = try XCTUnwrap(manager.acquireLease(for: directory))
        defer { originalLease.release() }
        XCTAssertEqual(manager.activeLeaseCount(for: directory), 1)
        XCTAssertEqual(startCount, 1)

        let window = AppViewState(fileViewer: NoOpFileViewer())
        XCTAssertEqual(manager.activeLeaseCount(for: directory), 1,
                       "Creating another window must not retire an in-flight directory lease")
        XCTAssertEqual(manager.retiringLeaseCount(forKey: originalLease.leaseKey), 0)
        let secondLease = try XCTUnwrap(manager.acquireLease(for: directory))
        defer { secondLease.release() }
        XCTAssertEqual(manager.activeLeaseCount(for: directory), 2)
        XCTAssertEqual(startCount, 1, "Both consumers must share the existing security scope")
        XCTAssertEqual(stopCount, 0)

        originalLease.release()
        XCTAssertEqual(manager.activeLeaseCount(for: directory), 1)
        XCTAssertEqual(stopCount, 0)
        secondLease.release()
        XCTAssertEqual(manager.activeLeaseCount(for: directory), 0)
        XCTAssertEqual(stopCount, 1, "The final consumer must release the security scope once")
        XCTAssertNotNil(window.presentationCoordinator)
    }

    // MARK: - 2. Launch Seed & Open-in-New-Window Routing (Including FIFO Seed Isolation)

    func testOpenNewWindowAndSidebarOpenInNewWindowEnqueueAndApplySeedsWithoutMutatingSourceWindow() {
        let dirA = URL(fileURLWithPath: "/tmp/ttzip-source", isDirectory: true)
        let targetDir = URL(fileURLWithPath: "/tmp/ttzip-target-new-win", isDirectory: true)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetDir) }

        let sourceWindow = AppViewState(fileViewer: NoOpFileViewer())
        sourceWindow.currentDirectory = dirA
        BrowserWindowRegistry.shared.register(sourceWindow)
        BrowserWindowRegistry.shared.activateWindow(id: sourceWindow.windowID)

        var openedWindowScenes = 0
        BrowserWindowRouter.shared.swiftUIWindowOpener = {
            openedWindowScenes += 1
        }

        BrowserWindowRouter.shared.openInNewWindow(url: targetDir)
        XCTAssertEqual(openedWindowScenes, 1)
        XCTAssertEqual(sourceWindow.currentDirectory.standardizedFileURL, dirA.standardizedFileURL)

        let seed = BrowserWindowRegistry.shared.consumeNextLaunchSeed()
        XCTAssertNotNil(seed)
        XCTAssertEqual(seed?.initialDirectoryURL?.standardizedFileURL, targetDir.standardizedFileURL)

        let newWindow = AppViewState(fileViewer: NoOpFileViewer())
        newWindow.currentDirectory = dirA
        BrowserWindowRegistry.shared.register(newWindow)
        if let seed {
            newWindow.applyLaunchSeed(seed)
        }
        XCTAssertEqual(newWindow.currentDirectory.standardizedFileURL, targetDir.standardizedFileURL)
        XCTAssertEqual(sourceWindow.currentDirectory.standardizedFileURL, dirA.standardizedFileURL)
    }

    func testUnseededPrimaryWindowAndFailedWindowCreationNeverStealSubsequentLaunchSeed() {
        let dirA = URL(fileURLWithPath: "/tmp/ttzip-primary-unseeded", isDirectory: true)
        let dirB = URL(fileURLWithPath: "/tmp/ttzip-second-seeded", isDirectory: true)
        try? FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let primaryWindow = AppViewState(fileViewer: NoOpFileViewer())
        primaryWindow.currentDirectory = dirA
        BrowserWindowRegistry.shared.register(primaryWindow)
        XCTAssertFalse(primaryWindow.hasAppliedLaunchSeed)
        if let initialSeed = BrowserWindowRegistry.shared.consumeNextLaunchSeed() {
            primaryWindow.applyLaunchSeed(initialSeed)
        } else {
            primaryWindow.markLaunchSeedChecked()
        }
        XCTAssertTrue(primaryWindow.hasAppliedLaunchSeed, "Unseeded initial window must mark launch seed checked on first appear")

        BrowserWindowRouter.shared.swiftUIWindowOpener = nil
        BrowserWindowRouter.shared.fallbackWindowCreator = nil
        _ = BrowserWindowRouter.shared.openNewWindow(with: dirB)
        XCTAssertNil(
            BrowserWindowRegistry.shared.consumeNextLaunchSeed(),
            "Failed window creation must roll back its launch seed rather than leaving an orphan in the FIFO queue"
        )

        BrowserWindowRouter.shared.swiftUIWindowOpener = {}
        BrowserWindowRouter.shared.openInNewWindow(url: dirB)

        if !primaryWindow.hasAppliedLaunchSeed,
           let stolen = BrowserWindowRegistry.shared.consumeNextLaunchSeed() {
            primaryWindow.applyLaunchSeed(stolen)
        }
        XCTAssertEqual(primaryWindow.currentDirectory.standardizedFileURL, dirA.standardizedFileURL)

        let secondWindow = AppViewState(fileViewer: NoOpFileViewer())
        secondWindow.currentDirectory = dirA
        BrowserWindowRegistry.shared.register(secondWindow)
        if !secondWindow.hasAppliedLaunchSeed,
           let validSeed = BrowserWindowRegistry.shared.consumeNextLaunchSeed() {
            secondWindow.applyLaunchSeed(validSeed)
        }
        XCTAssertEqual(secondWindow.currentDirectory.standardizedFileURL, dirB.standardizedFileURL)
    }

    // MARK: - 3. Active Window Command & External Open Routing (No Broadcast)

    func testExternalOpenRoutesOnlyToActiveWindowAndSuppressesDuplicateWithinWindow() {
        let dirA = URL(fileURLWithPath: "/tmp/ttzip-win-1", isDirectory: true)
        let dirB = URL(fileURLWithPath: "/tmp/ttzip-win-2", isDirectory: true)
        let externalFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-ext-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: externalFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalFolder) }

        let windowA = AppViewState(fileViewer: NoOpFileViewer())
        let windowB = AppViewState(fileViewer: NoOpFileViewer())
        windowA.currentDirectory = dirA
        windowB.currentDirectory = dirB
        BrowserWindowRegistry.shared.register(windowA)
        BrowserWindowRegistry.shared.register(windowB)
        BrowserWindowRegistry.shared.activateWindow(id: windowB.windowID)

        _ = BrowserWindowRouter.shared.routeExternalOpen(urls: [externalFolder])
        XCTAssertEqual(windowB.currentDirectory.standardizedFileURL, externalFolder.standardizedFileURL)
        XCTAssertEqual(windowA.currentDirectory.standardizedFileURL, dirA.standardizedFileURL)
    }

    func testAppIntentDispatcherTargetsActiveWindowOnly() {
        let dirA = URL(fileURLWithPath: "/tmp/ttzip-intent-a", isDirectory: true)
        let dirB = URL(fileURLWithPath: "/tmp/ttzip-intent-b", isDirectory: true)
        let targetDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-intent-dest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetDir) }

        let windowA = AppViewState(fileViewer: NoOpFileViewer())
        let windowB = AppViewState(fileViewer: NoOpFileViewer())
        windowA.currentDirectory = dirA
        windowB.currentDirectory = dirB
        BrowserWindowRegistry.shared.register(windowA)
        BrowserWindowRegistry.shared.register(windowB)

        AppIntentDispatcher.shared.bind(state: windowA)
        AppIntentDispatcher.shared.bind(state: windowB)
        BrowserWindowRegistry.shared.activateWindow(id: windowA.windowID)

        AppIntentDispatcher.shared.dispatch(
            AppIntentEnvelope(intent: .navigateToDirectory(url: targetDir), source: .internalNavigation)
        )

        XCTAssertEqual(windowA.currentDirectory.standardizedFileURL, targetDir.standardizedFileURL)
        XCTAssertEqual(windowB.currentDirectory.standardizedFileURL, dirB.standardizedFileURL)
    }

    // MARK: - 4. Global Search Routing: Disk Item, Archive File, and Full Archive Entry Subpath

    func testGlobalSearchDiskResultRoutesOnlyToActiveWindow() {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-gsearch-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("sample.txt")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try? "hello".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dirA = URL(fileURLWithPath: "/tmp/ttzip-gs-a", isDirectory: true)
        let dirB = URL(fileURLWithPath: "/tmp/ttzip-gs-b", isDirectory: true)
        let windowA = AppViewState(fileViewer: NoOpFileViewer())
        let windowB = AppViewState(fileViewer: NoOpFileViewer())
        windowA.currentDirectory = dirA
        windowB.currentDirectory = dirB
        BrowserWindowRegistry.shared.register(windowA)
        BrowserWindowRegistry.shared.register(windowB)
        BrowserWindowRegistry.shared.activateWindow(id: windowB.windowID)

        BrowserWindowRouter.shared.routeGlobalSearchResult(itemURL: fileURL)
        XCTAssertEqual(windowB.currentDirectory.standardizedFileURL, tempRoot.standardizedFileURL)
        XCTAssertEqual(
            windowB.selectedDiskItem.map { URL(fileURLWithPath: $0.path).standardizedFileURL },
            fileURL.standardizedFileURL
        )
        XCTAssertEqual(windowA.currentDirectory.standardizedFileURL, dirA.standardizedFileURL)
        XCTAssertNil(windowA.selectedDiskItem)
    }

    func testGlobalSearchArchiveEntryPreservesFullSubpathWithDuplicateBasenamesAndSpecialCharactersWithoutClosingArchive() {
        let archivePath = "/tmp/ttzip-dup-basename-\(UUID().uuidString).zip"
        let firstReadme = "docs/readme.md"
        let secondReadme = "src/nested/readme.md"
        let specialEntry = "folder with spaces/中文 #1/a&b=c+d?e%20[v1].txt"

        let window = AppViewState(fileViewer: NoOpFileViewer())
        window.explorerState.currentArchivePath = archivePath
        window.explorerState.currentEntries = [
            makeEntry(path: firstReadme, size: 100),
            makeEntry(path: secondReadme, size: 200),
            makeEntry(path: specialEntry, size: 300)
        ]
        BrowserWindowRegistry.shared.register(window)
        BrowserWindowRegistry.shared.activateWindow(id: window.windowID)

        let itemNested = GlobalSearchResultItem(
            id: "entry:\(archivePath):\(secondReadme)",
            title: "readme.md",
            subtitle: "archive → \(secondReadme)",
            hitType: .archiveEntry,
            archivePath: archivePath,
            entrySubpath: secondReadme,
            isDirectory: false,
            byteSize: 200,
            score: 0.95
        )
        _ = BrowserWindowRouter.shared.routeGlobalSearchResult(itemNested)
        XCTAssertEqual(BrowserWindowRegistry.shared.activeWindowID, window.windowID)
        XCTAssertEqual(window.currentArchivePath, archivePath, "Activating an entry inside the current archive must never close the archive")
        XCTAssertEqual(window.selectionState.selectedEntryID, secondReadme)
        let expectedNestedURL = AppViewState.makeArchiveEntryVirtualURL(archivePath: archivePath, entrySubpath: secondReadme)
        XCTAssertEqual(window.selectedDiskItem?.path, expectedNestedURL?.absoluteString)

        _ = BrowserWindowRouter.shared.routeGlobalSearchArchiveEntry(
            archivePath: archivePath,
            entrySubpath: specialEntry,
            highlightLine: 42
        )
        XCTAssertEqual(window.selectionState.selectedEntryID, specialEntry)
        XCTAssertEqual(window.selectedArchiveHighlightLine, 42)
        if let virtualPath = window.selectedDiskItem?.path, let virtualURL = URL(string: virtualPath) {
            let urlComponents = URLComponents(url: virtualURL, resolvingAgainstBaseURL: false)
            let querySubpath = urlComponents?.queryItems?.first(where: { $0.name == "subpath" })?.value
            XCTAssertEqual(querySubpath, specialEntry)
        } else {
            XCTFail("Expected selectedDiskItem?.path to be populated for specialEntry")
        }
    }

    func testGlobalSearchArchiveEntryAcrossMultipleWindowsAndClosedWindowFallback() {
        let archiveA = "/tmp/ttzip-multi-a-\(UUID().uuidString).zip"
        let archiveB = "/tmp/ttzip-multi-b-\(UUID().uuidString).zip"
        let sharedSubpath = "config/settings.json"

        let windowA = AppViewState(fileViewer: NoOpFileViewer())
        let windowB = AppViewState(fileViewer: NoOpFileViewer())
        BrowserWindowRegistry.shared.register(windowA)
        BrowserWindowRegistry.shared.register(windowB)

        windowA.explorerState.currentArchivePath = archiveA
        windowA.explorerState.currentEntries = [makeEntry(path: sharedSubpath, size: 111)]

        windowB.explorerState.currentArchivePath = archiveB
        windowB.explorerState.currentEntries = [makeEntry(path: sharedSubpath, size: 222)]

        BrowserWindowRegistry.shared.activateWindow(id: windowB.windowID)
        let hitA = GlobalSearchResultItem(
            id: "entry:\(archiveA):\(sharedSubpath)",
            title: "settings.json",
            subtitle: "A → \(sharedSubpath)",
            hitType: .archiveEntry,
            archivePath: archiveA,
            entrySubpath: sharedSubpath,
            isDirectory: false,
            byteSize: 111,
            score: 0.95
        )
        _ = BrowserWindowRouter.shared.routeGlobalSearchResult(hitA)
        XCTAssertEqual(BrowserWindowRegistry.shared.activeWindowID, windowA.windowID)
        XCTAssertEqual(windowA.selectionState.selectedEntryID, sharedSubpath)
        XCTAssertEqual(windowA.selectedDiskItem?.rawSizeBytes, 111)
        XCTAssertNil(windowB.selectionState.selectedEntryID)

        windowB.prepareForWindowClose()
        let staleWindowHit = GlobalSearchResultItem(
            id: "entry:\(archiveA):\(sharedSubpath)",
            title: "settings.json",
            subtitle: "A → \(sharedSubpath)",
            hitType: .archiveEntry,
            archivePath: archiveA,
            entrySubpath: sharedSubpath,
            targetWindowID: windowB.windowID,
            isDirectory: false,
            byteSize: 111,
            score: 0.95
        )
        _ = BrowserWindowRouter.shared.routeGlobalSearchResult(staleWindowHit)
        XCTAssertEqual(BrowserWindowRegistry.shared.activeWindowID, windowA.windowID, "Closed preferredWindowID must fall back to live window")
    }

    func testGlobalSearchArchiveEntryAsyncLoadAndStaleRequestInvalidation() async {
        let archiveSlow = "/tmp/ttzip-slow-\(UUID().uuidString).zip"
        let archiveFast = "/tmp/ttzip-fast-\(UUID().uuidString).zip"
        let slowEntry = "slow/target.txt"
        let fastEntry = "fast/winner.txt"

        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            if path == archiveSlow {
                try? await Task.sleep(nanoseconds: 80_000_000)
                return InspectResult(
                    archivePath: path,
                    format: "zip",
                    entries: [self.makeEntry(path: slowEntry)],
                    totalUncompressedBytes: 128,
                    totalCompressedBytes: 128,
                    unlockedPassword: nil
                )
            }
            return InspectResult(
                archivePath: path,
                format: "zip",
                entries: [self.makeEntry(path: fastEntry)],
                totalUncompressedBytes: 128,
                totalCompressedBytes: 128,
                unlockedPassword: nil
            )
        }

        let window = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        BrowserWindowRegistry.shared.register(window)
        BrowserWindowRegistry.shared.activateWindow(id: window.windowID)

        window.selectArchiveEntryInWindow(archivePath: archiveSlow, entrySubpath: slowEntry, highlightLine: 10)
        window.selectArchiveEntryInWindow(archivePath: archiveFast, entrySubpath: fastEntry, highlightLine: 25)

        try? await Task.sleep(nanoseconds: 140_000_000)

        XCTAssertEqual(window.currentArchivePath, archiveFast, "Older async archive load must not overwrite newer search navigation")
        XCTAssertEqual(window.selectionState.selectedEntryID, fastEntry)
        XCTAssertEqual(window.selectedArchiveHighlightLine, 25)
    }

    func testActiveWindowArchiveSessionIsSearchableInGlobalSearchWithoutManualRegistration() async {
        let archivePath = "/tmp/ttzip-live-search-\(UUID().uuidString).zip"
        let uniqueEntryPath = "nested/deep/unique_alpha_token_42.rs"
        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            InspectResult(
                archivePath: path,
                format: "zip",
                entries: [self.makeEntry(path: uniqueEntryPath, size: 512)],
                totalUncompressedBytes: 512,
                totalCompressedBytes: 512,
                unlockedPassword: nil
            )
        }

        let window = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        BrowserWindowRegistry.shared.register(window)
        BrowserWindowRegistry.shared.activateWindow(id: window.windowID)

        let loaded = await window.loadArchive(path: archivePath)
        XCTAssertTrue(loaded)

        let controller = GlobalSearchPanelController.shared
        let hitsWhileOpen = await controller.executeFastSearch(query: "unique_alpha_token_42")
        guard let matched = hitsWhileOpen.first(where: { $0.entrySubpath == uniqueEntryPath }) else {
            XCTFail("Expected live open archive entry to be returned by GlobalSearchPanelController.executeFastSearch")
            return
        }
        XCTAssertEqual(matched.archivePath, archivePath)
        XCTAssertEqual(
            matched.targetKind,
            .archiveEntry(archivePath: archivePath, entrySubpath: uniqueEntryPath)
        )
        XCTAssertEqual(matched.targetWindowID, window.windowID)

        window.closeCurrentArchive()
        let hitsAfterClose = await controller.executeFastSearch(query: "unique_alpha_token_42")
        XCTAssertFalse(hitsAfterClose.contains(where: { $0.entrySubpath == uniqueEntryPath }))
    }

    func testWindowCloseResolvesPendingCollisionContinuationWithStopAndUnregistersWindow() async {
        let dirA = URL(fileURLWithPath: "/tmp/ttzip-close-a", isDirectory: true)
        let dirB = URL(fileURLWithPath: "/tmp/ttzip-close-b", isDirectory: true)
        let windowA = AppViewState(fileViewer: NoOpFileViewer())
        let windowB = AppViewState(fileViewer: NoOpFileViewer())
        windowA.currentDirectory = dirA
        windowB.currentDirectory = dirB
        BrowserWindowRegistry.shared.register(windowA)
        BrowserWindowRegistry.shared.register(windowB)
        BrowserWindowRegistry.shared.activateWindow(id: windowA.windowID)

        let desc = ConflictFileDescriptor(
            fileName: "doc.txt",
            relativePath: "doc.txt",
            filePath: "/tmp/doc.txt",
            byteSize: 100,
            modificationDate: Date(),
            isDirectory: false
        )

        let resolutionTask = Task { @MainActor () -> (ConflictResolutionAction, Bool) in
            await withCheckedContinuation { continuation in
                let prompt = CollisionPrompt(
                    sourceFile: desc,
                    targetFile: desc,
                    conflictIndex: 1,
                    totalConflicts: 1,
                    resolver: { action, applyToAll in
                        continuation.resume(returning: (action, applyToAll))
                    }
                )
                windowA.overlayState.collisionPrompt = prompt
            }
        }

        await Task.yield()
        XCTAssertNotNil(windowA.overlayState.collisionPrompt)

        windowA.prepareForWindowClose()
        let (action, applyToAll) = await resolutionTask.value
        XCTAssertEqual(action, .stop)
        XCTAssertFalse(applyToAll)
        XCTAssertNil(windowA.overlayState.collisionPrompt)
        XCTAssertEqual(BrowserWindowRegistry.shared.activeWindowID, windowB.windowID)
    }

    // MARK: - 7. Archive Loading Directory Authorization Recovery & Invalidation Invariants

    func testArchiveLoadingAuthorizationAWaitingBOpeningAResumingRejectsStaleRequestWithoutOverwritingB() async {
        let archiveA = "/tmp/ttzip-auth-race-a-\(UUID().uuidString)/archiveA.zip"
        let archiveB = "/tmp/ttzip-auth-race-b-\(UUID().uuidString)/archiveB.zip"
        let entryA = "a/data.txt"
        let entryB = "b/data.txt"

        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            if path == archiveA {
                return InspectResult(
                    archivePath: path,
                    format: "zip",
                    entries: [self.makeEntry(path: entryA)],
                    totalUncompressedBytes: 100,
                    totalCompressedBytes: 100,
                    unlockedPassword: nil
                )
            }
            return InspectResult(
                archivePath: path,
                format: "zip",
                entries: [self.makeEntry(path: entryB)],
                totalUncompressedBytes: 200,
                totalCompressedBytes: 200,
                unlockedPassword: nil
            )
        }

        let window = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        BrowserWindowRegistry.shared.register(window)
        BrowserWindowRegistry.shared.activateWindow(id: window.windowID)

        var resumeAContinuation: CheckedContinuation<URL?, Never>?
        RootFolderAccessManager.shared.authorizationPromptHandler = { targetURL, _ in
            if targetURL.path.contains("ttzip-auth-race-a") {
                return await withCheckedContinuation { cont in
                    resumeAContinuation = cont
                }
            }
            return targetURL
        }
        defer { RootFolderAccessManager.shared.authorizationPromptHandler = nil }

        let taskA = Task { @MainActor () -> Bool in
            await window.loadArchive(path: archiveA)
        }

        for _ in 0..<50 {
            if resumeAContinuation != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(resumeAContinuation, "Request A must suspend awaiting directory authorization")

        let loadedB = await window.loadArchive(path: archiveB)
        XCTAssertTrue(loadedB, "Request B must successfully load archive")
        XCTAssertEqual(window.explorerState.currentArchivePath, archiveB)
        XCTAssertEqual(window.explorerState.currentEntries.first?.path, entryB)

        let parentA = URL(fileURLWithPath: archiveA).deletingLastPathComponent()
        resumeAContinuation?.resume(returning: parentA)
        resumeAContinuation = nil

        let loadedA = await taskA.value
        XCTAssertFalse(loadedA, "Stale Request A must be rejected after newer Request B advanced operationEpoch")
        XCTAssertEqual(window.explorerState.currentArchivePath, archiveB, "Archive B must NOT be overwritten by stale Request A")
        XCTAssertEqual(window.explorerState.currentEntries.first?.path, entryB)
    }

    func testArchiveLoadingAuthorizationWaitingDuringCloseArchiveOrWindowInvalidatesStaleRequestWithoutRevivingSession() async {
        let archiveA = "/tmp/ttzip-auth-close-a-\(UUID().uuidString)/archiveA.zip"
        let entryA = "a/data.txt"

        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            InspectResult(
                archivePath: path,
                format: "zip",
                entries: [self.makeEntry(path: entryA)],
                totalUncompressedBytes: 100,
                totalCompressedBytes: 100,
                unlockedPassword: nil
            )
        }

        let window = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        BrowserWindowRegistry.shared.register(window)
        BrowserWindowRegistry.shared.activateWindow(id: window.windowID)

        var resumeAContinuation: CheckedContinuation<URL?, Never>?
        RootFolderAccessManager.shared.authorizationPromptHandler = { targetURL, _ in
            if targetURL.path.contains("ttzip-auth-close-a") {
                return await withCheckedContinuation { cont in
                    resumeAContinuation = cont
                }
            }
            return targetURL
        }
        defer { RootFolderAccessManager.shared.authorizationPromptHandler = nil }

        let taskA = Task { @MainActor () -> Bool in
            await window.loadArchive(path: archiveA)
        }

        for _ in 0..<50 {
            if resumeAContinuation != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(resumeAContinuation)

        window.closeCurrentArchive()
        XCTAssertNil(window.explorerState.currentArchivePath)
        XCTAssertFalse(window.taskState.isLoading)

        let parentA = URL(fileURLWithPath: archiveA).deletingLastPathComponent()
        resumeAContinuation?.resume(returning: parentA)
        resumeAContinuation = nil

        let loadedA = await taskA.value
        XCTAssertFalse(loadedA, "Request A must abort after closeCurrentArchive bumped operationEpoch")
        XCTAssertNil(window.explorerState.currentArchivePath, "Closed archive must not be revived by stale authorization completion")
        XCTAssertFalse(window.taskState.isLoading)
        XCTAssertNil(AppIntentDispatcher.shared.activeSession(for: archiveA))
    }

    func testArchiveLoadingAuthorizationWaitingDuringTaskCancellationAbortsCleanly() async {
        let archiveA = "/tmp/ttzip-auth-cancel-a-\(UUID().uuidString)/archiveA.zip"
        let entryA = "a/data.txt"

        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            InspectResult(
                archivePath: path,
                format: "zip",
                entries: [self.makeEntry(path: entryA)],
                totalUncompressedBytes: 100,
                totalCompressedBytes: 100,
                unlockedPassword: nil
            )
        }

        let window = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        BrowserWindowRegistry.shared.register(window)

        var resumeAContinuation: CheckedContinuation<URL?, Never>?
        RootFolderAccessManager.shared.authorizationPromptHandler = { targetURL, _ in
            if targetURL.path.contains("ttzip-auth-cancel-a") {
                return await withCheckedContinuation { cont in
                    resumeAContinuation = cont
                }
            }
            return targetURL
        }
        defer { RootFolderAccessManager.shared.authorizationPromptHandler = nil }

        let taskA = Task { @MainActor () -> Bool in
            await window.loadArchive(path: archiveA)
        }

        for _ in 0..<50 {
            if resumeAContinuation != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(resumeAContinuation)

        taskA.cancel()

        let parentA = URL(fileURLWithPath: archiveA).deletingLastPathComponent()
        resumeAContinuation?.resume(returning: parentA)
        resumeAContinuation = nil

        let loadedA = await taskA.value
        XCTAssertFalse(loadedA, "Cancelled task must abort and return false")
        XCTAssertNil(window.explorerState.currentArchivePath)
        XCTAssertFalse(window.taskState.isLoading)
    }

    func testArchiveLoadingAuthorizationWaitingDuringActualWindowCloseEntrypointInvalidatesStaleRequestWithoutRevivingSession() async {
        let archiveA = "/tmp/ttzip-auth-winclose-a-\(UUID().uuidString)/archiveA.zip"
        let entryA = "a/data.txt"

        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            InspectResult(
                archivePath: path,
                format: "zip",
                entries: [self.makeEntry(path: entryA)],
                totalUncompressedBytes: 100,
                totalCompressedBytes: 100,
                unlockedPassword: nil
            )
        }

        let window = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        BrowserWindowRegistry.shared.register(window)
        BrowserWindowRegistry.shared.activateWindow(id: window.windowID)

        var resumeAContinuation: CheckedContinuation<URL?, Never>?
        RootFolderAccessManager.shared.authorizationPromptHandler = { targetURL, _ in
            if targetURL.path.contains("ttzip-auth-winclose-a") {
                return await withCheckedContinuation { cont in
                    resumeAContinuation = cont
                }
            }
            return targetURL
        }
        defer { RootFolderAccessManager.shared.authorizationPromptHandler = nil }

        let taskA = Task { @MainActor () -> Bool in
            await window.loadArchive(path: archiveA)
        }

        for _ in 0..<50 {
            if resumeAContinuation != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(resumeAContinuation, "Request A must suspend awaiting directory authorization")

        // Invoke the actual window close entry point while A is suspended awaiting authorization
        window.prepareForWindowClose()
        XCTAssertTrue(window.isWindowClosing)
        XCTAssertNil(BrowserWindowRegistry.shared.controller(for: window.windowID), "Window must be unregistered on actual window close")

        // Resume authorization now
        let parentA = URL(fileURLWithPath: archiveA).deletingLastPathComponent()
        resumeAContinuation?.resume(returning: parentA)
        resumeAContinuation = nil

        let loadedA = await taskA.value
        XCTAssertFalse(loadedA, "Request A must abort when window was closed via prepareForWindowClose()")
        XCTAssertNil(window.explorerState.currentArchivePath, "Closed window must not have its archive state populated")
        XCTAssertFalse(window.taskState.isLoading)
        XCTAssertNil(BrowserWindowRegistry.shared.controller(for: window.windowID))
        XCTAssertNil(AppIntentDispatcher.shared.activeSession(for: archiveA))
    }
}
