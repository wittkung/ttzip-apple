// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import XCTest
@testable import TTZipApp
import TTZipCore
import TTZipUI

/// Regression test suite for the 4 mandatory review remediation items across Slices A, B, and C:
/// 1. Local file URL identity enforcement in `GoToFolderNavigationService` (Slice A)
/// 2. Cancellation & attempt generation ownership in `GoToFolderNavigationService` and `ServerConnectionService` (Slices A & C)
/// 3. End-to-end structured criteria & scope consumption for saved Smart Folders through production entry points (Slice B)
/// 4. Exact protocol/host/port/share endpoint matching for already-mounted volumes in `ServerConnectionService` (Slice C)
@MainActor
final class DockApplicationMenuReviewRemediationTests: XCTestCase {
    var tempRootURL: URL!
    var isolatedDefaults: UserDefaults!
    var isolatedSuiteName: String!
    var customSmartFolderFileURL: URL!

    func setUpFixtures() throws {
        let baseTemp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TTZipDockReviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseTemp, withIntermediateDirectories: true)
        tempRootURL = baseTemp

        isolatedSuiteName = "com.metastudyline.ttzip.tests.dock_review.\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: isolatedSuiteName)!
        customSmartFolderFileURL = baseTemp.appendingPathComponent("smart_folders_review.json")

        BrowserWindowRegistry.shared.resetForTesting()
        BrowserWindowRouter.shared.resetForTesting()

        SmartFolderStore.shared.configureStorageFileForTesting(customSmartFolderFileURL, reload: true)
        SmartFolderStore.shared.defaultDirectoryScanner = DefaultDirectoryRecursiveScanner()
        SmartFolderStore.shared.defaultSystemSearchProvider = SpotlightArchiveSearchProvider.shared
        SmartFolderStore.shared.defaultAccessChecker = { _ in true }
        SmartFolderStore.shared.additionalFullDiskScopeURLs = []
    }

    func tearDownFixtures() {
        BrowserWindowRegistry.shared.resetForTesting()
        BrowserWindowRouter.shared.resetForTesting()

        SmartFolderStore.shared.configureStorageFileForTesting(nil, reload: false)
        SmartFolderStore.shared.defaultAccessChecker = nil
        SmartFolderStore.shared.additionalFullDiskScopeURLs = []

        if let suite = isolatedSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        if let root = tempRootURL {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func makeDirectory(_ name: String) throws -> URL {
        let dir = tempRootURL.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func invokeMenuItem(_ item: NSMenuItem) {
        guard let action = item.action, let target = item.target as? NSObject else {
            XCTFail("Menu item '\(item.title)' is missing target or action")
            return
        }
        _ = target.perform(action, with: item)
    }

    // MARK: - 1. Local File URL Identity (Slice A)

    func testReview1_GoToFolderLocalURLIdentityRejectsRemoteAuthorityCredentialsPortQueryAndFragment() async throws {
        try setUpFixtures()
        defer { tearDownFixtures() }

        let startDir = try makeDirectory("StartDir")
        let localDirA = try makeDirectory("LocalDirA")
        let localDirB = try makeDirectory("LocalDirB")
        let specialDir = try makeDirectory("notes#draft dir")

        let win = AppViewState(fileViewer: NoOpFileViewer())
        win.navigateToDirectory(startDir)

        let service = GoToFolderNavigationService()
        service.accessCheckOverride = { _ in true }

        // Negative Controls: Remote authority, credentials, port, query, fragment, non-file scheme
        // Even though `localDirA.path` exists on the local machine, none of these may resolve to or open `localDirA`.
        let rejectedInputs = [
            "file://remote.example\(localDirA.path)",
            "file://evil.host.local\(localDirA.path)",
            "file://user:secret@localhost\(localDirA.path)",
            "file://user@localhost\(localDirA.path)",
            "file://localhost:123\(localDirA.path)",
            "file://\(localDirA.path)?subpath=inner",
            "file://\(localDirA.path)?",
            "file://\(localDirA.path)#section",
            "https://example.test\(localDirA.path)",
            "smb://nas.local\(localDirA.path)"
        ]

        for rejected in rejectedInputs {
            let parsed = GoToFolderNavigationService.parseInputToCanonicalURL(
                rawInput: rejected,
                relativeTo: startDir
            )
            if case .success(let unexpectedURL) = parsed {
                XCTFail("Expected parseInputToCanonicalURL to reject '\(rejected)', but got \(unexpectedURL)")
            }

            service.updateInput(rejected, baseDirectory: startDir)
            let submitResult = await service.submitAndNavigate(in: win)
            if case .success(let target) = submitResult {
                XCTFail("Expected submitAndNavigate to reject '\(rejected)', but navigated to \(target)")
            }
            XCTAssertNotNil(service.inlineErrorMessage, "Inline error must be retained for rejected input '\(rejected)'")
            XCTAssertEqual(
                win.currentDirectoryURL.standardizedFileURL,
                startDir.standardizedFileURL,
                "Rejected input '\(rejected)' must never navigate the browser window"
            )
        }

        // Direct `validateTargetOnDisk` negative check when given a non-local file:// URL object
        let remoteFileURL = try XCTUnwrap(URL(string: "file://remote.example\(localDirA.path)"))
        if case .success(let unexpected) = GoToFolderNavigationService.validateTargetOnDisk(url: remoteFileURL) {
            XCTFail("validateTargetOnDisk must reject remote file authority URL, got \(unexpected)")
        }

        // Positive Controls: Empty authority, localhost (case-insensitive), percent-encoded local path, POSIX path
        let encodedSpecialPath = specialDir.path
            .replacingOccurrences(of: "#", with: "%23")
            .replacingOccurrences(of: " ", with: "%20")

        let positiveCases: [(input: String, expected: URL)] = [
            ("file://\(localDirA.path)", localDirA),
            ("file://localhost\(localDirB.path)", localDirB),
            ("file://LOCALHOST\(localDirA.path)", localDirA),
            ("file://\(encodedSpecialPath)", specialDir),
            (localDirB.path, localDirB)
        ]

        for (input, expected) in positiveCases {
            service.updateInput(input, baseDirectory: startDir)
            let outcome = await service.submitAndNavigate(in: win)
            XCTAssertEqual(outcome, .success(.directory(expected.standardizedFileURL)), "Failed positive input: \(input)")
            XCTAssertNil(service.inlineErrorMessage)
            XCTAssertEqual(win.currentDirectoryURL.standardizedFileURL, expected.standardizedFileURL)
        }
    }

    // MARK: - 2. Cancellation & Attempt Ownership in GoToFolder & ConnectToServer (Slices A & C)

    func testReview2_GoToFolderAndConnectToServerCancellationAndStaleAttemptOwnership() async throws {
        try setUpFixtures()
        defer { tearDownFixtures() }

        let startDir = try makeDirectory("OriginDir")
        let folderA = try makeDirectory("FolderA_Stale")
        let folderB = try makeDirectory("FolderB_Winner")
        let folderC = try makeDirectory("FolderC_Cancelled")

        let win = AppViewState(fileViewer: NoOpFileViewer())
        win.navigateToDirectory(startDir)

        // --- Part 2A: GoToFolderNavigationService attempt ownership across await ---
        let goToService = GoToFolderNavigationService()
        let gateA = AsyncManualGate()

        goToService.accessCheckOverride = { url in
            if url.standardizedFileURL == folderA.standardizedFileURL {
                await gateA.wait()
                return true
            }
            return true
        }

        // Start attempt A (suspends in accessCheckOverride)
        goToService.updateInput(folderA.path, baseDirectory: startDir)
        let taskA = Task { @MainActor in
            await goToService.submitAndNavigate(in: win)
        }
        await gateA.waitUntilWaiterArrived()

        // User cancels / supersedes with attempt B -> B completes immediately
        goToService.cancelActiveSubmission()
        goToService.updateInput(folderB.path, baseDirectory: startDir)
        let outcomeB = await goToService.submitAndNavigate(in: win)
        XCTAssertEqual(outcomeB, .success(.directory(folderB.standardizedFileURL)))
        XCTAssertEqual(win.currentDirectoryURL.standardizedFileURL, folderB.standardizedFileURL)

        // Now stale attempt A resumes from await -> MUST NOT overwrite window navigation to folderA!
        gateA.open()
        _ = await taskA.value
        XCTAssertEqual(
            win.currentDirectoryURL.standardizedFileURL,
            folderB.standardizedFileURL,
            "Stale GoToFolder attempt A must not navigate after cancellation / supersession by B"
        )

        // Start attempt C -> cancel/close without a new attempt -> C resumes -> must not navigate to folderC
        let gateC = AsyncManualGate()
        goToService.accessCheckOverride = { url in
            if url.standardizedFileURL == folderC.standardizedFileURL {
                await gateC.wait()
                return true
            }
            return true
        }
        goToService.updateInput(folderC.path, baseDirectory: folderB)
        let taskC = Task { @MainActor in
            await goToService.submitAndNavigate(in: win)
        }
        await gateC.waitUntilWaiterArrived()
        goToService.cancelActiveSubmission()
        gateC.open()
        _ = await taskC.value
        XCTAssertEqual(
            win.currentDirectoryURL.standardizedFileURL,
            folderB.standardizedFileURL,
            "Cancelled GoToFolder attempt C must not navigate when its access check finishes late"
        )

        // --- Part 2B: ServerConnectionService attempt A suspended -> cancelled -> B succeeds -> A finishes late ---
        let mountA = try makeDirectory("MountA_Stale")
        let mountB = try makeDirectory("MountB_Winner")
        let mountGateA = AsyncManualGate()

        let transport = PerHostGateServerMountTransport { endpoint in
            if endpoint.host == "slow-a.local" {
                await mountGateA.wait()
                return [mountA]
            }
            return [mountB]
        }

        let serverService = ServerConnectionService(
            transport: transport,
            userDefaults: isolatedDefaults,
            loadRecentsOnInit: false
        )
        serverService.volumeAccessCheckOverride = { _ in true }

        // 1. Start attempt A (suspends in transport)
        let serverTaskA = Task { @MainActor in
            await serverService.connectAndNavigate(
                rawInput: "smb://slow-a.local/shareA",
                allowAuthenticationUI: false,
                in: win
            )
        }
        await mountGateA.waitUntilWaiterArrived()
        let endpointA = try ServerConnectionService.validateServerInput("smb://slow-a.local/shareA").get()
        XCTAssertEqual(serverService.state, .connecting(endpoint: endpointA))

        // 2. Cancel attempt A -> state becomes .cancelled
        serverService.cancelActiveConnection()
        XCTAssertEqual(serverService.state, .cancelled)

        // 3. Start attempt B -> B succeeds and navigates `win` to `mountB`
        let serverOutcomeB = await serverService.connectAndNavigate(
            rawInput: "smb://fast-b.local/shareB",
            allowAuthenticationUI: false,
            in: win
        )
        XCTAssertEqual(serverOutcomeB, .success(mountB.standardizedFileURL))
        XCTAssertEqual(
            serverService.state,
            .connected(mountPointURL: mountB.standardizedFileURL, reusedExistingMount: false)
        )
        XCTAssertEqual(win.currentDirectoryURL.standardizedFileURL, mountB.standardizedFileURL)

        // 4. Release attempt A so it arrives late after B is already connected
        mountGateA.open()
        _ = await serverTaskA.value

        // Stale A MUST NOT overwrite `serverService.state` to `.cancelled` or `mountA`, nor navigate `win` to `mountA`!
        XCTAssertEqual(
            serverService.state,
            .connected(mountPointURL: mountB.standardizedFileURL, reusedExistingMount: false),
            "Late completion of cancelled attempt A must never overwrite active attempt B's .connected state"
        )
        XCTAssertEqual(
            win.currentDirectoryURL.standardizedFileURL,
            mountB.standardizedFileURL,
            "Late completion of cancelled attempt A must never overwrite window navigation"
        )
    }

    // MARK: - 3. Smart Folder Structured Criteria & Full-Disk Production Consumption (Slice B)

    func testReview3_SmartFolderProductionConsumptionCombinedKindOnlyFullDiskReopenAndRefresh() async throws {
        try setUpFixtures()
        defer { tearDownFixtures() }

        let searchRoot = try makeDirectory("SmartFolderWorkspace")
        let nestedSubfolder = searchRoot.appendingPathComponent("report_subfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSubfolder, withIntermediateDirectories: true)

        let reportZip1 = searchRoot.appendingPathComponent("report_q1.zip")
        let report7z = searchRoot.appendingPathComponent("report_q1.7z")
        let reportTxt = searchRoot.appendingPathComponent("report_q1.txt")
        let otherZip = searchRoot.appendingPathComponent("other_archive.zip")
        let nestedChildFolder = nestedSubfolder.appendingPathComponent("deep_folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedChildFolder, withIntermediateDirectories: true)

        try Data("zip1".utf8).write(to: reportZip1)
        try Data("7z".utf8).write(to: report7z)
        try Data("txt".utf8).write(to: reportTxt)
        try Data("other".utf8).write(to: otherZip)

        let fullDiskDir = try makeDirectory("FullDiskIndexedScope")
        let fullDiskMatch7z = fullDiskDir.appendingPathComponent("ledger_2026.7z")
        let fullDiskNonMatchZip = fullDiskDir.appendingPathComponent("ledger_2026.zip")
        try Data("ledger7z".utf8).write(to: fullDiskMatch7z)
        try Data("ledgerzip".utf8).write(to: fullDiskNonMatchZip)

        SmartFolderStore.shared.defaultSystemSearchProvider = StaticSystemSearchProvider(items: [
            GlobalSearchResultItem(
                id: "spotlight:\(fullDiskMatch7z.path)",
                title: "ledger_2026.7z",
                subtitle: fullDiskMatch7z.path,
                hitType: .archiveFile,
                archivePath: fullDiskMatch7z.path,
                isDirectory: false,
                byteSize: 8,
                score: 0.9
            ),
            GlobalSearchResultItem(
                id: "spotlight:\(fullDiskNonMatchZip.path)",
                title: "ledger_2026.zip",
                subtitle: fullDiskNonMatchZip.path,
                hitType: .archiveFile,
                archivePath: fullDiskNonMatchZip.path,
                isDirectory: false,
                byteSize: 9,
                score: 0.9
            )
        ])

        let win = AppViewState(fileViewer: NoOpFileViewer())
        win.navigateToDirectory(tempRootURL)
        BrowserWindowRegistry.shared.register(win)

        // 1. Save & Open combined criteria (nameQuery: "report", fileExtension: "zip", kindFilter: .archivesOnly)
        let combinedRecord = try win.saveAndActivateSmartFolder(
            editingID: nil,
            name: "Q1 Zip Reports",
            criteria: SmartFolderCriteria(
                nameQuery: "report",
                fileExtension: "zip",
                kindFilter: .archivesOnly
            ),
            scope: .directory(path: searchRoot.path, bookmarkData: nil)
        )
        await win.waitForActiveSmartFolderEvaluation()

        XCTAssertEqual(win.overlayState.activeSmartFolderID, combinedRecord.id)
        XCTAssertEqual(win.overlayState.activeSmartFolderRecord?.criteria, combinedRecord.criteria)
        XCTAssertEqual(
            win.overlayState.activeSmartFolderResult?.items.map(\.title),
            ["report_q1.zip"],
            "Combined criteria must filter by nameQuery + fileExtension + kindFilter, excluding .7z, .txt, and folders"
        )

        // 2. Kind-only Smart Folder (nameQuery: "", fileExtension: "", kindFilter: .foldersOnly) via real Dock menu action
        let kindOnlyRecord = try SmartFolderStore.shared.createSmartFolder(
            name: "All Folders Only",
            criteria: SmartFolderCriteria(
                nameQuery: "",
                fileExtension: "",
                kindFilter: .foldersOnly
            ),
            scope: .directory(path: searchRoot.path, bookmarkData: nil)
        )

        let dockMenu1 = DockMenuController.shared.buildDockMenu()
        let kindOnlyMenuItem = try XCTUnwrap(
            dockMenu1.items.first(where: {
                $0.tag == DockMenuController.ItemTag.smartFolderItem.rawValue && $0.title == "All Folders Only"
            })
        )

        invokeMenuItem(kindOnlyMenuItem)
        await win.waitForActiveSmartFolderEvaluation()

        XCTAssertEqual(win.overlayState.activeSmartFolderID, kindOnlyRecord.id)
        XCTAssertNotEqual(win.explorerState.searchQuery, "*", "Kind-only Smart Folder must never inject literal '*' into searchQuery")
        let folderTitles = Set(win.overlayState.activeSmartFolderResult?.items.map(\.title) ?? [])
        XCTAssertEqual(
            folderTitles,
            Set(["report_subfolder", "deep_folder"]),
            "Kind-only folders Smart Folder must recursively find folders and exclude files/archives"
        )

        // 3. Full-Disk Smart Folder opened from real Dock menu action must execute & display results (NOT open editor modal)
        let fullDiskRecord = try SmartFolderStore.shared.createSmartFolder(
            name: "Full Disk 7z Ledgers",
            criteria: SmartFolderCriteria(
                nameQuery: "ledger",
                fileExtension: "7z",
                kindFilter: .archivesOnly
            ),
            scope: .fullDisk
        )
        let dockMenu2 = DockMenuController.shared.buildDockMenu()
        let fullDiskMenuItem = try XCTUnwrap(
            dockMenu2.items.first(where: {
                $0.tag == DockMenuController.ItemTag.smartFolderItem.rawValue && $0.title == "Full Disk 7z Ledgers"
            })
        )

        win.overlayState.showSmartFolderModal = false
        invokeMenuItem(fullDiskMenuItem)
        await win.waitForActiveSmartFolderEvaluation()

        XCTAssertFalse(
            win.overlayState.showSmartFolderModal,
            "Opening a saved Full-Disk Smart Folder must consume and display results in the window, not merely open the editor modal"
        )
        XCTAssertEqual(win.overlayState.activeSmartFolderID, fullDiskRecord.id)
        XCTAssertEqual(
            win.overlayState.activeSmartFolderResult?.items.map(\.title),
            ["ledger_2026.7z"]
        )

        // 4. Close / Restart / Reopen from Dock menu preserves full structured criteria
        win.deactivateSmartFolder()
        XCTAssertNil(win.overlayState.activeSmartFolderID)
        XCTAssertNil(win.overlayState.activeSmartFolderResult)

        SmartFolderStore.shared.loadFromStorage()
        let dockMenu3 = DockMenuController.shared.buildDockMenu()
        let reopenCombinedItem = try XCTUnwrap(
            dockMenu3.items.first(where: {
                $0.tag == DockMenuController.ItemTag.smartFolderItem.rawValue && $0.title == "Q1 Zip Reports"
            })
        )

        invokeMenuItem(reopenCombinedItem)
        await win.waitForActiveSmartFolderEvaluation()
        XCTAssertEqual(win.overlayState.activeSmartFolderID, combinedRecord.id)
        XCTAssertEqual(win.overlayState.activeSmartFolderResult?.items.map(\.title), ["report_q1.zip"])

        // 5. Add & remove files on disk -> production `refreshActiveSmartFolder()` updates displayed items
        let reportZip2 = searchRoot.appendingPathComponent("report_q2.zip")
        try Data("zip2".utf8).write(to: reportZip2)
        try FileManager.default.removeItem(at: reportZip1)

        win.refreshActiveSmartFolder()
        await win.waitForActiveSmartFolderEvaluation()
        XCTAssertEqual(
            win.overlayState.activeSmartFolderResult?.items.map(\.title),
            ["report_q2.zip"]
        )
    }

    // MARK: - 4. Exact Endpoint Identity Matching for Already-Mounted Volumes (Slice C)

    func testReview4_FindAlreadyMountedVolumeRequiresExactProtocolHostPortAndShareIdentity() throws {
        try setUpFixtures()
        defer { tearDownFixtures() }

        let wrongHostMount = try makeDirectory("Mount_OtherNAS")
        let wrongShareMount = try makeDirectory("Mount_WrongShare")
        let wrongPortMount = try makeDirectory("Mount_WrongPort")
        let wrongSchemeMount = try makeDirectory("Mount_AFP")
        let wrongCaseShareMount = try makeDirectory("Mount_LowerCaseShare")
        let unparseableMount = try makeDirectory("Mount_LocalAPFS")
        let exactMatchMount = try makeDirectory("Mount_ExactTeamDocs")

        let service = ServerConnectionService(
            transport: ControlledServerMountTransport(behavior: .succeed(mountPoints: [])),
            userDefaults: isolatedDefaults,
            loadRecentsOnInit: false
        )

        service.mountedVolumeSourcesProvider = {
            [
                MountedVolumeSourceDescriptor(
                    mountPointURL: wrongHostMount,
                    volumeName: "media",
                    fileSystemTypeName: "smbfs",
                    mountFromName: "//kevin@othernas.local/media"
                ),
                MountedVolumeSourceDescriptor(
                    mountPointURL: wrongShareMount,
                    volumeName: "media",
                    fileSystemTypeName: "smbfs",
                    mountFromName: "//kevin@nas.local/backup_media"
                ),
                MountedVolumeSourceDescriptor(
                    mountPointURL: wrongPortMount,
                    volumeName: "media",
                    fileSystemTypeName: "smbfs",
                    mountFromName: "//kevin@nas.local:1445/media"
                ),
                MountedVolumeSourceDescriptor(
                    mountPointURL: wrongSchemeMount,
                    volumeName: "media",
                    fileSystemTypeName: "afpfs",
                    mountFromName: "afp://kevin@nas.local/media"
                ),
                MountedVolumeSourceDescriptor(
                    mountPointURL: wrongCaseShareMount,
                    volumeName: "team docs",
                    fileSystemTypeName: "smbfs",
                    mountFromName: "//kevin@nas.local/team%20docs"
                ),
                MountedVolumeSourceDescriptor(
                    mountPointURL: unparseableMount,
                    volumeName: "media",
                    fileSystemTypeName: "apfs",
                    mountFromName: "//nas.local/media"
                )
            ]
        }

        // 1. Substring host `nas.local` must NOT match `othernas.local`, wrong share, wrong port, wrong scheme, or APFS
        let mediaEndpoint = try ServerConnectionService.validateServerInput("smb://nas.local/media").get()
        XCTAssertNil(
            service.findAlreadyMountedVolume(for: mediaEndpoint),
            "Must not reuse othernas.local, wrong share, wrong port 1445, AFP, or APFS mount for smb://nas.local/media"
        )

        // 2. Host `nas` must NOT match `othernas.local`
        let shortHostEndpoint = try ServerConnectionService.validateServerInput("smb://nas/media").get()
        XCTAssertNil(
            service.findAlreadyMountedVolume(for: shortHostEndpoint),
            "Substring host 'nas' must never match 'othernas.local'"
        )

        // 3. Share case difference (`Team Docs` vs `team docs`) and escaped slash (`Team%2FDocs` vs `Team/Docs`) must NOT match
        let teamDocsEndpoint = try ServerConnectionService.validateServerInput("smb://NAS.LOCAL:445/Team%20Docs").get()
        XCTAssertNil(
            service.findAlreadyMountedVolume(for: teamDocsEndpoint),
            "Case-different share 'team docs' must not match 'Team Docs'"
        )

        // 4. Add exact matching mount (`//kevin@nas.local/Team%20Docs` on `smbfs`, implicit default port 445)
        service.mountedVolumeSourcesProvider = {
            [
                MountedVolumeSourceDescriptor(
                    mountPointURL: wrongHostMount,
                    volumeName: "Team Docs",
                    fileSystemTypeName: "smbfs",
                    mountFromName: "//kevin@othernas.local/Team%20Docs"
                ),
                MountedVolumeSourceDescriptor(
                    mountPointURL: exactMatchMount,
                    volumeName: "Team Docs",
                    fileSystemTypeName: "smbfs",
                    mountFromName: "//kevin@nas.local/Team%20Docs"
                )
            ]
        }

        XCTAssertEqual(
            service.findAlreadyMountedVolume(for: teamDocsEndpoint),
            exactMatchMount.standardizedFileURL,
            "Exact protocol (smbfs), case-insensitive host (NAS.LOCAL == nas.local), default port (445), and percent-decoded share ('Team Docs') must match"
        )
    }
}

// MARK: - Deterministic Test Helpers

@MainActor
final class AsyncManualGate {
    private var isOpen = false
    private var waiterContinuation: CheckedContinuation<Void, Never>?
    private var arrivedContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiterContinuation = cont
            arrivedContinuation?.resume()
            arrivedContinuation = nil
        }
    }

    func waitUntilWaiterArrived() async {
        if waiterContinuation != nil || isOpen { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            arrivedContinuation = cont
        }
    }

    func open() {
        isOpen = true
        waiterContinuation?.resume()
        waiterContinuation = nil
    }
}

final class PerHostGateServerMountTransport: ServerMountTransport, @unchecked Sendable {
    private let handler: @Sendable (ValidatedServerEndpoint) async throws -> [URL]

    init(handler: @escaping @Sendable (ValidatedServerEndpoint) async throws -> [URL]) {
        self.handler = handler
    }

    func mountShare(endpoint: ValidatedServerEndpoint, allowAuthenticationUI: Bool) async throws -> [URL] {
        try await handler(endpoint)
    }
}

struct StaticSystemSearchProvider: SystemFileSearchProviding {
    let items: [GlobalSearchResultItem]

    func searchAllAccessibleItems(
        query: String,
        maxResults: Int,
        additionalScopes: [URL]
    ) async -> [GlobalSearchResultItem] {
        items
    }
}
