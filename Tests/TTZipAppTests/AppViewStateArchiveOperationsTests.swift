// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class AppViewStateArchiveOperationsTests: XCTestCase {
    
    // MARK: - Helper Methods
    
    private func createSampleZipArchive(
        in tempDir: URL,
        fileName: String = "sample.zip",
        contents: [String: String]
    ) async throws -> URL {
        let zipURL = tempDir.appendingPathComponent(fileName)
        var inputPaths: [String] = []
        
        for (relName, text) in contents {
            let fileURL = tempDir.appendingPathComponent(relName)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            inputPaths.append(fileURL.path)
        }
        
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: inputPaths
        )
        return zipURL
    }
    
    private func createPasswordProtectedZipArchive(
        in tempDir: URL,
        fileName: String = "locked.zip",
        password: String = "SecretKey123"
    ) async throws -> URL {
        let zipURL = tempDir.appendingPathComponent(fileName)
        let sampleFile = tempDir.appendingPathComponent("secret_notes.txt")
        try "Highly confidential report data".write(to: sampleFile, atomically: true, encoding: .utf8)
        
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [sampleFile.path],
            password: password
        )
        return zipURL
    }
    
    // MARK: - 1. Load Archive Tests
    
    func testLoadArchiveSuccessLifecycle() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "ArchiveOps")
        let mockFileViewer = MockFileViewerHarness()
        let zipURL = try await createSampleZipArchive(in: tempDir, contents: [
            "readme.txt": "Welcome to TTZip",
            "docs/manual.pdf": "PDF Specification Guide"
        ])
        
        let sut = AppViewState(fileViewer: mockFileViewer)
        sut.activeTab = .compressWorkspace
        
        let success = await sut.loadArchive(path: zipURL.path)
        
        XCTAssertTrue(success, "loadArchive must return true for valid zip archive")
        XCTAssertEqual(sut.currentArchivePath, zipURL.path)
        XCTAssertEqual(sut.activeTab, .home, "loadArchive must navigate to Home/Archive Explorer tab")
        XCTAssertFalse(sut.isLoading)
        XCTAssertFalse(sut.showPasswordPrompt)
        XCTAssertGreaterThanOrEqual(sut.currentEntries.count, 2)
        XCTAssertTrue(sut.statusMessage.contains("Loaded") || sut.statusMessage.contains("entries"))
        XCTAssertTrue(sut.recentArchives.contains { $0.path == zipURL.path })
    }
    
    func testLoadArchivePasswordProtectedLifecycle() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "ArchiveOps")
        let mockFileViewer = MockFileViewerHarness()
        ArchivePasswordStore.shared.clearAll()
        defer { ArchivePasswordStore.shared.clearAll() }
        let lockedURL = try await createPasswordProtectedZipArchive(in: tempDir)
        
        let sut = AppViewState(fileViewer: mockFileViewer)
        let success = await sut.loadArchive(path: lockedURL.path)
        
        // Listing zip entries succeeds
        XCTAssertTrue(success, "loadArchive lists entries from zip central directory")
        XCTAssertEqual(sut.currentArchivePath, lockedURL.path)
        XCTAssertEqual(sut.currentEntries.count, 1)
        XCTAssertTrue(sut.currentEntries.first?.isEncrypted == true)
        
        // Provide explicit password to unlock
        let unlocked = await sut.loadArchive(path: lockedURL.path, password: "SecretKey123")
        XCTAssertTrue(unlocked)
        XCTAssertEqual(sut.currentArchivePath, lockedURL.path)
        XCTAssertFalse(sut.showPasswordPrompt)
    }
    
    // MARK: - 2. Quick Extract Archive Tests
    
    func testQuickExtractArchiveLifecycle() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "ArchiveOps")
        let mockFileViewer = MockFileViewerHarness()
        let zipURL = try await createSampleZipArchive(in: tempDir, contents: [
            "file_a.txt": "Content of File A",
            "file_b.txt": "Content of File B"
        ])
        
        let extractTargetDir = tempDir.appendingPathComponent("Extracted_Output")
        try FileManager.default.createDirectory(at: extractTargetDir, withIntermediateDirectories: true)
        
        let sut = AppViewState(fileViewer: mockFileViewer)
        await sut.quickExtractArchive(
            archivePath: zipURL.path,
            targetDir: extractTargetDir.path,
            isSmartExtract: false
        )
        
        XCTAssertTrue(sut.statusMessage.contains("Extraction complete"))
        XCTAssertEqual(mockFileViewer.revealedPaths.count, 1, "quickExtractArchive must call revealInFinder once")
        let expectedExtractDir = extractTargetDir.appendingPathComponent("sample").path
        XCTAssertEqual(mockFileViewer.revealedPaths.first, expectedExtractDir, "revealInFinder must target the extraction directory")
        
        let extractedFileA = extractTargetDir.appendingPathComponent("sample/file_a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedFileA.path) || FileManager.default.fileExists(atPath: extractTargetDir.appendingPathComponent("file_a.txt").path))
    }
    
    func testQuickExtractPasswordProtectedTriggersPrompt() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "ArchiveOps")
        let mockFileViewer = MockFileViewerHarness()
        ArchivePasswordStore.shared.clearAll()
        defer { ArchivePasswordStore.shared.clearAll() }
        let lockedURL = try await createPasswordProtectedZipArchive(in: tempDir)
        let extractTargetDir = tempDir.appendingPathComponent("Extracted_Locked")
        try FileManager.default.createDirectory(at: extractTargetDir, withIntermediateDirectories: true)
        
        let sut = AppViewState(fileViewer: mockFileViewer)
        await sut.quickExtractArchive(
            archivePath: lockedURL.path,
            targetDir: extractTargetDir.path,
            password: nil,
            isSmartExtract: false
        )
        
        XCTAssertTrue(sut.showPasswordPrompt, "Password prompt must be shown when extracting encrypted archive without password")
        XCTAssertEqual(sut.pendingEncryptedPath, lockedURL.path)
        XCTAssertTrue(sut.statusMessage.lowercased().contains("password") || sut.statusMessage.lowercased().contains("encrypted"))
        XCTAssertTrue(mockFileViewer.revealedPaths.isEmpty, "revealInFinder must not be called when password prompt is triggered")
    }

    func testQuickExtractStoppedOnConflictNeverRevealsOrTrashesSource() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "ArchiveOps")
        let mockFileViewer = MockFileViewerHarness()
        let zipURL = try await createSampleZipArchive(in: tempDir, contents: [
            "file_a.txt": "Archive Version of File A"
        ])

        let extractTargetDir = tempDir.appendingPathComponent("Extracted_Stop")
        let sampleSubdir = extractTargetDir.appendingPathComponent("sample")
        try FileManager.default.createDirectory(at: sampleSubdir, withIntermediateDirectories: true)
        let conflictingFile = sampleSubdir.appendingPathComponent("file_a.txt")
        let originalContent = "Existing User File A"
        try originalContent.write(to: conflictingFile, atomically: true, encoding: .utf8)

        let sut = AppViewState(fileViewer: mockFileViewer)
        await sut.quickExtractArchive(
            archivePath: zipURL.path,
            targetDir: extractTargetDir.path,
            isSmartExtract: false,
            trashSourceAfterExtract: true,
            collisionHandling: .policy(.stop)
        )

        XCTAssertFalse(
            sut.statusMessage.contains("Extraction complete"),
            "Stopped extraction must never report Extraction complete, got: \(sut.statusMessage)"
        )
        XCTAssertTrue(mockFileViewer.revealedPaths.isEmpty, "revealInFinder must not be called when extraction stops")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: zipURL.path),
            "Source archive must not be trashed when extraction stops"
        )
        XCTAssertEqual(try String(contentsOf: conflictingFile, encoding: .utf8), originalContent)
    }

    func testQuickExtractPartialFailureDoesNotReportSuccessOrTrashSource() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "ArchiveOpsPartialFailure")
        let mockFileViewer = MockFileViewerHarness()

        let srcRoot = tempDir.appendingPathComponent("src_root")
        let srcLockedDir = srcRoot.appendingPathComponent("locked_dir")
        try FileManager.default.createDirectory(at: srcLockedDir, withIntermediateDirectories: true)
        let okFileURL = srcRoot.appendingPathComponent("ok_file.txt")
        let blockedFileURL = srcLockedDir.appendingPathComponent("blocked.txt")
        try "Valid sibling file".write(to: okFileURL, atomically: true, encoding: .utf8)
        try "Cannot be committed into read-only directory".write(
            to: blockedFileURL,
            atomically: true,
            encoding: .utf8
        )

        let zipURL = tempDir.appendingPathComponent("sample.zip")
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [okFileURL.path, srcLockedDir.path]
        )

        let extractTargetDir = tempDir.appendingPathComponent("Extracted_PartialFailure")
        let lockedDir = extractTargetDir.appendingPathComponent("sample/locked_dir")
        try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        let protectedFile = lockedDir.appendingPathComponent("protected.txt")
        try "Existing Protected Content".write(to: protectedFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)

        let sut = AppViewState(fileViewer: mockFileViewer)
        await sut.quickExtractArchive(
            archivePath: zipURL.path,
            targetDir: extractTargetDir.path,
            isSmartExtract: false,
            trashSourceAfterExtract: true,
            collisionHandling: .policy(.replace)
        )

        XCTAssertFalse(
            sut.statusMessage.contains("Extraction complete"),
            "Partial failure must never report ordinary Extraction complete, got: \(sut.statusMessage)"
        )
        XCTAssertTrue(
            sut.statusMessage.contains("failed"),
            "Status message must surface partial extraction failure, got: \(sut.statusMessage)"
        )
        XCTAssertTrue(
            mockFileViewer.revealedPaths.isEmpty,
            "revealInFinder must not be called on partial extraction failure"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: zipURL.path),
            "Source archive must not be trashed when partial extraction failure occurs"
        )
        XCTAssertEqual(
            try String(contentsOf: protectedFile, encoding: .utf8),
            "Existing Protected Content"
        )
    }

    // MARK: - 2b. Selected Entry Extraction Terminal Classification (E2)

    func testExtractEntriesStoppedOnConflictNeverReportsFatalErrorOrReveals() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "EntryExtractStop")
        let mockFileViewer = MockFileViewerHarness()
        AppErrorReporter.shared.dismiss()
        defer { AppErrorReporter.shared.dismiss() }

        let zipURL = try await createSampleZipArchive(in: tempDir, contents: [
            "file_a.txt": "Archive Version of File A"
        ])

        let extractTargetDir = tempDir.appendingPathComponent("Entry_Extract_Stop")
        try FileManager.default.createDirectory(at: extractTargetDir, withIntermediateDirectories: true)
        let conflictingFile = extractTargetDir.appendingPathComponent("file_a.txt")
        let originalContent = "Existing User File A"
        try originalContent.write(to: conflictingFile, atomically: true, encoding: .utf8)

        let sut = AppViewState(fileViewer: mockFileViewer)
        await sut.extractEntries(
            archivePath: zipURL.path,
            entryPaths: ["file_a.txt"],
            destinationDir: extractTargetDir.path,
            collisionHandling: .policy(.stop)
        )

        XCTAssertEqual(
            sut.statusMessage,
            "Extraction stopped: file_a.txt",
            "Stopped entry extraction must report Extraction stopped, got: \(sut.statusMessage)"
        )
        XCTAssertEqual(sut.taskStateName, "Stopped")
        XCTAssertFalse(
            AppErrorReporter.shared.isPresentingError,
            "Stopped entry extraction must never present a fatal error alert"
        )
        XCTAssertNil(AppErrorReporter.shared.activeError)
        XCTAssertTrue(
            mockFileViewer.revealedPaths.isEmpty,
            "revealInFinder must not be called when entry extraction stops on collision"
        )
        XCTAssertEqual(try String(contentsOf: conflictingFile, encoding: .utf8), originalContent)
    }

    func testExtractEntriesPartialFailureReportsPartialErrorAndNeverRevealsOrClaimsFullSuccess() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "EntryExtractPartialFailure")
        let mockFileViewer = MockFileViewerHarness()
        AppErrorReporter.shared.dismiss()
        defer { AppErrorReporter.shared.dismiss() }

        let srcRoot = tempDir.appendingPathComponent("src_root")
        let srcLockedDir = srcRoot.appendingPathComponent("locked_dir")
        try FileManager.default.createDirectory(at: srcLockedDir, withIntermediateDirectories: true)
        let okFileURL = srcRoot.appendingPathComponent("ok_file.txt")
        let blockedFileURL = srcLockedDir.appendingPathComponent("protected.txt")
        try "Valid sibling entry".write(to: okFileURL, atomically: true, encoding: .utf8)
        try "Archive replacement for protected entry".write(to: blockedFileURL, atomically: true, encoding: .utf8)

        let zipURL = tempDir.appendingPathComponent("entry_partial.zip")
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [okFileURL.path, srcLockedDir.path]
        )

        let extractTargetDir = tempDir.appendingPathComponent("Entry_Extract_Partial")
        let lockedDir = extractTargetDir.appendingPathComponent("locked_dir")
        try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        let protectedFile = lockedDir.appendingPathComponent("protected.txt")
        try "Existing Protected Content".write(to: protectedFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)

        let sut = AppViewState(fileViewer: mockFileViewer)
        await sut.extractEntries(
            archivePath: zipURL.path,
            entryPaths: ["ok_file.txt", "locked_dir/protected.txt"],
            destinationDir: extractTargetDir.path,
            collisionHandling: .policy(.replace)
        )

        XCTAssertEqual(
            sut.statusMessage,
            "Extracted 2 items with 1 failed item(s)",
            "Partial entry extraction failure must surface failed item count, got: \(sut.statusMessage)"
        )
        XCTAssertEqual(sut.taskStateName, "Completed with errors")
        XCTAssertTrue(AppErrorReporter.shared.isPresentingError)
        XCTAssertEqual(AppErrorReporter.shared.activeError?.title, "Partial Extraction Error")
        XCTAssertTrue(
            mockFileViewer.revealedPaths.isEmpty,
            "revealInFinder must not be called on partial entry extraction failure"
        )
        XCTAssertEqual(
            try String(contentsOf: extractTargetDir.appendingPathComponent("ok_file.txt"), encoding: .utf8),
            "Valid sibling entry"
        )
        XCTAssertEqual(
            try String(contentsOf: protectedFile, encoding: .utf8),
            "Existing Protected Content"
        )
    }

    func testExtractEntriesCompletedAndPasswordPromptPositiveControls() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "EntryExtractPositive")
        let mockFileViewer = MockFileViewerHarness()
        AppErrorReporter.shared.dismiss()
        ArchivePasswordStore.shared.clearAll()
        defer {
            AppErrorReporter.shared.dismiss()
            ArchivePasswordStore.shared.clearAll()
        }

        let zipURL = try await createSampleZipArchive(in: tempDir, contents: [
            "readme.txt": "Selected Entry Payload"
        ])
        let extractTargetDir = tempDir.appendingPathComponent("Entry_Extract_OK")
        try FileManager.default.createDirectory(at: extractTargetDir, withIntermediateDirectories: true)

        let sut = AppViewState(fileViewer: mockFileViewer)
        await sut.extractEntries(
            archivePath: zipURL.path,
            entryPaths: ["readme.txt"],
            destinationDir: extractTargetDir.path
        )

        let extractedFile = extractTargetDir.appendingPathComponent("readme.txt")
        XCTAssertEqual(sut.statusMessage, "Extracted entry: readme.txt")
        XCTAssertFalse(AppErrorReporter.shared.isPresentingError)
        XCTAssertEqual(mockFileViewer.revealedPaths, [extractedFile.path])
        XCTAssertEqual(try String(contentsOf: extractedFile, encoding: .utf8), "Selected Entry Payload")

        // Encrypted entry without password must still stage password prompt without error alert
        let lockedURL = try await createPasswordProtectedZipArchive(in: tempDir)
        await sut.extractEntries(
            archivePath: lockedURL.path,
            entryPaths: ["secret_notes.txt"],
            destinationDir: extractTargetDir.path,
            password: nil
        )
        XCTAssertTrue(sut.showPasswordPrompt)
        XCTAssertEqual(sut.pendingEncryptedPath, lockedURL.path)
        XCTAssertFalse(AppErrorReporter.shared.isPresentingError)
    }
    
    // MARK: - 3. Open Archive As Folder & Reset
    
    func testOpenArchiveAsFolderAndReset() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "ArchiveOps")
        let mockFileViewer = MockFileViewerHarness()
        let zipURL = try await createSampleZipArchive(in: tempDir, contents: ["file.txt": "Hello"])
        
        let sut = AppViewState(fileViewer: mockFileViewer)
        sut.openArchiveAsFolder(url: zipURL)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline && (
            sut.currentArchivePath != zipURL.path || sut.selectedDiskItem?.path != zipURL.path ||
            !sut.recentArchives.contains(where: { $0.path == zipURL.path }) || sut.isLoading
        ) {
            await Task.yield()
        }
        XCTAssertEqual(sut.currentArchivePath, zipURL.path, "The wrapper must commit the real archive in budget")

        XCTAssertEqual(sut.selectedDiskItem?.path, zipURL.path)
        XCTAssertEqual(sut.activeTab, .home)
        XCTAssertTrue(sut.recentArchives.contains { $0.path == zipURL.path })
        
        sut.reset()
        XCTAssertNil(sut.currentArchivePath)
        XCTAssertNil(sut.activePassword)
        XCTAssertTrue(sut.currentEntries.isEmpty)
        XCTAssertEqual(sut.statusMessage, "Ready")
        XCTAssertFalse(sut.isLoading)
        XCTAssertEqual(sut.activeTab, .home)
    }
}

// MARK: - MM49 bounded command and window identity acceptance

@MainActor
final class WindowBusyIdentityOwnershipTests: ArchiveHostAcceptanceTestCase {
    func testCommandKeepsTheWindowBusyWhileItAwaitsAndReleasesOnlyItsOwnIdentity() async throws {
        let archiveURL = try makeArchiveFixture(named: "busy-command")
        let path = archiveURL.path
        assertTemporaryFixturePath(path)
        await withBusyScenario { scenario in
            let commandGate = scenario.barrier()
            let extractionGate = scenario.barrier()
            let driver = self.makeGatedArchiveDriver(extractBarriers: [path: extractionGate])
            let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let command = scenario.start { try await state.executeCommand(GatedArchiveCommand(barrier: commandGate)) }
            try await scenario.entered(commandGate)
            scenario.expect(state.isLoading, "A running command must own a busy identity")
            let extraction = scenario.start { await state.quickExtractArchive(archivePath: path, isSmartExtract: false) }
            try await scenario.entered(extractionGate)
            await commandGate.release()
            let result = try await scenario.finish(command)
            scenario.expect(result.success, "The real command must complete successfully")
            scenario.expect(state.isLoading, "Command completion must not release the running extraction")
            await extractionGate.release()
            try await scenario.finish(extraction)
            scenario.expect(!state.isLoading, "The final extraction must release the window busy identity")
        }
    }

    func testCommandIsRejectedWhileTheWindowIsBusy() async throws {
        let archiveURL = try makeArchiveFixture(named: "busy-command-guard")
        let path = archiveURL.path
        assertTemporaryFixturePath(path)
        await withBusyScenario { scenario in
            let extractionGate = scenario.barrier()
            let commandGate = scenario.barrier()
            let driver = self.makeGatedArchiveDriver(extractBarriers: [path: extractionGate])
            let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let extraction = scenario.start { await state.quickExtractArchive(archivePath: path, isSmartExtract: false) }
            try await scenario.entered(extractionGate)
            scenario.expect(state.isLoading, "The extraction must make the window busy before command admission")
            let rejection = scenario.start {
                do {
                    _ = try await state.executeCommand(GatedArchiveCommand(barrier: commandGate))
                    return false
                } catch let error as CommandError {
                    return error == .invalidState(reason: "Another task is in progress.")
                } catch { return false }
            }
            // If admission breaks, this receipt expires; cleanup releases BOTH gates before failing.
            let rejectedWithExpectedReason = try await scenario.finish(rejection)
            scenario.expect(rejectedWithExpectedReason, "A busy window must reject the real command with its exact existing reason")
            await extractionGate.release()
            try await scenario.finish(extraction)
            scenario.expect(!state.isLoading, "The extraction must release its identity after rejection")
        }
    }

    func testBusyStateOfOneWindowDoesNotAffectAnotherWindow() async throws {
        let archiveURL = try makeArchiveFixture(named: "busy-windows")
        let path = archiveURL.path
        assertTemporaryFixturePath(path)
        await withBusyScenario { scenario in
            let extractionGate = scenario.barrier()
            let driver = self.makeGatedArchiveDriver(extractBarriers: [path: extractionGate])
            let busyWindow = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
            let extraction = scenario.start { await busyWindow.quickExtractArchive(archivePath: path, isSmartExtract: false) }
            try await scenario.entered(extractionGate)
            scenario.expect(busyWindow.isLoading, "The extracting window must own its busy identity")
            let idleWindow = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: self.makeGatedArchiveDriver())
            let open = scenario.start { await idleWindow.loadArchive(path: path) }
            let loaded = try await scenario.finish(open)
            scenario.expect(loaded, "The second window must commit its own open")
            scenario.expect(!idleWindow.isLoading, "The second window must not inherit another window's busy identities")
            scenario.expect(busyWindow.isLoading, "Completing the other window's open must not release the extraction")
            await extractionGate.release()
            try await scenario.finish(extraction)
            scenario.expect(!busyWindow.isLoading, "Extraction completion must release its window's last identity")
        }
    }

    func testBusyIdentitiesAreReleasedIdempotentlyAndEpochScoped() {
        let taskState = TaskExecutionState()
        let operationID = taskState.beginBusyOperation()
        XCTAssertTrue(taskState.isLoading, "A live operation must make the window busy")
        taskState.endBusyOperation(id: operationID)
        taskState.endBusyOperation(id: operationID)
        XCTAssertFalse(taskState.isLoading, "A repeated release must be a no-op")
        taskState.beginArchiveRequest(epoch: 1)
        taskState.beginArchiveRequest(epoch: 2)
        XCTAssertFalse(taskState.endArchiveRequest(ifOwnedBy: 1), "An old epoch cannot release a new owner")
        XCTAssertTrue(taskState.isLoading, "The newer epoch must remain busy")
        XCTAssertTrue(taskState.endArchiveRequest(ifOwnedBy: 2), "The owning epoch may release itself")
        XCTAssertFalse(taskState.isLoading, "Releasing the owner must leave the foreground idle")
        let outerID = taskState.beginBusyOperation()
        let innerID = taskState.beginBusyOperation()
        taskState.endBusyOperation(id: innerID)
        XCTAssertTrue(taskState.isLoading, "The outer operation must survive inner cleanup")
        taskState.endBusyOperation(id: outerID)
        XCTAssertFalse(taskState.isLoading, "All identities have been released")
    }
}
