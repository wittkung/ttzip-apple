// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
@testable import TTZipApp
import TTZipCore

extension SemanticIndexingLifecycleS2Tests {
    @MainActor
    func testS2RegressionD_RealAccessManagerRevokeDefersSystemStopUntilRetiringNativeWorkReleases() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-reg-d-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let gate = IndexingRunGateBox()
        let eventLog = OrderedLifecycleEventLog()
        let uniffiDouble = S2LifecycleUniFFIDouble(runGate: gate, eventLog: eventLog)
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: tmpDir, uniffiEngine: uniffiDouble)
        let accessManager = RootFolderAccessManager.shared
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir,
            bridge: bridge,
            directoryLeaseProvider: { url in await MainActor.run { accessManager.acquireLease(for: url) } }
        )
        let scopeHarness = SystemSecurityScopeTestHarness(eventLog: eventLog, autoIndexingEnabled: true, engine: engine)
        defer {
            gate.releaseRun1()
            scopeHarness.restore(revoking: [tmpDir])
        }

        XCTAssertNotNil(scopeHarness.persist(tmpDir))
        guard await gate.waitRun1Entered(timeoutSeconds: 2.0) else {
            gate.releaseRun1()
            _ = await engine.shutdown()
            XCTFail("Auto-indexing failed to enter native work with real RootFolderAccessManager lease")
            return
        }
        XCTAssertEqual(scopeHarness.observer.startCount, 1)
        XCTAssertEqual(scopeHarness.counts(tmpDir).active, 1)
        XCTAssertEqual(scopeHarness.counts(tmpDir).retiring, 0)
        XCTAssertEqual(scopeHarness.counts(tmpDir).stop, 0)

        scopeHarness.revoke(tmpDir)
        XCTAssertEqual(scopeHarness.counts(tmpDir).active, 0, "Revoke must clear active admission immediately")
        XCTAssertEqual(scopeHarness.counts(tmpDir).retiring, 1, "In-flight lease must move to retiring ledger")
        XCTAssertEqual(scopeHarness.counts(tmpDir).stop, 0, "System stop must not fire while native work holds lease")

        gate.releaseRun1()
        let didDrain = await waitForMainActorCondition(timeoutSeconds: 2.0) {
            scopeHarness.counts(tmpDir).retiring == 0 && eventLog.snapshot().contains("bridge.revokeScope")
        }
        XCTAssertTrue(didDrain, "Retiring lease and scope revocation must complete after native work exits")
        XCTAssertEqual(scopeHarness.counts(tmpDir).stop, 1, "System stop must fire exactly once on final release")
        let finalEvents = eventLog.snapshot()
        let exitIdx = try XCTUnwrap(finalEvents.firstIndex(of: "run1.exitedNative"))
        let stopIdx = try XCTUnwrap(finalEvents.firstIndex(of: "systemScope.stop"))
        let revokeIdx = try XCTUnwrap(finalEvents.firstIndex(of: "bridge.revokeScope"))
        XCTAssertLessThan(exitIdx, stopIdx)
        XCTAssertLessThan(stopIdx, revokeIdx)
        _ = await engine.shutdown()
    }

    @MainActor
    func testS2RegressionD2_RealAccessManagerReauthorizeParentCoverageAndRevokeAllIsolatesRetiredLeases() throws {
        let parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-reg-d2-\(UUID().uuidString)", isDirectory: true)
        let childDir = parentDir.appendingPathComponent("nested_project", isDirectory: true)
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let scopeHarness = SystemSecurityScopeTestHarness(autoIndexingEnabled: false)
        defer { scopeHarness.restore(revoking: [parentDir], restoreSavedBookmarks: true) }

        XCTAssertNotNil(scopeHarness.persist(parentDir))
        let leaseOld = try XCTUnwrap(scopeHarness.acquire(parentDir))
        XCTAssertEqual(scopeHarness.observer.startCount, 1)
        XCTAssertEqual(scopeHarness.counts(parentDir).active, 1)
        XCTAssertEqual(scopeHarness.counts(parentDir).stop, 0)

        scopeHarness.revoke(parentDir)
        XCTAssertEqual(scopeHarness.counts(parentDir).active, 0)
        XCTAssertEqual(scopeHarness.counts(parentDir).retiring, 1)
        XCTAssertEqual(scopeHarness.counts(parentDir).stop, 0)

        XCTAssertNotNil(scopeHarness.persist(parentDir))
        let leaseChild = try XCTUnwrap(scopeHarness.acquire(childDir))
        let leaseSibling = try XCTUnwrap(scopeHarness.acquire(parentDir))
        XCTAssertEqual(scopeHarness.counts(parentDir).active, 2)
        XCTAssertEqual(scopeHarness.counts(childDir).active, 2)
        XCTAssertEqual(scopeHarness.counts(parentDir).retiring, 1)

        leaseOld.release()
        XCTAssertEqual(scopeHarness.counts(parentDir).retiring, 0)
        XCTAssertEqual(scopeHarness.counts(parentDir).active, 2, "Old retired release must not decrement new active lease")
        XCTAssertEqual(scopeHarness.counts(parentDir).stop, 0, "System stop must not fire while re-authorized holders live")

        scopeHarness.accessManager.revokeAllAccess()
        XCTAssertEqual(scopeHarness.counts(parentDir).active, 0)
        XCTAssertEqual(scopeHarness.counts(parentDir).retiring, 2)
        XCTAssertEqual(scopeHarness.counts(parentDir).stop, 0)

        leaseChild.release()
        XCTAssertEqual(scopeHarness.counts(parentDir).retiring, 1)
        XCTAssertEqual(scopeHarness.counts(parentDir).stop, 0, "System stop must wait until all retiring holders release")

        leaseSibling.release()
        XCTAssertEqual(scopeHarness.counts(parentDir).retiring, 0)
        XCTAssertEqual(scopeHarness.counts(parentDir).stop, 1, "System stop must fire once when last holder releases")
    }

    @MainActor
    func testS2RegressionE_RepeatedPersistAndRegisterWithoutCancelRetiresActiveRunAndDrainsAllOnRevoke() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-reg-e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let gate = IndexingRunGateBox()
        let eventLog = OrderedLifecycleEventLog()
        let cancelSignal = BoundedSignalReceipt()
        let uniffiDouble = S2LifecycleUniFFIDouble(
            runGate: gate,
            eventLog: eventLog,
            onCancelIndexingCalled: { cancelSignal.signal() }
        )
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: tmpDir, uniffiEngine: uniffiDouble)
        let accessManager = RootFolderAccessManager.shared
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir,
            bridge: bridge,
            directoryLeaseProvider: { url in await MainActor.run { accessManager.acquireLease(for: url) } }
        )
        let scopeHarness = SystemSecurityScopeTestHarness(eventLog: eventLog, autoIndexingEnabled: false)
        defer {
            gate.releaseRun1()
            gate.releaseRun2()
            scopeHarness.restore(revoking: [tmpDir])
        }

        XCTAssertNotNil(scopeHarness.persist(tmpDir))
        let scopeId = SemanticSearchEngine.scopeId(forDirectoryURL: tmpDir)
        let handleA = BoundedTaskHandle {
            await engine.registerAuthorizedDirectory(url: tmpDir, isAuthorized: true, startIndexingImmediately: true)
        }
        guard await gate.waitRun1Entered(timeoutSeconds: 2.0) else {
            gate.releaseRun1()
            _ = await handleA.waitCompleted(timeoutSeconds: 1.0)
            _ = await engine.shutdown()
            XCTFail("Run A failed to enter native indexing")
            return
        }
        let handleB = BoundedTaskHandle {
            await engine.registerAuthorizedDirectory(url: tmpDir, isAuthorized: true, startIndexingImmediately: true)
        }
        let didCancelA = await cancelSignal.wait(timeoutSeconds: 2.0)
        XCTAssertTrue(didCancelA, "Re-registration must cancel and retire active Run A")
        _ = await engine.indexProgress(scopeId: scopeId)
        XCTAssertEqual(uniffiDouble.directoryIndexingCallCount, 1, "Run B must wait for retiring Run A and never overtake")

        let revokeHandle = BoundedTaskHandle { await engine.revokeAuthorizedDirectory(url: tmpDir) }
        let didEnterRevokeDrain = await waitForMainActorCondition(timeoutSeconds: 2.0) {
            eventLog.snapshot().filter { $0 == "cancelA.called" }.count >= 2
        }
        XCTAssertTrue(didEnterRevokeDrain, "Revoke must retire Run B and enter drain while Run A is still in flight")
        XCTAssertFalse(eventLog.snapshot().contains("bridge.revokeScope"))
        XCTAssertEqual(scopeHarness.counts(tmpDir).stop, 0)

        gate.releaseRun1()
        guard let resA = await handleA.valueIfCompleted(timeoutSeconds: 2.0),
              let resB = await handleB.valueIfCompleted(timeoutSeconds: 2.0),
              let revoked = await revokeHandle.valueIfCompleted(timeoutSeconds: 2.0)
        else {
            _ = await engine.shutdown()
            XCTFail("Run A, Run B, or revoke failed to drain within bounded timeout")
            return
        }
        XCTAssertEqual(resA.progress?.phase, .cancelled)
        XCTAssertFalse(resB.loadedExistingIndex, "Superseded registration B must not report loadedExistingIndex")
        XCTAssertNil(
            resB.progress,
            "Registration B superseded by revoke before indexing admission must return nil progress without fabricating native entry"
        )
        XCTAssertTrue(revoked, "Explicit revokeScope must commit as single revocation owner after draining A and B")
        XCTAssertEqual(
            eventLog.snapshot().filter { $0 == "bridge.revokeScope" }.count,
            1,
            "bridge.revokeScope must execute once from explicit revokeScope without dual-owner race"
        )
        XCTAssertEqual(uniffiDouble.directoryIndexingCallCount, 1, "Cancelled Run B must not enter native after revoke")
        XCTAssertEqual(uniffiDouble.segmentsCount(for: scopeId), 0)
        XCTAssertEqual(scopeHarness.counts(tmpDir).stop, 1)
        _ = await engine.shutdown()
    }

    @MainActor
    func testS2RegressionF_InFlightRevokeSupersededByReauthorizePreservesNewScopeAndRunWhileUnreauthorizedRevokePurges() async throws {
        try await assertSupersededRevokeAndUnreauthorizedPurge { engine, url, _ in
            await engine.revokeAuthorizedDirectory(url: url)
        }
        try await assertSupersededRevokeAndUnreauthorizedPurge { engine, _, scopeId in
            await engine.revokeScope(scopeId: scopeId)
        }
    }

    @MainActor
    private func assertSupersededRevokeAndUnreauthorizedPurge(
        revokeEntry: @escaping @Sendable (SemanticSearchEngine, URL, String) async -> Bool
    ) async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-reg-f-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let gate = IndexingRunGateBox()
        let eventLog = OrderedLifecycleEventLog()
        let cancelSignal = BoundedSignalReceipt()
        let uniffiDouble = S2LifecycleUniFFIDouble(
            runGate: gate,
            eventLog: eventLog,
            onCancelIndexingCalled: { cancelSignal.signal() }
        )
        let bridge = UniFFIRustSemanticCoreBridge(storageDirectory: tmpDir, uniffiEngine: uniffiDouble)
        let accessManager = RootFolderAccessManager.shared
        let engine = SemanticSearchEngine(
            storageDirectory: tmpDir,
            bridge: bridge,
            directoryLeaseProvider: { url in await MainActor.run { accessManager.acquireLease(for: url) } }
        )
        let scopeHarness = SystemSecurityScopeTestHarness(eventLog: eventLog, autoIndexingEnabled: false)
        defer {
            gate.releaseRun1()
            gate.releaseRun2()
            scopeHarness.restore(revoking: [tmpDir])
        }

        XCTAssertNotNil(scopeHarness.persist(tmpDir))
        let scopeId = SemanticSearchEngine.scopeId(forDirectoryURL: tmpDir)
        let handleA = BoundedTaskHandle {
            await engine.registerAuthorizedDirectory(url: tmpDir, isAuthorized: true, startIndexingImmediately: true)
        }
        guard await gate.waitRun1Entered(timeoutSeconds: 2.0) else {
            gate.releaseRun1()
            _ = await handleA.waitCompleted(timeoutSeconds: 1.0)
            _ = await engine.shutdown()
            XCTFail("Run A failed to enter native indexing")
            return
        }

        scopeHarness.revoke(tmpDir)
        let revokeHandle = BoundedTaskHandle { await revokeEntry(engine, tmpDir, scopeId) }
        let didRetireA = await cancelSignal.wait(timeoutSeconds: 2.0)
        XCTAssertTrue(didRetireA, "Revoke must retire Run A and await drain")

        XCTAssertNotNil(scopeHarness.persist(tmpDir))
        let handleB = BoundedTaskHandle {
            await engine.registerAuthorizedDirectory(url: tmpDir, isAuthorized: true, startIndexingImmediately: true)
        }
        let didRegisterC = await waitForMainActorCondition(timeoutSeconds: 2.0) {
            uniffiDouble.isScopeRegistered(for: scopeId)
        }
        XCTAssertTrue(didRegisterC, "Re-authorization C must register while Run A is still draining")
        _ = await engine.indexProgress(scopeId: scopeId)

        gate.releaseRun1()
        gate.releaseRun2()
        guard let resA = await handleA.valueIfCompleted(timeoutSeconds: 2.0),
              let revokedOld = await revokeHandle.valueIfCompleted(timeoutSeconds: 2.0),
              let resB = await handleB.valueIfCompleted(timeoutSeconds: 2.0)
        else {
            _ = await engine.shutdown()
            XCTFail("Run A, superseded revoke, or Run B failed to complete within bounded timeout")
            return
        }
        XCTAssertEqual(resA.progress?.phase, .cancelled)
        XCTAssertFalse(revokedOld, "Superseded old revoke must not claim revocation after re-authorization C")
        XCTAssertEqual(resB.progress?.phase, .completed, "New Run B must not be cancelled by old revoke drain")
        XCTAssertEqual(resB.progress?.indexedSegments, 6)
        XCTAssertFalse(eventLog.snapshot().contains("bridge.revokeScope"))
        XCTAssertTrue(uniffiDouble.isScopeRegistered(for: scopeId))
        XCTAssertEqual(uniffiDouble.segmentsCount(for: scopeId), 6)
        let covAfterReauth = await engine.indexedCoverageSummary()
        XCTAssertEqual(covAfterReauth.authorizedScopeCount, 1)
        XCTAssertEqual(covAfterReauth.totalIndexedSegments, 6)

        await assertUnreauthorizedRevokePurgesScope(
            engine: engine,
            uniffiDouble: uniffiDouble,
            scopeHarness: scopeHarness,
            tmpDir: tmpDir,
            scopeId: scopeId,
            revokeEntry: revokeEntry
        )
        _ = await engine.shutdown()
    }

    @MainActor
    private func assertUnreauthorizedRevokePurgesScope(
        engine: SemanticSearchEngine,
        uniffiDouble: S2LifecycleUniFFIDouble,
        scopeHarness: SystemSecurityScopeTestHarness,
        tmpDir: URL,
        scopeId: String,
        revokeEntry: @escaping @Sendable (SemanticSearchEngine, URL, String) async -> Bool
    ) async {
        scopeHarness.revoke(tmpDir)
        let purged = await revokeEntry(engine, tmpDir, scopeId)
        XCTAssertTrue(purged, "Un-reauthorized revoke must purge the scope")
        XCTAssertFalse(uniffiDouble.isScopeRegistered(for: scopeId))
        XCTAssertEqual(uniffiDouble.segmentsCount(for: scopeId), 0)
        let progAfterPurge = await engine.indexProgress(scopeId: scopeId)
        XCTAssertNil(progAfterPurge)
        let covAfterPurge = await engine.indexedCoverageSummary()
        XCTAssertEqual(covAfterPurge.authorizedScopeCount, 0)
        XCTAssertEqual(covAfterPurge.totalIndexedSegments, 0)
    }

    @MainActor
    func testS2RegressionG_RevokedScopeRejectsUnbookmarkedLeaseWhileRetiringAndAllowsDirectReadableScopeAndExplicitReauthorization() async throws {
        let revokedRootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-reg-g-revoked-\(UUID().uuidString)", isDirectory: true)
        let revokedChildDir = revokedRootDir.appendingPathComponent("subscope", isDirectory: true)
        let directReadableDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-reg-g-direct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: revokedChildDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directReadableDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: revokedRootDir)
            try? FileManager.default.removeItem(at: directReadableDir)
        }

        let scopeHarness = SystemSecurityScopeTestHarness(autoIndexingEnabled: false)
        defer {
            scopeHarness.restore(revoking: [revokedRootDir, directReadableDir], restoreSavedBookmarks: true)
        }

        let syncEnsure: @MainActor (URL, Bool) -> Bool = scopeHarness.accessManager.ensureAccess(for:promptIfMissing:)
        let directInitialLease = try XCTUnwrap(
            scopeHarness.acquire(directReadableDir),
            "Ordinary readable directory that was never revoked must remain accessible in Direct mode"
        )
        XCTAssertTrue(syncEnsure(directReadableDir, false))
        XCTAssertEqual(scopeHarness.observer.startCount, 0)
        directInitialLease.release()

        XCTAssertNotNil(scopeHarness.persist(revokedRootDir))
        let leaseOld = try XCTUnwrap(scopeHarness.acquire(revokedRootDir))
        XCTAssertEqual(scopeHarness.observer.startCount, 1)
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).active, 1)
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).retiring, 0)
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).stop, 0)

        scopeHarness.revoke(revokedRootDir)
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).active, 0)
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).retiring, 1)
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).stop, 0)

        XCTAssertNil(
            scopeHarness.acquire(revokedRootDir),
            "Unbookmarked acquireLease after revoke must not borrow retiring system scope or local readability"
        )
        XCTAssertNil(
            scopeHarness.acquire(revokedChildDir),
            "Unbookmarked acquireLease on child of retiring/revoked scope must be rejected"
        )
        XCTAssertFalse(syncEnsure(revokedRootDir, false))
        let asyncEnsureWhileRetiring = await scopeHarness.accessManager.ensureAccess(for: revokedRootDir)
        XCTAssertFalse(asyncEnsureWhileRetiring)
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).active, 0)
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).retiring, 1)

        let directWhileRetiring = try XCTUnwrap(
            scopeHarness.acquire(directReadableDir),
            "Unrevoked Direct readable directory must remain unaffected while another scope is retiring"
        )
        directWhileRetiring.release()

        XCTAssertNotNil(scopeHarness.persist(revokedRootDir))
        let leaseNewRoot = try XCTUnwrap(scopeHarness.acquire(revokedRootDir))
        let leaseNewChild = try XCTUnwrap(scopeHarness.acquire(revokedChildDir))
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).active, 2)
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).retiring, 1)
        XCTAssertEqual(scopeHarness.observer.startCount, 1, "Re-authorization while retiring reuses live token")

        leaseOld.release()
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).retiring, 0)
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).active, 2, "Old release must not decrement new active refCount")
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).stop, 0)

        leaseNewChild.release()
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).active, 1)
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).stop, 0)

        leaseNewRoot.release()
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).active, 0)
        XCTAssertEqual(scopeHarness.counts(revokedRootDir).stop, 1, "System start/stop must pair 1:1 on final release")
    }

    // MARK: - Regression H (Active Ancestor Lease Does Not Bypass Revoked Child Subscope)

    @MainActor
    func testS2RegressionH_ActiveParentLeaseDoesNotBypassRevokedChildSubscopeUntilExplicitChildReauthorization() async throws {
        let parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-s2-reg-h-parent-\(UUID().uuidString)", isDirectory: true)
        let childDir = parentDir.appendingPathComponent("revoked_child", isDirectory: true)
        let descendantDir = childDir.appendingPathComponent("deep_nested", isDirectory: true)
        let siblingDir = parentDir.appendingPathComponent("active_sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: descendantDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let scopeHarness = SystemSecurityScopeTestHarness(autoIndexingEnabled: false)
        defer {
            scopeHarness.restore(revoking: [childDir, parentDir], restoreSavedBookmarks: true)
        }

        let syncEnsure: @MainActor (URL, Bool) -> Bool = scopeHarness.accessManager.ensureAccess(for:promptIfMissing:)
        XCTAssertNotNil(scopeHarness.persist(parentDir))
        let leaseParent = try XCTUnwrap(scopeHarness.acquire(parentDir))
        let leasePreRevokeChild = try XCTUnwrap(scopeHarness.acquire(childDir))
        XCTAssertEqual(scopeHarness.observer.startCount, 1)
        XCTAssertEqual(scopeHarness.counts(parentDir).active, 2)
        XCTAssertEqual(scopeHarness.counts(childDir).active, 2)

        scopeHarness.revoke(childDir)
        XCTAssertEqual(scopeHarness.counts(parentDir).active, 2, "In-flight parent lease must stay active when child is revoked")
        XCTAssertEqual(scopeHarness.counts(parentDir).stop, 0, "Revoking child must not forcibly close in-flight parent lease")
        XCTAssertEqual(scopeHarness.counts(childDir).active, 0, "Revoked child must report 0 active admission leases")

        await assertRevokedSubscopeAdmissionBlockedAndSiblingUsable(
            scopeHarness: scopeHarness,
            parentDir: parentDir,
            childDir: childDir,
            descendantDir: descendantDir,
            siblingDir: siblingDir,
            syncEnsure: syncEnsure
        )

        XCTAssertNotNil(scopeHarness.persist(childDir))
        let leaseNewChild = try XCTUnwrap(
            scopeHarness.acquire(childDir),
            "Explicitly re-authorizing child must restore child lease admission"
        )
        let leaseNewDescendant = try XCTUnwrap(
            scopeHarness.acquire(descendantDir),
            "Explicitly re-authorizing child must restore descendant lease admission"
        )
        XCTAssertTrue(syncEnsure(childDir, false))
        XCTAssertTrue(syncEnsure(descendantDir, false))
        let asyncChildAfterReauth = await scopeHarness.accessManager.ensureAccess(for: childDir)
        let asyncDescendantAfterReauth = await scopeHarness.accessManager.ensureAccess(for: descendantDir)
        XCTAssertTrue(asyncChildAfterReauth)
        XCTAssertTrue(asyncDescendantAfterReauth)
        XCTAssertEqual(scopeHarness.counts(childDir).active, 2)
        XCTAssertEqual(scopeHarness.observer.startCount, 2, "Re-authorized child bookmark must start its own security scope")

        leasePreRevokeChild.release()
        leaseParent.release()
        XCTAssertEqual(scopeHarness.counts(parentDir).active, 0)
        XCTAssertEqual(
            scopeHarness.counts(childDir).active,
            2,
            "Releasing pre-revoke/parent leases must not decrement newly re-authorized child leases"
        )
        XCTAssertEqual(scopeHarness.observer.stopCount, 1, "Releasing parent lease stops only parent security scope")

        leaseNewDescendant.release()
        XCTAssertEqual(scopeHarness.counts(childDir).active, 1)
        XCTAssertEqual(scopeHarness.observer.stopCount, 1)
        leaseNewChild.release()
        XCTAssertEqual(scopeHarness.counts(childDir).active, 0)
        XCTAssertEqual(scopeHarness.observer.stopCount, 2, "Parent and child start/stop counts must pair 1:1 on final release")
    }

    @MainActor
    private func assertRevokedSubscopeAdmissionBlockedAndSiblingUsable(
        scopeHarness: SystemSecurityScopeTestHarness,
        parentDir: URL,
        childDir: URL,
        descendantDir: URL,
        siblingDir: URL,
        syncEnsure: @MainActor (URL, Bool) -> Bool
    ) async {
        XCTAssertNil(
            scopeHarness.acquire(childDir),
            "Active parent lease must not bypass revoked child boundary on acquireLease(child)"
        )
        XCTAssertNil(
            scopeHarness.acquire(descendantDir),
            "Active parent lease must not bypass revoked child boundary on acquireLease(descendant)"
        )
        XCTAssertFalse(syncEnsure(childDir, false), "Sync ensureAccess(child) must reject revoked child despite active parent")
        XCTAssertFalse(syncEnsure(descendantDir, false), "Sync ensureAccess(descendant) must reject descendant of revoked child")
        let asyncEnsureChild = await scopeHarness.accessManager.ensureAccess(for: childDir)
        let asyncEnsureDescendant = await scopeHarness.accessManager.ensureAccess(for: descendantDir)
        XCTAssertFalse(asyncEnsureChild, "Async ensureAccess(child) must reject revoked child despite active parent")
        XCTAssertFalse(asyncEnsureDescendant, "Async ensureAccess(descendant) must reject descendant of revoked child")

        let leaseSibling = try? XCTUnwrap(
            scopeHarness.acquire(siblingDir),
            "Unrevoked sibling under the same active parent lease must remain accessible"
        )
        XCTAssertNotNil(leaseSibling)
        XCTAssertTrue(syncEnsure(siblingDir, false))
        let asyncEnsureSibling = await scopeHarness.accessManager.ensureAccess(for: siblingDir)
        XCTAssertTrue(asyncEnsureSibling)
        XCTAssertTrue(syncEnsure(parentDir, false))
        let asyncEnsureParent = await scopeHarness.accessManager.ensureAccess(for: parentDir)
        XCTAssertTrue(asyncEnsureParent)
        XCTAssertEqual(scopeHarness.counts(parentDir).active, 3)
        leaseSibling?.release()
        XCTAssertEqual(scopeHarness.counts(parentDir).active, 2)
    }
}

final class RetiringPredecessorWaitReceiptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var receipts: [SemanticRetiringPredecessorWaitReceipt] = []

    func record(_ receipt: SemanticRetiringPredecessorWaitReceipt) {
        lock.withLock {
            receipts.append(receipt)
        }
    }

    var snapshot: [SemanticRetiringPredecessorWaitReceipt] {
        lock.withLock { receipts }
    }

    func waitForReceipt(at index: Int, timeoutSeconds: Double) async -> SemanticRetiringPredecessorWaitReceipt? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let hit = lock.withLock({ index < receipts.count ? receipts[index] : nil }) {
                return hit
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return lock.withLock { index < receipts.count ? receipts[index] : nil }
    }
}

func waitForEngineDrainingAdmissionRevoked(
    engine: SemanticSearchEngine,
    timeoutSeconds: Double
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await engine.isDrainingRuntime {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await engine.isDrainingRuntime
}

func waitForEngineAndBridgeDraining(
    engine: SemanticSearchEngine,
    bridge: UniFFIRustSemanticCoreBridge,
    timeoutSeconds: Double
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let engineDraining = await engine.isDrainingRuntime
        let bridgeDraining = await bridge.isDraining
        if engineDraining && bridgeDraining {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    let engineDraining = await engine.isDrainingRuntime
    let bridgeDraining = await bridge.isDraining
    return engineDraining && bridgeDraining
}

func makeControlledIndexingEngineAndScope(
    at tmpDir: URL,
    tracker: ControlledGenerationBindingTracker,
    waitLog: RetiringPredecessorWaitReceiptLog? = nil
) async -> (engine: SemanticSearchEngine, scopeID: String) {
    let bridge = UniFFIRustSemanticCoreBridge(
        storageDirectory: tmpDir,
        uniffiEngine: ControlledGenerationUniFFIDouble(tracker: tracker)
    )
    let engine = SemanticSearchEngine(
        storageDirectory: tmpDir,
        bridge: bridge,
        directoryLeaseProvider: { SecurityScopeLease(url: $0, onRelease: { _ in }) },
        pluginEnabled: true
    )
    if let waitLog {
        await engine.setPredecessorWaitObserver { waitLog.record($0) }
    }
    _ = await engine.registerAuthorizedDirectory(
        url: tmpDir,
        isAuthorized: true,
        startIndexingImmediately: false
    )
    let scopeID = SemanticSearchEngine.scopeId(forDirectoryURL: tmpDir)
    return (engine, scopeID)
}

func assertAllNewWorkRejectedWhileDisableDrains(
    engine: SemanticSearchEngine,
    bridge: UniFFIRustSemanticCoreBridge,
    tracker: ControlledGenerationBindingTracker,
    scopeID: String,
    tmpDir: URL,
    activeSessionID: Int
) async {
    let engineDraining = await engine.isDrainingRuntime
    let bridgeDraining = await bridge.isDraining
    XCTAssertTrue(engineDraining)
    XCTAssertTrue(bridgeDraining)
    let prepBefore = tracker.prepareCount
    let regBefore = tracker.registerCount
    let reloadWhileDraining = await engine.reloadModelRuntime()
    let searchWhileDraining = await engine.search(
        SemanticSearchRequest(requestId: 701, windowId: "w", query: "test")
    )
    let indexWhileDraining = await engine.startIndexing(scopeId: scopeID)
    let upsertWhileDraining = await engine.upsertArchiveEntries(
        scopeId: scopeID,
        entries: [("a.txt", Data("x".utf8), 1)]
    )
    let regWhileDraining = await engine.registerScope(
        SemanticScopeDescriptor(
            scopeId: "dir:\(tmpDir.path)/sub",
            kind: .authorizedDirectory,
            rootPath: tmpDir.path,
            displayName: "sub",
            isAuthorized: true
        )
    )
    let removeWhileDraining = await engine.removeIndexedFile(scopeId: scopeID, relativePath: "a.txt")
    XCTAssertEqual(reloadWhileDraining, .notInstalled)
    XCTAssertTrue(searchWhileDraining.isCancelled)
    XCTAssertEqual(indexWhileDraining.phase, .cancelled)
    XCTAssertEqual(upsertWhileDraining.phase, .cancelled)
    XCTAssertFalse(regWhileDraining)
    XCTAssertFalse(removeWhileDraining)
    XCTAssertEqual(tracker.prepareCount, prepBefore)
    XCTAssertEqual(tracker.registerCount, regBefore)
    XCTAssertEqual(tracker.removeFileCount, 0)
    XCTAssertEqual(tracker.upsertCount, 0)
    XCTAssertEqual(tracker.searchCount, 0)
    let eventsWhileHeld = tracker.eventLog.snapshot()
    XCTAssertTrue(
        eventsWhileHeld.contains("destroy#1"),
        "Prior idle binding #1 was retired and destroyed on enable"
    )
    XCTAssertFalse(eventsWhileHeld.contains("destroy#\(activeSessionID)"))
    XCTAssertFalse(eventsWhileHeld.contains("disable.completed"))
}

final class ControlledGenerationUniFFIDouble: UniFFISemanticSearchEngineBindingProtocol, @unchecked Sendable {
    let instanceID: Int
    let tracker: ControlledGenerationBindingTracker

    init(tracker: ControlledGenerationBindingTracker) {
        self.tracker = tracker
        self.instanceID = tracker.allocateInstance()
    }

    deinit {
        tracker.recordDestroy(instanceID)
    }

    func modelState() -> AppUniFFISemanticModelState {
        .notInstalled
    }

    func prepareModelRuntime() -> AppUniFFISemanticModelState {
        tracker.recordPrepare(instanceID)
        return .ready(
            info: AppUniFFISemanticModelInfo(
                modelId: PinnedSemanticModelConstants.modelId,
                modelRevision: PinnedSemanticModelConstants.modelRevision,
                ggufFilename: PinnedSemanticModelConstants.ggufFilename,
                expectedBytes: PinnedSemanticModelConstants.ggufSizeBytes,
                expectedSha256: PinnedSemanticModelConstants.ggufSha256,
                llamaCppTag: PinnedSemanticModelConstants.llamaCppTag,
                llamaCppCommit: PinnedSemanticModelConstants.llamaCppCommit,
                modelFingerprint: PinnedSemanticModelConstants.testDoubleModelFingerprint,
                backend: .deterministicTestDouble
            )
        )
    }

    func registerScope(descriptor: AppUniFFISemanticScopeDescriptor) -> Bool {
        tracker.recordRegister()
        return true
    }

    func revokeScope(scopeId: String) -> Bool {
        true
    }

    func startDirectoryIndexing(scopeId: String) -> AppUniFFISemanticIndexProgress {
        tracker.enterIndex(instanceID)
        return AppUniFFISemanticIndexProgress(
            scopeId: scopeId,
            phase: .completed,
            processedFiles: 1,
            totalFiles: 1,
            indexedSegments: 1,
            indexGeneration: 1,
            errorMessage: nil
        )
    }

    func cancelIndexing(scopeId: String) {
        tracker.eventLog.record("cancelIndex#\(instanceID)")
    }

    func scopeProgress(scopeId: String) -> AppUniFFISemanticIndexProgress? {
        nil
    }

    func upsertArchiveEntries(
        scopeId: String,
        entries: [AppUniFFISemanticArchiveEntryInput]
    ) -> AppUniFFISemanticIndexProgress {
        tracker.recordUpsert()
        return AppUniFFISemanticIndexProgress(
            scopeId: scopeId,
            phase: .completed,
            processedFiles: 1,
            totalFiles: 1,
            indexedSegments: 1,
            indexGeneration: 1,
            errorMessage: nil
        )
    }

    func removeIndexedFile(scopeId: String, relativePath: String) -> Bool {
        tracker.recordRemoveFile()
        return true
    }

    func search(request: AppUniFFISemanticSearchRequest) -> AppUniFFISemanticSearchResponse {
        tracker.recordSearch()
        return AppUniFFISemanticSearchResponse(
            requestId: request.requestId,
            windowId: request.windowId,
            isCancelled: false,
            degradedLexicalOnly: false,
            hits: []
        )
    }

    func cancelSearch(requestId: UInt64) {
        tracker.eventLog.record("cancelSearch#\(instanceID)")
    }

    func buildOpenRequest(hit: AppUniFFISemanticSearchHit) -> AppUniFFISemanticOpenRequest {
        AppUniFFISemanticOpenRequest(
            scopeId: hit.scopeId,
            sourceKind: hit.sourceKind,
            outerPath: hit.containerOrRootPath,
            archiveEntryPath: hit.archiveEntryPath,
            lineNumber: hit.lineStart
        )
    }
}
