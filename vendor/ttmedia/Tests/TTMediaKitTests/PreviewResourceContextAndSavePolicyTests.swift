// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import CryptoKit
import SwiftUI
@testable import TTMediaKit

@MainActor
final class PreviewResourceContextAndSavePolicyTests: XCTestCase {

    // MARK: - 1. Disk vs Archive Origin & Save Target Resolution

    func testDiskFileContextGrantsInPlaceEditCapability() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTUserWorkspace_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let csvURL = tempDir.appendingPathComponent("budget.csv")
        try "item,amount\nbook,20\n".write(to: csvURL, atomically: true, encoding: .utf8)

        let context = TTPreviewResourceContext.diskFile(url: csvURL)
        XCTAssertFalse(context.isArchiveEntry)
        XCTAssertEqual(context.readableURL, csvURL.standardizedFileURL)
        XCTAssertEqual(context.originalDiskURL, csvURL.standardizedFileURL)
        XCTAssertEqual(context.originalResourceURL, csvURL.standardizedFileURL)
        XCTAssertTrue(context.isEditableInPlace)
        XCTAssertNil(context.readOnlyReason)
        XCTAssertEqual(context.writableSaveTargetURL, csvURL.standardizedFileURL)
        XCTAssertTrue(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: csvURL,
                fileName: "budget.csv",
                resourceContext: context
            )
        )
    }

    func testSpreadsheetSaveRejectsExplicitReadOnlyContextAndReadOnlyDiskFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpreadsheetPermissions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("locked.csv")
        let original = "name,value\nbook,20\n"
        try Data(original.utf8).write(to: url)
        let context = TTPreviewResourceContext.diskFile(url: url)
        XCTAssertTrue(SpreadsheetSavePolicy.canSaveInPlace(fileURL: url, resourceContext: context))

        let locked = context.forcingReadOnly()
        XCTAssertFalse(SpreadsheetSavePolicy.canSaveInPlace(fileURL: url, resourceContext: locked))
        XCTAssertFalse(try SpreadsheetSavePolicy.saveInPlace(
            content: "name,value\nbook,50\n", expectedBaseline: original, fileURL: url, resourceContext: locked
        ))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        XCTAssertFalse(SpreadsheetSavePolicy.canSaveInPlace(fileURL: url))
        XCTAssertFalse(try SpreadsheetSavePolicy.saveInPlace(
            content: "name,value\nbook,50\n", expectedBaseline: original, fileURL: url
        ))
        XCTAssertEqual(try Data(contentsOf: url), Data(original.utf8))
    }

    func testArchiveEntryContextRemainsStrictlyReadOnlyEvenWhenStagedFileIsWritableOnDisk() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTArchiveReadOnlyTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let stagingDir = tempRoot
            .appendingPathComponent("TTZipLRUPreviewCache/session_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let archiveURL = tempRoot.appendingPathComponent("bundle.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18)).write(to: archiveURL)

        let stagedCSV = stagingDir.appendingPathComponent("report.csv")
        let originalCSV = "col1,col2\n1,2\n"
        try originalCSV.write(to: stagedCSV, atomically: true, encoding: .utf8)

        // Even though the OS marks the staged file writable (0600), archive context must block editing.
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: stagedCSV.path))

        let context = TTPreviewResourceContext.archiveEntry(
            archiveURL: archiveURL,
            entryPath: "docs/report.csv",
            stagedReadURL: stagedCSV,
            fileName: "report.csv"
        )
        XCTAssertTrue(context.isArchiveEntry)
        XCTAssertEqual(context.archiveContainerURL, archiveURL.standardizedFileURL)
        XCTAssertEqual(context.archiveEntryPath, "docs/report.csv")
        XCTAssertEqual(context.readableURL, stagedCSV.standardizedFileURL)
        XCTAssertNil(context.originalDiskURL)
        XCTAssertFalse(context.isEditableInPlace)
        XCTAssertEqual(context.readOnlyReason, .archiveEntry)
        XCTAssertNil(context.writableSaveTargetURL)
        XCTAssertNil(context.validateInPlaceSaveTarget(expectedFileURL: stagedCSV))

        XCTAssertFalse(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: stagedCSV,
                fileName: "report.csv",
                resourceContext: context
            )
        )
        let saved = try SpreadsheetSavePolicy.saveInPlace(
            content: "tampered,data\n9,9\n",
            fileURL: stagedCSV,
            fileName: "report.csv",
            resourceContext: context
        )
        XCTAssertFalse(saved)
        XCTAssertEqual(try String(contentsOf: stagedCSV, encoding: .utf8), originalCSV)
    }

    // MARK: - 2. Non-Staged /tmp & /var/folders User Files vs Managed Staging Directories

    func testUserFilesInTmpAndVarFoldersAreNotBlanketClassifiedAsArchiveReadOnly() throws {
        // 1. User file inside FileManager.default.temporaryDirectory (/var/folders/...)
        let varFoldersDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NormalUserFolder_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: varFoldersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: varFoldersDir) }

        let varFoldersCSV = varFoldersDir.appendingPathComponent("user_notes.csv")
        try "a,b\n1,2\n".write(to: varFoldersCSV, atomically: true, encoding: .utf8)

        XCTAssertFalse(TTPreviewResourceContext.isManagedPreviewStagingURL(varFoldersCSV))
        let varContext = TTPreviewResourceContext.diskFile(url: varFoldersCSV)
        XCTAssertTrue(varContext.isEditableInPlace)
        XCTAssertTrue(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: varFoldersCSV,
                fileName: "user_notes.csv",
                resourceContext: varContext
            )
        )
        let didSaveVar = try SpreadsheetSavePolicy.saveInPlace(
            content: "a,b\n3,4\n",
            fileURL: varFoldersCSV,
            fileName: "user_notes.csv",
            resourceContext: varContext
        )
        XCTAssertTrue(didSaveVar)
        XCTAssertEqual(try String(contentsOf: varFoldersCSV, encoding: .utf8), "a,b\n3,4\n")

        // 2. User file directly under /tmp
        let tmpFile = URL(fileURLWithPath: "/tmp/ttmedia_user_file_\(UUID().uuidString).csv")
        try "k,v\nx,y\n".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        XCTAssertFalse(TTPreviewResourceContext.isManagedPreviewStagingURL(tmpFile))
        let tmpContext = TTPreviewResourceContext.diskFile(url: tmpFile)
        XCTAssertTrue(tmpContext.isEditableInPlace)
        XCTAssertNotNil(tmpContext.writableSaveTargetURL)
    }

    func testManagedPreviewStagingMarkersAreBlockedEvenIfPassedAsDiskFile() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTManagedMarkerTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let managedMarkers = [
            "TTZipLRUPreviewCache",
            "TTMediaEphemeralStorage",
            "TTZipPreviewCache",
            "TTZipArchiveMediaCache",
            "ttzip_previews_12345",
            "TTZip_QuickLook_abc",
            "TTZip_Extract_xyz"
        ]
        for marker in managedMarkers {
            let dir = tempRoot.appendingPathComponent("\(marker)/slot", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent("data.csv")
            try "h1,h2\n1,2\n".write(to: fileURL, atomically: true, encoding: .utf8)

            XCTAssertTrue(
                TTPreviewResourceContext.isManagedPreviewStagingURL(fileURL),
                "Expected marker \(marker) to be detected as managed staging URL"
            )
            let forgedDiskContext = TTPreviewResourceContext.diskFile(url: fileURL)
            XCTAssertFalse(forgedDiskContext.isEditableInPlace)
            XCTAssertEqual(forgedDiskContext.readOnlyReason, .managedStagingCachePath)
            XCTAssertNil(forgedDiskContext.writableSaveTargetURL)
            XCTAssertFalse(
                SpreadsheetSavePolicy.canSaveInPlace(
                    fileURL: fileURL,
                    fileName: "data.csv",
                    resourceContext: forgedDiskContext
                )
            )
        }
    }

    // MARK: - 3. Unknown Origin Fail-Closed & Truncated / Derived Read-Only Enforcement

    func testUnknownOriginAndDefaultPreviewContextNeverGrantOverwritePermission() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTUnknownOrigin_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("editable_on_disk.csv")
        let initial = "col1,col2\n10,20\n"
        try initial.write(to: fileURL, atomically: true, encoding: .utf8)

        let resolved = TTPreviewResourceContext.resolvingPreview(
            explicitContext: nil,
            type: .spreadsheetTable(initial, fileURL),
            fileName: "editable_on_disk.csv",
            fileURL: fileURL
        )
        XCTAssertEqual(resolved.origin, .unknown(readableURL: fileURL.standardizedFileURL))
        XCTAssertFalse(resolved.isEditableInPlace)
        XCTAssertEqual(resolved.readOnlyReason, .unknownOrigin)
        XCTAssertNil(resolved.writableSaveTargetURL)
        XCTAssertFalse(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: fileURL,
                fileName: "editable_on_disk.csv",
                resourceContext: resolved
            )
        )
        let saved = try SpreadsheetSavePolicy.saveInPlace(
            content: "mutated,0\n",
            fileURL: fileURL,
            fileName: "editable_on_disk.csv",
            resourceContext: resolved
        )
        XCTAssertFalse(saved)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), initial)
    }

    func testTruncatedAndDerivedContextsBlockSaveAtBothViewAndSaveEntryPoints() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTTruncatedDerived_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let csvURL = tempDir.appendingPathComponent("large.csv")
        let original = "id,val\n1,100\n"
        try original.write(to: csvURL, atomically: true, encoding: .utf8)

        let diskContext = TTPreviewResourceContext.diskFile(url: csvURL)
        let truncatedContext = diskContext.withTruncatedPreview(true)
        XCTAssertFalse(truncatedContext.isEditableInPlace)
        XCTAssertEqual(truncatedContext.readOnlyReason, .truncatedPreview)
        XCTAssertNil(truncatedContext.validateInPlaceSaveTarget(expectedFileURL: csvURL))
        XCTAssertFalse(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: csvURL,
                fileName: "large.csv",
                resourceContext: truncatedContext
            )
        )

        let derivedContext = diskContext.withDerivedRepresentation(true, description: "OfficeSpreadsheet")
        XCTAssertFalse(derivedContext.isEditableInPlace)
        XCTAssertEqual(derivedContext.readOnlyReason, .derivedContent)
        XCTAssertNil(derivedContext.validateInPlaceSaveTarget(expectedFileURL: csvURL))
        XCTAssertFalse(
            SpreadsheetSavePolicy.canSaveInPlace(
                fileURL: csvURL,
                fileName: "large.csv",
                resourceContext: derivedContext
            )
        )
    }

    // MARK: - 4. SHA-256 Integrity Across Archive, Staged, and Neighbor Disk Files

    func testArchivePreviewSaveAttemptPreservesArchiveStagedAndNeighborFileSHA256() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTSHA256Guard_\(UUID().uuidString)", isDirectory: true)
        let stagingDir = workspace.appendingPathComponent("TTZipLRUPreviewCache/slot1", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let archiveURL = workspace.appendingPathComponent("archive.zip")
        let neighborCSV = workspace.appendingPathComponent("data.csv")
        let stagedCSV = stagingDir.appendingPathComponent("data.csv")

        try Data("PK\u{03}\u{04}ARCHIVE_BYTES".utf8).write(to: archiveURL)
        try "neighbor,1\n".write(to: neighborCSV, atomically: true, encoding: .utf8)
        try "staged,2\n".write(to: stagedCSV, atomically: true, encoding: .utf8)

        let archiveHashBefore = try sha256Hex(of: archiveURL)
        let neighborHashBefore = try sha256Hex(of: neighborCSV)
        let stagedHashBefore = try sha256Hex(of: stagedCSV)

        let archiveContext = TTPreviewResourceContext.archiveEntry(
            archiveURL: archiveURL,
            entryPath: "nested/data.csv",
            stagedReadURL: stagedCSV,
            fileName: "data.csv"
        )

        XCTAssertFalse(SpreadsheetSavePolicy.canSaveInPlace(fileURL: stagedCSV, resourceContext: archiveContext))
        XCTAssertFalse(try SpreadsheetSavePolicy.saveInPlace(
            content: "overwritten,999\n", expectedBaseline: "staged,2\n",
            fileURL: stagedCSV, resourceContext: archiveContext
        ))

        // Also verify target mismatch protection if someone passes neighborCSV to validateInPlaceSaveTarget
        XCTAssertNil(archiveContext.validateInPlaceSaveTarget(expectedFileURL: neighborCSV))

        XCTAssertEqual(try sha256Hex(of: archiveURL), archiveHashBefore)
        XCTAssertEqual(try sha256Hex(of: neighborCSV), neighborHashBefore)
        XCTAssertEqual(try sha256Hex(of: stagedCSV), stagedHashBefore)
    }

    // MARK: - 5. Lifecycle Transitions: Sidebar -> Fullscreen, Prev/Next Switching, Close/Reopen

    func testLifecycleHandoffPreservesPermissionsAcrossFullscreenPrevNextAndReopen() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTLifecycle_\(UUID().uuidString)", isDirectory: true)
        let stagingDir = tempDir.appendingPathComponent("TTZipLRUPreviewCache/entry", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskFileA = tempDir.appendingPathComponent("a.csv")
        let diskFileB = tempDir.appendingPathComponent("b.md")
        let stagedArchiveFile = stagingDir.appendingPathComponent("archived.csv")
        let archiveURL = tempDir.appendingPathComponent("pack.zip")

        try "a,1\n".write(to: diskFileA, atomically: true, encoding: .utf8)
        try "# Title\n".write(to: diskFileB, atomically: true, encoding: .utf8)
        try "arch,2\n".write(to: stagedArchiveFile, atomically: true, encoding: .utf8)
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: archiveURL)

        // 1. Sidebar -> Fullscreen notification serialization for archive entry
        let archiveCtx = TTPreviewResourceContext.archiveEntry(
            archiveURL: archiveURL,
            entryPath: "archived.csv",
            stagedReadURL: stagedArchiveFile
        )
        let userInfo = archiveCtx.toUserInfoDictionary(additional: ["url": stagedArchiveFile])
        let restoredArchiveCtx = try XCTUnwrap(TTPreviewResourceContext.fromUserInfoDictionary(userInfo))
        XCTAssertEqual(restoredArchiveCtx, archiveCtx)
        XCTAssertFalse(restoredArchiveCtx.isEditableInPlace)
        XCTAssertEqual(restoredArchiveCtx.readOnlyReason, .archiveEntry)

        // 2. Prev/Next switching from Archive Entry -> Disk File A -> Disk File B -> back to Archive Entry
        let diskCtxA = TTPreviewResourceContext.diskFile(url: diskFileA)
        let diskCtxB = TTPreviewResourceContext.diskFile(url: diskFileB)
        XCTAssertTrue(diskCtxA.isEditableInPlace)
        XCTAssertTrue(diskCtxB.isEditableInPlace)

        let reopenedArchiveCtx = TTPreviewResourceContext.archiveEntry(
            archiveURL: archiveURL,
            entryPath: "archived.csv",
            stagedReadURL: stagedArchiveFile
        )
        XCTAssertFalse(reopenedArchiveCtx.isEditableInPlace)
        XCTAssertNil(reopenedArchiveCtx.writableSaveTargetURL)
    }

    // MARK: - 6. Controlled Text & CSV Delta Save Transaction (#185)

    func testCSVControlledDeltaSaveTransactionAndRoundTripReopen() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTDeltaSaveCSV_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let csvURL = tempDir.appendingPathComponent("metrics.csv")
        let initialCSV = [
            "id,service,latency_ms,status",
            "1,demux,4,healthy",
            "2,syntax,7,healthy",
            "3,delta,12,degraded",
            "4,inspector,3,healthy",
            "5,waveform,9,healthy",
            ""
        ].joined(separator: "\n")
        try initialCSV.write(to: csvURL, atomically: true, encoding: .utf8)

        let surgicalEdit1 = initialCSV.replacingOccurrences(of: "3,delta,12,degraded", with: "3,delta,2,healthy")
        let diskContext = TTPreviewResourceContext.diskFile(url: csvURL)
        let receipt = try XCTUnwrap(
            SpreadsheetSavePolicy.saveInPlaceWithDeltaReceipt(
                content: surgicalEdit1,
                expectedBaseline: initialCSV,
                fileURL: csvURL,
                fileName: "metrics.csv",
                resourceContext: diskContext
            )
        )
        XCTAssertGreaterThan(receipt.opsCount, 0)
        XCTAssertTrue(receipt.usedDeltaPath, "Surgical single-row CSV update must take the delta + WAL path")
        XCTAssertEqual(try String(contentsOf: csvURL, encoding: .utf8), surgicalEdit1)

        let surgicalEdit2 = surgicalEdit1.replacingOccurrences(of: "5,waveform,9,healthy", with: "5,waveform,5,healthy")
        XCTAssertTrue(try SpreadsheetSavePolicy.saveInPlace(
            content: surgicalEdit2, expectedBaseline: surgicalEdit1, fileURL: csvURL, resourceContext: diskContext
        ))
        let reloaded = try String(contentsOf: csvURL, encoding: .utf8)
        XCTAssertEqual(reloaded, surgicalEdit2)

        let parsedReopen = TTSpreadsheetParser.parsePrefix(text: reloaded, delimiter: ",", maxRows: 20)
        XCTAssertEqual(parsedReopen.rows.count, 6)
        XCTAssertEqual(parsedReopen.rows[3], ["3", "delta", "2", "healthy"])
        XCTAssertEqual(parsedReopen.rows[5], ["5", "waveform", "5", "healthy"])

        let directoryEntries = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertFalse(directoryEntries.contains { $0.hasPrefix(".ttmedia_save_txn_") })
    }

    func testTextControlledDeltaSavePreservesUTF8BOMAndSequentialMultiSave() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTDeltaSaveText_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let codeURL = tempDir.appendingPathComponent("pipeline.swift")
        let initialCode = (1...8).map { "let stage\($0) = \($0 * 10)" }.joined(separator: "\n") + "\n"
        let bom = Data([0xEF, 0xBB, 0xBF])
        try (bom + Data(initialCode.utf8)).write(to: codeURL)

        let source = TTTextSourceInspection.inspect(url: codeURL, fallbackText: initialCode)
        XCTAssertEqual(source.encoding, .utf8BOM)
        let tracker = TTSavedBaselineTracker(initialContent: initialCode, fileURL: codeURL)
        let codeEdit1 = initialCode.replacingOccurrences(of: "let stage3 = 30", with: "let stage3 = 300")
        let codeEdit2 = codeEdit1.replacingOccurrences(of: "let stage7 = 70", with: "let stage7 = 700")
        for edit in [codeEdit1, codeEdit2] {
            _ = try TTControlledTextSaveTransaction.commit(
                payload: edit,
                expectedBaseline: tracker.activeBaseline(hasContentOverride: false, stateBaseline: nil),
                encoding: source.encoding,
                targetURL: codeURL,
                isCSV: false
            )
            tracker.recordSave(edit)
            XCTAssertEqual(try Data(contentsOf: codeURL), bom + Data(edit.utf8))
        }
    }

    func testWholeFileFallbackWhenFullRewriteIsSmallerThanDeltaPayload() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTDeltaWholeFallback_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let csvURL = tempDir.appendingPathComponent("compact.csv")
        let initialCSV = "a,b\n1,2\n3,4\n"
        let tinyReplacement = "x,y\n"
        try initialCSV.write(to: csvURL, atomically: true, encoding: .utf8)

        let receipt = try XCTUnwrap(
            SpreadsheetSavePolicy.saveInPlaceWithDeltaReceipt(
                content: tinyReplacement,
                expectedBaseline: initialCSV,
                fileURL: csvURL,
                fileName: "compact.csv",
                resourceContext: .diskFile(url: csvURL)
            )
        )
        XCTAssertGreaterThan(receipt.opsCount, 0)
        XCTAssertFalse(receipt.usedDeltaPath, "Full rewrite smaller than 24-byte op header must take whole-file path")
        XCTAssertEqual(try String(contentsOf: csvURL, encoding: .utf8), tinyReplacement)
    }

    func testExternalFileModificationConflictRejectsSaveAndPreservesOnDiskFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTDeltaConflict_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let csvURL = tempDir.appendingPathComponent("shared.csv")
        let codeURL = tempDir.appendingPathComponent("shared.swift")

        let baseCSV = "k,v\n1,10\n2,20\n"
        let baseCode = "let v = 1\n"
        try baseCSV.write(to: csvURL, atomically: true, encoding: .utf8)
        try baseCode.write(to: codeURL, atomically: true, encoding: .utf8)

        let tracker = TTSavedBaselineTracker(initialContent: baseCode, fileURL: codeURL)

        // Simulate external concurrent modification on disk after views loaded their baselines
        let extCSV = "k,v\n1,999\n2,888\n"
        let extCode = "let v = 999\n"
        try extCSV.write(to: csvURL, atomically: true, encoding: .utf8)
        try extCode.write(to: codeURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try SpreadsheetSavePolicy.saveInPlaceWithDeltaReceipt(
                content: "k,v\n1,11\n2,20\n",
                expectedBaseline: baseCSV,
                fileURL: csvURL,
                fileName: "shared.csv",
                resourceContext: .diskFile(url: csvURL)
            )
        ) { error in
            XCTAssertEqual(error as? TTDeltaSaveConflictError, .externalFileModified(csvURL.standardizedFileURL))
        }

        XCTAssertThrowsError(try TTControlledTextSaveTransaction.commit(
            payload: "let v = 2\n",
            expectedBaseline: tracker.activeBaseline(hasContentOverride: false, stateBaseline: nil),
            encoding: .utf8,
            targetURL: codeURL,
            isCSV: false
        )) { error in
            XCTAssertEqual(error as? TTDeltaSaveConflictError, .externalFileModified(codeURL.standardizedFileURL))
        }

        XCTAssertEqual(try String(contentsOf: csvURL, encoding: .utf8), extCSV)
        XCTAssertEqual(try String(contentsOf: codeURL, encoding: .utf8), extCode)
    }

    func testReadOnlyArchiveDerivedAndTruncatedSourcesRemainBlockedUnderDeltaSave() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTDeltaGuards_\(UUID().uuidString)", isDirectory: true)
        let stagingDir = tempDir.appendingPathComponent("TTZipLRUPreviewCache/slot", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskCSV = tempDir.appendingPathComponent("guarded.csv")
        let stagedCSV = stagingDir.appendingPathComponent("staged.csv")
        let original = "col1,col2\n1,2\n"
        try original.write(to: diskCSV, atomically: true, encoding: .utf8)
        try original.write(to: stagedCSV, atomically: true, encoding: .utf8)

        let readOnlyCtx = TTPreviewResourceContext.diskFile(url: diskCSV, allowsEditing: false)
        let truncatedCtx = TTPreviewResourceContext.diskFile(url: diskCSV).withTruncatedPreview(true)
        let derivedCtx = TTPreviewResourceContext.diskFile(url: diskCSV).withDerivedRepresentation(true, description: "Workbook")
        let archiveCtx = TTPreviewResourceContext.archiveEntry(
            archiveURL: tempDir.appendingPathComponent("archive.zip"),
            entryPath: "staged.csv",
            stagedReadURL: stagedCSV
        )

        for ctx in [readOnlyCtx, truncatedCtx, derivedCtx] {
            let receipt = try SpreadsheetSavePolicy.saveInPlaceWithDeltaReceipt(
                content: "col1,col2\n9,9\n",
                expectedBaseline: original,
                fileURL: diskCSV,
                fileName: "guarded.csv",
                resourceContext: ctx
            )
            XCTAssertNil(receipt)
        }
        let archiveReceipt = try SpreadsheetSavePolicy.saveInPlaceWithDeltaReceipt(
            content: "col1,col2\n9,9\n",
            expectedBaseline: original,
            fileURL: stagedCSV,
            fileName: "staged.csv",
            resourceContext: archiveCtx
        )
        XCTAssertNil(archiveReceipt)
        XCTAssertEqual(try String(contentsOf: diskCSV, encoding: .utf8), original)
        XCTAssertEqual(try String(contentsOf: stagedCSV, encoding: .utf8), original)
    }

    // MARK: - 7. Issue #314 Document Preview Switch & Baseline Regression Tests

    func testMarkdownSourceSwitchResetsScrollAndSelection() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMarkdownSwitch314_\(UUID().uuidString)", isDirectory: true)
        let stagingDir = tempDir.appendingPathComponent("TTZipLRUPreviewCache/md", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskURL = tempDir.appendingPathComponent("a.md")
        let stagedURL = stagingDir.appendingPathComponent("b.md")
        let archiveURL = tempDir.appendingPathComponent("docs.zip")
        let markdownA = "# Doc A\n" + String(repeating: "Paragraph A\n", count: 80)
        let markdownB = "# Doc B\nParagraph B\n"
        try markdownA.write(to: diskURL, atomically: true, encoding: .utf8)
        try markdownB.write(to: stagedURL, atomically: true, encoding: .utf8)

        let blocksA = TTMarkdownParser.parseDocumentBlocks(markdownA)
        let blocksB = TTMarkdownParser.parseDocumentBlocks(markdownB)
        XCTAssertNotEqual(blocksA.map(\.id), blocksB.map(\.id))

        let diskContext = TTPreviewResourceContext.diskFile(url: diskURL)
        let archiveContext = TTPreviewResourceContext.archiveEntry(
            archiveURL: archiveURL, entryPath: "docs/b.md", stagedReadURL: stagedURL
        )

        let editorRep = CodeHighlightingEditorNSView(
            text: .constant(markdownA),
            fileName: "a.md",
            showLineNumbers: true,
            isEditable: diskContext.isEditableInPlace
        )
        let coordinator = editorRep.makeCoordinator()
        let scrollView = editorRep.makeEditorScrollView(coordinator: coordinator)
        scrollView.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        let textView = try XCTUnwrap(scrollView.documentView as? LargeTextEditorTextView)
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: 1200)
        XCTAssertEqual(textView.string, markdownA)
        XCTAssertTrue(textView.isEditable)
        textView.setSelectedRange(NSRange(location: 5, length: 6))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 180))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 180, accuracy: 0.5)

        let archiveEditor = CodeHighlightingEditorNSView(
            text: .constant(markdownB), fileName: "b.md", showLineNumbers: true,
            isEditable: archiveContext.isEditableInPlace
        )
        archiveEditor.applyUpdate(to: scrollView, coordinator: coordinator)
        XCTAssertEqual(textView.string, markdownB)
        XCTAssertFalse(textView.isEditable)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0.0, accuracy: 0.5)
    }

    func testDocxAndEPUBDocumentSwitchStateReset() throws {
        let urlA = URL(fileURLWithPath: "/tmp/docA.docx")
        let urlB = URL(fileURLWithPath: "/tmp/docB.docx")
        let attrA = NSAttributedString(string: String(repeating: "Paragraph in Doc A.\n", count: 60))
        let attrB = NSAttributedString(string: "Short Doc B")

        let docxViewA = DocxTextEditorNSView(attributedString: attrA, fileURL: urlA)
        let docxCoordinator = docxViewA.makeCoordinator()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 900))
        textView.textStorage?.setAttributedString(attrA)
        scrollView.documentView = textView
        textView.setSelectedRange(NSRange(location: 4, length: 5))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 150))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 150, accuracy: 0.5)

        let docxViewB = DocxTextEditorNSView(attributedString: attrB, fileURL: urlB)
        docxViewB.applyUpdate(to: scrollView, coordinator: docxCoordinator)
        XCTAssertEqual(textView.autoresizingMask, [.width])
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(scrollView.contentView.bounds.origin, .zero)
        XCTAssertEqual(textView.string, "Short Doc B")

        let epubDataA = Data("EPUB_BUFFER_ALPHA_0123456789".utf8)
        let epubDataB = Data("EPUB_BUFFER_BETA_9876543210_EXTRA".utf8)
        let epubIdA = EPUBReaderSession.makeTaskIdentity(fileURL: nil, epubData: epubDataA)
        let epubIdB = EPUBReaderSession.makeTaskIdentity(fileURL: nil, epubData: epubDataB)
        XCTAssertNotEqual(epubIdA, epubIdB)

        let epubDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTEPUB314_\(UUID().uuidString)", isDirectory: true)
        let epubBook = EPUBBookModel(
            url: epubDir.appendingPathComponent("book.epub"),
            title: "Book",
            chapters: [EPUBChapterItem(id: "c1", title: "Ch 1", fileURL: epubDir.appendingPathComponent("ch1.xhtml"))],
            extractDir: epubDir
        )
        let epubReader = EPUBReaderSession(bookModel: epubBook, fileURL: nil, epubData: epubDataA)
        let dummySearchTask = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(5)) }
        epubReader.stageSearchAndPopoverStateForTesting(
            isSearchPresented: true,
            isTOCPresented: true,
            query: "stale query",
            matches: ["Chapter 1"],
            task: dummySearchTask
        )
        XCTAssertTrue(epubReader.effectiveIsSearchPopoverPresented)
        XCTAssertTrue(epubReader.effectiveIsTOCPopoverPresented)
        XCTAssertEqual(epubReader.effectiveSearchQuery, "stale query")

        epubReader.loadEPUBPackage()
        XCTAssertTrue(dummySearchTask.isCancelled)
        XCTAssertFalse(epubReader.effectiveIsSearchPopoverPresented)
        XCTAssertFalse(epubReader.effectiveIsTOCPopoverPresented)
        XCTAssertEqual(epubReader.effectiveSearchQuery, "")
        XCTAssertTrue(epubReader.effectiveSearchMatches.isEmpty)
    }

    func testSavedBaselineTrackerBoundsDiskLoads() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTBaselineBounded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskURL = tempDir.appendingPathComponent("sample.txt")
        let diskText = "0123456789ABCDEF0123456789ABCDEF" // 32 bytes
        try diskText.write(to: diskURL, atomically: true, encoding: .utf8)

        let disabledTracker = TTSavedBaselineTracker(
            initialContent: "fallback",
            fileURL: diskURL,
            allowsDiskBaselineLoad: false
        )
        XCTAssertEqual(disabledTracker.activeBaseline(hasContentOverride: false, stateBaseline: nil), "fallback")

        let oversizedTracker = TTSavedBaselineTracker(
            initialContent: "fallback",
            fileURL: diskURL,
            allowsDiskBaselineLoad: true,
            maxBaselineBytes: 8
        )
        XCTAssertEqual(oversizedTracker.activeBaseline(hasContentOverride: false, stateBaseline: nil), "fallback")

        let allowedTracker = TTSavedBaselineTracker(
            initialContent: "fallback",
            fileURL: diskURL,
            allowsDiskBaselineLoad: true,
            maxBaselineBytes: 64
        )
        XCTAssertEqual(allowedTracker.activeBaseline(hasContentOverride: false, stateBaseline: nil), diskText)
    }

    func testSavedBaselineTrackerResetAllowsSaveAfterReload() throws {
        let codeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTBaselineReload-\(UUID().uuidString).swift")
        let lastSaved = "let v = 1\n"
        try Data(lastSaved.utf8).write(to: codeURL)
        defer { try? FileManager.default.removeItem(at: codeURL) }
        let tracker = TTSavedBaselineTracker(initialContent: lastSaved, fileURL: codeURL)
        tracker.recordSave(lastSaved)

        let reloaded = "let v = 2\n"
        try Data(reloaded.utf8).write(to: codeURL, options: .atomic)
        tracker.reset(initialContent: reloaded, fileURL: codeURL)
        let baseline = tracker.activeBaseline(hasContentOverride: false, stateBaseline: nil)
        XCTAssertEqual(baseline, reloaded)

        let edited = "let v = 3\n"
        _ = try TTControlledTextSaveTransaction.commit(
            payload: edited, expectedBaseline: baseline, encoding: .utf8, targetURL: codeURL, isCSV: false
        )
        XCTAssertEqual(try Data(contentsOf: codeURL), Data(edited.utf8))
    }
}
