// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
import TTZipPreviewKit
import TTZipUI
@testable import TTZipApp
@testable import TTZipCore

@MainActor
final class ArchiveEntryPreviewPasswordRoutingTests: ArchiveHostAcceptanceTestCase {
    private let selectedPath = "README.txt"
    private let otherPath = "smaller-secret.txt"

    func testEncryptedAcceptedEntryDoubleClickRequestsPasswordBeforeExtraction() async throws {
        let (state, driver, archive) = try await preparedState()
        let item = try XCTUnwrap(state.selectedDiskItem)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archive.path))

        let cache = PreviewLRUCacheManager(customCacheDir: try makeDestinationDirectory())
        let extraction = ControlledEntryPreviewExtraction()
        let opened = await state.activateExplorerItem(
            item,
            createAppKitWindow: false,
            cacheManager: cache,
            customExtractor: { path, entry, destination, password in
                try await extraction.extract(path: path, entry: entry, destination: destination, password: password)
            }
        )

        XCTAssertFalse(opened)
        XCTAssertTrue(state.showPasswordPrompt)
        let extractionCount = await extraction.count
        let stagingCount = await cache.activeStagingCount()
        XCTAssertEqual(extractionCount, 0)
        XCTAssertEqual(stagingCount, 0)
        XCTAssertEqual(inspectCount(driver), 1)
        state.cancelPasswordPrompt()
        await cache.purgeAll()
    }

    func testEncryptedAcceptedEntryRequestsPasswordBeforePreviewWhenNoCandidateExists() async throws {
        let (state, driver, archive) = try await preparedState()
        let item = try XCTUnwrap(state.selectedDiskItem)
        let request = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: item.path))
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archive.path))
        XCTAssertTrue(state.requiresPasswordForArchiveEntryPreview(request))

        let cache = PreviewLRUCacheManager(customCacheDir: try makeDestinationDirectory())
        let extraction = ControlledEntryPreviewExtraction()
        let result = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archive.path,
            subpath: selectedPath,
            cacheManager: cache,
            passwordRequiredWithoutCache: true,
            customExtractor: { path, entry, destination, password in
                try await extraction.extract(path: path, entry: entry, destination: destination, password: password)
            }
        )
        let failure = try XCTUnwrap(result.failure)
        XCTAssertEqual(failure, .archive(.passwordRequired, attemptedPassword: nil))
        let extractionCount = await extraction.count
        XCTAssertEqual(extractionCount, 0)
        let stagingCount = await cache.activeStagingCount()
        XCTAssertEqual(stagingCount, 0)
        state.acceptArchiveEntryPreviewFailure(failure, request: request)
        XCTAssertTrue(state.showPasswordPrompt)
        XCTAssertEqual(inspectCount(driver), 1)

        state.cancelPasswordPrompt()
        XCTAssertFalse(state.showPasswordPrompt)
        ArchivePasswordStore.shared.setPassword(correctPassword, for: archive.path)
        defer { ArchivePasswordStore.shared.removePassword(for: archive.path) }
        XCTAssertFalse(state.requiresPasswordForArchiveEntryPreview(request))

        let filled = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archive.path, subpath: selectedPath, cacheManager: cache,
            customExtractor: { path, entry, destination, password in
                try await extraction.extract(path: path, entry: entry, destination: destination, password: password)
            }
        )
        XCTAssertNotNil(filled.url)
        if let lease = filled.lease { await cache.releaseLease(lease) }
        ArchivePasswordStore.shared.removePassword(for: archive.path)
        XCTAssertTrue(state.requiresPasswordForArchiveEntryPreview(request))
        let cached = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archive.path, subpath: selectedPath, cacheManager: cache,
            passwordRequiredWithoutCache: true
        )
        XCTAssertNotNil(cached.url)
        XCTAssertNil(cached.failure)
        if let lease = cached.lease { await cache.releaseLease(lease) }
        let finalExtractionCount = await extraction.count
        XCTAssertEqual(finalExtractionCount, 1)
        await cache.purgeAll()
    }

    func testAcceptedEntryPasswordResumeRetriesPreviewWithoutReinspectionOrHistoryCommit() async throws {
        let (state, driver, archive) = try await preparedState()
        let item = try XCTUnwrap(state.selectedDiskItem)
        let request = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: item.path))
        let history = state.navigationState.activeTabSession?.historyStack
        let location = state.navigationState.currentDirectory
        let cache = PreviewLRUCacheManager(customCacheDir: try makeDestinationDirectory())
        let extraction = ControlledEntryPreviewExtraction()
        let extractor: ExplorerItemInspectorView.VirtualEntryExtractor = { path, entry, destination, password in
            try await extraction.extract(path: path, entry: entry, destination: destination, password: password)
        }
        let first = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archive.path, subpath: selectedPath, cacheManager: cache, customExtractor: extractor
        )
        let failure = try XCTUnwrap(first.failure)
        XCTAssertTrue(failure.isPasswordRelated)
        XCTAssertNil(first.url)
        state.acceptArchiveEntryPreviewFailure(failure, request: request)
        XCTAssertTrue(state.showPasswordPrompt)
        driver.verifyPayloadHandler = { _, entry, password in
            XCTAssertEqual(entry, self.selectedPath, "Do not verify the smaller sibling instead of the selected entry")
            return password == self.correctPassword ? Data("verified".utf8) : nil
        }
        let displayReceipt = ArchiveHostCompletionReceipt<Bool>()
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil, queue: .main
        ) { notification in
            let name = notification.name
            let objectPath = notification.object as? String
            let windowID = notification.userInfo?["windowID"] as? UUID
            let previewEntryPath = notification.userInfo?["previewEntryPath"] as? String
            let shouldRetry = MainActor.assumeIsolated {
                var userInfo: [AnyHashable: Any] = [:]
                if let windowID { userInfo["windowID"] = windowID }
                if let previewEntryPath { userInfo["previewEntryPath"] = previewEntryPath }
                let delivered = Notification(
                    name: name, object: objectPath, userInfo: userInfo.isEmpty ? nil : userInfo
                )
                return state.shouldRetryArchiveEntryPreview(request, notification: delivered)
            }
            Task { await displayReceipt.store(shouldRetry) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let outcome = await state.submitArchivePassword(correctPassword)
        XCTAssertEqual(outcome, .verifiedAndResumed)
        let shouldRetry = await displayReceipt.waitForValue(timeout: .seconds(2))
        XCTAssertEqual(shouldRetry, true)
        XCTAssertEqual(state.navigationState.activeTabSession?.historyStack, history)
        XCTAssertEqual(state.navigationState.currentDirectory, location)
        XCTAssertEqual(state.passwordEvidenceState, .verified(.selectedEntries([selectedPath])))
        XCTAssertEqual(inspectCount(driver), 1)
        XCTAssertEqual(driver.verifyPayloadCallCount, 1)
        let second = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archive.path, subpath: selectedPath, cacheManager: cache, customExtractor: extractor
        )
        XCTAssertNotNil(second.url)
        XCTAssertNil(second.failure)
        let extractionCount = await extraction.count
        XCTAssertEqual(extractionCount, 2, "One failed read and one display retry, without another inspection")
        XCTAssertEqual(inspectCount(driver), 1)
        if let lease = second.lease { await cache.releaseLease(lease) }
        await cache.purgeAll()
        state.navigationState.goUp()
        state.navigationState.goBack()
        XCTAssertEqual(state.passwordEvidenceState, .verified(.selectedEntries([selectedPath])))
        XCTAssertEqual(inspectCount(driver), 1, "Evidence restoration retains the accepted projection")
    }

    func testNonPasswordAndCancelledReadFailuresStayTypedAndNeverStagePassword() async throws {
        let (state, _, archive) = try await preparedState()
        let item = try XCTUnwrap(state.selectedDiskItem)
        let request = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: item.path))
        let errors: [any Error] = [
            ArchiveError.corruptedData(archivePath: archive.path, entryPath: selectedPath),
            ArchiveError.unsupportedEncryptionMethod(archivePath: archive.path, method: "controlled"),
            CocoaError(.fileReadNoPermission), CancellationError()
        ]
        for error in errors {
            let cache = PreviewLRUCacheManager(customCacheDir: try makeDestinationDirectory())
            let resolution = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
                archivePath: archive.path, subpath: selectedPath, cacheManager: cache,
                customExtractor: { _, _, _, _ in throw error }
            )
            let failure = try XCTUnwrap(resolution.failure)
            XCTAssertFalse(failure.isPasswordRelated)
            if error is CancellationError {
                XCTAssertEqual(failure, .cancelled)
            } else {
                XCTAssertFalse(failure.message.isEmpty, "The inspector must have an error to display")
            }
            state.acceptArchiveEntryPreviewFailure(failure, request: request)
            XCTAssertFalse(state.showPasswordPrompt)
            XCTAssertNil(state.pendingPasswordContext)
            let stagingCount = await cache.activeStagingCount()
            XCTAssertEqual(stagingCount, 0)
            await cache.purgeAll()
        }
    }

    func testLateReadFailureCannotPromptAfterNavigationOrSelectionChanged() async throws {
        for mode in ["historyABA", "tabABA", "selection"] {
            let (state, _, archive) = try await preparedState()
            let originSessionID = state.navigationState.activeSessionID
            let otherDir = try makeDestinationDirectory()
            let item = try XCTUnwrap(state.selectedDiskItem)
            let request = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: item.path))
            let cache = PreviewLRUCacheManager(customCacheDir: try makeDestinationDirectory())
            await withBusyScenario { scenario in
                let read = scenario.barrier()
                let result = scenario.start {
                    await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
                        archivePath: archive.path, subpath: self.selectedPath, cacheManager: cache,
                        customExtractor: { _, _, _, _ in
                            await read.suspendUntilReleased()
                            throw ArchiveError.passwordRequired
                        }
                    )
                }
                try await scenario.entered(read)
                if mode == "historyABA" {
                    state.navigationState.goUp()
                    state.navigationState.goBack()
                } else if mode == "tabABA" {
                    state.navigationState.openNewTab(url: otherDir)
                    state.navigationState.switchToTab(id: originSessionID)
                    state.selectArchiveEntry(path: self.selectedPath, inArchive: archive.path)
                } else {
                    state.selectArchiveEntry(path: self.otherPath, inArchive: archive.path)
                }
                await read.release()
                let resolution = try await scenario.finish(result)
                let failure = try XCTUnwrap(resolution.failure)
                state.acceptArchiveEntryPreviewFailure(failure, request: request)
                scenario.expect(!state.showPasswordPrompt, "A stale failure must not stage a password operation (\(mode))")
                scenario.expect(state.pendingPasswordContext == nil, "A stale failure has no resumable context (\(mode))")
            }
            await cache.purgeAll()
        }
    }

    func testSelectionChangedDuringPasswordProbeCannotCommitCredentials() async throws {
        for leaveTab in [false, true] {
            let (state, driver, archive) = try await preparedState()
            let otherDir = try makeDestinationDirectory()
            let item = try XCTUnwrap(state.selectedDiskItem)
            let request = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: item.path))
            state.acceptArchiveEntryPreviewFailure(.archive(.passwordRequired, attemptedPassword: nil), request: request)
            await withBusyScenario { scenario in
                let probe = scenario.barrier()
                driver.verifyPayloadHandler = { _, _, _ in
                    await probe.suspendUntilReleased()
                    return Data("verified".utf8)
                }
                let submission = scenario.start { await state.submitArchivePassword(self.correctPassword) }
                try await scenario.entered(probe)
                if leaveTab {
                    state.navigationState.openNewTab(url: otherDir)
                } else {
                    state.selectArchiveEntry(path: self.otherPath, inArchive: archive.path)
                }
                await probe.release()
                let outcome = try await scenario.finish(submission)
                scenario.expectEqual(outcome, .cancelledOrStale, "An abandoned selected-entry probe must not succeed")
                scenario.expect(ArchivePasswordStore.shared.getPassword(for: archive.path) == nil, "A stale probe must not publish its candidate")
                scenario.expect(!state.showPasswordPrompt, "The stale entry prompt must close")
                scenario.expectEqual(self.inspectCount(driver), 1, "Preview verification must not re-inspect the archive")
            }
        }
    }

    func testNoEvidenceForSelectedEntryDoesNotUseAnotherEntryOrCacheCandidate() async throws {
        let (state, driver, archive) = try await preparedState(selectedSize: 0)
        let item = try XCTUnwrap(state.selectedDiskItem)
        let request = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: item.path))
        state.acceptArchiveEntryPreviewFailure(.archive(.passwordRequired, attemptedPassword: nil), request: request)
        let outcome = await state.submitArchivePassword(correctPassword)
        guard case .nonPasswordFailure = outcome else {
            return XCTFail("Missing selected-entry evidence must not be accepted as success: \(outcome)")
        }
        XCTAssertEqual(driver.verifyPayloadCallCount, 0, "The qualifying sibling must not stand in for the selected entry")
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archive.path))
        XCTAssertEqual(inspectCount(driver), 1)
    }

    func testCancelledPreviewTaskCannotStageAnOtherwiseCurrentPasswordFailure() async throws {
        let (state, _, _) = try await preparedState()
        let item = try XCTUnwrap(state.selectedDiskItem)
        let request = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: item.path))
        await withBusyScenario { scenario in
            let delivery = scenario.barrier()
            let operation = scenario.start {
                await delivery.suspendUntilReleased()
                state.acceptArchiveEntryPreviewFailure(
                    .archive(.passwordRequired, attemptedPassword: nil), request: request
                )
                return state.showPasswordPrompt
            }
            try await scenario.entered(delivery)
            operation.task.cancel()
            await delivery.release()
            let presented = try await scenario.finish(operation)
            scenario.expect(!presented, "Cancellation must reject even a matching navigation/selection identity")
            scenario.expect(state.pendingPasswordContext == nil, "A cancelled preview owns no password operation")
        }
    }

    func testDisplayRetryRejectsWrongWindowAndStaleSelection() async throws {
        let (state, _, archive) = try await preparedState()
        let item = try XCTUnwrap(state.selectedDiskItem)
        let request = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: item.path))
        let otherWindow = Notification(
            name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: archive.path,
            userInfo: ["windowID": UUID(), "previewEntryPath": selectedPath]
        )
        XCTAssertFalse(state.shouldRetryArchiveEntryPreview(request, notification: otherWindow))
        let matching = Notification(
            name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: archive.path,
            userInfo: ["windowID": state.windowID, "previewEntryPath": selectedPath]
        )
        XCTAssertTrue(state.shouldRetryArchiveEntryPreview(request, notification: matching))
        let displayOnly = Notification(name: matching.name, object: archive.path, userInfo: ["windowID": state.windowID])
        XCTAssertFalse(state.shouldRetryArchiveEntryPreview(request, notification: displayOnly))
        state.selectArchiveEntry(path: otherPath, inArchive: archive.path)
        XCTAssertFalse(state.shouldRetryArchiveEntryPreview(request, notification: matching))
    }

    func testGoUpToArchiveRootAndSelectionReplacementStageCurrentEntryPasswordOwner() async throws {
        let (state, driver, archive) = try await preparedState()
        let childDir = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(archivePath: archive.path, entrySubpath: "docs"))
        let rootColumnURL = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(archivePath: archive.path, entrySubpath: ""))
        state.navigationState.navigateTo(childDir)
        state.navigationState.goUp()
        // FinderMillerColumnsView+Selection sets selected entry then assigns column dirURL (?subpath=).
        state.selectArchiveEntry(path: selectedPath, inArchive: archive.path)
        state.navigationState.currentDirectory = rootColumnURL
        let firstItem = try XCTUnwrap(state.selectedDiskItem)
        let firstRequest = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: firstItem.path))
        XCTAssertTrue(state.isArchiveEntryPreviewRequestCurrent(firstRequest))
        state.acceptArchiveEntryPreviewFailure(.archive(.passwordRequired, attemptedPassword: nil), request: firstRequest)
        XCTAssertTrue(state.showPasswordPrompt)

        // Switching selection while the first entry's prompt is open must retire the stale prompt and accept the new entry's failure.
        state.selectArchiveEntry(path: otherPath, inArchive: archive.path)
        XCTAssertFalse(state.showPasswordPrompt)
        XCTAssertNil(state.pendingPasswordContext)
        let secondItem = try XCTUnwrap(state.selectedDiskItem)
        let secondRequest = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: secondItem.path))
        state.acceptArchiveEntryPreviewFailure(.archive(.passwordRequired, attemptedPassword: nil), request: secondRequest)
        XCTAssertTrue(state.showPasswordPrompt)
        driver.verifyPayloadHandler = { _, entry, password in
            XCTAssertEqual(entry, self.otherPath)
            return password == self.correctPassword ? Data("verified".utf8) : nil
        }
        let outcome = await state.submitArchivePassword(correctPassword)
        XCTAssertEqual(outcome, .verifiedAndResumed)
        XCTAssertEqual(state.passwordEvidenceState, .verified(.selectedEntries([otherPath])))
    }

    func testArchiveAddressAliasKeepsReadSourceCredentialAndBrowsingOwner() async throws {
        let archive = try makeArchiveFixture(named: "alias-preview")
        let sourcePath = archive.standardizedFileURL.path
        let aliasPath = "/private" + sourcePath
        XCTAssertNotEqual(aliasPath, sourcePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aliasPath))
        XCTAssertEqual(URL(fileURLWithPath: aliasPath).standardizedFileURL.path, sourcePath)
        let driver = MockArchivePasswordDriver()
        let entry = ArchiveEntry(
            path: selectedPath, uncompressedSize: 128, isDirectory: false, modificationDate: nil,
            isEncrypted: true, compressedSize: 128, crc32: nil
        )
        driver.inspectHandler = { path, _, _ in
            InspectResult(archivePath: path, format: "zip", entries: [entry],
                          totalUncompressedBytes: 128, totalCompressedBytes: 128, unlockedPassword: nil)
        }
        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        let loaded = await state.loadArchive(path: aliasPath)
        XCTAssertTrue(loaded)
        state.selectArchiveEntry(path: selectedPath, inArchive: sourcePath)
        let item = try XCTUnwrap(state.selectedDiskItem)
        let history = state.navigationState.activeTabSession?.historyStack
        XCTAssertEqual(history?.current.path, aliasPath)
        let request = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: item.path))
        state.acceptArchiveEntryPreviewFailure(.archive(.passwordRequired, attemptedPassword: nil), request: request)
        XCTAssertTrue(state.showPasswordPrompt)
        XCTAssertEqual(state.pendingPasswordContext?.archivePath, sourcePath)
        driver.verifyPayloadHandler = { path, entry, password in
            XCTAssertEqual(path, sourcePath)
            XCTAssertEqual(entry, self.selectedPath)
            return password == self.correctPassword ? Data("verified".utf8) : nil
        }
        let outcome = await state.submitArchivePassword(correctPassword)
        XCTAssertEqual(outcome, .verifiedAndResumed)
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: sourcePath), correctPassword)
        XCTAssertEqual(state.navigationState.activeTabSession?.historyStack, history)
        XCTAssertEqual(inspectCount(driver), 1)
        let refresh = Notification(
            name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: sourcePath,
            userInfo: ["windowID": state.windowID, "previewEntryPath": selectedPath]
        )
        XCTAssertTrue(state.shouldRetryArchiveEntryPreview(request, notification: refresh))
    }

    func testCancelledEntryPasswordPromptCanRetryExplicitlyAndVerifySelectedEntryWithoutReinspection() async throws {
        let (state, driver, archive) = try await preparedState()
        let item = try XCTUnwrap(state.selectedDiskItem)
        let request = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: item.path))
        let history = state.navigationState.activeTabSession?.historyStack
        let location = state.navigationState.currentDirectory
        let initialEpoch = state.operationEpoch
        let cache = PreviewLRUCacheManager(customCacheDir: try makeDestinationDirectory())
        let extraction = ControlledEntryPreviewExtraction()
        let extractor: ExplorerItemInspectorView.VirtualEntryExtractor = { path, entry, destination, password in
            try await extraction.extract(path: path, entry: entry, destination: destination, password: password)
        }
        let first = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archive.path, subpath: selectedPath, cacheManager: cache, customExtractor: extractor
        )
        let failure = try XCTUnwrap(first.failure)
        state.acceptArchiveEntryPreviewFailure(failure, request: request)
        XCTAssertTrue(state.showPasswordPrompt)
        XCTAssertFalse(ExplorerItemInspectorView.canRetryPasswordLockedPreviewPrompt(failure: failure, request: request, in: state))
        XCTAssertFalse(ExplorerItemInspectorView.retryPasswordLockedPreviewPrompt(failure: failure, request: request, in: state))

        state.cancelPasswordPrompt()
        XCTAssertFalse(state.showPasswordPrompt)
        XCTAssertNil(state.pendingPasswordContext)
        XCTAssertEqual(state.passwordEvidenceState, .directoryBrowsableUnverified)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archive.path))
        XCTAssertEqual(state.selectedDiskItem?.path, item.path)
        XCTAssertEqual(state.selectedEntryID, selectedPath)
        XCTAssertEqual(state.navigationState.currentDirectory, location)
        XCTAssertEqual(state.navigationState.activeTabSession?.historyStack, history)
        XCTAssertEqual(state.operationEpoch, initialEpoch)
        XCTAssertEqual(inspectCount(driver), 1)

        XCTAssertTrue(ExplorerItemInspectorView.canRetryPasswordLockedPreviewPrompt(failure: failure, request: request, in: state))
        XCTAssertTrue(ExplorerItemInspectorView.retryPasswordLockedPreviewPrompt(failure: failure, request: request, in: state))
        XCTAssertTrue(state.showPasswordPrompt)
        XCTAssertEqual(state.pendingPasswordContext?.windowID, state.windowID)
        XCTAssertEqual(state.pendingPasswordContext?.tabID, request.sessionID)
        XCTAssertEqual(state.pendingPasswordContext?.archivePath, request.archivePath)
        XCTAssertEqual(inspectCount(driver), 1)
        XCTAssertEqual(state.navigationState.activeTabSession?.historyStack, history)

        driver.verifyPayloadHandler = { _, entry, password in
            XCTAssertEqual(entry, self.selectedPath)
            return password == self.correctPassword ? Data("verified".utf8) : nil
        }
        let outcome = await state.submitArchivePassword(correctPassword)
        XCTAssertEqual(outcome, .verifiedAndResumed)
        XCTAssertEqual(state.passwordEvidenceState, .verified(.selectedEntries([selectedPath])))
        XCTAssertEqual(inspectCount(driver), 1)
        XCTAssertEqual(driver.verifyPayloadCallCount, 1)
        XCTAssertEqual(state.navigationState.activeTabSession?.historyStack, history)
        XCTAssertEqual(state.navigationState.currentDirectory, location)
        let second = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archive.path, subpath: selectedPath, cacheManager: cache, customExtractor: extractor
        )
        XCTAssertNotNil(second.url)
        XCTAssertNil(second.failure)
        let extractionCount = await extraction.count
        XCTAssertEqual(extractionCount, 2)
        if let lease = second.lease { await cache.releaseLease(lease) }
        await cache.purgeAll()
    }

    func testExplicitRetryRejectsSelectionNavigationTabCloseAndNonPasswordFailuresAfterCancel() async throws {
        for mode in ["nonPassword", "cancelled", "selection", "goUp", "newTab", "closeArchive", "closeWindow"] {
            let (state, driver, archive) = try await preparedState()
            let otherDir = try makeDestinationDirectory()
            let item = try XCTUnwrap(state.selectedDiskItem)
            let request = try XCTUnwrap(state.captureArchiveEntryPreviewRequest(itemPath: item.path))
            let passwordFailure = ArchiveEntryPreviewFailure.archive(.passwordRequired, attemptedPassword: nil)
            state.acceptArchiveEntryPreviewFailure(passwordFailure, request: request)
            state.cancelPasswordPrompt()
            XCTAssertFalse(state.showPasswordPrompt)

            let candidateFailure: ArchiveEntryPreviewFailure
            switch mode {
            case "nonPassword":
                candidateFailure = .archive(.corruptedData(archivePath: archive.path, entryPath: selectedPath), attemptedPassword: nil)
            case "cancelled":
                candidateFailure = .cancelled
            case "selection":
                candidateFailure = passwordFailure
                state.selectArchiveEntry(path: otherPath, inArchive: archive.path)
            case "goUp":
                candidateFailure = passwordFailure
                state.navigationState.goUp()
            case "newTab":
                candidateFailure = passwordFailure
                state.navigationState.openNewTab(url: otherDir)
            case "closeArchive":
                candidateFailure = passwordFailure
                state.closeCurrentArchive(discardAcceptedResources: true)
            default:
                candidateFailure = passwordFailure
                state.prepareForWindowClose()
            }

            XCTAssertFalse(
                ExplorerItemInspectorView.canRetryPasswordLockedPreviewPrompt(
                    failure: candidateFailure, request: request, in: state
                ),
                "Retry must be unavailable for mode \(mode)"
            )
            XCTAssertFalse(
                ExplorerItemInspectorView.retryPasswordLockedPreviewPrompt(
                    failure: candidateFailure, request: request, in: state
                ),
                "Retry must not stage a prompt for mode \(mode)"
            )
            XCTAssertFalse(state.showPasswordPrompt, "No prompt may open for mode \(mode)")
            XCTAssertNil(state.pendingPasswordContext, "No pending context may exist for mode \(mode)")
            XCTAssertEqual(inspectCount(driver), 1, "Negative control \(mode) must not re-inspect")
        }
    }

    private func preparedState(selectedSize: Int64 = 128) async throws -> (AppViewState, MockArchivePasswordDriver, URL) {
        let archive = try makeArchiveFixture(named: "selected-preview")
        let driver = MockArchivePasswordDriver()
        let entries = [(selectedPath, selectedSize), (otherPath, Int64(1))].map { path, size in
            ArchiveEntry(path: path, uncompressedSize: size, isDirectory: false, modificationDate: nil,
                         isEncrypted: true, compressedSize: size, crc32: nil)
        }
        driver.inspectHandler = { path, _, _ in
            InspectResult(archivePath: path, format: "zip", entries: entries,
                          totalUncompressedBytes: 129, totalCompressedBytes: 129, unlockedPassword: nil)
        }
        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        let loaded = await state.loadArchive(path: archive.path)
        XCTAssertTrue(loaded)
        state.selectArchiveEntry(path: selectedPath, inArchive: archive.path)
        return (state, driver, archive)
    }

    private func inspectCount(_ driver: MockArchivePasswordDriver) -> Int {
        driver.calls.filter { if case .inspect = $0.kind { return true }; return false }.count
    }
}

private actor ControlledEntryPreviewExtraction {
    private(set) var count = 0

    func extract(path: String, entry: String, destination: String, password: String?) throws {
        count += 1
        guard password != nil else { throw ArchiveError.passwordRequired }
        let target = URL(fileURLWithPath: destination).appendingPathComponent((entry as NSString).lastPathComponent)
        try Data("Selected encrypted entry".utf8).write(to: target, options: .atomic)
    }
}
