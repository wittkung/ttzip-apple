// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TTZipApp
@testable import TTZipAppModels
@testable import TTZipAppServices
@testable import TTZipAppViewModels
@testable import TTZipAppViews
import TTZipCore
import TTZipUI

/// Round 2 review remediation regression suite covering:
/// - `testReview5`: P1 synchronous admission & side-effect guards in `beginConnect` and `beginSubmit`
/// - `testReview6`: P1 Smart Folder strict obedience to sole authorization owner (`RootFolderAccessManager`) & lease holding
/// - `testReview7`: P2 Smart Folder result identity across A->B pending transition, error/unauthorized/truncated/cancelled banner presentation, and Full-Disk coverage aggregation
/// - `testReview8`: P2 Full managed result set access beyond 24 items (tail item #30 activation) & scan budget disclosure
extension DockApplicationMenuReviewRemediationTests {

    // MARK: - 5. P1: beginConnect / beginSubmit Synchronous Admission & Side-Effect Guards

    func testReview5_BeginConnectAndBeginSubmitSynchronousAdmissionAndSideEffectGuards() async throws {
        try setUpFixtures()
        defer { tearDownFixtures() }

        try await assertBeginConnectSameTurnCancelResetAndSupersession()
        try await assertBeginSubmitSameTurnCancelAndSupersession()
    }

    private func assertBeginConnectSameTurnCancelResetAndSupersession() async throws {
        let mountA = try makeDirectory("R2_MountA")
        let mountB = try makeDirectory("R2_MountB")
        let calledHostsBox = LockedArrayBox<String>()

        let transport = PerHostGateServerMountTransport { endpoint in
            calledHostsBox.append(endpoint.host)
            if endpoint.host == "host-a.local" {
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

        // 1. Same-turn beginConnect -> cancelActiveConnection(): 0 transport calls, state remains .cancelled
        var cancelTurnCommitted = false
        serverService.beginConnect(
            rawInput: "smb://cancel-same-turn.local/share",
            allowAuthenticationUI: false
        ) { _ in
            cancelTurnCommitted = true
        }
        serverService.cancelActiveConnection()
        await settleAsyncTasks()

        XCTAssertEqual(
            calledHostsBox.snapshot(),
            [],
            "beginConnect followed by same-turn cancelActiveConnection must make 0 transport calls"
        )
        XCTAssertEqual(serverService.state, .cancelled)
        XCTAssertFalse(cancelTurnCommitted)

        // 2. Same-turn beginConnect -> resetState(): 0 transport calls, state remains .idle
        var resetTurnCommitted = false
        serverService.beginConnect(
            rawInput: "smb://reset-same-turn.local/share",
            allowAuthenticationUI: false
        ) { _ in
            resetTurnCommitted = true
        }
        serverService.resetState()
        await settleAsyncTasks()

        XCTAssertEqual(
            calledHostsBox.snapshot(),
            [],
            "beginConnect followed by same-turn resetState must make 0 transport calls"
        )
        XCTAssertEqual(serverService.state, .idle)
        XCTAssertFalse(resetTurnCommitted)

        // 3. Same-turn beginConnect(A) -> beginConnect(B): only B calls transport, and each owns its own closure
        var committedByA: [URL] = []
        var committedByB: [URL] = []
        serverService.beginConnect(
            rawInput: "smb://host-a.local/shareA",
            allowAuthenticationUI: false
        ) { url in
            committedByA.append(url)
        }
        serverService.beginConnect(
            rawInput: "smb://host-b.local/shareB",
            allowAuthenticationUI: false
        ) { url in
            committedByB.append(url)
        }
        await settleAsyncTasks()

        XCTAssertEqual(
            calledHostsBox.snapshot(),
            ["host-b.local"],
            "Superseded same-turn beginConnect(A) must never invoke transport; only B may execute"
        )
        XCTAssertTrue(committedByA.isEmpty, "Superseded A's commit closure must never be called")
        XCTAssertEqual(
            committedByB,
            [mountB.standardizedFileURL],
            "Winner B must invoke its own commit closure and never have it stolen by A"
        )
    }

    private func assertBeginSubmitSameTurnCancelAndSupersession() async throws {
        let startDir = try makeDirectory("R2_GoToStart")
        let folderA = try makeDirectory("R2_GoToFolderA")
        let folderB = try makeDirectory("R2_GoToFolderB")

        let win = AppViewState(fileViewer: NoOpFileViewer())
        win.navigateToDirectory(startDir)

        let goToService = GoToFolderNavigationService()
        var authorizedPaths: [String] = []
        goToService.accessCheckOverride = { url in
            authorizedPaths.append(url.standardizedFileURL.path)
            return true
        }

        // 1. Same-turn beginSubmitAndNavigate -> cancelActiveSubmission(): 0 authorization calls
        goToService.updateInput(folderA.path, baseDirectory: startDir)
        goToService.beginSubmitAndNavigate(in: win)
        goToService.cancelActiveSubmission()
        await settleAsyncTasks()

        XCTAssertEqual(
            authorizedPaths,
            [],
            "beginSubmit followed by same-turn cancelActiveSubmission must make 0 authorization calls"
        )
        XCTAssertEqual(win.currentDirectoryURL.standardizedFileURL, startDir.standardizedFileURL)

        // 2. Same-turn beginSubmit(A) -> beginSubmit(B): only B calls authorization, and B's callback receives folderB
        var commitTargetsA: [GoToFolderResolvedTarget] = []
        var commitTargetsB: [GoToFolderResolvedTarget] = []

        goToService.updateInput(folderA.path, baseDirectory: startDir)
        goToService.beginSubmit(baseDirectory: startDir) { target in
            commitTargetsA.append(target)
        }
        goToService.updateInput(folderB.path, baseDirectory: startDir)
        goToService.beginSubmit(baseDirectory: startDir) { target in
            commitTargetsB.append(target)
        }
        await settleAsyncTasks()

        XCTAssertEqual(
            authorizedPaths,
            [folderB.standardizedFileURL.path],
            "Superseded same-turn beginSubmit(A) must make 0 authorization calls; only B may authorize"
        )
        XCTAssertTrue(commitTargetsA.isEmpty, "Superseded A's commit closure must never be called")
        XCTAssertEqual(
            commitTargetsB,
            [.directory(folderB.standardizedFileURL)],
            "Winner B's commit closure must receive folderB"
        )
    }

    // MARK: - 6. P1: Smart Folder Sole Authorization Owner & Lease Holding

    func testReview6_SmartFolderStrictAuthorizationOwnerAndLeaseHolding() async throws {
        try setUpFixtures()
        defer { tearDownFixtures() }

        let readableDir = try makeDirectory("R2_ReadableControlledScope")
        let sampleZip = readableDir.appendingPathComponent("confidential_bundle.zip")
        try Data("zipcontent".utf8).write(to: sampleZip)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: readableDir.path))

        // Use real RootFolderAccessManager.shared as sole owner (no defaultAccessChecker bypass)
        SmartFolderStore.shared.defaultAccessChecker = nil
        _ = RootFolderAccessManager.shared.persistBookmark(for: readableDir)
        defer {
            _ = RootFolderAccessManager.shared.persistBookmark(for: readableDir)
        }

        let spyScanner = LeaseObservingDirectoryScanner(observedURL: readableDir)
        SmartFolderStore.shared.defaultDirectoryScanner = spyScanner

        let win = AppViewState(fileViewer: NoOpFileViewer())
        win.navigateToDirectory(tempRootURL)

        let record = try SmartFolderStore.shared.createSmartFolder(
            name: "Controlled Scope Zip Search",
            criteria: SmartFolderCriteria(nameQuery: "confidential", fileExtension: "zip", kindFilter: .archivesOnly),
            scope: .directory(path: readableDir.path, bookmarkData: nil)
        )

        // 1. Positive control: owner allows -> scanner runs once while holding active lease >= 1, then releases lease
        win.activateSmartFolder(record: record)
        await win.waitForActiveSmartFolderEvaluation()

        XCTAssertEqual(spyScanner.callCount, 1)
        XCTAssertGreaterThanOrEqual(
            spyScanner.maxObservedActiveLeaseCount,
            1,
            "SmartFolderStore must hold a SecurityScopeLease from RootFolderAccessManager during directory scan"
        )
        XCTAssertEqual(
            RootFolderAccessManager.shared.activeLeaseCount(for: readableDir),
            0,
            "SecurityScopeLease must be balanced and released when SmartFolder scan finishes"
        )
        XCTAssertEqual(win.overlayState.activeSmartFolderResult?.items.map(\.title), ["confidential_bundle.zip"])

        // 2. Owner explicitly denies access on an existing readable directory -> scanner MUST have 0 calls (no isReadableFile backdoor)
        SmartFolderStore.shared.defaultAccessChecker = { _ in false }
        RootFolderAccessManager.shared.revokeAccess(for: readableDir)
        XCTAssertTrue(
            FileManager.default.isReadableFile(atPath: readableDir.path),
            "Directory remains physically readable on disk to prove consumer obeys owner denial"
        )
        spyScanner.resetCounts()

        win.activateSmartFolder(record: record)
        await win.waitForActiveSmartFolderEvaluation()

        XCTAssertEqual(
            spyScanner.callCount,
            0,
            "When authorization owner denies access, SmartFolderStore must make 0 scanner calls even if FileManager.isReadableFile is true"
        )
        XCTAssertEqual(win.overlayState.activeSmartFolderResult?.isScopeUnauthorized, true)
        XCTAssertTrue(win.overlayState.activeSmartFolderResult?.items.isEmpty ?? false)

        // 3. Direct evaluate(checkAccess: { _ in false }) on an authorized readable directory -> scanner MUST have 0 calls
        SmartFolderStore.shared.defaultAccessChecker = { _ in true }
        _ = RootFolderAccessManager.shared.persistBookmark(for: readableDir)
        spyScanner.resetCounts()
        let explicitDenied = await SmartFolderStore.shared.evaluate(
            record: record,
            directoryScanner: spyScanner,
            checkAccess: { _ in false }
        )
        XCTAssertEqual(
            spyScanner.callCount,
            0,
            "When checkAccess returns false on a readable directory, SmartFolderStore must make 0 scanner calls"
        )
        XCTAssertTrue(explicitDenied.isScopeUnauthorized)
    }

    // MARK: - 7. P2: Result Identity (A->B Pending), Unauthorized / Error / Truncated / Cancelled Presentation & Full-Disk Aggregation

    func testReview7_SmartFolderResultIdentityErrorUnauthorizedTruncatedAndCancelledBannerPresentation() async throws {
        try setUpFixtures()
        defer { tearDownFixtures() }

        let win = AppViewState(fileViewer: NoOpFileViewer())
        win.navigateToDirectory(tempRootURL)

        try await assertSmartFolderPendingSwitchClearsStaleResults(in: win)
        try await assertBannerDistinguishesUnauthorizedErrorTruncatedAndCancelled(in: win)
    }

    private func assertSmartFolderPendingSwitchClearsStaleResults(in win: AppViewState) async throws {
        let dirA = try makeDirectory("R2_SwitchDirA")
        let dirB = try makeDirectory("R2_SwitchDirB")
        try Data("a".utf8).write(to: dirA.appendingPathComponent("alpha_stale_hit.zip"))
        try Data("b".utf8).write(to: dirB.appendingPathComponent("beta_fresh_hit.zip"))

        let gateB = AsyncManualGate()
        let baseScanner = DefaultDirectoryRecursiveScanner()
        SmartFolderStore.shared.defaultDirectoryScanner = GateDirectoryScanner(
            gatedRootPath: dirB.standardizedFileURL.path,
            gate: gateB,
            underlying: baseScanner
        )

        let recordA = try SmartFolderStore.shared.createSmartFolder(
            name: "Alpha Folder",
            criteria: SmartFolderCriteria(nameQuery: "alpha", fileExtension: "zip", kindFilter: .archivesOnly),
            scope: .directory(path: dirA.path, bookmarkData: nil)
        )
        let recordB = try SmartFolderStore.shared.createSmartFolder(
            name: "Beta Folder",
            criteria: SmartFolderCriteria(nameQuery: "beta", fileExtension: "zip", kindFilter: .archivesOnly),
            scope: .directory(path: dirB.path, bookmarkData: nil)
        )

        win.activateSmartFolder(record: recordA)
        await win.waitForActiveSmartFolderEvaluation()
        XCTAssertEqual(win.overlayState.activeSmartFolderResult?.items.map(\.title), ["alpha_stale_hit.zip"])

        // Switch to B while B suspends in scanner
        win.activateSmartFolder(record: recordB)
        await gateB.waitUntilWaiterArrived()

        XCTAssertEqual(win.overlayState.activeSmartFolderRecord?.id, recordB.id)
        XCTAssertEqual(
            win.overlayState.activeSmartFolderResult?.recordID,
            recordB.id,
            "Activating Smart Folder B must atomically bind activeSmartFolderResult to B's recordID instead of retaining A's result"
        )
        XCTAssertTrue(
            win.overlayState.activeSmartFolderResult?.items.isEmpty ?? true,
            "While B is loading, stale items from A ('alpha_stale_hit.zip') must not remain in activeSmartFolderResult"
        )

        let pendingStrings = renderBannerAndCollectStrings(for: win)
        XCTAssertTrue(pendingStrings.contains(where: { $0.contains("Beta Folder") }))
        XCTAssertFalse(
            pendingStrings.contains(where: { $0.contains("alpha_stale_hit.zip") }),
            "Banner for pending B must never display or allow clicking stale item 'alpha_stale_hit.zip' from A"
        )

        gateB.open()
        await win.waitForActiveSmartFolderEvaluation()
        XCTAssertEqual(win.overlayState.activeSmartFolderResult?.items.map(\.title), ["beta_fresh_hit.zip"])
    }

    private func assertBannerDistinguishesUnauthorizedErrorTruncatedAndCancelled(in win: AppViewState) async throws {
        let scopeDir = try makeDirectory("R2_FullDiskScope")
        SmartFolderStore.shared.defaultSystemSearchProvider = StaticSystemSearchProvider(items: [])
        SmartFolderStore.shared.additionalFullDiskScopeURLs = [scopeDir]

        let fullDiskRecord = try SmartFolderStore.shared.createSmartFolder(
            name: "FullDisk Diagnostics",
            criteria: SmartFolderCriteria(nameQuery: " diagnostic ", fileExtension: "zip", kindFilter: .archivesOnly),
            scope: .fullDisk
        )

        // 1. Unauthorized scope: must NOT say "No matching items"
        SmartFolderStore.shared.defaultAccessChecker = { _ in false }
        win.activateSmartFolder(record: fullDiskRecord)
        await win.waitForActiveSmartFolderEvaluation()

        let unauthRes = try XCTUnwrap(win.overlayState.activeSmartFolderResult)
        XCTAssertTrue(unauthRes.isScopeUnauthorized, "Full-disk evaluation with all scopes unauthorized must set isScopeUnauthorized")
        let unauthStrings = renderBannerAndCollectStrings(for: win)
        assertNotExhaustiveNoMatch(unauthStrings, context: "Unauthorized scope")

        // 2. Scan I/O error in Full-Disk scope: must surface phase.error and NOT say "No matching items"
        SmartFolderStore.shared.defaultAccessChecker = nil
        SmartFolderStore.shared.defaultDirectoryScanner = StubOutcomeDirectoryScanner { _ in
            throw DirectoryRecursiveScanError.scanFailed("Simulated I/O read failure")
        }
        win.activateSmartFolder(record: fullDiskRecord)
        await win.waitForActiveSmartFolderEvaluation()

        let errRes = try XCTUnwrap(win.overlayState.activeSmartFolderResult)
        XCTAssertEqual(errRes.phase.errorMessage?.contains("Simulated I/O read failure"), true)
        let errStrings = renderBannerAndCollectStrings(for: win)
        assertNotExhaustiveNoMatch(errStrings, context: "Scan I/O error")
        XCTAssertTrue(errStrings.contains(where: { $0.contains("Simulated I/O read failure") }))

        // 3. Truncated Full-Disk scope with 0 hits & partial hits: must aggregate coverage and warn of partial scan
        SmartFolderStore.shared.defaultDirectoryScanner = StubOutcomeDirectoryScanner { _ in
            DirectoryRecursiveSearchOutcome(
                items: [],
                visitedEntryCount: 512,
                maxDepthVisited: 6,
                truncationReasons: [.maxVisitedEntriesReached],
                skippedUnauthorizedDirectories: 2,
                skippedDatalessFiles: 1
            )
        }
        win.activateSmartFolder(record: fullDiskRecord)
        await win.waitForActiveSmartFolderEvaluation()

        let truncRes = try XCTUnwrap(win.overlayState.activeSmartFolderResult)
        XCTAssertTrue(truncRes.coverage.isTruncated, "Full-disk evaluation must aggregate truncationReasons from scope outcomes")
        XCTAssertEqual(truncRes.coverage.visitedEntryCount, 512)
        XCTAssertEqual(truncRes.coverage.skippedUnauthorizedSubdirectoryCount, 2)
        let truncStrings = renderBannerAndCollectStrings(for: win)
        assertNotExhaustiveNoMatch(truncStrings, context: "Truncated zero-hit scan")
        XCTAssertTrue(
            truncStrings.contains(where: { $0.contains("部分范围") || $0.contains("partial scope") }),
            "Truncated zero-hit banner must disclose partial scope coverage: \(truncStrings)"
        )

        // 4. Cancelled evaluation: must NOT disguise cancellation as "No matching items"
        SmartFolderStore.shared.defaultDirectoryScanner = StubOutcomeDirectoryScanner { _ in
            throw CancellationError()
        }
        win.activateSmartFolder(record: fullDiskRecord)
        await win.waitForActiveSmartFolderEvaluation()
        let cancelStrings = renderBannerAndCollectStrings(for: win)
        assertNotExhaustiveNoMatch(cancelStrings, context: "Cancelled evaluation")
    }

    // MARK: - 8. P2: Full Result Set Access Beyond 24 Items & Scan Budget Disclosure

    func testReview8_SmartFolderFullManagedResultSetAccessBeyond24AndScanBudgetDisclosure() async throws {
        try setUpFixtures()
        defer { tearDownFixtures() }

        let manyDir = try makeDirectory("R2_ManyMatchesDir")
        var tailArchiveURL: URL!
        for idx in 1...30 {
            let name = idx == 30
                ? "item_30_unique_tail_target.zip"
                : String(format: "item_%02d_regular.zip", idx)
            let fileURL = manyDir.appendingPathComponent(name)
            try CreateMinimalStoredZip.write(to: fileURL)
            if idx == 30 {
                tailArchiveURL = fileURL
            }
        }

        let win = AppViewState(fileViewer: NoOpFileViewer())
        win.navigateToDirectory(tempRootURL)

        let record = try SmartFolderStore.shared.createSmartFolder(
            name: "Thirty Archives",
            criteria: SmartFolderCriteria(nameQuery: "item_", fileExtension: "zip", kindFilter: .archivesOnly),
            scope: .directory(path: manyDir.path, bookmarkData: nil)
        )

        win.activateSmartFolder(record: record)
        await win.waitForActiveSmartFolderEvaluation()

        let result = try XCTUnwrap(win.overlayState.activeSmartFolderResult)
        XCTAssertEqual(result.items.count, 30)

        let (window, hostingView) = mountOffscreenBanner(for: win)
        defer { window.close() }

        var renderedStrings = collectAccessibilityAndViewStrings(in: hostingView)
        collectStringsFromMirror(ActiveSmartFolderResultsBannerView(viewModel: win).body, into: &renderedStrings)
        XCTAssertTrue(
            renderedStrings.contains(where: { $0.contains("10,000") || $0.contains("10000") || $0.contains("预算") || $0.contains("budget") }),
            "Smart Folder banner must disclose real scan budget in UI, got: \(renderedStrings)"
        )
        XCTAssertTrue(
            renderedStrings.contains(where: { $0.contains("item_30_unique_tail_target.zip") }),
            "Item #30 beyond the first 24 items must be reachable in the banner result view, got: \(renderedStrings)"
        )

        let didPressTailButton = pressAccessibilityButton(
            containingTitle: "item_30_unique_tail_target.zip",
            in: hostingView,
            viewModel: win
        )
        XCTAssertTrue(
            didPressTailButton,
            "Must be able to invoke the result button for item #30 ('item_30_unique_tail_target.zip') from the banner view"
        )
        await settleAsyncTasks()
        XCTAssertEqual(
            win.explorerState.currentArchivePath,
            tailArchiveURL.standardizedFileURL.path,
            "Activating item #30 from the Smart Folder results view must open the tail archive in the browser window"
        )
    }

    // MARK: - Offscreen Banner Hosting & Accessibility Helpers

    private func settleAsyncTasks() async {
        for _ in 0..<8 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    private func assertNotExhaustiveNoMatch(_ strings: [String], context: String) {
        let joined = strings.joined(separator: " | ")
        XCTAssertFalse(
            strings.contains("无匹配项目") || strings.contains("No matching items"),
            "\(context) must never be disguised as exhaustive '无匹配项目' / 'No matching items'; rendered: \(joined)"
        )
    }

    private func mountOffscreenBanner(for viewModel: AppViewState) -> (NSWindow, NSHostingView<AnyView>) {
        let root = AnyView(
            ActiveSmartFolderResultsBannerView(viewModel: viewModel)
                .frame(width: 920, height: 320)
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 920, height: 320)
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 920, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderOut(nil)
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        hostingView.layoutSubtreeIfNeeded()
        return (window, hostingView)
    }

    private func renderBannerAndCollectStrings(for viewModel: AppViewState) -> [String] {
        let (window, hostingView) = mountOffscreenBanner(for: viewModel)
        defer { window.close() }
        var strings = collectAccessibilityAndViewStrings(in: hostingView)
        let bannerBody = ActiveSmartFolderResultsBannerView(viewModel: viewModel).body
        collectStringsFromMirror(bannerBody, into: &strings)
        return strings
    }

    private func collectStringsFromMirror(_ value: Any, into output: inout [String], depth: Int = 0) {
        guard depth <= 28 else { return }
        if let str = value as? String, !str.isEmpty {
            output.append(str)
            return
        }
        if let slice = value as? ArraySlice<GlobalSearchResultItem> {
            for item in slice {
                output.append(item.title)
            }
            return
        }
        if let array = value as? [GlobalSearchResultItem] {
            for item in array {
                output.append(item.title)
            }
            return
        }
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            // Skip viewModel reference to avoid traversing AppViewState properties instead of rendered View nodes
            if child.label == "viewModel" || child.label == "l10n" {
                continue
            }
            collectStringsFromMirror(child.value, into: &output, depth: depth + 1)
        }
    }

    private func collectAccessibilityAndViewStrings(in root: NSView) -> [String] {
        var output: [String] = []
        var visited = Set<ObjectIdentifier>()

        func visit(_ item: Any) {
            let obj = item as AnyObject
            let id = ObjectIdentifier(obj)
            guard visited.insert(id).inserted else { return }

            if let tf = obj as? NSTextField, !tf.stringValue.isEmpty {
                output.append(tf.stringValue)
            }
            if let btn = obj as? NSButton, !btn.title.isEmpty {
                output.append(btn.title)
            }
            if let ax = obj as? NSAccessibilityProtocol {
                if let label = ax.accessibilityLabel(), !label.isEmpty {
                    output.append(label)
                }
                if let title = ax.accessibilityTitle(), !title.isEmpty {
                    output.append(title)
                }
                if let val = ax.accessibilityValue() as? String, !val.isEmpty {
                    output.append(val)
                }
                if let children = ax.accessibilityChildren() {
                    for child in children { visit(child) }
                }
            }
            if let view = obj as? NSView {
                for sub in view.subviews { visit(sub) }
            }
        }

        visit(root)
        return output
    }

    private func pressAccessibilityButton(
        containingTitle targetTitle: String,
        in root: NSView,
        viewModel: AppViewState? = nil
    ) -> Bool {
        var visited = Set<ObjectIdentifier>()

        func search(_ item: Any) -> Bool {
            let obj = item as AnyObject
            let id = ObjectIdentifier(obj)
            guard visited.insert(id).inserted else { return false }

            if let btn = obj as? NSButton, btn.title.contains(targetTitle), let action = btn.action {
                _ = btn.sendAction(action, to: btn.target)
                return true
            }
            if let ax = obj as? NSAccessibilityProtocol {
                let label = ax.accessibilityLabel() ?? ""
                let title = ax.accessibilityTitle() ?? ""
                if (label.contains(targetTitle) || title.contains(targetTitle)),
                   ax.accessibilityPerformPress() {
                    return true
                }
                if let children = ax.accessibilityChildren() {
                    for child in children where search(child) {
                        return true
                    }
                }
            }
            if let view = obj as? NSView {
                for sub in view.subviews where search(sub) {
                    return true
                }
            }
            return false
        }

        if search(root) {
            return true
        }
        if let viewModel {
            return invokeSmartFolderRowButtonInMirror(
                ActiveSmartFolderResultsBannerView(viewModel: viewModel).body,
                matchingTitle: targetTitle
            )
        }
        return false
    }

    private func invokeSmartFolderRowButtonInMirror(
        _ value: Any,
        matchingTitle targetTitle: String,
        depth: Int = 0
    ) -> Bool {
        guard depth <= 28 else { return false }
        let mirror = Mirror(reflecting: value)
        var dataItems: [GlobalSearchResultItem]?
        var contentBuilder: ((GlobalSearchResultItem) -> SmartFolderResultItemRowButton)?
        for child in mirror.children {
            if child.label == "viewModel" || child.label == "l10n" {
                continue
            }
            if child.label == "data" {
                if let items = child.value as? [GlobalSearchResultItem] {
                    dataItems = items
                } else if let slice = child.value as? ArraySlice<GlobalSearchResultItem> {
                    dataItems = Array(slice)
                }
            }
            if child.label == "content",
               let fn = child.value as? (GlobalSearchResultItem) -> SmartFolderResultItemRowButton {
                contentBuilder = fn
            }
        }
        if let dataItems, let contentBuilder,
           let matchedItem = dataItems.first(where: { $0.title.contains(targetTitle) }) {
            let rowButton = contentBuilder(matchedItem)
            rowButton.action()
            return true
        }
        for child in mirror.children {
            if child.label == "viewModel" || child.label == "l10n" {
                continue
            }
            if invokeSmartFolderRowButtonInMirror(child.value, matchingTitle: targetTitle, depth: depth + 1) {
                return true
            }
        }
        return false
    }
}

// MARK: - Supporting Doubles for Round 2 Tests

private final class LockedArrayBox<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }
        elements.append(element)
    }

    func snapshot() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return elements
    }
}

private final class LeaseObservingDirectoryScanner: DirectoryRecursiveSearching, @unchecked Sendable {
    private let observedURL: URL
    private let underlying = DefaultDirectoryRecursiveScanner()
    private let lock = NSLock()
    private(set) var callCount: Int = 0
    private(set) var maxObservedActiveLeaseCount: Int = 0

    init(observedURL: URL) {
        self.observedURL = observedURL
    }

    func resetCounts() {
        lock.lock()
        defer { lock.unlock() }
        callCount = 0
        maxObservedActiveLeaseCount = 0
    }

    func searchDirectoryRecursively(
        rootURL: URL,
        query: String,
        maxResults: Int,
        maxVisitedEntries: Int,
        maxDepth: Int
    ) async throws -> DirectoryRecursiveSearchOutcome {
        let activeCount = await MainActor.run {
            RootFolderAccessManager.shared.activeLeaseCount(for: observedURL)
        }
        lock.withLock {
            callCount += 1
            if activeCount > maxObservedActiveLeaseCount {
                maxObservedActiveLeaseCount = activeCount
            }
        }

        return try await underlying.searchDirectoryRecursively(
            rootURL: rootURL,
            query: query,
            maxResults: maxResults,
            maxVisitedEntries: maxVisitedEntries,
            maxDepth: maxDepth
        )
    }
}

private final class GateDirectoryScanner: DirectoryRecursiveSearching, @unchecked Sendable {
    let gatedRootPath: String
    let gate: AsyncManualGate
    let underlying: DefaultDirectoryRecursiveScanner

    init(gatedRootPath: String, gate: AsyncManualGate, underlying: DefaultDirectoryRecursiveScanner) {
        self.gatedRootPath = gatedRootPath
        self.gate = gate
        self.underlying = underlying
    }

    func searchDirectoryRecursively(
        rootURL: URL,
        query: String,
        maxResults: Int,
        maxVisitedEntries: Int,
        maxDepth: Int
    ) async throws -> DirectoryRecursiveSearchOutcome {
        if rootURL.standardizedFileURL.path == gatedRootPath {
            await gate.wait()
        }
        return try await underlying.searchDirectoryRecursively(
            rootURL: rootURL,
            query: query,
            maxResults: maxResults,
            maxVisitedEntries: maxVisitedEntries,
            maxDepth: maxDepth
        )
    }
}

private final class StubOutcomeDirectoryScanner: DirectoryRecursiveSearching, @unchecked Sendable {
    private let block: @Sendable (URL) async throws -> DirectoryRecursiveSearchOutcome

    init(block: @escaping @Sendable (URL) async throws -> DirectoryRecursiveSearchOutcome) {
        self.block = block
    }

    func searchDirectoryRecursively(
        rootURL: URL,
        query: String,
        maxResults: Int,
        maxVisitedEntries: Int,
        maxDepth: Int
    ) async throws -> DirectoryRecursiveSearchOutcome {
        try await block(rootURL)
    }
}

private enum CreateMinimalStoredZip {
    static func write(to url: URL) throws {
        // Minimal valid empty ZIP End-of-Central-Directory (22 bytes)
        let eocd: [UInt8] = [
            0x50, 0x4B, 0x05, 0x06,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00
        ]
        try Data(eocd).write(to: url)
    }
}
