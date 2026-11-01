// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import TTZipUI
@testable import TTZipCore
@testable import TTZipApp

// MM41 — ownership of an asynchronous archive open across foreground navigation.
//
// Contract (products/ttzip/docs/twin/archive/mm41-archive-open-navigation-ownership.md):
// navigating away from the page that started an archive open abandons that request. A late
// success, failure or password prompt of an abandoned request must never be written to the
// page the user navigated to: not into the newly active tab, not into the window-level
// explorer state and not as a password prompt for the new page.
//
// Scope: host orchestration only. The engine is replaced by the controlled driver double
// `MockArchivePasswordDriver` (ArchivePasswordOperationTests.swift) and the inspection is held
// in flight by the deterministic barrier `ArchiveHostAsyncBarrier`
// (ArchiveHostAcceptanceTestSupport.swift). No wall-clock waiting is used anywhere: every
// regression releases the inspection explicitly. The barrier proves which production call
// chain ran and how the host reacted; it does not prove real ZipCrypto correctness, which
// stays with MM14 / MM15.
//
// Wiring requirement: this file MUST be compiled into the same `swift_test` target as
// `ArchivePasswordOperationTests.swift` and `ArchiveHostAcceptanceTestSupport.swift`
// (currently `AppCoreGateTests`), because it reuses the controlled
// driver double and the shared barrier.

@MainActor
final class ArchiveOpenNavigationOwnershipTests: ArchiveHostAcceptanceTestCase {

    // MARK: - 1. Success of an abandoned request must not reach the new page

    func testArchiveOpenResultIsRejectedAfterTheUserSwitchedToAnotherTab() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-success")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        let barrier = ArchiveHostAsyncBarrier()
        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            await barrier.suspendUntilReleased()
            return self.makeInspectResult(path: path)
        }

        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        let originatingSessionID = state.navigationState.activeSessionID

        let load = Task { await state.loadArchive(path: archivePath) }
        await barrier.waitUntilSuspended()

        // The user leaves the page that started the open.
        let otherDirectory = try makeDestinationDirectory()
        state.navigationState.openNewTab(url: otherDirectory)
        let activeSessionIDAfterNavigation = state.navigationState.activeSessionID
        XCTAssertNotEqual(activeSessionIDAfterNavigation, originatingSessionID)

        await barrier.release()
        let loaded = await load.value

        XCTAssertFalse(loaded, "An abandoned archive open must not report success")
        XCTAssertNil(
            state.explorerState.currentArchivePath,
            "The window must not host the archive of an abandoned request"
        )
        XCTAssertTrue(
            state.explorerState.currentEntries.isEmpty,
            "The abandoned request must not publish archive entries to the new page"
        )
        XCTAssertNil(
            state.navigationState.tabSessions.first(where: { $0.id == activeSessionIDAfterNavigation })?.archivePath,
            "The newly active tab must not become the archive of an abandoned request"
        )
        XCTAssertNil(
            state.navigationState.tabSessions.first(where: { $0.id == originatingSessionID })?.archivePath,
            "The originating tab must not be committed to either"
        )
        XCTAssertFalse(
            state.isLoading,
            "An abandoned request must not leave the window spinner running"
        )
        XCTAssertFalse(state.showPasswordPrompt)
    }

    // MARK: - 2. A stale password error must not be staged for the new page

    func testPasswordRequiredOfAnAbandonedRequestDoesNotStageAPromptForTheNewPage() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-password")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        let barrier = ArchiveHostAsyncBarrier()
        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            await barrier.suspendUntilReleased()
            throw ArchiveError.wrongPassword(archivePath: path)
        }

        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)

        let load = Task { await state.loadArchive(path: archivePath) }
        await barrier.waitUntilSuspended()

        let otherDirectory = try makeDestinationDirectory()
        state.navigationState.openNewTab(url: otherDirectory)

        await barrier.release()
        let loaded = await load.value

        XCTAssertFalse(loaded, "An abandoned archive open must not report success")
        XCTAssertFalse(
            state.showPasswordPrompt,
            "A stale password error must not stage a prompt for the newly active page"
        )
        XCTAssertNil(state.pendingPasswordContext)
        XCTAssertNil(state.overlayState.pendingEncryptedPath)
        XCTAssertNil(state.explorerState.currentArchivePath)
    }

    // MARK: - 3. T1 -> T2 -> T1 must not revive the abandoned request

    func testReturningToTheOriginatingTabDoesNotReviveTheAbandonedRequest() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-aba")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        let barrier = ArchiveHostAsyncBarrier()
        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            await barrier.suspendUntilReleased()
            return self.makeInspectResult(path: path)
        }

        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        let originatingSessionID = state.navigationState.activeSessionID

        let load = Task { await state.loadArchive(path: archivePath) }
        await barrier.waitUntilSuspended()

        let otherDirectory = try makeDestinationDirectory()
        state.navigationState.openNewTab(url: otherDirectory)
        state.navigationState.switchToTab(id: originatingSessionID)
        XCTAssertEqual(
            state.navigationState.activeSessionID,
            originatingSessionID,
            "The test must end on the originating session to exercise the ABA case"
        )

        await barrier.release()
        let loaded = await load.value

        XCTAssertFalse(loaded, "T1 -> T2 -> T1 must not revive the abandoned request")
        XCTAssertNil(
            state.explorerState.currentArchivePath,
            "The window must not host the archive of an abandoned request"
        )
        XCTAssertNil(
            state.navigationState.tabSessions.first(where: { $0.id == originatingSessionID })?.archivePath,
            "The originating tab must not be committed to after the ABA round trip"
        )
    }

    // MARK: - 4. Closing the originating tab must reject the pending result

    func testClosingTheOriginatingTabRejectsThePendingResult() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-close")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        let barrier = ArchiveHostAsyncBarrier()
        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            await barrier.suspendUntilReleased()
            return self.makeInspectResult(path: path)
        }

        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        let originatingSessionID = state.navigationState.activeSessionID

        let load = Task { await state.loadArchive(path: archivePath) }
        await barrier.waitUntilSuspended()

        let otherDirectory = try makeDestinationDirectory()
        state.navigationState.openNewTab(url: otherDirectory)
        state.navigationState.closeTab(id: originatingSessionID)

        await barrier.release()
        let loaded = await load.value

        XCTAssertFalse(loaded, "A request whose originating tab was closed must not commit")
        XCTAssertNil(
            state.explorerState.currentArchivePath,
            "The window must not host the archive of a closed request"
        )
        XCTAssertFalse(
            state.navigationState.tabSessions.contains { $0.id == originatingSessionID },
            "The closed tab must stay closed"
        )
    }

    // MARK: - 5. Directory navigation while the open is pending rejects the result

    func testDirectoryNavigationWhileTheOpenIsPendingRejectsTheResult() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-directory")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        let barrier = ArchiveHostAsyncBarrier()
        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            await barrier.suspendUntilReleased()
            return self.makeInspectResult(path: path)
        }

        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        XCTAssertNil(
            state.explorerState.currentArchivePath,
            "The window starts without an archive, so no archive state may excuse the request"
        )

        let load = Task { await state.loadArchive(path: archivePath) }
        await barrier.waitUntilSuspended()

        let targetDirectory = try makeDestinationDirectory()
        state.navigateToDirectory(targetDirectory)

        await barrier.release()
        let loaded = await load.value

        XCTAssertFalse(loaded, "A directory navigation must abandon the pending archive open")
        XCTAssertNil(
            state.explorerState.currentArchivePath,
            "The window must not host the archive of an abandoned request"
        )
        XCTAssertEqual(
            state.navigationState.currentDirectory.standardizedFileURL,
            targetDirectory.standardizedFileURL,
            "The abandoned request must not undo the directory the user navigated to"
        )
        XCTAssertFalse(
            state.isLoading,
            "An abandoned request must not leave the window spinner running"
        )
    }

    // MARK: - 6. Positive control: an open without navigation still commits

    func testArchiveOpenWithoutNavigationCommitsToTheOriginatingTab() async throws {
        let archiveURL = try makeArchiveFixture(named: "ownership-control")
        let archivePath = archiveURL.path
        assertTemporaryFixturePath(archivePath)

        let barrier = ArchiveHostAsyncBarrier()
        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in
            await barrier.suspendUntilReleased()
            return self.makeInspectResult(path: path)
        }

        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        let originatingSessionID = state.navigationState.activeSessionID

        let load = Task { await state.loadArchive(path: archivePath) }
        await barrier.waitUntilSuspended()
        await barrier.release()
        let loaded = await load.value

        XCTAssertTrue(loaded, "An archive open without navigation must still commit")
        XCTAssertEqual(state.explorerState.currentArchivePath, archivePath)
        XCTAssertEqual(state.navigationState.activeSessionID, originatingSessionID)
        XCTAssertEqual(
            state.navigationState.tabSessions.first(where: { $0.id == originatingSessionID })?.archivePath,
            archivePath,
            "The commit must land in the tab session that started the request"
        )
        XCTAssertFalse(state.isLoading, "A committed open must not leave the spinner running")
        XCTAssertTrue(state.statusMessage.contains("Loaded") || state.statusMessage.contains("entries"))
    }

    func testAcceptedArchiveHistoryRestoresResourcesAndDispatcherWithoutReinspection() async throws {
        let archive = try makeArchiveFixture(named: "miller-history")
        let driver = MockArchivePasswordDriver()
        var inspections = 0
        driver.inspectHandler = { path, _, _ in
            inspections += 1
            return self.makeInspectResult(path: path)
        }
        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        AppIntentDispatcher.shared.bind(state: state)
        defer { AppIntentDispatcher.shared.unregister(windowID: state.windowID) }
        state.navigateToDirectory(archive.deletingLastPathComponent())
        let sessionID = state.navigationState.activeSessionID
        let loaded = await state.loadArchive(path: archive.path)
        XCTAssertTrue(loaded)
        XCTAssertEqual(state.navigationState.currentDirectory.path, archive.path)
        XCTAssertNotNil(state.explorerState.acceptedArchiveProjection(for: sessionID, archivePath: archive.path))

        state.navigationState.goUp()
        XCTAssertNil(state.explorerState.currentArchivePath)
        XCTAssertFalse(AppIntentDispatcher.shared.allSessions.contains { $0.id == state.windowID })
        state.navigationState.goBack()
        XCTAssertEqual(state.explorerState.currentArchivePath, archive.path)
        XCTAssertEqual(state.explorerState.currentEntries.first?.path, probeEntryPath)
        XCTAssertEqual(AppIntentDispatcher.shared.allSessions.first { $0.id == state.windowID }?.currentArchivePath, archive.path)
        XCTAssertEqual(inspections, 1, "History must reuse the accepted inspection")

        state.navigationState.openNewTab(url: try makeDestinationDirectory())
        state.navigationState.closeTab(id: sessionID)
        XCTAssertNil(state.explorerState.acceptedArchiveProjection(for: sessionID, archivePath: archive.path))
    }

    func testFailedArchiveRefreshClearsAcceptedContentWithoutChangingLocation() async throws {
        let archive = try makeArchiveFixture(named: "miller-refresh")
        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in self.makeInspectResult(path: path) }
        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        let loaded = await state.loadArchive(path: archive.path)
        XCTAssertTrue(loaded)
        var location = try XCTUnwrap(URLComponents(url: archive, resolvingAgainstBaseURL: false))
        location.queryItems = [URLQueryItem(name: "subpath", value: "docs")]
        let child = try XCTUnwrap(location.url)
        state.navigationState.navigateTo(child)
        driver.inspectHandler = { _, _, _ in throw ArchiveError.engineFailure(code: -1, message: "Controlled refresh failure") }

        await state.refreshAcceptedArchive(at: child)

        XCTAssertEqual(state.navigationState.currentDirectory, child)
        XCTAssertTrue(state.explorerState.currentEntries.isEmpty)
        XCTAssertNil(state.explorerState.activePassword)
        XCTAssertNil(state.explorerState.acceptedArchiveProjection(
            for: state.navigationState.activeSessionID, archivePath: archive.path
        ))
        XCTAssertFalse(state.isLoading)
        driver.inspectHandler = { path, _, _ in self.makeInspectResult(path: path) }
        await state.refreshAcceptedArchive(at: child)
        XCTAssertEqual(state.navigationState.currentDirectory, child)
        XCTAssertEqual(state.explorerState.currentEntries.first?.path, probeEntryPath)
        XCTAssertNotNil(state.explorerState.acceptedArchiveProjection(
            for: state.navigationState.activeSessionID, archivePath: archive.path
        ), "A failed refresh must remain retryable")
    }

    func testClosingBackgroundTabKeepsTheActiveArchiveRequest() async throws {
        for closesLeftTab in [true, false] {
            let archive = try makeArchiveFixture(named: closesLeftTab ? "close-left-tab" : "close-right-tab")
            let destination = try makeDestinationDirectory()
            await withBusyScenario { scenario in
                let inspection = scenario.barrier()
                let driver = MockArchivePasswordDriver()
                driver.inspectHandler = { path, _, _ in
                    await inspection.suspendUntilReleased()
                    return self.makeInspectResult(path: path)
                }
                let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
                var backgroundID = state.navigationState.activeSessionID
                state.navigationState.openNewTab(url: destination)
                let activeID = state.navigationState.activeSessionID
                if !closesLeftTab {
                    state.navigationState.openNewTab(url: destination)
                    backgroundID = state.navigationState.activeSessionID
                    state.navigationState.switchToTab(id: activeID)
                }
                let location = state.navigationState.currentDirectory
                let open = scenario.start { await state.loadArchive(path: archive.path) }
                try await scenario.entered(inspection)
                let epoch = state.taskState.archiveRequestOwnerEpoch
                state.navigationState.closeTab(id: backgroundID)
                scenario.expectEqual(state.navigationState.activeSessionID, activeID, "The active session must survive")
                scenario.expectEqual(state.navigationState.currentDirectory, location, "Background close must preserve location")
                scenario.expectEqual(state.taskState.archiveRequestOwnerEpoch, epoch, "Background close must preserve the request")
                scenario.expect(!state.navigationState.tabSessions.contains { $0.id == backgroundID }, "The background session must retire")
                await inspection.release()
                let loaded = try await scenario.finish(open)
                scenario.expect(loaded, "Closing a background tab must not abandon the active inspection")
                scenario.expectEqual(state.explorerState.currentArchivePath, archive.path, "The active result must commit")
            }
        }
    }

    func testExplicitSameDirectorySelectionStillAbandonsArchiveRequest() async throws {
        let archive = try makeArchiveFixture(named: "explicit-same-directory")
        await withBusyScenario { scenario in
            let inspection = scenario.barrier()
            let driver = MockArchivePasswordDriver()
            driver.inspectHandler = { path, _, _ in
                await inspection.suspendUntilReleased()
                return self.makeInspectResult(path: path)
            }
            let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let location = state.navigationState.currentDirectory
            let open = scenario.start { await state.loadArchive(path: archive.path) }
            try await scenario.entered(inspection)
            state.navigationState.navigateTo(location)
            await inspection.release()
            let loaded = try await scenario.finish(open)
            scenario.expect(!loaded, "An explicit same-directory navigation must still invalidate the request")
            scenario.expect(state.explorerState.currentArchivePath == nil, "The abandoned result must not commit")
        }
    }

    func testBackgroundArchiveMutationDoesNotAbandonAnotherTabInspection() async throws {
        let backgroundArchive = try makeArchiveFixture(named: "background-mutation-a")
        let activeArchive = try makeArchiveFixture(named: "background-mutation-b")
        let destination = try makeDestinationDirectory()
        await withBusyScenario { scenario in
            let inspection = scenario.barrier()
            let driver = MockArchivePasswordDriver()
            driver.inspectHandler = { path, _, _ in
                if path == activeArchive.path { await inspection.suspendUntilReleased() }
                return self.makeInspectResult(path: path)
            }
            let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let backgroundID = state.navigationState.activeSessionID
            let backgroundLoaded = await state.loadArchive(path: backgroundArchive.path)
            scenario.expect(backgroundLoaded, "The background archive fixture must be accepted first")
            state.navigationState.openNewTab(url: destination)
            let activeID = state.navigationState.activeSessionID
            let open = scenario.start { await state.loadArchive(path: activeArchive.path) }
            try await scenario.entered(inspection)
            let epoch = state.taskState.archiveRequestOwnerEpoch
            await state.archiveContentsDidChange(at: backgroundArchive.path)
            scenario.expect(state.explorerState.acceptedArchiveProjection(
                for: backgroundID, archivePath: backgroundArchive.path
            ) == nil, "The mutated background archive snapshot must be discarded")
            scenario.expectEqual(state.navigationState.activeSessionID, activeID, "Mutation must preserve the active session")
            scenario.expectEqual(state.taskState.archiveRequestOwnerEpoch, epoch, "Background mutation must preserve the active request")
            scenario.expectEqual(driver.calls.filter {
                if case .inspect(let path, _, _) = $0.kind { return path == backgroundArchive.path }
                return false
            }.count, 1, "Background invalidation must not start another reader")
            await inspection.release()
            let loaded = try await scenario.finish(open)
            scenario.expect(loaded, "The unrelated active inspection must still commit")
            scenario.expectEqual(state.explorerState.currentArchivePath, activeArchive.path, "Only the active archive may commit")
        }
    }

    func testRemoteFileAuthorityCannotRestoreLocalAcceptedArchive() async throws {
        let archive = try makeArchiveFixture(named: "local-resource-remote-authority")
        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in self.makeInspectResult(path: path) }
        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        let loaded = await state.loadArchive(path: archive.path)
        XCTAssertTrue(loaded)
        let sessionID = state.navigationState.activeSessionID
        var components = try XCTUnwrap(URLComponents(url: archive, resolvingAgainstBaseURL: false))
        components.host = "remote.example"
        let remote = try XCTUnwrap(components.url)
        XCTAssertEqual(remote.path, archive.path)
        state.navigationState.navigateTo(remote)
        XCTAssertEqual(state.navigationState.currentDirectory, remote)
        XCTAssertNil(state.explorerState.currentArchivePath, "Remote authority must not restore local archive state")
        XCTAssertTrue(state.explorerState.currentEntries.isEmpty)
        XCTAssertNotNil(state.explorerState.acceptedArchiveProjection(
            for: sessionID, archivePath: archive.path
        ), "The local back-history resource remains reachable, but cannot represent the remote location")
        XCTAssertEqual(driver.calls.count, 1, "A rejected restore must not silently fall back to another reader")
    }

    func testBackToInvalidatedArchiveReloadsThroughTheOwningRequest() async throws {
        let archive = try makeArchiveFixture(named: "history-invalidated-reload")
        let destination = try makeDestinationDirectory()
        await withBusyScenario { scenario in
            let inspection = scenario.barrier()
            let driver = MockArchivePasswordDriver()
            var inspectionCount = 0
            driver.inspectHandler = { path, _, _ in
                inspectionCount += 1
                if inspectionCount > 1 { await inspection.suspendUntilReleased() }
                return self.makeInspectResult(path: path)
            }
            let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let loaded = await state.loadArchive(path: archive.path)
            scenario.expect(loaded, "The initial archive must be accepted")
            let acceptedLocation = state.navigationState.currentDirectory
            scenario.expectEqual(URLComponents(url: acceptedLocation, resolvingAgainstBaseURL: false)?
                .queryItems, [URLQueryItem(name: "subpath", value: "")], "Root history must retain archive identity")
            state.navigationState.navigateTo(destination)
            await state.archiveContentsDidChange(at: archive.path)
            state.navigationState.goBack()
            try await scenario.entered(inspection)
            scenario.expectEqual(inspectionCount, 2, "Only the owner must reopen the invalidated history entry")
            scenario.expect(state.isLoading, "The reload must own foreground busy state")
            await inspection.release()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while state.explorerState.currentArchivePath == nil && ContinuousClock.now < deadline {
                await Task.yield()
            }
            scenario.expectEqual(state.explorerState.currentArchivePath, archive.path, "The owner must commit the reloaded archive")
            scenario.expectEqual(state.navigationState.currentDirectory, acceptedLocation, "Reload must preserve virtual history")
            scenario.expect(!state.isLoading, "A completed reload must release its busy identity")
        }
    }

    func testExplicitCloseLeavesTheArchiveAndDiscardsItsAcceptedProjection() async throws {
        let archive = try makeArchiveFixture(named: "explicit-close-projection")
        let driver = MockArchivePasswordDriver()
        driver.inspectHandler = { path, _, _ in self.makeInspectResult(path: path) }
        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        let loaded = await state.loadArchive(path: archive.path)
        XCTAssertTrue(loaded)
        state.closeCurrentArchive(discardAcceptedResources: true)
        XCTAssertEqual(state.navigationState.currentDirectory.path, archive.deletingLastPathComponent().path)
        XCTAssertNil(state.navigationState.currentDirectory.query)
        XCTAssertNil(state.explorerState.currentArchivePath)
        XCTAssertNil(state.explorerState.acceptedArchiveProjection(
            for: state.navigationState.activeSessionID, archivePath: archive.path
        ))
        XCTAssertFalse(state.isLoading)
    }

    // MARK: - Helpers

    /// Builds a plain (unencrypted) inspection result for the controlled driver double.
    private func makeInspectResult(path: String) -> InspectResult {
        InspectResult(
            archivePath: path,
            format: "zip",
            entries: [
                ArchiveEntry(
                    path: probeEntryPath,
                    uncompressedSize: 128,
                    isDirectory: false,
                    modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                    isEncrypted: false,
                    compressedSize: 128,
                    crc32: 0x1234_5678
                )
            ],
            totalUncompressedBytes: 128,
            totalCompressedBytes: 128,
            unlockedPassword: nil
        )
    }
}

// MARK: - MM49 bounded window busy ownership acceptance

@MainActor
final class WindowBusyOwnershipTests: ArchiveHostAcceptanceTestCase {
    private func assertOpenAndExtractionOverlap(openFirst: Bool) async throws {
        let archiveURL = try makeArchiveFixture(named: openFirst ? "busy-open-extract" : "busy-extract-open")
        let path = archiveURL.path
        assertTemporaryFixturePath(path)
        await withBusyScenario { scenario in
            let inspection = scenario.barrier()
            let extractionGate = scenario.barrier()
            let driver = self.makeGatedArchiveDriver(
                inspectBarriers: [path: inspection], extractBarriers: [path: extractionGate]
            )
            let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let open: ArchiveBusyObservedTask<Bool>
            let extraction: ArchiveBusyObservedTask<Void>
            if openFirst {
                open = scenario.start { await state.loadArchive(path: path) }
                try await scenario.entered(inspection)
                scenario.expect(state.isLoading, "A pending archive open must make the window busy")
                extraction = scenario.start { await state.quickExtractArchive(archivePath: path, isSmartExtract: false) }
                try await scenario.entered(extractionGate)
            } else {
                extraction = scenario.start { await state.quickExtractArchive(archivePath: path, isSmartExtract: false) }
                try await scenario.entered(extractionGate)
                scenario.expect(state.isLoading, "A running extraction must make the window busy")
                open = scenario.start { await state.loadArchive(path: path) }
                try await scenario.entered(inspection)
            }
            scenario.expect(state.isLoading, "Both operations must keep the window busy")
            if openFirst {
                await inspection.release()
                let loaded = try await scenario.finish(open)
                scenario.expect(loaded, "The foreground open must commit")
                scenario.expect(state.isLoading, "Finishing the open must leave the extraction busy")
                await extractionGate.release()
                try await scenario.finish(extraction)
            } else {
                await extractionGate.release()
                try await scenario.finish(extraction)
                scenario.expect(state.isLoading, "Finishing extraction must leave the open busy")
                await inspection.release()
                let loaded = try await scenario.finish(open)
                scenario.expect(loaded, "The foreground open must commit")
            }
            scenario.expect(!state.isLoading, "The window must be idle once both operations finish")
            scenario.expectEqual(self.quickExtractCallCount(driver, path: path), 1, "The controlled extraction must run once")
            scenario.expect(self.hasExpectedQuickExtractDestination(driver, archiveURL: archiveURL), "Extraction must use its actual source and destination")
        }
    }

    private func assertInvalidatedForegroundKeepsExtractionBusy(
        named name: String, invalidate: @escaping @MainActor (AppViewState) -> Void
    ) async throws {
        let archiveURL = try makeArchiveFixture(named: name)
        let path = archiveURL.path
        assertTemporaryFixturePath(path)
        await withBusyScenario { scenario in
            let inspection = scenario.barrier()
            let extractionGate = scenario.barrier()
            let driver = self.makeGatedArchiveDriver(
                inspectBarriers: [path: inspection], extractBarriers: [path: extractionGate]
            )
            let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let extraction = scenario.start { await state.quickExtractArchive(archivePath: path, isSmartExtract: false) }
            try await scenario.entered(extractionGate)
            let open = scenario.start { await state.loadArchive(path: path) }
            try await scenario.entered(inspection)
            invalidate(state)
            await inspection.release()
            let loaded = try await scenario.finish(open)
            scenario.expect(!loaded, "The invalidated open must not report success")
            scenario.expect(state.explorerState.currentArchivePath == nil, "The invalidated open must not commit")
            scenario.expect(state.isLoading, "Invalidation must keep the authorized extraction busy")
            await extractionGate.release()
            try await scenario.finish(extraction)
            scenario.expect(!state.isLoading, "Finishing extraction must release the last identity")
        }
    }

    func testArchiveOpenAndExtractionOverlapKeepsTheWindowBusyUntilBothFinish() async throws {
        try await assertOpenAndExtractionOverlap(openFirst: true)
    }

    func testExtractionAndArchiveOpenOverlapKeepsTheWindowBusyUntilBothFinish() async throws {
        try await assertOpenAndExtractionOverlap(openFirst: false)
    }

    func testTwoOverlappingExtractionsKeepTheWindowBusyUntilBothFinish() async throws {
        let firstURL = try makeArchiveFixture(named: "busy-extract-first")
        let secondURL = try makeArchiveFixture(named: "busy-extract-second")
        assertTemporaryFixturePath(firstURL.path)
        assertTemporaryFixturePath(secondURL.path)
        await withBusyScenario { scenario in
            let firstGate = scenario.barrier()
            let secondGate = scenario.barrier()
            let driver = self.makeGatedArchiveDriver(extractBarriers: [firstURL.path: firstGate, secondURL.path: secondGate])
            let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let first = scenario.start { await state.quickExtractArchive(archivePath: firstURL.path, isSmartExtract: false) }
            try await scenario.entered(firstGate)
            let second = scenario.start { await state.quickExtractArchive(archivePath: secondURL.path, isSmartExtract: false) }
            try await scenario.entered(secondGate)
            scenario.expect(state.isLoading, "Two overlapping extractions must make the window busy")
            await secondGate.release()
            try await scenario.finish(second)
            scenario.expect(state.isLoading, "The older extraction must stay busy when the newer one finishes")
            await firstGate.release()
            try await scenario.finish(first)
            scenario.expect(!state.isLoading, "The window must be idle after both extractions")
            scenario.expectEqual(self.quickExtractCallCount(driver, path: firstURL.path), 1, "The first controlled extraction must run once")
            scenario.expectEqual(self.quickExtractCallCount(driver, path: secondURL.path), 1, "The second controlled extraction must run once")
            scenario.expect(self.hasExpectedQuickExtractDestination(driver, archiveURL: firstURL), "The first destination must match its archive")
            scenario.expect(self.hasExpectedQuickExtractDestination(driver, archiveURL: secondURL), "The second destination must match its archive")
        }
    }

    func testNavigationInvalidatesTheForegroundRequestAndKeepsTheExtractionBusy() async throws {
        let targetDirectory = try makeDestinationDirectory()
        try await assertInvalidatedForegroundKeepsExtractionBusy(named: "busy-navigate") { $0.navigateToDirectory(targetDirectory) }
    }

    func testClosingTheArchiveInvalidatesTheForegroundRequestAndKeepsTheExtractionBusy() async throws {
        try await assertInvalidatedForegroundKeepsExtractionBusy(named: "busy-close") { $0.closeCurrentArchive() }
    }

    func testResettingTheWindowInvalidatesTheForegroundRequestAndKeepsTheExtractionBusy() async throws {
        try await assertInvalidatedForegroundKeepsExtractionBusy(named: "busy-reset") { $0.reset() }
    }

    func testFailedArchiveOpenReleasesTheForegroundAndLeavesTheBackgroundBusy() async throws {
        let archiveURL = try makeArchiveFixture(named: "busy-failure")
        let path = archiveURL.path
        assertTemporaryFixturePath(path)
        await withBusyScenario { scenario in
            let inspection = scenario.barrier()
            let extractionGate = scenario.barrier()
            let driver = self.makeGatedArchiveDriver(extractBarriers: [path: extractionGate])
            driver.inspectHandler = { _, _, _ in
                await inspection.suspendUntilReleased()
                throw ArchiveError.fileNotFound
            }
            let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let extraction = scenario.start { await state.quickExtractArchive(archivePath: path, isSmartExtract: false) }
            try await scenario.entered(extractionGate)
            let open = scenario.start { await state.loadArchive(path: path) }
            try await scenario.entered(inspection)
            await inspection.release()
            let loaded = try await scenario.finish(open)
            scenario.expect(!loaded, "The deliberately failed inspection must not report success")
            scenario.expect(state.isLoading, "A failed open must not release the running extraction")
            await extractionGate.release()
            try await scenario.finish(extraction)
            scenario.expect(!state.isLoading, "Extraction completion must release the final identity")
        }
    }

    func testCancelledArchiveOpenReleasesTheForegroundAndLeavesTheBackgroundBusy() async throws {
        let archiveURL = try makeArchiveFixture(named: "busy-cancel")
        let path = archiveURL.path
        assertTemporaryFixturePath(path)
        await withBusyScenario { scenario in
            let inspection = scenario.barrier()
            let extractionGate = scenario.barrier()
            let driver = self.makeGatedArchiveDriver(inspectBarriers: [path: inspection], extractBarriers: [path: extractionGate])
            let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let extraction = scenario.start { await state.quickExtractArchive(archivePath: path, isSmartExtract: false) }
            try await scenario.entered(extractionGate)
            let open = scenario.start { await state.loadArchive(path: path) }
            try await scenario.entered(inspection)
            open.task.cancel()
            await inspection.release()
            let loaded = try await scenario.finish(open)
            scenario.expect(!loaded, "The cancelled open must not report success")
            scenario.expect(state.isLoading, "A cancelled open must not release the running extraction")
            await extractionGate.release()
            try await scenario.finish(extraction)
            scenario.expect(!state.isLoading, "Extraction completion must release the final identity")
        }
    }

    func testArchiveOpenAloneLeavesNoBusyIdentityBehind() async throws {
        let archiveURL = try makeArchiveFixture(named: "busy-control")
        let path = archiveURL.path
        assertTemporaryFixturePath(path)
        await withBusyScenario { scenario in
            let inspection = scenario.barrier()
            let driver = self.makeGatedArchiveDriver(inspectBarriers: [path: inspection])
            let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let open = scenario.start { await state.loadArchive(path: path) }
            try await scenario.entered(inspection)
            scenario.expect(state.isLoading, "The pending open must own its busy identity")
            await inspection.release()
            let loaded = try await scenario.finish(open)
            scenario.expect(loaded, "The standalone open must commit")
            scenario.expect(!state.isLoading, "The standalone open must leave no busy identity")
        }
    }

    func testBrowsePasswordResultDoesNotReleaseTheBusyStateOfARunningExtraction() async throws {
        let archiveURL = try makeArchiveFixture(named: "busy-browse")
        let path = archiveURL.path
        assertTemporaryFixturePath(path)
        await withBusyScenario { scenario in
            let extractionGate = scenario.barrier()
            let driver = self.makeGatedArchiveDriver(extractBarriers: [path: extractionGate])
            // The catalog is readable without credentials; only a correct payload password verifies it.
            driver.inspectHandler = { inspectedPath, _, _ in
                self.makeEncryptedInspectResult(path: inspectedPath)
            }
            driver.verifyPayloadHandler = { inspectedPath, _, candidate in
                guard candidate == self.correctPassword else {
                    throw ArchiveError.wrongPassword(archivePath: inspectedPath)
                }
                return Data("decrypted".utf8)
            }
            let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let extraction = scenario.start { await state.quickExtractArchive(archivePath: path, isSmartExtract: false) }
            try await scenario.entered(extractionGate)
            scenario.expect(state.isLoading, "The running extraction must own a busy identity")
            let open = scenario.start { await state.loadArchive(path: path, password: "incorrect-mm49-password") }
            let loaded = try await scenario.finish(open)
            scenario.expect(!loaded, "Wrong-password inspection must stage a prompt, not commit")
            scenario.expect(state.showPasswordPrompt, "The real open chain must stage its password prompt")
            scenario.expect(state.isLoading, "Staging the prompt must not release the extraction")
            let probesBeforeSubmission = driver.verifyPayloadCallCount
            scenario.expectEqual(probesBeforeSubmission, 1, "The explicit wrong password must fail one real payload probe before prompting")
            let submission = scenario.start { await state.submitArchivePassword(self.correctPassword) }
            let outcome = try await scenario.finish(submission)
            scenario.expectEqual(outcome, .verifiedAndResumed, "The real browse submission must verify and resume")
            scenario.expect(state.isLoading, "The browse result must not release the extraction")
            scenario.expectEqual(driver.verifyPayloadCallCount - probesBeforeSubmission, 1, "The real password payload probe must run once for the submitted candidate")
            scenario.expectEqual(driver.verifyPayloadCallCount, 2, "Wrong open and correct submission must each run exactly one payload probe")
            await extractionGate.release()
            try await scenario.finish(extraction)
            scenario.expect(!state.isLoading, "The extraction must release the final busy identity")
        }
    }
}
