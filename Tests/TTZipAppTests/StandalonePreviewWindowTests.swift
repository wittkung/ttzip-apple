// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TTMediaKit
import TTZipCore
import TTZipUI
@testable import TTZipApp
@testable import TTZipPreviewKit

/// Headless lifecycle evidence; these tests intentionally do not create or order front a window.
@MainActor
final class StandalonePreviewWindowTests: XCTestCase {
    internal var manager: StandalonePreviewWindowManager!
    internal var directory: URL!
    internal var cache: PreviewLRUCacheManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = StandalonePreviewWindowManager()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("standalone-preview-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = PreviewLRUCacheManager(customCacheDir: directory.appendingPathComponent("cache"))
    }

    override func tearDown() async throws {
        await manager.closeAll()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    internal func file(_ name: String) throws -> ImmersiveMediaItem {
        let url = directory.appendingPathComponent(name)
        try Data("Resource lifecycle fixture; not a decoding fixture.".utf8).write(to: url)
        return ImmersiveMediaItem(url: url, name: name)
    }

    private func staged(_ name: String, key: String) async throws -> (ImmersiveMediaItem, PreviewCacheLease) {
        let consumer = UUID()
        let reservation = try await cache.acquireStagingReservation(
            forKey: key, filename: name, estimatedBytes: 32, consumerID: consumer, pinActive: true
        )
        try Data(repeating: 42, count: 32).write(to: reservation.targetURL)
        let resolved = try await cache.resolveAndRegisterExtractedPreview(
            forKey: key, filename: name, subpath: name, pinActive: true,
            consumerID: consumer, reservationID: reservation.id
        )
        let url = try XCTUnwrap(resolved)
        let lease = await cache.acquireLease(forKey: key, consumerID: consumer)
        return (ImmersiveMediaItem(url: url, name: name, sourceArchivePath: "/tmp/preview.zip",
                                   archiveSubpath: name, resourceCacheKey: key), lease)
    }

    func testRepeatedOpenFromSameOriginUsesOneHeadlessSession() async throws {
        let item = try file("document.pdf")
        let origin = UUID()
        let first = await manager.open(item: item, originWindowID: origin, createAppKitWindow: false, cacheManager: cache)
        let second = await manager.open(item: item, originWindowID: origin, createAppKitWindow: false, cacheManager: cache)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(manager.activeWindowCount, 1)
        XCTAssertEqual(manager.createdWindowCount, 0)
        await manager.close(item: item, originWindowID: origin)
        XCTAssertEqual(manager.activeWindowCount, 0)
    }

    func testDifferentFilesAndDifferentOriginsRemainIndependent() async throws {
        let first = try file("first.epub")
        let second = try file("second.pdf")
        let originA = UUID()
        let originB = UUID()
        let openA = await manager.open(item: first, originWindowID: originA, createAppKitWindow: false, cacheManager: cache)
        let openB = await manager.open(item: second, originWindowID: originA, createAppKitWindow: false, cacheManager: cache)
        let openC = await manager.open(item: first, originWindowID: originB, createAppKitWindow: false, cacheManager: cache)
        XCTAssertTrue(openA && openB && openC)
        XCTAssertEqual(manager.activeWindowCount, 3)
        await manager.close(item: first, originWindowID: originA)
        XCTAssertTrue(manager.isPresenting(item: second, originWindowID: originA))
        XCTAssertTrue(manager.isPresenting(item: first, originWindowID: originB))
        XCTAssertEqual(manager.activeWindowCount, 2)
    }

    func testIndependentCacheLeaseSurvivesOriginReleaseAndClosingOneOrigin() async throws {
        let (item, browserLease) = try await staged("book.epub", key: "book_lease")
        let originA = UUID()
        let originB = UUID()
        let a = await manager.open(item: item, originWindowID: originA, createAppKitWindow: false, cacheManager: cache)
        let b = await manager.open(item: item, originWindowID: originB, createAppKitWindow: false, cacheManager: cache)
        XCTAssertTrue(a && b)
        let aLease = try XCTUnwrap(manager.cacheLease(item: item, originWindowID: originA))
        let bLease = try XCTUnwrap(manager.cacheLease(item: item, originWindowID: originB))
        XCTAssertNotEqual(aLease.consumerID, bLease.consumerID)
        let initialCount = await cache.activeLeaseCount(forKey: browserLease.key)
        XCTAssertEqual(initialCount, 3)
        await cache.releaseLease(browserLease)
        await manager.close(item: item, originWindowID: originA)
        let remaining = await cache.activeLeaseCount(forKey: browserLease.key)
        XCTAssertEqual(remaining, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        await manager.close(item: item, originWindowID: originB)
        let finalCount = await cache.activeLeaseCount(forKey: browserLease.key)
        XCTAssertEqual(finalCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
    }

    func testMissingCacheKeyNeverCreatesSyntheticProtection() async throws {
        let readable = try file("readable.pdf")
        let item = ImmersiveMediaItem(url: readable.url, name: readable.name,
                                      sourceArchivePath: "/tmp/missing.zip", archiveSubpath: readable.name,
                                      resourceCacheKey: "absent_key")
        let opened = await manager.open(item: item, originWindowID: UUID(), createAppKitWindow: false, cacheManager: cache)
        XCTAssertFalse(opened)
        XCTAssertEqual(manager.activeWindowCount, 0)
        let count = await cache.activeLeaseCount(forKey: "absent_key")
        XCTAssertEqual(count, 0)
    }

    func testSecurityScopeBalancesAndMissingFileIsRejected() async throws {
        let item = try file("text.txt")
        let origin = UUID()
        let baseline = RootFolderAccessManager.shared.activeLeaseCount(for: item.url)
        let opened = await manager.open(item: item, originWindowID: origin, createAppKitWindow: false, cacheManager: cache)
        XCTAssertTrue(opened)
        XCTAssertEqual(RootFolderAccessManager.shared.activeLeaseCount(for: item.url), baseline + 1)
        await manager.close(item: item, originWindowID: origin)
        XCTAssertEqual(RootFolderAccessManager.shared.activeLeaseCount(for: item.url), baseline)
        try FileManager.default.removeItem(at: item.url)
        let missing = await manager.open(item: item, originWindowID: origin, createAppKitWindow: false, cacheManager: cache)
        XCTAssertFalse(missing)
        XCTAssertEqual(manager.activeWindowCount, 0)
        XCTAssertEqual(RootFolderAccessManager.shared.activeLeaseCount(for: item.url), baseline)
    }

    func testCloseDuringAcquisitionCannotReopenOrReleaseBrowserLease() async throws {
        let (item, browserLease) = try await staged("waiting.pdf", key: "waiting")
        let origin = UUID()
        let gate = StandalonePreviewCommitGate()
        manager.onWillCommitAcquiredLeaseHook = { await gate.wait() }
        let request = Task { await manager.open(item: item, originWindowID: origin, createAppKitWindow: false, cacheManager: cache) }
        await fulfillment(of: [gate.arrived], timeout: 3)
        await manager.close(item: item, originWindowID: origin)
        await gate.finish()
        let opened = await request.value
        XCTAssertFalse(opened)
        XCTAssertEqual(manager.activeWindowCount, 0)
        let remaining = await cache.activeLeaseCount(forKey: browserLease.key)
        XCTAssertEqual(remaining, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        await cache.releaseLease(browserLease)
    }

    func testConcurrentSameIdentityRequestsCoalesce() async throws {
        let (item, browserLease) = try await staged("concurrent.pdf", key: "concurrent")
        let origin = UUID()
        let gate = StandalonePreviewCommitGate()
        manager.onWillCommitAcquiredLeaseHook = { await gate.wait() }
        let first = Task { await manager.open(item: item, originWindowID: origin, createAppKitWindow: false, cacheManager: cache) }
        await fulfillment(of: [gate.arrived], timeout: 3)
        let second = Task { await manager.open(item: item, originWindowID: origin, createAppKitWindow: false, cacheManager: cache) }
        await gate.finish()
        let a = await first.value
        let b = await second.value
        XCTAssertTrue(a && b)
        XCTAssertEqual(manager.activeWindowCount, 1)
        let count = await cache.activeLeaseCount(forKey: browserLease.key)
        XCTAssertEqual(count, 2)
        await cache.releaseLease(browserLease)
    }

    func testEphemeralResourceKeepsItsIndependentConsumerUntilClose() async throws {
        let payload = Data("Independent ephemeral \(UUID())".utf8)
        let url = try XCTUnwrap(TTMediaDetector.writeDataToTemporaryFile(data: payload, fileName: "note.txt"))
        let item = ImmersiveMediaItem(url: url, name: "note.txt")
        let origin = UUID()
        let initial = TTMediaDetector.activeEphemeralLeaseCount(for: url)
        let opened = await manager.open(item: item, originWindowID: origin, createAppKitWindow: false, cacheManager: cache)
        XCTAssertTrue(opened)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: url), initial + 1)
        await manager.close(item: item, originWindowID: origin)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: url), initial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        TTMediaDetector.releaseEphemeralMediaFile(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEphemeralResourceDoesNotReleaseAnAlreadyClaimedOriginConsumer() async throws {
        let payload = Data("Claimed origin \(UUID())".utf8)
        let url = try XCTUnwrap(TTMediaDetector.writeDataToTemporaryFile(data: payload, fileName: "claimed.txt"))
        let originalBox = TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: url)
        let item = ImmersiveMediaItem(url: url, name: "claimed.txt")
        let origin = UUID()
        let initial = TTMediaDetector.activeEphemeralLeaseCount(for: url)
        let opened = await manager.open(item: item, originWindowID: origin, createAppKitWindow: false, cacheManager: cache)
        XCTAssertTrue(opened)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: url), initial + 1)
        originalBox.release()
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: url), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        await manager.close(item: item, originWindowID: origin)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: url), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCallerCancellationAfterAcquisitionRollsBackOnlyItsConsumer() async throws {
        let (item, browserLease) = try await staged("cancelled.pdf", key: "cancelled")
        let origin = UUID()
        let gate = StandalonePreviewCommitGate()
        manager.onWillCommitAcquiredLeaseHook = { await gate.wait() }
        let request = Task { await manager.open(item: item, originWindowID: origin, createAppKitWindow: false, cacheManager: cache) }
        await fulfillment(of: [gate.arrived], timeout: 3)
        request.cancel()
        await gate.finish()
        let opened = await request.value
        XCTAssertFalse(opened)
        XCTAssertEqual(manager.activeWindowCount, 0)
        let remaining = await cache.activeLeaseCount(forKey: browserLease.key)
        XCTAssertEqual(remaining, 1)
        await cache.releaseLease(browserLease)
    }

    func testArchiveProvenanceSurvivesURLResolutionAndCannotBecomeEditable() async throws {
        let (item, browserLease) = try await staged("readonly.txt", key: "readonly")
        let origin = UUID()
        let opened = await manager.open(item: item, originWindowID: origin,
                                        resourceContext: item.resolvedResourceContext.withTruncatedPreview(),
                                        createAppKitWindow: false, cacheManager: cache)
        XCTAssertTrue(opened)
        let resolved = try XCTUnwrap(manager.resolvedItem(item: item, originWindowID: origin))
        XCTAssertEqual(resolved.resolvedResourceContext.archiveIdentity, item.resolvedResourceContext.archiveIdentity)
        XCTAssertTrue(resolved.resolvedResourceContext.isPreviewTruncated)
        XCTAssertFalse(resolved.resolvedResourceContext.isEditableInPlace)
        XCTAssertFalse(resolved.isEditable)
        await cache.releaseLease(browserLease)
    }

    private func securityScopeCounts(_ access: RootFolderAccessManager) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: access.accessingURLs.map { url in
            (url.path, access.activeLeaseCount(forKey: url.path))
        })
    }

    func testArchiveSourceScopeIsIndependentOfStagedScopeAndBrowserLifetime() async throws {
        let sourceDirectory = directory.appendingPathComponent("source-archive")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let archive = sourceDirectory.appendingPathComponent("books.zip")
        try Data("Source identity fixture".utf8).write(to: archive)
        let (cached, browserCacheLease) = try await staged("source-scope.epub", key: "source_scope")
        let item = ImmersiveMediaItem(url: cached.url, name: cached.name, sourceArchivePath: archive.path,
                                      archiveSubpath: cached.name, resourceCacheKey: cached.resourceCacheKey)
        let access = RootFolderAccessManager.shared
        let initialTotal = access.totalActiveLeaseCount
        let browserScope = try XCTUnwrap(access.acquireLease(for: archive))
        XCTAssertEqual(access.totalActiveLeaseCount, initialTotal + 1)
        let before = securityScopeCounts(access)
        let acquired = await StandalonePreviewResources.acquire(for: item, cacheManager: cache)
        let resources = try XCTUnwrap(acquired?.resources)
        let sourceKey = try XCTUnwrap(resources.sourceScopeLeaseKey)
        XCTAssertEqual(sourceKey, browserScope.leaseKey)
        var ownedCounts = [sourceKey: 1]
        ownedCounts[resources.readableScopeLeaseKey, default: 0] += 1
        XCTAssertEqual(access.totalActiveLeaseCount, initialTotal + 3,
                       "The browser plus two independent resource holds must exist even if their scope keys alias")
        for (key, count) in ownedCounts {
            XCTAssertEqual(access.activeLeaseCount(forKey: key), before[key, default: 0] + count)
        }
        browserScope.release()
        XCTAssertEqual(access.totalActiveLeaseCount, initialTotal + 2)
        for (key, count) in ownedCounts {
            let browserRelease = key == browserScope.leaseKey ? 1 : 0
            XCTAssertEqual(access.activeLeaseCount(forKey: key), before[key, default: 0] + count - browserRelease)
        }
        await resources.release()
        XCTAssertEqual(access.totalActiveLeaseCount, initialTotal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        await cache.releaseLease(browserCacheLease)
    }

    func testUnavailableArchiveSourceDoesNotBlockValidatedCachedPreview() async throws {
        let archive = directory.appendingPathComponent("missing-source-folder/books.zip")
        let (cached, browserCacheLease) = try await staged("cached-only.pdf", key: "cached_only")
        let item = ImmersiveMediaItem(url: cached.url, name: cached.name, sourceArchivePath: archive.path,
                                      archiveSubpath: cached.name, resourceCacheKey: cached.resourceCacheKey)
        let access = RootFolderAccessManager.shared
        let before = securityScopeCounts(access)
        let initialTotal = access.totalActiveLeaseCount
        let acquired = await StandalonePreviewResources.acquire(for: item, cacheManager: cache)
        let resources = try XCTUnwrap(acquired?.resources)
        XCTAssertNil(resources.sourceScopeLeaseKey, "An unavailable source must not retain a synthetic archive hold")
        XCTAssertNotNil(resources.cacheLease)
        XCTAssertEqual(access.totalActiveLeaseCount, initialTotal + 1)
        let stagedKey = resources.readableScopeLeaseKey
        XCTAssertEqual(access.activeLeaseCount(forKey: stagedKey), before[stagedKey, default: 0] + 1)
        await resources.release()
        XCTAssertEqual(access.totalActiveLeaseCount, initialTotal)
        await cache.releaseLease(browserCacheLease)
    }

    func testFailedCacheAcquisitionReleasesOnlyItsOwnArchiveScope() async throws {
        let sourceDirectory = directory.appendingPathComponent("source-failure")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let archive = sourceDirectory.appendingPathComponent("source.zip")
        try Data("Archive source".utf8).write(to: archive)
        let readable = try file("uncached.pdf")
        let item = ImmersiveMediaItem(url: readable.url, name: readable.name, sourceArchivePath: archive.path,
                                      archiveSubpath: readable.name, resourceCacheKey: "missing_source_cache")
        let access = RootFolderAccessManager.shared
        let baseline = access.activeLeaseCount(for: archive)
        let browserScope = try XCTUnwrap(access.acquireLease(for: archive))
        let opened = await manager.open(item: item, originWindowID: UUID(), createAppKitWindow: false, cacheManager: cache)
        XCTAssertFalse(opened)
        XCTAssertEqual(access.activeLeaseCount(for: archive), baseline + 1)
        XCTAssertEqual(manager.activeWindowCount, 0)
        browserScope.release()
        XCTAssertEqual(access.activeLeaseCount(for: archive), baseline)
    }

    func testVideoCannotEnterTheNonVideoManager() async throws {
        let fixture = try locatePreviewFixturesRoot().appendingPathComponent("video/clip.mp4")
        let item = ImmersiveMediaItem(url: fixture, name: fixture.lastPathComponent)
        XCTAssertTrue(StandalonePlaybackWindowManager.isVideoItem(item))
        let opened = await manager.open(item: item, originWindowID: UUID(), createAppKitWindow: false, cacheManager: cache)
        XCTAssertFalse(opened)
        XCTAssertEqual(manager.activeWindowCount, 0)
    }

    func testInspectorMediaPreviewUsesBottomRightFloatingExpandWithoutDedicatedTopBar() async throws {
        let sample = try file("sample-inspector.txt")
        let preview = MediaPreviewView(
            previewType: .text("Line 1 unoccluded\nLine 2 content\nLine 3 content"),
            fileName: sample.name,
            fileURL: sample.url,
            isImmersiveFullscreen: false,
            showsFloatingFullScreenButton: true,
            isEditable: true,
            resourceContext: .diskFile(url: sample.url, fileName: sample.name, allowsEditing: true)
        )
        XCTAssertTrue(preview.effectiveShowsStandaloneWindowButton)
        XCTAssertFalse(preview.effectiveShowsFloatingFullScreenButton)

        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: preview.frame(width: 280, height: 360))
        host.sizingOptions = []
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.setContentSize(NSSize(width: 280, height: 360))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()

        let textLabels = findStaticTextValues(in: host)
        XCTAssertFalse(textLabels.contains(AppLocalizationState.shared.t(L10n.Preview.fullScreen)),
                       "Inspector expand button must be an icon-only floating button without a full-row text label")
        let scrollRects = findScrollViewRects(in: host, relativeTo: host)
        XCTAssertTrue(scrollRects.contains(where: { $0.height >= 280 }),
                      "Removing the dedicated top button row must give the Inspector document viewport full vertical height")
        try await assertBottomRightExpandButtonVisibleAcrossReadingModes(sample: sample)

        final class NotificationRecorder: @unchecked Sendable {
            var item: ImmersiveMediaItem?
        }
        let recorder = NotificationRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TTZipToggleMediaFocusNotification"),
            object: nil,
            queue: .main
        ) { note in
            recorder.item = note.object as? ImmersiveMediaItem
        }
        defer { NotificationCenter.default.removeObserver(token) }

        preview.toggleFullScreen()
        XCTAssertEqual(recorder.item?.url.standardizedFileURL, sample.url.standardizedFileURL)
        XCTAssertEqual(recorder.item?.name, sample.name)
    }

    private func assertBottomRightExpandButtonVisibleAcrossReadingModes(sample: ImmersiveMediaItem) async throws {
        let prefs = TTTextReadingPreferenceStore.shared
        let prevMode = prefs.mode
        defer { prefs.mode = prevMode }
        for mode in [TTTextReadingBackgroundMode.black, .white, .fluidTransparent] {
            prefs.mode = mode
            let modePreview = MediaPreviewView(
                previewType: .text("Line 1 unoccluded\nLine 2 content\nLine 3 content"),
                fileName: sample.name,
                fileURL: sample.url,
                isImmersiveFullscreen: false,
                showsFloatingFullScreenButton: true,
                isEditable: true,
                resourceContext: .diskFile(url: sample.url, fileName: sample.name, allowsEditing: true)
            )
            let modeWin = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            modeWin.isReleasedWhenClosed = false
            modeWin.appearance = NSAppearance(named: mode == .white ? .aqua : .darkAqua)
            let modeHost = NSHostingView(rootView: modePreview.frame(width: 280, height: 360))
            modeHost.sizingOptions = []
            modeWin.contentView = modeHost
            defer { modeWin.contentView = nil; modeWin.close() }
            modeWin.setContentSize(NSSize(width: 280, height: 360))
            modeHost.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
            await settleOffscreenHost(modeHost, cycles: 4, delayNanoseconds: 10_000_000)
            try await assertCornerButtonHiddenThenRevealedBySensorHover(
                in: modeHost,
                window: modeWin,
                logicalSize: NSSize(width: 280, height: 360),
                bgPoint: NSPoint(x: 140, y: 334),
                region: NSRect(x: 240, y: 320, width: 28, height: 28),
                label: "Inspector expand button (\(mode.rawValue))"
            )
        }
    }

    internal func countContrastingPixels(
        in bitmap: NSBitmapImageRep,
        logicalSize: NSSize,
        bgPoint: NSPoint,
        region: NSRect
    ) -> Int {
        let scaleX = Double(bitmap.pixelsWide) / Double(logicalSize.width)
        let scaleY = Double(bitmap.pixelsHigh) / Double(logicalSize.height)
        guard let bgSample = bitmap.colorAt(
            x: Int(Double(bgPoint.x) * scaleX),
            y: Int(Double(bgPoint.y) * scaleY)
        )?.usingColorSpace(.sRGB) else { return 0 }
        var diffPixels = 0
        for py in Int(Double(region.minY) * scaleY)..<Int(Double(region.maxY) * scaleY) {
            for px in Int(Double(region.minX) * scaleX)..<Int(Double(region.maxX) * scaleX) {
                guard let c = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                let delta = abs(c.redComponent - bgSample.redComponent)
                    + abs(c.greenComponent - bgSample.greenComponent)
                    + abs(c.blueComponent - bgSample.blueComponent)
                if delta > 0.12 { diffPixels += 1 }
            }
        }
        return diffPixels
    }

    func testStandaloneWindowContentRemovesDuplicateHeaderAndRoutesReturnAndUnconsumedEscape() async throws {
        let sample = try file("sample-immersive.txt")
        let origin = UUID()
        let opened = await manager.open(item: sample, originWindowID: origin, createAppKitWindow: false, cacheManager: cache)
        XCTAssertTrue(opened)

        var didReturn = false
        var didClose = false
        let controls = MediaControlsVisibility()
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = StandalonePreviewWindowContent.makeHostingView(
            item: sample,
            controls: controls,
            onReturn: { didReturn = true },
            onClose: { didClose = true }
        )
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.setContentSize(NSSize(width: 720, height: 480))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()

        let textLabels = findStaticTextValues(in: host)
        XCTAssertFalse(textLabels.contains("关闭窗口"))
        XCTAssertFalse(textLabels.contains("Close Window"))
        XCTAssertFalse(textLabels.contains(AppLocalizationState.shared.t(PlaybackWindowLocaleKey.returnToOriginPreview)),
                       "Standalone immersive window must use an icon-only return button rather than a text header bar")

        try await assertCornerButtonHiddenThenRevealedBySensorHover(
            in: host,
            window: window,
            logicalSize: NSSize(width: 720, height: 480),
            bgPoint: NSPoint(x: 360, y: 454),
            region: NSRect(x: 680, y: 440, width: 28, height: 28),
            label: "Standalone return button"
        )

        XCTAssertTrue(StandalonePreviewWindowContent.shouldInterceptEscapeReturn(
            keyCode: 53, modifiers: [], eventWindowNumber: 42, hostWindowNumber: 42,
            hasAttachedSheet: false, hasActiveMenu: false, hasActivePopoverOrPanel: false, isAppKitTextInputActive: false
        ))
        XCTAssertFalse(StandalonePreviewWindowContent.shouldInterceptEscapeReturn(
            keyCode: 53, modifiers: [], eventWindowNumber: 0, hostWindowNumber: 42, isHostKeyWindow: false
        ), "Unowned 0-window Escape event must never close a non-key standalone preview window")
        XCTAssertFalse(StandalonePreviewWindowContent.shouldInterceptEscapeReturn(
            keyCode: 53, modifiers: [], eventWindowNumber: nil, hostWindowNumber: 42, isHostKeyWindow: false
        ), "Nil-window Escape event must never close a non-key standalone preview window")
        XCTAssertTrue(StandalonePreviewWindowContent.shouldInterceptEscapeReturn(
            keyCode: 53, modifiers: [], eventWindowNumber: 0, hostWindowNumber: 42, isHostKeyWindow: true
        ), "0-window Escape event is allowed only when host window is proven to be the active keyWindow")
        XCTAssertFalse(StandalonePreviewWindowContent.shouldInterceptEscapeReturn(
            keyCode: 53, modifiers: [.command], eventWindowNumber: 42, hostWindowNumber: 42
        ))
        XCTAssertFalse(StandalonePreviewWindowContent.shouldInterceptEscapeReturn(
            keyCode: 53, modifiers: [], eventWindowNumber: 99, hostWindowNumber: 42
        ))
        XCTAssertFalse(StandalonePreviewWindowContent.shouldInterceptEscapeReturn(
            keyCode: 53, modifiers: [], eventWindowNumber: 42, hostWindowNumber: 42, isAppKitTextInputActive: true
        ))
        XCTAssertFalse(StandalonePreviewWindowContent.shouldInterceptEscapeReturn(
            keyCode: 123, modifiers: [], eventWindowNumber: 42, hostWindowNumber: 42
        ), "Pagination/navigation arrow keys must never be swallowed by Escape return routing")

        try await assertLiveStandaloneAaPopoverAndEscapeChain(
            window: window, host: host, controls: controls, didReturn: { didReturn }
        )

        await manager.performReturnToOrigin(item: sample, originWindowID: origin)
        XCTAssertFalse(manager.isPresenting(item: sample, originWindowID: origin))
        XCTAssertEqual(manager.activeWindowCount, 0)
        _ = (didReturn, didClose)
    }

    private func assertLiveStandaloneAaPopoverAndEscapeChain(
        window: NSWindow,
        host: NSView,
        controls: MediaControlsVisibility,
        didReturn: () -> Bool
    ) async throws {
        controls.recordMouseMove(at: CGPoint(x: 360, y: 240))
        var resolvedAa: NSButton?
        for _ in 0..<40 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            if let btn = findButton(id: "CodeFloatingAaToolsButton", in: host) {
                resolvedAa = btn
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let aaButton = try XCTUnwrap(
            resolvedAa,
            "Pointer reveal must mount CodeFloatingAaToolsButton in standalone preview"
        )
        XCTAssertFalse(aaButton.isTransparent, "Aa button must be a visible control, never a transparent test bridge")
        try dragOutCancelVisibleButtonViaHitTest(aaButton, in: host, window: window)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        XCTAssertFalse(controls.hasActiveInteractionLock, "Dragging out of Aa before mouseUp must cancel and not open popover")
        XCTAssertNil(findButton(id: "CodeFloatingFontIncreaseButton", in: host))

        try clickVisibleButtonViaHitTest(aaButton, in: host, window: window)
        for _ in 0..<8 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        XCTAssertTrue(controls.hasActiveInteractionLock)
        XCTAssertNotNil(
            findButton(id: "CodeFloatingFontIncreaseButton", in: host),
            "Clicking real Aa button in standalone preview must open the reading tools popover"
        )

        // Unowned (`windowNumber == 0`) or other-window Escape must be rejected and leave both popover & window open.
        sendLocalEscapeKey(windowNumber: 0)
        sendLocalEscapeKey(windowNumber: window.windowNumber + 9_999)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        XCTAssertTrue(controls.hasActiveInteractionLock, "Unowned 0-window or foreign-window Escape must not dismiss popover")
        XCTAssertNotNil(findButton(id: "CodeFloatingFontIncreaseButton", in: host))
        XCTAssertFalse(didReturn(), "Unowned 0-window or foreign-window Escape must not trigger return")

        let editableField = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 20))
        editableField.isEditable = true
        host.addSubview(editableField)
        _ = window.makeFirstResponder(editableField)
        sendLocalEscapeKey(windowNumber: window.windowNumber)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        XCTAssertNotNil(
            findButton(id: "CodeFloatingFontIncreaseButton", in: host),
            "Active editable text input must take priority over popover Escape dismissal"
        )
        XCTAssertFalse(didReturn())
        editableField.removeFromSuperview()
        _ = window.makeFirstResponder(nil)

        sendLocalEscapeKey(windowNumber: window.windowNumber)
        for _ in 0..<8 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        XCTAssertNil(
            findButton(id: "CodeFloatingFontIncreaseButton", in: host),
            "First unconsumed Esc must close the open Aa popover"
        )
        XCTAssertFalse(didReturn(), "First Esc while Aa popover was open must not trigger standalone window return")

        // Unowned (`windowNumber == 0`) Escape when popover is closed must still NOT trigger standalone return on a non-key window.
        sendLocalEscapeKey(windowNumber: 0)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        XCTAssertFalse(didReturn(), "Unowned 0-window Escape must not trigger return on a non-key standalone preview window")

        sendLocalEscapeKey(windowNumber: window.windowNumber)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        XCTAssertTrue(didReturn(), "Second unconsumed Esc bound to this window must return to origin preview")
    }
}
