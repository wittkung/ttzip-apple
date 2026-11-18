// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Dispatch
import Foundation
import TTZipCore
import TTZipPreviewKit
import XCTest
@testable import TTZipApp

/// Records what the memory pressure handler saw and delivered.
private final class MemoryPressureDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveredEvents: [DispatchSource.MemoryPressureEvent] = []
    private var readOnMainThread = true
    private var deliveredOnMainThread = false

    /// The thread the handler body ran on when it read the source event.
    var handlerRanOnMainThread: Bool {
        lock.withLock { readOnMainThread }
    }

    /// The thread the delivery closure ran on.
    var deliveryRanOnMainThread: Bool {
        lock.withLock { deliveredOnMainThread }
    }

    var events: [DispatchSource.MemoryPressureEvent] {
        lock.withLock { deliveredEvents }
    }

    func recordEventRead(onMainThread: Bool) {
        lock.withLock { readOnMainThread = onMainThread }
    }

    func recordDelivery(_ event: DispatchSource.MemoryPressureEvent, onMainThread: Bool) {
        lock.withLock {
            deliveredEvents.append(event)
            deliveredOnMainThread = onMainThread
        }
    }
}

private final class MdnsReadDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var processedCount = 0
    private var completedCount = 0
    private var processedOnMainThread = true
    private var completedOnMainThread = false

    var processCallCount: Int {
        lock.withLock { processedCount }
    }

    var completeCallCount: Int {
        lock.withLock { completedCount }
    }

    var processRanOnMainThread: Bool {
        lock.withLock { processedOnMainThread }
    }

    var completeRanOnMainThread: Bool {
        lock.withLock { completedOnMainThread }
    }

    func recordProcessResult(onMainThread: Bool) {
        lock.withLock {
            processedCount += 1
            processedOnMainThread = onMainThread
        }
    }

    func recordComplete(onMainThread: Bool) {
        lock.withLock {
            completedCount += 1
            completedOnMainThread = onMainThread
        }
    }
}

/// Regression coverage for issue #114.
///
/// The Darwin memory pressure handler used to be formed inside a `@MainActor` context.
/// `setEventHandler` takes a C block, so Swift 6 wrapped the isolated closure in a thunk
/// that verifies the running executor. GCD fired that callback on the source's background
/// queue, the check failed, and TTZip died with `EXC_BREAKPOINT` instead of reacting to
/// memory pressure.
@MainActor
final class MemoryPressureIsolationTests: XCTestCase {
    /// Fires the handler from a background queue and expects the event to reach the main actor.
    ///
    /// The handler is installed through the coordinator's own installation path. A timer
    /// source stands in for the memory pressure source because a real kernel memory
    /// pressure event cannot be triggered on demand, and the timer fires on the same
    /// background queue GCD would use.
    func testHandlerDeliversOnMainActorWhenSourceFiresOnBackgroundQueue() {
        let source = DispatchSource.makeTimerSource(
            flags: .strict,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        let recorder = MemoryPressureDeliveryRecorder()
        let delivered = expectation(description: "memory pressure event delivered on the main actor")
        delivered.assertForOverFulfill = false

        AppMemoryPressureCoordinator.installMemoryPressureHandler(
            on: source,
            readEvent: {
                recorder.recordEventRead(onMainThread: Thread.isMainThread)
                return .warning
            },
            deliver: { event in
                recorder.recordDelivery(event, onMainThread: Thread.isMainThread)
                delivered.fulfill()
            }
        )

        source.schedule(deadline: .now())
        source.resume()

        wait(for: [delivered], timeout: 10)

        XCTAssertFalse(
            recorder.handlerRanOnMainThread,
            "the handler body must run on the source's queue, not on the main thread"
        )
        XCTAssertTrue(
            recorder.deliveryRanOnMainThread,
            "the isolated work must be delivered on the main actor"
        )
        XCTAssertEqual(recorder.events, [.warning], "the handler must forward the source event")
    }

    /// The handler must be installed from a nonisolated factory, never from the main actor.
    ///
    /// A handler formed in a main-actor-isolated context inherits that isolation, and the
    /// executor check Swift 6 emits for an isolated closure handed to a C block callback
    /// traps as soon as GCD fires the callback off the main thread.
    func testCoordinatorInstallsTheHandlerFromANonisolatedFactory() throws {
        let sourceText = try XCTUnwrap(coordinatorSourceText(), "the coordinator source must be readable")

        XCTAssertEqual(
            sourceText.components(separatedBy: "setEventHandler(").count - 1,
            1,
            "the memory pressure handler must be installed in exactly one place"
        )
        XCTAssertTrue(
            sourceText.contains("nonisolated static func installMemoryPressureHandler"),
            "the handler must be installed by a nonisolated factory so it carries no main-actor isolation"
        )

        let setupStart = try XCTUnwrap(sourceText.range(of: "private func setupSource()"))
        let setupEnd = try XCTUnwrap(
            sourceText.range(of: "\n    }", range: setupStart.upperBound..<sourceText.endIndex),
            "setupSource must have a closing brace"
        )
        let setupBody = String(sourceText[setupStart.lowerBound..<setupEnd.upperBound])
        XCTAssertFalse(
            setupBody.contains("setEventHandler("),
            "setupSource must not form the handler closure inside the main actor"
        )
        XCTAssertTrue(
            setupBody.contains("[weak source]"),
            "setupSource must capture source weakly in readEvent to avoid a retain cycle"
        )
    }

    func testMdnsReadHandlerProcessesOnBackgroundQueueAndCompletesOnMainActor() {
        let source = DispatchSource.makeTimerSource(
            flags: .strict,
            queue: DispatchQueue(label: "com.ttzip.mdns.browser.test", qos: .userInitiated)
        )
        let recorder = MdnsReadDeliveryRecorder()
        let completed = expectation(description: "mDNS read completion delivered on the main actor")
        completed.assertForOverFulfill = false

        DarwinDnsSdResolver.installReadHandler(
            on: source,
            processResult: {
                recorder.recordProcessResult(onMainThread: Thread.isMainThread)
            },
            onComplete: {
                recorder.recordComplete(onMainThread: Thread.isMainThread)
                completed.fulfill()
            }
        )

        source.schedule(deadline: .now())
        source.resume()

        wait(for: [completed], timeout: 10)
        source.cancel()

        XCTAssertEqual(recorder.processCallCount, 1, "the read handler must invoke processResult once")
        XCTAssertFalse(
            recorder.processRanOnMainThread,
            "processResult must run on the background browser queue, not on the main thread"
        )
        XCTAssertEqual(recorder.completeCallCount, 1, "the read handler must hop to onComplete once")
        XCTAssertTrue(
            recorder.completeRanOnMainThread,
            "onComplete must run on the main actor"
        )
    }

    func testMdnsResolverInstallsReadHandlerFromANonisolatedFactory() throws {
        let sourceText = try XCTUnwrap(mdnsCoordinatorSourceText(), "the mDNS coordinator source must be readable")

        XCTAssertEqual(
            sourceText.components(separatedBy: "setEventHandler(").count - 1,
            1,
            "the mDNS read handler must be installed in exactly one place"
        )
        XCTAssertTrue(
            sourceText.contains("nonisolated static func installReadHandler"),
            "the mDNS read handler must be installed by a nonisolated factory so it carries no main-actor isolation"
        )

        let resolveStart = try XCTUnwrap(sourceText.range(of: "func resolve("))
        let resolveEnd = try XCTUnwrap(
            sourceText.range(of: "\n    }", range: resolveStart.upperBound..<sourceText.endIndex),
            "resolve must have a closing brace"
        )
        let resolveBody = String(sourceText[resolveStart.lowerBound..<resolveEnd.upperBound])
        XCTAssertFalse(
            resolveBody.contains("setEventHandler"),
            "resolve must not form a setEventHandler closure inside the main actor"
        )

        let factoryStart = try XCTUnwrap(sourceText.range(of: "nonisolated static func installReadHandler"))
        let factoryEnd = try XCTUnwrap(
            sourceText.range(of: "\n    }", range: factoryStart.upperBound..<sourceText.endIndex),
            "installReadHandler must have a closing brace"
        )
        let factoryBody = String(sourceText[factoryStart.lowerBound..<factoryEnd.upperBound])
        XCTAssertTrue(
            factoryBody.contains("setEventHandler("),
            "installReadHandler must own the single setEventHandler call"
        )
    }

    func testShouldActivateOnLaunchRespectsCliFlagAndEnvironment() {
        XCTAssertTrue(
            AppDelegate.shouldActivateOnLaunch(arguments: ["TTZip"], environment: [:]),
            "normal launches must activate the app by default"
        )
        XCTAssertTrue(
            TTZipApp.shouldActivateOnLaunch(arguments: ["TTZip"], environment: [:]),
            "TTZipApp.shouldActivateOnLaunch must match AppDelegate by default"
        )
        XCTAssertFalse(
            AppDelegate.shouldActivateOnLaunch(arguments: ["TTZip", "--no-activate"], environment: [:]),
            "--no-activate must suppress startup activation"
        )
        XCTAssertFalse(
            TTZipApp.shouldActivateOnLaunch(arguments: ["TTZip", "--no-activate"], environment: [:]),
            "TTZipApp must suppress startup activation when --no-activate is passed"
        )
        for truthyValue in ["1", "true", "YES", " true "] {
            XCTAssertFalse(
                AppDelegate.shouldActivateOnLaunch(
                    arguments: ["TTZip"],
                    environment: ["TTZIP_NO_ACTIVATE": truthyValue]
                ),
                "TTZIP_NO_ACTIVATE=\(truthyValue) must suppress startup activation"
            )
            XCTAssertFalse(
                TTZipApp.shouldActivateOnLaunch(
                    arguments: ["TTZip"],
                    environment: ["TTZIP_NO_ACTIVATE": truthyValue]
                ),
                "TTZipApp must suppress startup activation for TTZIP_NO_ACTIVATE=\(truthyValue)"
            )
        }
        for falsyValue in ["0", ""] {
            XCTAssertTrue(
                AppDelegate.shouldActivateOnLaunch(
                    arguments: ["TTZip"],
                    environment: ["TTZIP_NO_ACTIVATE": falsyValue]
                ),
                "TTZIP_NO_ACTIVATE=\(falsyValue) must preserve normal startup activation"
            )
            XCTAssertTrue(
                TTZipApp.shouldActivateOnLaunch(
                    arguments: ["TTZip"],
                    environment: ["TTZIP_NO_ACTIVATE": falsyValue]
                ),
                "TTZipApp must preserve startup activation for TTZIP_NO_ACTIVATE=\(falsyValue)"
            )
        }
    }

    func testStartupForegroundActivationIsGuardedByNoActivateCheck() throws {
        let appSource = try XCTUnwrap(ttzipAppSourceText(), "TTZipApp.swift must be readable")
        let delegateSource = try XCTUnwrap(appDelegateSourceText(), "AppDelegate.swift must be readable")

        XCTAssertEqual(
            appSource.components(separatedBy: "activate(ignoringOtherApps:").count - 1,
            1,
            "TTZipApp.swift must have exactly one startup activate call"
        )
        let initStart = try XCTUnwrap(appSource.range(of: "public init()"))
        let initEnd = try XCTUnwrap(
            appSource.range(of: "\n    }", range: initStart.upperBound..<appSource.endIndex),
            "TTZipApp.init must have a closing brace"
        )
        let initBody = String(appSource[initStart.lowerBound..<initEnd.upperBound])
        XCTAssertTrue(
            initBody.contains("NSApplication.shared.setActivationPolicy(.regular)"),
            "TTZipApp.init must keep .regular activation policy for Accessibility and window creation"
        )
        XCTAssertTrue(
            initBody.contains("if Self.shouldActivateOnLaunch()"),
            "TTZipApp.init must guard foreground activation behind Self.shouldActivateOnLaunch()"
        )

        let launchStart = try XCTUnwrap(
            delegateSource.range(of: "public func applicationDidFinishLaunching(_ notification: Notification)")
        )
        let launchEnd = try XCTUnwrap(
            delegateSource.range(of: "\n    }", range: launchStart.upperBound..<delegateSource.endIndex),
            "applicationDidFinishLaunching must have a closing brace"
        )
        let launchBody = String(delegateSource[launchStart.lowerBound..<launchEnd.upperBound])
        XCTAssertTrue(
            launchBody.contains("if Self.shouldActivateOnLaunch()"),
            "applicationDidFinishLaunching must guard makeKeyAndOrderFront behind Self.shouldActivateOnLaunch()"
        )
        XCTAssertTrue(
            launchBody.contains("window.makeKeyAndOrderFront(nil)"),
            "applicationDidFinishLaunching must preserve makeKeyAndOrderFront on normal launches"
        )
        XCTAssertTrue(
            launchBody.contains("window.orderFront(nil)"),
            "applicationDidFinishLaunching must order the window on screen without stealing focus when suppressed"
        )
    }

    @MainActor
    func testNonActivatingLaunchPathPreservesFrontmostApplication() throws {
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let previousEnv = ProcessInfo.processInfo.environment["TTZIP_NO_ACTIVATE"]
        defer {
            if let previousEnv {
                setenv("TTZIP_NO_ACTIVATE", previousEnv, 1)
            } else {
                unsetenv("TTZIP_NO_ACTIVATE")
            }
        }

        let existingWindows = NSApplication.shared.windows.filter { $0.canBecomeMain }
        for existing in existingWindows {
            existing.orderOut(nil)
        }
        let window = LaunchWindowProbe(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }

        setenv("TTZIP_NO_ACTIVATE", "1", 1)
        XCTAssertFalse(
            AppDelegate.shouldActivateOnLaunch(),
            "non-activating launch configuration must evaluate to false"
        )
        let delegate = AppDelegate(modelManager: .shared, registerAsShared: false)
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        XCTAssertEqual(window.orderFrontCallCount, 1)
        XCTAssertEqual(window.makeKeyAndOrderFrontCallCount, 0)

        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        XCTAssertEqual(
            frontmostAfter,
            frontmostBefore,
            "non-activating launch path must not steal frontmost application focus"
        )

        setenv("TTZIP_NO_ACTIVATE", "0", 1)
        window.suppressKeyWindowForwarding = true
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        XCTAssertEqual(
            window.makeKeyAndOrderFrontCallCount,
            1,
            "normal launch path must invoke makeKeyAndOrderFront on the main window"
        )
    }

    @MainActor
    func testForgetArchivePasswordReportsVaultErrorAndScopesPreviewEviction() async throws {
        let archiveA = "/tmp/forget-scope-a-\(UUID().uuidString).zip"
        let archiveB = "/tmp/forget-scope-b-\(UUID().uuidString).zip"
        let subpathA = "nested/folder/secretA.txt"
        let subpathB = "docs/keepB.txt"
        defer {
            ArchivePasswordStore.shared.removePassword(for: archiveA)
            ArchivePasswordStore.shared.removePassword(for: archiveB)
        }

        let failingController = ArchiveRememberedPasswordController(store: FailingForgetCredentialStore())
        let stateWithFailingVault = AppViewState(archiveRememberedPasswordController: failingController)
        stateWithFailingVault.explorerState.currentArchivePath = archiveA
        let failedForget = await stateWithFailingVault.forgetArchivePassword(at: archiveA)
        XCTAssertFalse(failedForget)
        XCTAssertFalse(stateWithFailingVault.taskState.statusMessage.isEmpty)

        let catalogEntryA = ArchiveEntry(
            path: subpathA, uncompressedSize: 16, isDirectory: false,
            modificationDate: nil, isEncrypted: true, compressedSize: 16, crc32: 1
        )
        let unpreviewedEntryA = ArchiveEntry(
            path: "docs/unpreviewedA.txt", uncompressedSize: 16, isDirectory: false,
            modificationDate: nil, isEncrypted: true, compressedSize: 16, crc32: 2
        )
        let driverA = DirectExtractionCredentialDriver(
            acceptedPassword: "pw-a", catalogEntries: [catalogEntryA, unpreviewedEntryA]
        )
        let state = AppViewState(
            fileViewer: SilentTestFileViewer(), passwordDriver: driverA,
            archiveRememberedPasswordController: nil
        )
        ArchivePasswordStore.shared.setPassword("pw-a", for: archiveA)
        _ = await state.loadArchive(path: archiveA, password: "pw-a")
        let registeredOnOpen = ArchivePreviewKeyRegistry.shared.consumeKeys(
            forLogicalKey: ArchiveCredentialIdentity.logicalKey(for: archiveA), archivePaths: [archiveA]
        )
        XCTAssertTrue(registeredOnOpen.isEmpty)

        let keyA = PreviewLRUCacheManager.deterministicCacheKey(archivePath: archiveA, subpath: subpathA)
        let keyB = PreviewLRUCacheManager.deterministicCacheKey(archivePath: archiveB, subpath: subpathB)
        _ = try await PreviewLRUCacheManager.shared.stageFile(
            data: Data("keep-b".utf8), key: keyB, suggestedFileName: "keepB.txt"
        )
        let leaseB = await PreviewLRUCacheManager.shared.acquireLease(forKey: keyB)
        state.selectArchiveEntry(path: unpreviewedEntryA.path, inArchive: archiveA)
        let registeredOnSelectOnly = ArchivePreviewKeyRegistry.shared.consumeKeys(
            forLogicalKey: ArchiveCredentialIdentity.logicalKey(for: archiveA), archivePaths: [archiveA]
        )
        XCTAssertTrue(registeredOnSelectOnly.isEmpty)
        let taskBox = UnsafeMutableTransferBox<Task<AppViewState.VirtualPreviewResolution, Never>?>(nil)
        let previewTask = Task { @MainActor in
            await AppViewState.resolveAndPinVirtualPreviewURL(
                archivePath: archiveA,
                subpath: subpathA,
                customExtractor: { _, _, destinationDir, _ in
                    let fileURL = URL(fileURLWithPath: destinationDir).appendingPathComponent("secretA.txt")
                    try Data("secret-a".utf8).write(to: fileURL)
                    DispatchQueue.main.async {
                        DispatchQueue.main.async {
                            taskBox.value?.cancel()
                        }
                    }
                }
            )
        }
        taskBox.value = previewTask
        let previewResolution = await previewTask.value
        if let leaseA = previewResolution.lease {
            await PreviewLRUCacheManager.shared.releaseLease(leaseA)
        }
        state.closeCurrentArchive(discardAcceptedResources: true)
        for index in 0..<35 {
            ArchivePreviewKeyRegistry.shared.record(
                archivePath: "/tmp/other-archive-\(index).zip",
                cacheKey: "unstaged-key-\(index)"
            )
        }
        await ArchiveHierarchySessionCache.shared.invalidate(
            logicalKey: ArchiveCredentialIdentity.logicalKey(for: archiveA)
        )
        let disconnectedDriver = DirectExtractionCredentialDriver(acceptedPassword: "source-unavailable")
        let disconnectedState = AppViewState(
            fileViewer: SilentTestFileViewer(),
            passwordDriver: disconnectedDriver,
            archiveRememberedPasswordController: nil
        )
        let succeeded = await disconnectedState.forgetArchivePassword(at: archiveA)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            disconnectedDriver.inspectCallCount,
            0,
            "forgetArchivePassword must bound eviction to acquired preview keys and staged directories without inspecting catalogs"
        )
        let cachedA = await PreviewLRUCacheManager.shared.cachedURL(forKey: keyA, expectedFilename: "secretA.txt")
        let cachedB = await PreviewLRUCacheManager.shared.cachedURL(forKey: keyB, expectedFilename: "keepB.txt")
        let leaseCountB = await PreviewLRUCacheManager.shared.activeLeaseCount(forKey: keyB)
        await PreviewLRUCacheManager.shared.releaseLease(leaseB, reclaimImmediatelyIfIdle: true)

        XCTAssertNil(cachedA, "Staged nested preview must be evicted even after >32 archives when source is unavailable")
        XCTAssertNotNil(cachedB)
        XCTAssertEqual(leaseCountB, 1)
    }

    private func coordinatorSourceText() -> String? {
        try? String(contentsOf: applePackageRoot.appendingPathComponent("Sources/TTZipApp/Features/AppShell/AppMemoryPressureCoordinator.swift"), encoding: .utf8)
    }

    private func mdnsCoordinatorSourceText() -> String? {
        try? String(contentsOf: applePackageRoot.appendingPathComponent("Sources/TTZipApp/Features/DeviceTransferWireless/WirelessMdnsCoordinator.swift"), encoding: .utf8)
    }

    private func ttzipAppSourceText() -> String? {
        try? String(contentsOf: applePackageRoot.appendingPathComponent("Sources/TTZipApp/TTZipApp.swift"), encoding: .utf8)
    }

    private func appDelegateSourceText() -> String? {
        try? String(contentsOf: applePackageRoot.appendingPathComponent("Sources/TTZipApp/Features/AppShell/AppDelegate.swift"), encoding: .utf8)
    }

    /// The `products/ttzip/apple` package root, in the runfiles or in the source tree.
    private var applePackageRoot: URL {
        if let srcDir = ProcessInfo.processInfo.environment["RUNFILES_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_SRCDIR"] {
            let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] ?? "_main"
            let runfilesTarget = URL(fileURLWithPath: srcDir)
                .appendingPathComponent(workspace)
                .appendingPathComponent("products/ttzip/apple")
            if FileManager.default.fileExists(atPath: runfilesTarget.appendingPathComponent("Package.swift").path) {
                return runfilesTarget
            }
        }
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: currentDir.appendingPathComponent("Package.swift").path) {
            return currentDir
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            dir.deleteLastPathComponent()
        }
        return dir
    }

    @MainActor
    func testDirectExtractionReusesRememberedScopedPasswordAndUnlocksLockedVault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("direct-extract.zip")
        try Data("encrypted-fixture".utf8).write(to: archiveURL)
        defer { ArchivePasswordStore.shared.removePassword(for: archiveURL.path) }

        let identity = try XCTUnwrap(ArchiveCredentialIdentity.resolve(archivePath: archiveURL.path))
        let store = UnlockOnAsyncCredentialStore()
        let sharedGeneration = ArchiveCredentialGeneration()
        let controller = ArchiveRememberedPasswordController(store: store, generation: sharedGeneration)
        let saved = try await controller.rememberVerifiedAsync(
            "remembered-secret", for: identity,
            capturedGeneration: controller.operationGeneration(for: identity)
        )
        XCTAssertTrue(saved)
        XCTAssertEqual(store.asyncUnlockCount, 1)

        store.lockStore()
        let driver = DirectExtractionCredentialDriver(acceptedPassword: "remembered-secret")
        let state = AppViewState(
            fileViewer: SilentTestFileViewer(), passwordDriver: driver,
            archiveRememberedPasswordController: controller
        )
        await state.quickExtractArchive(archivePath: archiveURL.path, targetDir: root.path, isSmartExtract: false)
        XCTAssertFalse(state.overlayState.showPasswordPrompt)
        XCTAssertEqual(driver.quickExtractPasswords, [nil, "remembered-secret"])
        XCTAssertEqual(store.asyncUnlockCount, 2)

        ArchivePasswordStore.shared.removePassword(for: archiveURL.path)
        state.explorerState.activePassword = nil
        store.lockStore()
        await state.extractEntries(archivePath: archiveURL.path, entryPaths: ["secret.txt"], destinationDir: root.path)
        XCTAssertFalse(state.overlayState.showPasswordPrompt)
        XCTAssertEqual(driver.extractEntriesPasswords, [nil, "remembered-secret"])
        XCTAssertEqual(store.asyncUnlockCount, 3)

        try await assertWindowCloseAndConcurrentForgetCoordination(
            archivePath: archiveURL.path,
            targetDir: root.path,
            identity: identity,
            store: store,
            sharedGeneration: sharedGeneration,
            controller: controller,
            driver: driver
        )
    }

    @MainActor
    private func assertWindowCloseAndConcurrentForgetCoordination(
        archivePath: String,
        targetDir: String,
        identity: ArchiveCredentialIdentity,
        store: UnlockOnAsyncCredentialStore,
        sharedGeneration: ArchiveCredentialGeneration,
        controller: ArchiveRememberedPasswordController,
        driver: DirectExtractionCredentialDriver
    ) async throws {
        ArchivePasswordStore.shared.removePassword(for: archivePath)
        let closingQuickState = AppViewState(
            fileViewer: SilentTestFileViewer(), passwordDriver: driver, archiveRememberedPasswordController: controller
        )
        driver.onAuthenticatedExtract = { [weak closingQuickState] in closingQuickState?.prepareForWindowClose() }
        await closingQuickState.quickExtractArchive(archivePath: archivePath, targetDir: targetDir, isSmartExtract: false)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archivePath))

        let closingSelectedState = AppViewState(
            fileViewer: SilentTestFileViewer(), passwordDriver: driver, archiveRememberedPasswordController: controller
        )
        driver.onAuthenticatedExtract = { [weak closingSelectedState] in closingSelectedState?.prepareForWindowClose() }
        await closingSelectedState.extractEntries(archivePath: archivePath, entryPaths: ["secret.txt"], destinationDir: targetDir)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archivePath))

        let genBeforeForget = controller.operationGeneration(for: identity)
        var publishedUnderNewGenDuringUnlock = false
        store.onEnsureUnlocked = {
            let currentGen = controller.operationGeneration(for: identity)
            if currentGen != genBeforeForget {
                publishedUnderNewGenDuringUnlock = (try? controller.rememberVerified(
                    "newer-secret", for: identity, capturedGeneration: currentGen
                )) ?? false
            }
        }
        try await controller.forgetAsync(logicalKey: identity.logicalKey)
        store.onEnsureUnlocked = nil
        if publishedUnderNewGenDuringUnlock {
            let remaining = try await controller.passwordAsync(for: identity)
            XCTAssertEqual(remaining, "newer-secret")
        }
        XCTAssertFalse(try controller.rememberVerified("stale-secret", for: identity, capturedGeneration: genBeforeForget))

        _ = try await controller.rememberVerifiedAsync(
            "secret-to-forget", for: identity, capturedGeneration: controller.operationGeneration(for: identity)
        )
        store.lockStore()
        XCTAssertThrowsError(try controller.forget(identity))
        XCTAssertThrowsError(try controller.rejectSavedCandidate("stale-candidate", for: identity))
        let reconciledAfterFailedReject = try await controller.passwordAsync(for: identity)
        XCTAssertNil(reconciledAfterFailedReject, "Pending Forget must survive failed candidate rejection")

        _ = try await controller.rememberVerifiedAsync(
            "before-second-forget", for: identity, capturedGeneration: controller.operationGeneration(for: identity)
        )
        store.lockStore()
        XCTAssertThrowsError(try controller.forget(identity))
        let controllerB = ArchiveRememberedPasswordController(store: store, generation: sharedGeneration)
        let savedByB = try await controllerB.rememberVerifiedAsync(
            "window-b-secret", for: identity, capturedGeneration: controllerB.operationGeneration(for: identity)
        )
        XCTAssertTrue(savedByB)
        let readFromA = try await controller.passwordAsync(for: identity)
        XCTAssertEqual(readFromA, "window-b-secret")
    }
}

private final class UnsafeMutableTransferBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

private final class LaunchWindowProbe: NSWindow {
    var makeKeyAndOrderFrontCallCount = 0
    var orderFrontCallCount = 0
    var suppressKeyWindowForwarding = false
    override var canBecomeMain: Bool { true }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        makeKeyAndOrderFrontCallCount += 1
        if !suppressKeyWindowForwarding { super.makeKeyAndOrderFront(sender) }
    }
    override func orderFront(_ sender: Any?) {
        orderFrontCallCount += 1
        super.orderFront(sender)
    }
}

private struct SilentTestFileViewer: FileViewerServiceProtocol {
    func revealInFinder(at path: String) {}
    func openWithDefaultApp(at path: String) {}
}

private final class FailingForgetCredentialStore: ArchiveScopedCredentialStore, @unchecked Sendable {
    func password(logicalKey: String, contentKey: String) throws -> String? { nil }
    func upsert(password: String, logicalKey: String, contentKey: String, label: String) throws {}
    func remove(logicalKey: String) throws { throw ArchiveScopedVaultAccessError.locked }
    func remove(logicalKey: String, contentKey: String, ifPasswordMatches password: String) throws {}
}

private final class UnlockOnAsyncCredentialStore: ArchiveScopedCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var unlocked = false
    private var records: [String: (contentKey: String, password: String)] = [:]
    private(set) var asyncUnlockCount = 0
    var onEnsureUnlocked: (() -> Void)?

    func lockStore() { lock.withLock { unlocked = false } }

    func ensureUnlockedAsync() async throws {
        let hook = lock.withLock { () -> (() -> Void)? in
            unlocked = true
            asyncUnlockCount += 1
            return onEnsureUnlocked
        }
        hook?()
    }

    func password(logicalKey: String, contentKey: String) throws -> String? {
        try lock.withLock {
            guard unlocked else { throw ArchiveScopedVaultAccessError.locked }
            guard let record = records[logicalKey], record.contentKey == contentKey else { return nil }
            return record.password
        }
    }

    func upsert(password: String, logicalKey: String, contentKey: String, label: String) throws {
        try lock.withLock {
            guard unlocked else { throw ArchiveScopedVaultAccessError.locked }
            records[logicalKey] = (contentKey, password)
        }
    }

    func remove(logicalKey: String) throws {
        try lock.withLock {
            guard unlocked else { throw ArchiveScopedVaultAccessError.locked }
            _ = records.removeValue(forKey: logicalKey)
        }
    }

    func remove(logicalKey: String, contentKey: String, ifPasswordMatches password: String) throws {
        try lock.withLock {
            guard unlocked else { throw ArchiveScopedVaultAccessError.locked }
            if records[logicalKey]?.password == password && records[logicalKey]?.contentKey == contentKey {
                _ = records.removeValue(forKey: logicalKey)
            }
        }
    }
}

@MainActor
private final class DirectExtractionCredentialDriver: ArchivePasswordOperationsDriver {
    let acceptedPassword: String
    let catalogEntries: [ArchiveEntry]
    var inspectCallCount = 0
    var quickExtractPasswords: [String?] = []
    var extractEntriesPasswords: [String?] = []
    var onAuthenticatedExtract: (@MainActor () -> Void)?

    init(acceptedPassword: String, catalogEntries: [ArchiveEntry] = []) {
        self.acceptedPassword = acceptedPassword
        self.catalogEntries = catalogEntries
    }

    func inspectArchive(archivePath: String, password: String?, autoVaultUnlock: Bool) async throws -> InspectResult {
        inspectCallCount += 1
        guard password == acceptedPassword else { throw ArchiveError.wrongPassword(archivePath: archivePath) }
        return InspectResult(
            archivePath: archivePath, format: "zip", entries: catalogEntries,
            totalUncompressedBytes: 0, totalCompressedBytes: 0, unlockedPassword: password
        )
    }

    func verifyEncryptedEntryPayload(archivePath: String, entryPath: String, password: String) async throws -> Data? {
        guard password == acceptedPassword else { throw ArchiveError.wrongPassword(archivePath: archivePath) }
        return Data("ok".utf8)
    }

    func quickExtract(
        archivePath: String, destinationDir: String, password: String?,
        autoVaultUnlock: Bool, handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)?, token: CancellationToken?
    ) async throws -> ExtractResult {
        quickExtractPasswords.append(password)
        guard password == acceptedPassword else { throw ArchiveError.wrongPassword(archivePath: archivePath) }
        onAuthenticatedExtract?()
        return ExtractResult(
            archivePath: archivePath, destinationDir: destinationDir,
            durationSeconds: 0.01, unlockedPassword: password, isVaultUnlocked: false
        )
    }

    func extractEntries(
        archivePath: String, entryPaths: [String], destinationDir: String,
        password: String?, handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ExtractionOutcome {
        extractEntriesPasswords.append(password)
        guard password == acceptedPassword else { throw ArchiveError.wrongPassword(archivePath: archivePath) }
        onAuthenticatedExtract?()
        return ExtractionOutcome(
            status: .completed, extracted: UInt64(entryPaths.count),
            replaced: 0, keptBoth: 0, skipped: 0, failed: []
        )
    }
}
