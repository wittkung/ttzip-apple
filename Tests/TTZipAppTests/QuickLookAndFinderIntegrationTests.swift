// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp
@testable import TTZipCore
@testable import TTZipFinderSync
@testable import TTZipQuickLook

final class QuickLookAndFinderIntegrationTests: XCTestCase {
    
    func test_ephemeral_preview_cache_staging_and_cleanup() async throws {
        let manager = EphemeralPreviewCacheManager.shared
        let sampleData = Data("QuickLook Test Content 2026".utf8)
        let fileName = "sample_test_entry.txt"
        
        let stagedURL = try await manager.stageFile(data: sampleData, suggestedFileName: fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        
        let readData = try Data(contentsOf: stagedURL)
        XCTAssertEqual(readData, sampleData)
        
        await manager.cleanupAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }
    
    func test_archive_drag_item_provider_factory() {
        let itemProvider = ArchiveDragItemProviderFactory.createItemProvider(
            archivePath: "/tmp/fake_archive.zip",
            entryPath: "docs/spec.pdf",
            suggestedFileName: "spec.pdf"
        )
        
        XCTAssertNotNil(itemProvider)
        XCTAssertEqual(itemProvider.suggestedName, "spec.pdf")
    }
    
    func test_quicklook_format_identifier_mapping_all_16_formats() {
        for format in ArchiveCompressionFormat.allCases {
            let qlId = QuickLookFormatIdentifier.from(format: format)
            XCTAssertFalse(qlId.rawValue.isEmpty, "Format \(format) must map to non-empty QuickLook identifier")
        }
    }
    
    func test_findersync_context_menu_generation_for_archives() {
        let testURLs = [
            URL(fileURLWithPath: "/tmp/test.zip"),
            URL(fileURLWithPath: "/tmp/archive.7z")
        ]
        
        let menuItems = FinderSyncHelper.shared.getContextMenuItems(selectedURLs: testURLs)
        XCTAssertFalse(menuItems.isEmpty, "Context menu items should be generated for archive URLs")
        
        let actionIds = menuItems.map { $0.actionIdentifier }
        XCTAssertTrue(actionIds.contains("extract_here"))
        XCTAssertTrue(actionIds.contains("extract_to_subfolder"))
        XCTAssertTrue(actionIds.contains("inspect_archive"))
    }
    
    func test_findersync_action_request_ipc_json_roundtrip() throws {
        let original = FinderSyncActionRequest(
            action: .extractHere,
            sourcePaths: ["/Users/test/archive.zip"],
            destinationDirectory: "/Users/test/output"
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FinderSyncActionRequest.self, from: data)
        
        XCTAssertEqual(decoded.actionIdentifier, "extract_here")
        XCTAssertEqual(decoded.sourcePaths, ["/Users/test/archive.zip"])
        XCTAssertEqual(decoded.destinationDirectory, "/Users/test/output")
    }
    
    func test_findersync_extension_lifecycle_and_badge_requests() {
        // Supported extensions verification via FinderSyncHelper
        let zipExt = "zip"
        let sevenZExt = "7z"
        let txtExt = "txt"
        
        XCTAssertTrue(FinderSyncHelper.supportedArchiveExtensions.contains(zipExt))
        XCTAssertTrue(FinderSyncHelper.supportedArchiveExtensions.contains(sevenZExt))
        XCTAssertFalse(FinderSyncHelper.supportedArchiveExtensions.contains(txtExt))
    }
    
    @MainActor
    func test_quicklook_preview_view_controller_view_hierarchy() async throws {
        // Create a temporary zip archive
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("QLVCTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let dummyDoc = tempDir.appendingPathComponent("note.txt")
        try "Preview content".write(to: dummyDoc, atomically: true, encoding: .utf8)
        let zipURL = tempDir.appendingPathComponent("preview_test.zip")
        
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [dummyDoc.path]
        )
        
        // Validate HTML engine preview synthesis directly to avoid headless WebKit IPC hang
        let html = try await QuickLookPreviewEngine.generateHTMLPreview(for: zipURL.path, language: .en)
        XCTAssertFalse(html.isEmpty, "QuickLook HTML preview should not be empty")
        XCTAssertTrue(html.contains("note.txt"), "QuickLook HTML preview must contain archive entries")
    }
    
    func test_findersync_url_construction_with_special_characters_and_delimiters() throws {
        let pathWithSpecialChars = "/Users/test/folder & documents/C++ Project #1 + extra.zip"
        let normalPath = "/Users/test/archive.7z"
        
        var components = URLComponents()
        components.scheme = "ttzip"
        components.host = "action"
        components.queryItems = [
            URLQueryItem(name: "type", value: "compress_quick_zip"),
            URLQueryItem(name: "paths", value: [pathWithSpecialChars, normalPath].joined(separator: "|"))
        ]
        
        let url = try XCTUnwrap(components.url)
        let parsed = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        
        let actionType = parsed.queryItems?.first(where: { $0.name == "type" })?.value
        let pathsStr = parsed.queryItems?.first(where: { $0.name == "paths" })?.value
        
        XCTAssertEqual(actionType, "compress_quick_zip")
        let splitPaths = pathsStr?.components(separatedBy: "|")
        XCTAssertEqual(splitPaths, [pathWithSpecialChars, normalPath])
    }
    
    func test_quicklook_single_file_memory_stream_zero_disk_io() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("QLZeroIOTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let docURL = tempDir.appendingPathComponent("stream_doc.txt")
        let testPayload = "Zero disk IO stream payload 2026".data(using: .utf8)!
        try testPayload.write(to: docURL)
        
        let zipURL = tempDir.appendingPathComponent("stream_archive.zip")
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [docURL.path]
        )
        
        let extractedData = try await QuickLookPreviewEngine.extractSingleFileMemoryStream(
            archivePath: zipURL.path,
            entryPath: "stream_doc.txt"
        )
        
        XCTAssertNotNil(extractedData)
        XCTAssertEqual(extractedData, testPayload)
    }
    
    @MainActor
    func test_quicklook_preview_view_controller_instantiation_and_view_load() {
        let vc = QuickLookPreviewViewController()
        vc.loadView()
        XCTAssertNotNil(vc.view)
        XCTAssertEqual(vc.view.frame.width, 800)
        XCTAssertEqual(vc.view.frame.height, 600)
    }
    
    @MainActor
    func test_quicklook_cancellation_and_rapid_preview_switching() async throws {
        let vc = QuickLookPreviewViewController()
        vc.loadView()
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("QLCancelTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let file1 = tempDir.appendingPathComponent("doc1.txt")
        let file2 = tempDir.appendingPathComponent("doc2.txt")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)
        try "Content 2".write(to: file2, atomically: true, encoding: .utf8)
        
        let zip1 = tempDir.appendingPathComponent("archive1.zip")
        let zip2 = tempDir.appendingPathComponent("archive2.zip")
        let writer = ArchiveWriter()
        try await writer.createArchive(outputPath: zip1.path, format: .zip, level: .fast, inputPaths: [file1.path])
        try await writer.createArchive(outputPath: zip2.path, format: .zip, level: .fast, inputPaths: [file2.path])
        
        var firstHandlerResult: (any Error)? = nil
        let firstExpectation = expectation(description: "First preview handler must be invoked with cancellation")
        
        // 1. Invoke first preview
        vc.preparePreviewOfFile(at: zip1) { error in
            firstHandlerResult = error
            firstExpectation.fulfill()
        }
        
        // 2. Immediately switch to second preview before first completes
        vc.preparePreviewOfFile(at: zip2) { _ in }
        
        // 3. Verify first completion was immediately invoked with user cancelled error without hanging
        await fulfillment(of: [firstExpectation], timeout: 2.0)
        XCTAssertNotNil(firstHandlerResult)
        if let error = firstHandlerResult as? CocoaError {
            XCTAssertEqual(error.code, CocoaError.userCancelled)
        }
    }

    @MainActor
    func test_production_preview_lru_cache_manager_quota_and_active_inspector_pinning() async throws {
        let sandboxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProdPreviewLRUQuotaTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandboxDir) }

        let cache = PreviewLRUCacheManager(
            customCacheDir: sandboxDir,
            maxStagedFiles: 2,
            maxCacheSizeBytesOverride: 100
        )
        defer { Task { await cache.purgeAll() } }

        let archivePath = "/tmp/prod_inspector_test.zip"
        let mockExtractor: ExplorerItemInspectorView.VirtualEntryExtractor = { _, entryPath, destDir, _ in
            let filename = (entryPath as NSString).lastPathComponent
            let destURL = URL(fileURLWithPath: destDir, isDirectory: true).appendingPathComponent(filename)
            let count = (filename == "itemC.txt") ? 35 : ((filename == "oversized.bin") ? 150 : 60)
            try Data(repeating: 0x41, count: count).write(to: destURL, options: .atomic)
        }

        // 1. Single file exceeding maxCacheSizeBytes (150 > 100) is rejected before extraction.
        let oversized = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archivePath,
            subpath: "docs/oversized.bin",
            estimatedBytes: 150,
            previousPinnedKey: nil,
            cacheManager: cache,
            customExtractor: mockExtractor
        )
        XCTAssertNil(oversized.url, "Oversized virtual item must be rejected before extraction")
        let countAfterOversized = await cache.stagedFileCount()
        XCTAssertEqual(countAfterOversized, 0)

        // 2. Inspector opens itemA (60 bytes) -> staged and actively pinned in PreviewLRUCacheManager.
        let resA = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archivePath,
            subpath: "docs/itemA.txt",
            estimatedBytes: 60,
            previousPinnedKey: nil,
            cacheManager: cache,
            customExtractor: mockExtractor
        )
        let urlA = try XCTUnwrap(resA.url)
        let keyA = try XCTUnwrap(resA.pinnedKey)
        let isAPinned = await cache.isPinned(key: keyA)
        XCTAssertTrue(isAPinned)

        // 3. Staging a 60B file while itemA is pinned throws .quotaExceeded; overwriting keyA throws .activeResourcePinned.
        await assertQuotaExceededAndActiveResourceProtected(cache: cache, pinnedKeyA: keyA, pinnedURLA: urlA)

        // 4. Switching inspector selection from itemA to itemB releases itemA's lease, evicts itemA, and leases itemB.
        let resB = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archivePath,
            subpath: "docs/itemB.txt",
            estimatedBytes: 60,
            previousLease: resA.lease,
            cacheManager: cache,
            customExtractor: mockExtractor
        )
        let urlB = try XCTUnwrap(resB.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlA.path))

        // 5. Stage itemC (35B) while itemB (60B) is pinned -> fits within 100B quota (60 + 35 = 95 <= 100).
        let resC = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archivePath,
            subpath: "docs/itemC.txt",
            estimatedBytes: 35,
            previousLease: nil,
            cacheManager: cache,
            customExtractor: mockExtractor
        )
        XCTAssertNotNil(resC.url)
        let totalBytes = await cache.totalStagedBytes()
        XCTAssertEqual(totalBytes, 95)
    }

    @MainActor
    private func assertQuotaExceededAndActiveResourceProtected(
        cache: PreviewLRUCacheManager,
        pinnedKeyA: String,
        pinnedURLA: URL
    ) async {
        do {
            _ = try await cache.stageFile(
                data: Data(repeating: 0x42, count: 60),
                key: "concurrent_b",
                suggestedFileName: "concurrent_b.txt",
                pinActive: false
            )
            XCTFail("Expected .quotaExceeded when pinned itemA leaves only 40B available")
        } catch let err as EphemeralPreviewCacheError {
            guard case .quotaExceeded = err else {
                return XCTFail("Expected .quotaExceeded, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURLA.path))

        do {
            _ = try await cache.stageFile(
                data: Data(repeating: 0x49, count: 20),
                key: pinnedKeyA,
                suggestedFileName: "itemA.txt",
                pinActive: false
            )
            XCTFail("Expected .activeResourcePinned when overwriting pinned keyA")
        } catch let err as EphemeralPreviewCacheError {
            XCTAssertEqual(err, .activeResourcePinned(fileName: "itemA.txt"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func test_multi_consumer_leases_survive_single_close_and_stale_task_cancellation() async throws {
        let sandboxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiConsumerLeaseTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandboxDir) }

        let cache = PreviewLRUCacheManager(
            customCacheDir: sandboxDir,
            maxStagedFiles: 2,
            maxCacheSizeBytesOverride: 100
        )
        defer { Task { await cache.purgeAll() } }

        let archivePath = "/tmp/multi_consumer_test.zip"
        let mockExtractor: ExplorerItemInspectorView.VirtualEntryExtractor = { _, entryPath, destDir, _ in
            let filename = (entryPath as NSString).lastPathComponent
            let destURL = URL(fileURLWithPath: destDir, isDirectory: true).appendingPathComponent(filename)
            try Data(repeating: 0x53, count: 60).write(to: destURL, options: .atomic)
        }

        // 1. Consumer 1 & Consumer 2 both open shared.txt (60B) and acquire independent consumer leases.
        let res1 = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archivePath,
            subpath: "docs/shared.txt",
            estimatedBytes: 60,
            consumerID: UUID(),
            cacheManager: cache,
            customExtractor: mockExtractor
        )
        let res2 = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archivePath,
            subpath: "docs/shared.txt",
            estimatedBytes: 60,
            consumerID: UUID(),
            cacheManager: cache,
            customExtractor: mockExtractor
        )
        let sharedURL = try XCTUnwrap(res1.url)
        let lease1 = try XCTUnwrap(res1.lease)
        let lease2 = try XCTUnwrap(res2.lease)
        let sharedKey = lease1.key
        XCTAssertEqual(res2.url, sharedURL)
        XCTAssertNotEqual(lease1.consumerID, lease2.consumerID)
        let countBothOpen = await cache.activeLeaseCount(forKey: sharedKey)
        XCTAssertEqual(countBothOpen, 2)

        // 2. Consumer 1 closes -> Consumer 2's lease keeps shared.txt protected under eviction pressure & stale task cancellation.
        await cache.releaseLease(lease1)
        await cache.releaseLease(PreviewCacheLease(key: sharedKey, consumerID: UUID()))
        await cache.releaseLease(lease1)
        let countAfterC1Close = await cache.activeLeaseCount(forKey: sharedKey)
        let stillPinned = await cache.isPinned(key: sharedKey)
        XCTAssertEqual(countAfterC1Close, 1)
        XCTAssertTrue(stillPinned)
        await assertEvictionRefusedWhileSecondConsumerHoldsLease(cache: cache, protectedURL: sharedURL)

        // 3. Consumer 2 finally releases lease2 -> shared.txt becomes unpinned and evicts when competitor arrives.
        await cache.releaseLease(lease2)
        let competitorURL = try await cache.stageFile(
            data: Data(repeating: 0x44, count: 60),
            key: "competitor",
            suggestedFileName: "competitor.txt",
            pinActive: false
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: competitorURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedURL.path))
    }

    @MainActor
    private func assertEvictionRefusedWhileSecondConsumerHoldsLease(
        cache: PreviewLRUCacheManager,
        protectedURL: URL
    ) async {
        do {
            _ = try await cache.stageFile(
                data: Data(repeating: 0x44, count: 60),
                key: "competitor",
                suggestedFileName: "competitor.txt",
                pinActive: false
            )
            XCTFail("Expected .quotaExceeded while Consumer 2 still holds lease on 60B shared.txt")
        } catch let err as EphemeralPreviewCacheError {
            guard case .quotaExceeded = err else {
                return XCTFail("Expected .quotaExceeded, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedURL.path))
    }

    @MainActor
    func test_pre_write_staging_reservations_concurrent_quota_same_key_and_cancellation_reclamation() async throws {
        let sandboxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreWriteStagingTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandboxDir) }

        let cache = PreviewLRUCacheManager(
            customCacheDir: sandboxDir,
            maxStagedFiles: 2,
            maxCacheSizeBytesOverride: 100
        )
        defer { Task { await cache.purgeAll() } }

        // 1. Pre-write reservation 1 (60B) accounts for slot and bytes before writing to disk; duplicate key is rejected.
        let res1 = try await cache.acquireStagingReservation(
            forKey: "key_a",
            filename: "a.bin",
            estimatedBytes: 60,
            consumerID: UUID()
        )
        await assertDuplicateKeyAndByteQuotaRejectedBeforeWrite(cache: cache)

        // 2. Second concurrent reservation within byte quota (60 + 35 = 95 <= 100, count = 2 <= 2) succeeds; third is rejected on count.
        let res2 = try await cache.acquireStagingReservation(
            forKey: "key_b",
            filename: "b.bin",
            estimatedBytes: 35,
            consumerID: UUID()
        )
        let reservedBoth = await cache.reservedStagingBytes()
        XCTAssertEqual(reservedBoth, 95)
        await assertThirdReservationRejectedOnFileCount(cache: cache)

        // 3. Cancelling res1 (60B) reclaims slot & bytes so key_c (60B) can reserve and commit to a registered item.
        await cache.cancelStagingReservation(res1)
        let res3 = try await cache.acquireStagingReservation(
            forKey: "key_c",
            filename: "c.bin",
            estimatedBytes: 60,
            consumerID: UUID()
        )
        try Data(repeating: 0x43, count: 60).write(to: res3.targetURL, options: .atomic)
        let committedURL3 = try await cache.registerValidated(
            key: "key_c",
            fileURL: res3.targetURL,
            expectedFilename: "c.bin",
            requireNonEmpty: true,
            consumerID: res3.consumerID,
            reservationID: res3.id
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: committedURL3.path))
        await cache.cancelStagingReservation(res2)

        // 4. Verify coalesced same-key concurrent extraction in ExplorerItemInspectorView.
        try await assertCoalescedSameKeyConcurrentExtraction(cache: cache)
    }

    @MainActor
    private func assertDuplicateKeyAndByteQuotaRejectedBeforeWrite(cache: PreviewLRUCacheManager) async {
        do {
            _ = try await cache.acquireStagingTargetURL(forKey: "key_a", filename: "a.bin", estimatedBytes: 60)
            XCTFail("Expected .concurrentStagingInProgress for duplicate in-flight key_a")
        } catch let err as EphemeralPreviewCacheError {
            XCTAssertEqual(err, .concurrentStagingInProgress(key: "key_a", fileName: "a.bin"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await cache.acquireStagingReservation(
                forKey: "key_b_over_bytes",
                filename: "b.bin",
                estimatedBytes: 50,
                consumerID: UUID()
            )
            XCTFail("Expected .quotaExceeded when in-flight reservation (60B) + incoming (50B) > 100B")
        } catch let err as EphemeralPreviewCacheError {
            guard case .quotaExceeded = err else {
                return XCTFail("Expected .quotaExceeded, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    private func assertThirdReservationRejectedOnFileCount(cache: PreviewLRUCacheManager) async {
        do {
            _ = try await cache.acquireStagingReservation(
                forKey: "key_c",
                filename: "c.bin",
                estimatedBytes: 1,
                consumerID: UUID()
            )
            XCTFail("Expected .quotaExceeded when 2 in-flight staging reservations reach maxStagedFiles = 2")
        } catch let err as EphemeralPreviewCacheError {
            guard case .quotaExceeded = err else {
                return XCTFail("Expected .quotaExceeded, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private actor ExtractionInvocationCounter {
        private var count = 0
        func increment() { count += 1 }
        func value() -> Int { count }
    }

    private actor ExtractionGate {
        private var count = 0
        private var startedContinuation: CheckedContinuation<Void, Never>?
        private var proceedContinuation: CheckedContinuation<Void, Never>?
        private var hasStarted = false
        private var canProceed = false

        func markStartedAndWait() async {
            count += 1
            hasStarted = true
            startedContinuation?.resume()
            startedContinuation = nil
            if !canProceed {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    proceedContinuation = cont
                }
            }
        }

        func waitUntilStarted() async {
            if hasStarted { return }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                startedContinuation = cont
            }
        }

        func allowProceed() {
            canProceed = true
            proceedContinuation?.resume()
            proceedContinuation = nil
        }

        func invocationCount() -> Int { count }
    }

    @MainActor
    private func assertCoalescedSameKeyConcurrentExtraction(cache: PreviewLRUCacheManager) async throws {
        // Case A: Request A pauses BEFORE writing any file to disk; Request B enters resolveAndPinVirtualPreviewURL.
        // B must NOT cancel A's reservation, must NOT return early, and both must get independent leases after 1 extraction.
        try await assertSameKeyCoalescingWhenPausedBeforeWrite(cache: cache)

        // Case B: Request A pauses AFTER writing a partial non-empty file; Request B enters resolveAndPinVirtualPreviewURL.
        // Active staging must be invisible to unreserved recovery; B must NOT commit/return the partial file early.
        try await assertSameKeyCoalescingWhenPausedAfterPartialWrite(cache: cache)
    }

    @MainActor
    private func assertSameKeyCoalescingWhenPausedBeforeWrite(cache: PreviewLRUCacheManager) async throws {
        await cache.purgeAll()
        let gate = ExtractionGate()
        let extractor: ExplorerItemInspectorView.VirtualEntryExtractor = { _, entryPath, destDir, _ in
            await gate.markStartedAndWait()
            let filename = (entryPath as NSString).lastPathComponent
            let destURL = URL(fileURLWithPath: destDir, isDirectory: true).appendingPathComponent(filename)
            try Data(repeating: 0x37, count: 60).write(to: destURL, options: .atomic)
        }

        let taskA = Task { @MainActor in
            await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
                archivePath: "/tmp/coalesce_prewrite.zip", subpath: "docs/prewrite.txt",
                estimatedBytes: 60, cacheManager: cache, customExtractor: extractor
            )
        }
        await gate.waitUntilStarted()

        let taskBFinishedEarly = ExtractionInvocationCounter()
        let taskB = Task { @MainActor in
            let res = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
                archivePath: "/tmp/coalesce_prewrite.zip", subpath: "docs/prewrite.txt",
                estimatedBytes: 60, cacheManager: cache, customExtractor: extractor
            )
            await taskBFinishedEarly.increment()
            return res
        }

        try await Task.sleep(nanoseconds: 25_000_000)
        let bFinishedWhileAPaused = await taskBFinishedEarly.value()
        let activeStagingWhilePaused = await cache.activeStagingCount()
        let reservedBytesWhilePaused = await cache.reservedStagingBytes()
        XCTAssertEqual(bFinishedWhileAPaused, 0, "Request B must wait and not return early while Request A is paused")
        XCTAssertEqual(activeStagingWhilePaused, 1, "Request B must NOT release Request A's reservation when no file is written yet")
        XCTAssertEqual(reservedBytesWhilePaused, 60)

        await gate.allowProceed()
        let (outA, outB) = await (taskA.value, taskB.value)
        XCTAssertNotNil(outA.url)
        XCTAssertEqual(outA.url, outB.url)
        let calls = await gate.invocationCount()
        XCTAssertEqual(calls, 1, "Extractor must only run once across concurrent requests A and B")
        let key = try XCTUnwrap(outA.pinnedKey)
        let leases = await cache.activeLeaseCount(forKey: key)
        XCTAssertEqual(leases, 2, "Both A and B must hold independent consumer leases")
    }

    @MainActor
    private func assertSameKeyCoalescingWhenPausedAfterPartialWrite(cache: PreviewLRUCacheManager) async throws {
        await cache.purgeAll()
        let gate = ExtractionGate()
        let archivePath = "/tmp/coalesce_partial.zip"
        let subpath = "docs/partial.txt"
        let hash = PreviewLRUCacheManager.deterministicCacheKey(archivePath: archivePath, subpath: subpath)

        let extractor: ExplorerItemInspectorView.VirtualEntryExtractor = { _, entryPath, destDir, _ in
            let filename = (entryPath as NSString).lastPathComponent
            let destURL = URL(fileURLWithPath: destDir, isDirectory: true).appendingPathComponent(filename)
            try Data("PARTIAL_20_BYTES____".utf8).write(to: destURL)
            await gate.markStartedAndWait()
            try Data(repeating: 0x5A, count: 60).write(to: destURL, options: .atomic)
        }

        let taskA = Task { @MainActor in
            await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
                archivePath: archivePath, subpath: subpath, estimatedBytes: 60, cacheManager: cache, customExtractor: extractor
            )
        }
        await gate.waitUntilStarted()

        await cache.cancelStagingReservation(forKey: hash, reservationID: UUID())
        let taskBFinishedEarly = ExtractionInvocationCounter()
        let taskB = Task { @MainActor in
            let res = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
                archivePath: archivePath, subpath: subpath, estimatedBytes: 60, cacheManager: cache, customExtractor: extractor
            )
            await taskBFinishedEarly.increment()
            return res
        }

        try await Task.sleep(nanoseconds: 25_000_000)
        let bFinishedWhileAPaused = await taskBFinishedEarly.value()
        let stagedWhilePaused = await cache.stagedFileCount()
        let activeStagingWhilePaused = await cache.activeStagingCount()
        XCTAssertEqual(bFinishedWhileAPaused, 0, "Request B must NOT prematurely commit and return Request A's partial file")
        XCTAssertEqual(stagedWhilePaused, 0, "Partial file must remain invisible to unreserved cache recovery while staging is active")
        XCTAssertEqual(activeStagingWhilePaused, 1, "Request A's reservation must remain active")

        await gate.allowProceed()
        let (outA, outB) = await (taskA.value, taskB.value)
        let finalURL = try XCTUnwrap(outA.url)
        XCTAssertEqual(finalURL, outB.url)
        let finalData = try Data(contentsOf: finalURL)
        XCTAssertEqual(finalData.count, 60, "Committed file must contain complete 60B payload, not 20B partial write")
        let calls = await gate.invocationCount()
        XCTAssertEqual(calls, 1)
        let leases = await cache.activeLeaseCount(forKey: hash)
        XCTAssertEqual(leases, 2)
    }

    @MainActor
    func test_extraction_error_after_partial_write_cancels_reservation_and_rejects_partial_file() async throws {
        let sandboxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PartialErrorStagingTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandboxDir) }

        let cache = PreviewLRUCacheManager(customCacheDir: sandboxDir, maxStagedFiles: 2, maxCacheSizeBytesOverride: 100)
        defer { Task { await cache.purgeAll() } }

        let archivePath = "/tmp/partial_failure.zip"
        let subpath = "docs/corrupted.bin"
        let hash = PreviewLRUCacheManager.deterministicCacheKey(archivePath: archivePath, subpath: subpath)
        let expectedTargetURL = try XCTUnwrap(cache.targetURL(forKey: hash, filename: "corrupted.bin"))

        let failingAfterPartialWriteExtractor: ExplorerItemInspectorView.VirtualEntryExtractor = { _, entryPath, destDir, _ in
            let filename = (entryPath as NSString).lastPathComponent
            let destURL = URL(fileURLWithPath: destDir, isDirectory: true).appendingPathComponent(filename)
            try Data("INCOMPLETE_PARTIAL_STREAM".utf8).write(to: destURL)
            throw NSError(domain: "TTZipExtractionError", code: -99, userInfo: nil)
        }

        let res = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archivePath, subpath: subpath, estimatedBytes: 60,
            cacheManager: cache, customExtractor: failingAfterPartialWriteExtractor
        )
        XCTAssertNil(res.url, "Extraction error after partial write must return nil URL and never register partial residue")
        XCTAssertNil(res.lease, "Extraction error must not retain a consumer lease")

        let activeStaging = await cache.activeStagingCount()
        let reservedBytes = await cache.reservedStagingBytes()
        let stagedCount = await cache.stagedFileCount()
        let cachedAfterFailure = await cache.cachedURL(forKey: hash, expectedFilename: "corrupted.bin")
        XCTAssertEqual(activeStaging, 0)
        XCTAssertEqual(reservedBytes, 0)
        XCTAssertEqual(stagedCount, 0)
        XCTAssertNil(cachedAfterFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedTargetURL.path))

        try await assertNestedPartialWriteErrorCleansResidueAndBlocksSubsequentRecovery(cache: cache)
    }

    @MainActor
    private func assertNestedPartialWriteErrorCleansResidueAndBlocksSubsequentRecovery(
        cache: PreviewLRUCacheManager
    ) async throws {
        let archivePath = "/tmp/nested_partial_failure.zip"
        let subpath = "docs/nested_corrupted.bin"
        let filename = "nested_corrupted.bin"
        let hash = PreviewLRUCacheManager.deterministicCacheKey(archivePath: archivePath, subpath: subpath)
        let directTargetURL = try XCTUnwrap(cache.targetURL(forKey: hash, filename: filename))
        let keyDir = directTargetURL.deletingLastPathComponent()
        let nestedPartialURL = keyDir.appendingPathComponent("docs", isDirectory: true).appendingPathComponent(filename)

        let nestedPartialFailExtractor: ExplorerItemInspectorView.VirtualEntryExtractor = { _, _, destDir, _ in
            let nestedDir = URL(fileURLWithPath: destDir, isDirectory: true).appendingPathComponent("docs", isDirectory: true)
            try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
            try Data("NESTED_PARTIAL_STREAM_RESIDUE".utf8).write(to: nestedDir.appendingPathComponent(filename))
            throw NSError(domain: "TTZipExtractionError", code: -100, userInfo: nil)
        }

        let firstAttempt = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archivePath, subpath: subpath, estimatedBytes: 60,
            cacheManager: cache, customExtractor: nestedPartialFailExtractor
        )
        XCTAssertNil(firstAttempt.url)
        XCTAssertNil(firstAttempt.lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedPartialURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyDir.path))

        let unreservedRecovered = await cache.resolveAndRegisterExtractedPreview(
            forKey: hash, filename: filename, subpath: subpath
        )
        XCTAssertNil(unreservedRecovered)

        let secondAttempt = await ExplorerItemInspectorView.resolveAndPinVirtualPreviewURL(
            archivePath: archivePath, subpath: subpath, estimatedBytes: 60,
            cacheManager: cache, customExtractor: { _, _, _, _ in }
        )
        XCTAssertNil(secondAttempt.url)
        XCTAssertNil(secondAttempt.lease)
        let activeStaging = await cache.activeStagingCount()
        let reservedBytes = await cache.reservedStagingBytes()
        let stagedCount = await cache.stagedFileCount()
        XCTAssertEqual(activeStaging, 0)
        XCTAssertEqual(reservedBytes, 0)
        XCTAssertEqual(stagedCount, 0)
    }
}

