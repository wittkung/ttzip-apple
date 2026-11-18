// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
@testable import TTZipSearchKit
@testable import TTZipApp

final class AutoSemanticIndexingBridgeTests: XCTestCase {

    @MainActor
    func testNonSharedLocalModelManagerInitDoesNotMutateGlobalAutoIndexingProvider() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-nonshared-lmm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let accessManager = RootFolderAccessManager.shared
        let savedProvider = accessManager.autoSemanticIndexingEngineProvider
        defer { accessManager.autoSemanticIndexingEngineProvider = savedProvider }

        let sentinelEngine = makeTestSemanticSearchEngine(
            bridge: UniFFIRustSemanticCoreBridge(
                storageDirectory: tmpDir,
                uniffiEngine: S2LifecycleUniFFIDouble()
            )
        )
        accessManager.autoSemanticIndexingEngineProvider = { sentinelEngine }

        let customEngine = makeTestSemanticSearchEngine(
            bridge: UniFFIRustSemanticCoreBridge(
                storageDirectory: tmpDir,
                uniffiEngine: S2LifecycleUniFFIDouble()
            )
        )
        let resolver = LocalModelPathResolver(semanticStorageDirectory: tmpDir)
        let suiteName = "ttzip.test.lmm.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = LocalModelManager(pathResolver: resolver, engine: customEngine, userDefaults: defaults)
        let activeEngine = try XCTUnwrap(accessManager.autoSemanticIndexingEngineProvider?())
        XCTAssertTrue(ObjectIdentifier(activeEngine) == ObjectIdentifier(sentinelEngine))
    }

    @MainActor
    func testInstallAutoSemanticIndexingBridgeReplaysActiveBookmarksWithoutReentrancy() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-bridge-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let harness = SystemSecurityScopeTestHarness(autoIndexingEnabled: false)
        defer { harness.restore(revoking: [tmpDir], restoreSavedBookmarks: true) }

        XCTAssertNotNil(harness.persist(tmpDir))
        harness.accessManager.autoSemanticIndexingEngineProvider = nil
        harness.accessManager.isAutoSemanticIndexingEnabled = true

        let replayEngine = makeTestSemanticSearchEngine(
            bridge: UniFFIRustSemanticCoreBridge(
                storageDirectory: tmpDir,
                uniffiEngine: S2LifecycleUniFFIDouble()
            ),
            directoryLeaseProvider: { url in SecurityScopeLease(url: url, onRelease: { _ in }) }
        )

        LocalModelManager.installAutoSemanticIndexingBridgeIfNeeded(defaultEngine: replayEngine)
        for _ in 0..<50 {
            let summary = await replayEngine.indexedCoverageSummary()
            if summary.authorizedScopeCount >= 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let summary = await replayEngine.indexedCoverageSummary()
        XCTAssertEqual(summary.authorizedScopeCount, 1)
        XCTAssertTrue(
            ObjectIdentifier(LocalModelManager.shared.engine)
                == ObjectIdentifier(SemanticSearchComposition.shared)
        )
    }
}
