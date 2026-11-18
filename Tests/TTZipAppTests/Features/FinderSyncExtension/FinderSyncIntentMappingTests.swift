// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp
@testable import TTZipCore
@testable import TTZipFinderSync

final class FinderSyncIntentMappingTests: XCTestCase {
    
    // MARK: - 1. URL Scheme Query Parsing & Path Decoding
    
    func testURLSchemeQueryParsingAndPathDecoding() throws {
        let mockHarness = try MockFileURLHarness()
        defer { try? mockHarness.cleanup() }
        
        let path1 = mockHarness.createFile(named: "file with spaces.txt").path
        let path2 = mockHarness.createFile(named: "CJK_測試文檔.pdf").path
        
        let joinedPaths = [path1, path2].joined(separator: "|")
        let encodedPaths = joinedPaths.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let urlString = "ttzip://action?type=compress_quick_zip&paths=\(encodedPaths)"
        
        let url = try XCTUnwrap(URL(string: urlString))
        let envelope = try XCTUnwrap(AppIntentParser.parse(url: url))
        
        if case .createArchive(let paths, let options) = envelope.intent {
            XCTAssertEqual(paths, [path1, path2])
            XCTAssertEqual(options.targetFormat, .zip)
        } else {
            XCTFail("Parsed intent did not match .createArchive")
        }
    }
    
    // MARK: - 2. All 10 FinderSync Action Types Parsing Matrix
    
    func testAllFinderSyncActionTypesParsingMatrix() throws {
        let mockHarness = try MockFileURLHarness()
        defer { try? mockHarness.cleanup() }
        
        let testArchive = mockHarness.createFile(named: "archive.7z").path
        let testFile = mockHarness.createFile(named: "document.txt").path
        
        let expectations: [(String, String, (AppIntent) -> Bool)] = [
            ("extract_here", testArchive, { if case .extractArchive(let p, let o) = $0 { return p == [testArchive] && !o.isSmartExtract } else { return false } }),
            ("extract_to_subfolder", testArchive, { if case .extractArchive(let p, let o) = $0 { return p == [testArchive] && o.isSmartExtract } else { return false } }),
            ("inspect_archive", testArchive, { if case .inspectArchive(let p) = $0 { return p == testArchive } else { return false } }),
            ("compute_hash", testArchive, { if case .verifyIntegrity(let p) = $0 { return p == testArchive } else { return false } }),
            ("autofill_password", testArchive, { if case .autofillVaultPassword(let p) = $0 { return p == testArchive } else { return false } }),
            ("compress_quick_zip", testFile, { if case .createArchive(let p, let o) = $0 { return p == [testFile] && o.targetFormat == .zip } else { return false } }),
            ("compress_quick_7z", testFile, { if case .createArchive(let p, let o) = $0 { return p == [testFile] && o.targetFormat == .sevenZip } else { return false } }),
            ("compress_separate", testFile, { if case .createArchive(let p, let o) = $0 { return p == [testFile] && o.separateArchives } else { return false } }),
            ("compress_and_delete_source", testFile, { if case .createArchive(let p, let o) = $0 { return p == [testFile] && o.deleteSourceAfterCompression } else { return false } }),
            ("compress_modal_advanced", testFile, { if case .createArchive(let p, _) = $0 { return p == [testFile] } else { return false } })
        ]
        
        for (actionType, path, validator) in expectations {
            let url = try XCTUnwrap(URL(string: "ttzip://action?type=\(actionType)&paths=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"))
            let envelope = try XCTUnwrap(AppIntentParser.parse(url: url), "Failed to parse action \(actionType)")
            XCTAssertTrue(validator(envelope.intent), "Action \(actionType) did not map to expected AppIntent payload")
        }
    }
    
    // MARK: - 3. Direct File URL Dropping / Opening
    
    func testDirectFileURLParsing() throws {
        let mockHarness = try MockFileURLHarness()
        defer { try? mockHarness.cleanup() }
        
        let zipURL = mockHarness.createFile(named: "package.zip")
        let dirURL = mockHarness.createDirectory(named: "ProjectFolder")
        let imgURL = mockHarness.createFile(named: "photo.jpg")
        
        let zipEnvelope = try XCTUnwrap(AppIntentParser.parse(url: zipURL))
        if case .openArchive(let url, _) = zipEnvelope.intent {
            XCTAssertEqual(url.path, zipURL.path)
        } else {
            XCTFail("Zip URL must map to openArchive")
        }
        
        let dirEnvelope = try XCTUnwrap(AppIntentParser.parse(url: dirURL))
        if case .createArchive(let paths, _) = dirEnvelope.intent {
            XCTAssertEqual(paths, [dirURL.path])
        } else {
            XCTFail("Directory URL must map to createArchive")
        }
        
        let imgEnvelope = try XCTUnwrap(AppIntentParser.parse(url: imgURL))
        if case .previewItem(let url) = imgEnvelope.intent {
            XCTAssertEqual(url.path, imgURL.path)
        } else {
            XCTFail("Image URL must map to previewItem")
        }
    }
    
    // MARK: - 4. Darwin Notification Language Synchronization
    
    func testDarwinNotificationLanguageSynchronization() throws {
        let darwinHarness = MockDarwinNotificationHarness(
            notificationName: TTZipPreferencesStore.darwinNotificationName
        )
        
        darwinHarness.startObserving {}
        
        // Trigger preference change
        TTZipPreferencesStore.saveLanguage(.zhHans)
        
        // Assert Darwin notification broadcast
        XCTAssertTrue(darwinHarness.waitForNotification(timeout: 1.0), "Darwin notification must be delivered immediately")
        XCTAssertEqual(TTZipPreferencesStore.getSavedLanguage(), .zhHans)
        
        darwinHarness.stopObserving()
    }
    
    // MARK: - 5. Batch File Selection App Group Spooling (100+ files)
    
    func testFinderSyncBatchSpoolJobWith100PlusFiles() throws {
        let mockHarness = try MockFileURLHarness()
        defer { try? mockHarness.cleanup() }
        
        // Create 120 mock files to simulate large multi-selection
        var mockPaths: [String] = []
        for i in 1...120 {
            let fileURL = mockHarness.createFile(named: "batch_item_\(i).txt").resolvingSymlinksInPath()
            mockPaths.append(fileURL.path)
        }
        XCTAssertEqual(mockPaths.count, 120)
        
        // 1. Spool job through AppGroupSpooler from TTZipFinderSync
        let jobId = try AppGroupSpooler.shared.spoolJob(
            action: "compress_quick_zip",
            paths: mockPaths
        )
        
        // 2. Construct compact URL with jobId token (simulating NSWorkspace.open)
        let urlString = "ttzip://action?type=compress_quick_zip&jobId=\(jobId.uuidString)"
        let url = try XCTUnwrap(URL(string: urlString))
        
        // 3. Verify URL string length is compact (< 100 bytes vs ~10KB)
        XCTAssertLessThan(urlString.count, 120, "Spooled URL must remain compact even with 100+ files")
        
        // 4. Parse incoming URL via AppIntentParser
        let envelope = try XCTUnwrap(AppIntentParser.parse(url: url))
        
        if case .createArchive(let paths, let options) = envelope.intent {
            XCTAssertEqual(paths.count, 120, "All 120 spooled file paths must be recovered")
            let normPaths = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            let normMock = mockPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            XCTAssertEqual(normPaths, normMock)
            XCTAssertEqual(options.targetFormat, .zip)
        } else {
            XCTFail("Parsed intent did not match .createArchive")
        }
        
        // 5. Verify the spool file was atomically consumed and removed from disk
        let consumedAgain = AppGroupSpoolManager.shared.consumeJob(id: jobId)
        XCTAssertNil(consumedAgain, "Spool job must be single-use and deleted upon consumption")
    }

    // MARK: - 6. Per-Value Compression Level Isolation (#417 / 4501520928)

    func testCompressIntentOptionsPreservesIndependentCompressionLevelsPerValue() throws {
        let firstURL = try XCTUnwrap(
            URL(string: "ttzip://action?type=compress_quick_7z&paths=/tmp/doc.txt&level=9")
        )
        let secondURL = try XCTUnwrap(
            URL(string: "ttzip://action?type=compress_quick_7z&paths=/tmp/doc.txt&level=1")
        )
        let thirdURL = try XCTUnwrap(
            URL(string: "ttzip://action?type=compress_quick_7z&paths=/tmp/doc.txt")
        )

        let firstEnv = try XCTUnwrap(AppIntentParser.parse(url: firstURL))
        let secondEnv = try XCTUnwrap(AppIntentParser.parse(url: secondURL))
        let thirdEnv = try XCTUnwrap(AppIntentParser.parse(url: thirdURL))

        guard case .createArchive(_, let firstOpts) = firstEnv.intent,
              case .createArchive(_, let secondOpts) = secondEnv.intent,
              case .createArchive(_, let thirdOpts) = thirdEnv.intent else {
            return XCTFail("Expected .createArchive intents")
        }

        XCTAssertEqual(firstOpts.compressionLevel, 9, "First parsed intent must retain level 9 after later parses")
        XCTAssertEqual(secondOpts.compressionLevel, 1, "Second parsed intent must retain level 1")
        XCTAssertNil(thirdOpts.compressionLevel, "Third parsed intent without level must remain nil")
        XCTAssertNotEqual(firstOpts, secondOpts)
        XCTAssertNotEqual(firstOpts, thirdOpts)
        let distinctSet: Set<CompressIntentOptions> = [firstOpts, secondOpts, thirdOpts]
        XCTAssertEqual(distinctSet.count, 3)
    }

    // MARK: - 7. Repair Output Path Preservation & TAR Directory Baseline Filtering (#417 / 4459041210, 4459041230, 4459041193)

    @MainActor
    func testRepairIntentPreservesRequestedOutputPathIntoIntegrityViewAndViewModel() async throws {
        let mockHarness = try MockFileURLHarness()
        defer { try? mockHarness.cleanup() }

        let tempDir = mockHarness.createDirectory(named: "repair_intent_test")
        let archivePath = mockHarness.createFile(named: "damaged_input.zip", content: "PK\u{03}\u{04}broken").path
        let requestedOutput = tempDir.appendingPathComponent("custom_repaired_target.zip").path

        let envelope = try XCTUnwrap(
            AppIntentParser.parse(arguments: ["TTZip", "--repair", archivePath, "--output", requestedOutput])
        )
        XCTAssertEqual(envelope.intent, AppIntent.repairArchive(archivePath: archivePath, outputPath: requestedOutput))

        let state = AppViewState()
        AppIntentDispatcher.shared.bind(state: state)
        defer { AppIntentDispatcher.shared.unregister(windowID: state.windowID) }

        let result = AppIntentDispatcher.shared.dispatch(envelope, targetWindowID: state.windowID)
        XCTAssertEqual(result, IntentDispatchResult.success)
        XCTAssertEqual(state.overlayState.integrityArchivePath, archivePath)
        XCTAssertEqual(state.overlayState.integrityRepairOutputPath, requestedOutput)

        state.overlayState.integrityRepairOutputPath = nil
        let appDelegate = AppDelegate(modelManager: .shared, registerAsShared: false)
        var bridgedURL: URL?
        let token = appDelegate.registerHandler { url in
            bridgedURL = url
            if let bridgedEnvelope = AppIntentParser.parse(url: url) {
                _ = AppIntentDispatcher.shared.dispatch(bridgedEnvelope, targetWindowID: state.windowID)
            }
        }
        defer { token.cancel() }
        _ = appDelegate.handleLaunchArguments(["TTZip", "--repair", archivePath, "--output", requestedOutput])
        XCTAssertEqual(state.overlayState.integrityRepairOutputPath, requestedOutput)
        let replayURL = try XCTUnwrap(bridgedURL)
        let replayedEnvelope = try XCTUnwrap(AppIntentParser.parse(url: replayURL))
        XCTAssertEqual(replayedEnvelope.intent, .repairArchive(archivePath: archivePath, outputPath: nil))

        let view = ArchiveIntegrityView(
            archivePath: archivePath,
            initialRepairOutputPath: state.overlayState.integrityRepairOutputPath
        )
        XCTAssertEqual(view.repairOutputPath, requestedOutput)

        let vm = ArchiveIntegrityViewModel(initialOutputPath: state.overlayState.integrityRepairOutputPath)
        XCTAssertEqual(vm.repairOutputPath, requestedOutput)
        await vm.runIntegrityCheck(archivePath: archivePath)
        XCTAssertEqual(
            vm.customOutputPath,
            requestedOutput,
            "runIntegrityCheck must preserve explicit initial repair output path instead of resetting to _repaired"
        )
    }

    @MainActor
    func testRepairUrlSchemeIgnoresUnauthenticatedOutputPathAndRequiresAuthorization() throws {
        let mockHarness = try MockFileURLHarness()
        defer { try? mockHarness.cleanup() }

        let rawURL = try XCTUnwrap(
            URL(string: "ttzip://action?type=repair&path=/tmp/damaged.zip&output=/tmp/untrusted_autoload.zip")
        )
        let parsedEnvelope = try XCTUnwrap(AppIntentParser.parse(url: rawURL))
        XCTAssertEqual(parsedEnvelope.source, .urlScheme)
        XCTAssertEqual(
            parsedEnvelope.intent,
            AppIntent.repairArchive(archivePath: "/tmp/damaged.zip", outputPath: nil)
        )

        let archivePath = mockHarness.createFile(named: "damaged_url.zip", content: "PK\u{03}\u{04}broken").path
        let untrustedDir = mockHarness.createDirectory(named: "untrusted_autoload_dir")
        let untrustedOutput = untrustedDir.appendingPathComponent("autoload_polyglot.zip").path

        let state = AppViewState()
        AppIntentDispatcher.shared.bind(state: state)
        defer { AppIntentDispatcher.shared.unregister(windowID: state.windowID) }

        let unauthenticatedEnvelope = AppIntentEnvelope(
            intent: .repairArchive(archivePath: archivePath, outputPath: untrustedOutput),
            source: .urlScheme
        )
        let unauthResult = AppIntentDispatcher.shared.dispatch(unauthenticatedEnvelope, targetWindowID: state.windowID)
        XCTAssertEqual(unauthResult, .success)
        XCTAssertEqual(state.overlayState.integrityArchivePath, archivePath)
        XCTAssertNil(state.overlayState.integrityRepairOutputPath)

        let authorizedDir = mockHarness.createDirectory(named: "authorized_repair_out")
        let authorizedOutput = authorizedDir.appendingPathComponent("repaired_authorized.zip").path
        let scope = SecurityScopedResourceScope()
        scope.add(authorizedDir, isSecurityScoped: false)
        let session = ActiveBookmarkSession(scope: scope)
        let authorizedEnvelope = AppIntentEnvelope(
            intent: .repairArchive(archivePath: archivePath, outputPath: authorizedOutput),
            source: .urlScheme,
            bookmarkSession: session
        )
        let authResult = AppIntentDispatcher.shared.dispatch(authorizedEnvelope, targetWindowID: state.windowID)
        XCTAssertEqual(authResult, .success)
        XCTAssertEqual(state.overlayState.integrityRepairOutputPath, authorizedOutput)
    }

    @MainActor
    func testTarRepairExcludesDirectoryHeadersWhenRecoverableFilesExist() async throws {
        let mockHarness = try MockFileURLHarness()
        defer { try? mockHarness.cleanup() }

        var tarData = Data()
        tarData.append(Self.makeUstarHeader(name: "nested/", size: 0, typeflag: UInt8(ascii: "5")))
        let payload = Data("Recovered file inside nested folder".utf8)
        tarData.append(Self.makeUstarHeader(name: "nested/hello.txt", size: payload.count, typeflag: UInt8(ascii: "0")))
        tarData.append(payload)
        let pad = (512 - (payload.count % 512)) % 512
        if pad > 0 {
            tarData.append(Data(repeating: 0, count: pad))
        }
        tarData.append(Data(repeating: 0x7F, count: 512))
        tarData.append(Data(repeating: 0, count: 1024))

        let tempDir = mockHarness.createDirectory(named: "tar_dir_header_test")
        let tarURL = tempDir.appendingPathComponent("with_dir_header.tar")
        try tarData.write(to: tarURL, options: .atomic)
        let customOutURL = tempDir.appendingPathComponent("repaired_dir_header.tar")

        let vm = ArchiveIntegrityViewModel(initialOutputPath: customOutURL.path)
        let outcome = try await vm.repairArchive(damagedPath: tarURL.path)
        guard case .fullSuccess(let outputPath, let count, let entries, _) = outcome else {
            return XCTFail("Expected .fullSuccess when directory header is present alongside recoverable file, got \(outcome)")
        }
        XCTAssertEqual(outputPath, customOutURL.path)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(entries, ["nested/hello.txt"])
    }

    private static func makeUstarHeader(name: String, size: Int, typeflag: UInt8) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        let nameBytes = Array(name.utf8.prefix(99))
        block.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        writeOctalField(typeflag == UInt8(ascii: "5") ? 0o755 : 0o644, into: &block, offset: 100, length: 8)
        writeOctalField(0, into: &block, offset: 108, length: 8)
        writeOctalField(0, into: &block, offset: 116, length: 8)
        writeOctalField(size, into: &block, offset: 124, length: 12)
        writeOctalField(1_700_000_000, into: &block, offset: 136, length: 12)
        for i in 148..<156 {
            block[i] = 0x20
        }
        block[156] = typeflag
        let magic = Array("ustar\000".utf8)
        block.replaceSubrange(257..<(257 + magic.count), with: magic)
        let checksum = block.reduce(0) { $0 + Int($1) }
        let chkBytes = Array(String(format: "%06o\0 ", checksum).utf8.prefix(8))
        block.replaceSubrange(148..<(148 + chkBytes.count), with: chkBytes)
        return Data(block)
    }

    private static func writeOctalField(_ value: Int, into block: inout [UInt8], offset: Int, length: Int) {
        let digits = max(1, length - 1)
        let bytes = Array(String(format: "%0*o", digits, value).utf8.prefix(digits))
        block.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
