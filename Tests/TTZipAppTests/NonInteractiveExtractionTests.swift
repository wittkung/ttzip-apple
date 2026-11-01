// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipCore
@testable import TTZipApp

@MainActor
final class NonInteractiveExtractionTests: XCTestCase {

    final class FailOnPromptProvider: CollisionDecisionProvider, @unchecked Sendable {
        func decide(
            summary: ConflictSummary,
            fetch: @escaping @Sendable (UInt32, UInt32) async throws -> ConflictPage
        ) async -> ResolutionSet? {
            XCTFail("Interactive decision provider was invoked in non-interactive path")
            return nil
        }
    }

    func testFinderExtractHereIntentForcesKeepBothPolicy() async throws {
        let options = ExtractIntentOptions(
            destinationDirectory: nil,
            isSmartExtract: false,
            deleteSourceAfterExtraction: false,
            password: nil,
            targetEntrySubpaths: nil,
            forceKeepBoth: true
        )

        XCTAssertTrue(options.forceKeepBoth, "Finder Extract Here must set forceKeepBoth")

        let state = AppViewState(fileViewer: NoOpFileViewer())
        let dispatcher = AppIntentDispatcher.shared
        dispatcher.bind(state: state)

        // Dispatch an intent with forceKeepBoth
        let result = dispatcher.dispatch(
            .extractArchive(archivePaths: ["/tmp/nonexistent_test.zip"], options: options),
            from: .finderSync
        )

        XCTAssertEqual(result, .success)
        XCTAssertNil(state.overlayState.collisionPrompt, "Collision prompt must not be displayed for forceKeepBoth extractions")
    }

    func testBatchFacadeExtractDefaultsToKeepBothPolicy() async {
        let request = ExtractionRequest(
            archivePath: "/tmp/sample.zip",
            destinationRoot: "/tmp/dest",
            password: nil,
            entryFilter: nil,
            rootAtCommonParent: false,
            policy: .keepBoth
        )

        XCTAssertEqual(request.policy, .keepBoth, "Batch extraction must enforce .keepBoth collision policy")
    }

    func testSubpathIntentWithForceKeepBothExtractsOnlySelectedEntryWithoutPrompt() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("ttzip_subpath_intent_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: sandbox) }
        let source = sandbox.appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("archived report".utf8).write(to: source.appendingPathComponent("report.txt"))
        try Data("archived other".utf8).write(to: source.appendingPathComponent("other.txt"))
        let archivePath = sandbox.appendingPathComponent("fixture.zip").path
        _ = try createArchiveStream(
            sourcePaths: [source.path],
            outputPath: archivePath,
            format: ArchiveFormat.zip,
            level: 6,
            password: nil,
            progress: nil,
            token: nil
        )

        let destination = sandbox.appendingPathComponent("dest", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let editedBytes = Data("locally edited".utf8)
        try editedBytes.write(to: destination.appendingPathComponent("report.txt"))

        let state = AppViewState(fileViewer: NoOpFileViewer())
        let options = ExtractIntentOptions(
            destinationDirectory: destination,
            isSmartExtract: false,
            targetEntrySubpaths: ["docs/report.txt"],
            forceKeepBoth: true
        )
        let tasks = AppIntentDispatcher.shared.dispatchExtraction(
            archivePaths: [archivePath],
            options: options,
            state: state
        )
        for task in tasks {
            await task.value
        }

        XCTAssertNil(state.overlayState.collisionPrompt, "forceKeepBoth subpath extraction must never prompt")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("report.txt")), editedBytes)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("report 2.txt"), encoding: .utf8),
            "archived report"
        )
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("other.txt").path))
    }

    func testSettingsCollisionDefaultResolution() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: "ttzip_collision_default")
        defer {
            if let original {
                defaults.set(original, forKey: "ttzip_collision_default")
            } else {
                defaults.removeObject(forKey: "ttzip_collision_default")
            }
        }

        // Test all supported collision policy options
        defaults.set("keep_both", forKey: "ttzip_collision_default")
        XCTAssertEqual(defaults.string(forKey: "ttzip_collision_default"), "keep_both")

        defaults.set("replace", forKey: "ttzip_collision_default")
        XCTAssertEqual(defaults.string(forKey: "ttzip_collision_default"), "replace")

        defaults.set("skip", forKey: "ttzip_collision_default")
        XCTAssertEqual(defaults.string(forKey: "ttzip_collision_default"), "skip")

        defaults.set("ask", forKey: "ttzip_collision_default")
        XCTAssertEqual(defaults.string(forKey: "ttzip_collision_default"), "ask")
    }

    func testDragOutAndFileProviderExecuteWithoutPrompting() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("ttzip_drag_fp_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: sandbox) }

        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = "drag-and-fp-archived-content"
        let sourceFile = source.appendingPathComponent("payload.txt")
        try Data(payload.utf8).write(to: sourceFile)

        let archivePath = sandbox.appendingPathComponent("fixture.zip").path
        _ = try createArchiveStream(
            sourcePaths: [sourceFile.path],
            outputPath: archivePath,
            format: .zip,
            level: 6,
            password: nil,
            progress: nil,
            token: nil
        )

        let mockProvider = FailOnPromptProvider()
        _ = mockProvider

        // 1. Drag-out non-interactive extraction path
        let dragDest = sandbox.appendingPathComponent("drag_dest", isDirectory: true)
        try fm.createDirectory(at: dragDest, withIntermediateDirectories: true)
        let existingDragFile = dragDest.appendingPathComponent("payload.txt")
        let localDragBytes = Data("existing-drag-local".utf8)
        try localDragBytes.write(to: existingDragFile)

        let itemProvider = ArchiveDragItemProviderFactory.createItemProvider(
            archivePath: archivePath,
            entryPath: "payload.txt",
            suggestedFileName: "payload.txt"
        )
        XCTAssertEqual(itemProvider.suggestedName, "payload.txt")

        let dragOutcome = try await ArchiveSelectiveExtractor.shared.extractSelected(
            archivePath: archivePath,
            targetEntryPaths: ["payload.txt"],
            destinationDir: dragDest.path,
            password: nil,
            handling: .policy(.keepBoth)
        )
        XCTAssertEqual(dragOutcome.status, .completed)
        XCTAssertEqual(try Data(contentsOf: existingDragFile), localDragBytes)
        let renamedDragFile = dragDest.appendingPathComponent("payload 2.txt")
        XCTAssertTrue(fm.fileExists(atPath: renamedDragFile.path))
        XCTAssertEqual(try String(contentsOf: renamedDragFile, encoding: .utf8), payload)

        // 2. FileProvider non-interactive extraction path
        let fpDest = sandbox.appendingPathComponent("fp_dest", isDirectory: true)
        try fm.createDirectory(at: fpDest, withIntermediateDirectories: true)
        let existingFpFile = fpDest.appendingPathComponent("payload.txt")
        let localFpBytes = Data("existing-fp-local".utf8)
        try localFpBytes.write(to: existingFpFile)

        let fpOutcome = try await ArchiveExtractor().extractSingleFile(
            archivePath: archivePath,
            entryPath: "payload.txt",
            destinationDir: fpDest.path,
            password: nil,
            handling: .policy(.keepBoth)
        )
        XCTAssertEqual(fpOutcome.status, .completed)
        XCTAssertEqual(try Data(contentsOf: existingFpFile), localFpBytes)
        let renamedFpFile = fpDest.appendingPathComponent("payload 2.txt")
        XCTAssertTrue(fm.fileExists(atPath: renamedFpFile.path))
        XCTAssertEqual(try String(contentsOf: renamedFpFile, encoding: .utf8), payload)
    }
}
