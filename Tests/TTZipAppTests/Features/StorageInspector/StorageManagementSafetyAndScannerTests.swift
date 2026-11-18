// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import CryptoKit
import Darwin
import TTZipUI
@testable import TTZipApp
@testable import TTZipCore

@MainActor
final class StorageManagementSafetyAndScannerTests: XCTestCase {

    // MARK: - Helpers

    private func makeIsolatedSandbox(name: String = #function) throws -> URL {
        let sanitized = name.replacingOccurrences(of: "()", with: "")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipQ2_\(sanitized)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            // Restore permissions on any locked test subdirectories so cleanup succeeds cleanly
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let itemURL as URL in enumerator {
                    Darwin.chmod(itemURL.path, mode_t(0o755))
                }
            }
            Darwin.chmod(url.path, mode_t(0o755))
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func writeBytes(_ count: Int, byte: UInt8 = 0x5A, to fileURL: URL) throws -> String {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = Data(repeating: byte, count: count)
        try data.write(to: fileURL)
        return sha256Hex(of: fileURL)
    }

    private func sha256Hex(of fileURL: URL) -> String {
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 1. Accounting: Hidden Directories, Hard-Link Deduplication, Symlinks, Empty & Inaccessible Dirs

    func testScannerAccountingHardlinksSymlinksHiddenAndPermissions() throws {
        let root = try makeIsolatedSandbox()

        // 1. Regular file + hard link to the same inode (must be counted only ONCE)
        let fileA = root.appendingPathComponent("docs/report_a.txt")
        let fileB = root.appendingPathComponent("docs/report_b_hardlink.txt")
        _ = try writeBytes(16_384, byte: 0x41, to: fileA)
        XCTAssertEqual(Darwin.link(fileA.path, fileB.path), 0, "POSIX hard link creation must succeed")

        // 2. Hidden SwiftPM `.build` directory with sibling `Package.swift` (must be scanned and verified)
        let swiftPkg = root.appendingPathComponent("swift_pkg")
        _ = try writeBytes(128, byte: 0x23, to: swiftPkg.appendingPathComponent("Package.swift"))
        _ = try writeBytes(32_768, byte: 0x42, to: swiftPkg.appendingPathComponent(".build/debug/libApp.a"))

        // 3. Symlink pointing to an external directory (must NOT be followed, 0 bytes, never a candidate)
        let externalTarget = try makeIsolatedSandbox(name: "external_symlink_target")
        _ = try writeBytes(65_536, byte: 0x7F, to: externalTarget.appendingPathComponent("secret.bin"))
        let symlinkURL = root.appendingPathComponent("external_link")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: externalTarget)

        // 4. Empty directory
        let emptySubdir = root.appendingPathComponent("empty_folder")
        try FileManager.default.createDirectory(at: emptySubdir, withIntermediateDirectories: true)

        // 5. Unreadable subdirectory (chmod 000) when not running as root
        let lockedSubdir = root.appendingPathComponent("locked_vault")
        _ = try writeBytes(4_096, byte: 0x99, to: lockedSubdir.appendingPathComponent("inside.txt"))
        let isRootUser = (Darwin.geteuid() == 0)
        if !isRootUser {
            Darwin.chmod(lockedSubdir.path, mode_t(0o000))
        }

        let output = StorageDirectoryScanner.scanDirectory(rootURL: root)
        XCTAssertEqual(output.status, .completed)

        // Hardlink deduplication must record 1 duplicate hard link
        XCTAssertEqual(output.summary.deduplicatedHardLinks, 1, "Second hard link to same (st_dev, st_ino) must be deduplicated")
        XCTAssertEqual(output.summary.skippedSymlinks, 1, "Symlink must not be followed and must be counted as skipped symlink")

        // Logical bytes = 16,384 (report_a) + 128 (Package.swift) + 32,768 (libApp.a) = 49,280 (excluding locked dir)
        if !isRootUser {
            XCTAssertEqual(output.summary.logicalBytes, 49_280)
            XCTAssertEqual(output.summary.inaccessibleDirectories.count, 1)
        }

        // Hidden `.build` must be discovered as a verified candidate
        XCTAssertEqual(output.verifiedCandidates.count, 1)
        XCTAssertEqual(output.verifiedCandidates.first?.name, ".build")
        XCTAssertEqual(output.verifiedCandidates.first?.ruleKind, .swiftPMBuild)
    }

    // MARK: - 2. Candidate Verification Rules vs. Name-Only Matches & VCS Blockers

    func testCandidateEvidenceVerificationAndBlockers() throws {
        let root = try makeIsolatedSandbox()

        // Case A: Verified `node_modules` with sibling `package.json`
        let webApp = root.appendingPathComponent("web_app")
        _ = try writeBytes(64, to: webApp.appendingPathComponent("package.json"))
        _ = try writeBytes(8_192, to: webApp.appendingPathComponent("node_modules/pkg/index.js"))

        // Case B: Unverified `build` directory containing user documents (NO Gradle/CMake markers)
        let handWrittenBuild = root.appendingPathComponent("novel_project/build")
        _ = try writeBytes(12_288, to: handWrittenBuild.appendingPathComponent("chapter1_draft.md"))

        // Case C: `target` directory with Cargo.toml AND CACHEDIR.TAG (Verified)
        let rustCrate = root.appendingPathComponent("rust_crate")
        _ = try writeBytes(64, to: rustCrate.appendingPathComponent("Cargo.toml"))
        let cargoTag = (ForensicPathGuard.cacheDirTagSignature + "\n# Created by cargo\n").data(using: .utf8)!
        let targetDir = rustCrate.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try cargoTag.write(to: targetDir.appendingPathComponent("CACHEDIR.TAG"))
        _ = try writeBytes(16_384, to: targetDir.appendingPathComponent("debug/libfoo.rlib"))

        // Case D: `node_modules` that directly contains a `.git` repository (MUST BE BLOCKED)
        let forkedModules = root.appendingPathComponent("forked_app")
        _ = try writeBytes(64, to: forkedModules.appendingPathComponent("package.json"))
        try FileManager.default.createDirectory(
            at: forkedModules.appendingPathComponent("node_modules/.git"),
            withIntermediateDirectories: true
        )
        _ = try writeBytes(4_096, to: forkedModules.appendingPathComponent("node_modules/custom.js"))

        // Case E: `.log` and `.tmp` standalone files must NEVER become cleanup candidates
        _ = try writeBytes(4_096, to: root.appendingPathComponent("audit_trail.log"))
        _ = try writeBytes(4_096, to: root.appendingPathComponent("scratch.tmp"))

        let output = StorageDirectoryScanner.scanDirectory(rootURL: root)

        let verifiedPaths = Set(output.verifiedCandidates.map(\.path))
        let unverifiedPaths = Set(output.unverifiedCandidates.map(\.path))

        XCTAssertTrue(verifiedPaths.contains(webApp.appendingPathComponent("node_modules").resolvingSymlinksInPath().path))
        XCTAssertTrue(verifiedPaths.contains(targetDir.resolvingSymlinksInPath().path))
        XCTAssertEqual(output.verifiedCandidates.count, 2, "Only the 2 evidence-backed directories may be verified")

        XCTAssertTrue(
            unverifiedPaths.contains(handWrittenBuild.resolvingSymlinksInPath().path),
            "Name-only 'build' directory without Gradle/CMake evidence must be relegated to unverifiedItems"
        )
        XCTAssertFalse(
            verifiedPaths.contains(forkedModules.appendingPathComponent("node_modules").resolvingSymlinksInPath().path),
            "Directory containing .git must never be a verified candidate"
        )
    }

    // MARK: - 3. Pre-Cleanup Revalidation: Symlink Swap, Inode Swap, Parent Redirect, Same-Name Preservation & Neighbor Hash Invariance

    func testCleanupSafetyRevalidationAndNeighborHashPreservation() throws {
        let root = try makeIsolatedSandbox()

        // Neighbor source file at root and inside project_a
        let neighborRootFile = root.appendingPathComponent("README.md")
        let neighborRootHash = try writeBytes(4_096, byte: 0x11, to: neighborRootFile)

        // Project A: verified node_modules (will be selected and trashed)
        let projA = root.appendingPathComponent("project_a")
        let projASource = projA.appendingPathComponent("src/main.ts")
        let projASourceHash = try writeBytes(2_048, byte: 0x22, to: projASource)
        _ = try writeBytes(64, byte: 0x23, to: projA.appendingPathComponent("package.json"))
        _ = try writeBytes(8_192, byte: 0x24, to: projA.appendingPathComponent("node_modules/a.js"))

        // Project B: another verified node_modules with the SAME NAME (`node_modules`) that is NOT selected
        let projB = root.appendingPathComponent("project_b")
        _ = try writeBytes(64, byte: 0x33, to: projB.appendingPathComponent("package.json"))
        let projBModuleFile = projB.appendingPathComponent("node_modules/b.js")
        let projBModuleHash = try writeBytes(8_192, byte: 0x34, to: projBModuleFile)

        // Project C: verified node_modules that gets REPLACED BY A SYMLINK after scan (TOCTOU attack)
        let projC = root.appendingPathComponent("project_c")
        _ = try writeBytes(64, byte: 0x44, to: projC.appendingPathComponent("package.json"))
        let projCNodeModules = projC.appendingPathComponent("node_modules")
        _ = try writeBytes(8_192, byte: 0x45, to: projCNodeModules.appendingPathComponent("c.js"))

        // Project D: verified node_modules that gets deleted and recreated with a NEW INODE containing source code after scan
        let projD = root.appendingPathComponent("project_d")
        _ = try writeBytes(64, byte: 0x55, to: projD.appendingPathComponent("package.json"))
        let projDNodeModules = projD.appendingPathComponent("node_modules")
        _ = try writeBytes(8_192, byte: 0x56, to: projDNodeModules.appendingPathComponent("d.js"))

        // Isolated trash bin directory inside sandbox (never touches user's real ~/.Trash)
        let fakeTrashDir = try makeIsolatedSandbox(name: "isolated_trash_bin")
        let vm = StorageInspectorViewModel(
            initialDirectory: root,
            trashHandler: { url in
                let dest = fakeTrashDir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            }
        )

        vm.performSynchronousScan()
        XCTAssertEqual(vm.reclaimableItems.count, 4)

        // Simulate post-scan TOCTOU mutations on Project C (symlink swap) and Project D (inode replacement)
        try FileManager.default.removeItem(at: projCNodeModules)
        try FileManager.default.createSymbolicLink(at: projCNodeModules, withDestinationURL: projB)

        try FileManager.default.removeItem(at: projDNodeModules)
        // Create dummy file first so allocator assigns a fresh inode to the recreated directory
        let bumpInodeURL = projD.appendingPathComponent(".inode_bump")
        _ = try writeBytes(16, byte: 0xAA, to: bumpInodeURL)
        let preciousFileInD = projDNodeModules.appendingPathComponent("precious_user_file.txt")
        let preciousHash = try writeBytes(1_024, byte: 0x99, to: preciousFileInD)

        // Select Project A, Project C (symlink swapped), and Project D (inode replaced), leaving Project B unselected
        for item in vm.reclaimableItems where !item.path.contains("/project_b/") {
            vm.toggleCandidateSelection(item)
        }
        XCTAssertEqual(vm.selectedCandidates.count, 3)

        let report = vm.trashSelectedCandidates(rescanAfter: false)

        // Project A must be trashed; Project C and Project D must be rejected!
        XCTAssertEqual(report.trashedCount, 1)
        XCTAssertEqual(report.rejectedOrFailedCount, 2)

        // Verify neighbor hashes and unselected same-name `project_b/node_modules` are 100% intact
        XCTAssertEqual(sha256Hex(of: neighborRootFile), neighborRootHash, "Root neighbor file hash must be unchanged")
        XCTAssertEqual(sha256Hex(of: projASource), projASourceHash, "Sibling source file hash must be unchanged")
        XCTAssertEqual(sha256Hex(of: projBModuleFile), projBModuleHash, "Unselected same-name node_modules in project_b must remain untouched")
        XCTAssertEqual(sha256Hex(of: preciousFileInD), preciousHash, "Inode-replaced directory must be blocked from deletion")

        // Verify Project B's tile in vm.tiles was NOT removed by same-name matching
        let remainingTilePaths = Set(vm.tiles.map(\.relativePath))
        XCTAssertTrue(
            remainingTilePaths.contains(projB.resolvingSymlinksInPath().path),
            "Same-name tile removal bug regression: unrelated directory tile must remain"
        )
    }

    // MARK: - 4. Overlapping Parent/Child Candidates Deduplication

    func testOverlappingParentAndChildCandidatesDeduplication() throws {
        let root = try makeIsolatedSandbox()
        let parentURL = root.appendingPathComponent("workspace/node_modules")
        let childURL = parentURL.appendingPathComponent("nested_pkg/node_modules")
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)

        let parentItem = ReclaimableStorageItem(
            name: "node_modules",
            url: parentURL,
            sizeBytes: 100_000,
            reason: "Parent cache",
            ruleKind: .nodeModules,
            verification: .verified,
            scanRootPath: root.path
        )
        let childItem = ReclaimableStorageItem(
            name: "node_modules",
            url: childURL,
            sizeBytes: 40_000,
            reason: "Nested cache",
            ruleKind: .nodeModules,
            verification: .verified,
            scanRootPath: root.path
        )

        let (kept, covered) = StorageInspectorViewModel.deduplicateOverlappingAncestors([childItem, parentItem])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.path, parentURL.path)
        XCTAssertEqual(covered.count, 1)
        XCTAssertEqual(covered.first?.item.path, childURL.path)
        XCTAssertEqual(covered.first?.parentPath, parentURL.path)
    }

    // MARK: - 5. Scan -> Cancel -> Switch Directory -> Rescan (Stop Actual Enumeration & Generation Isolation)

    func testScanCancelSwitchDirectoryStopsEnumerationAndPreventsStaleOverwrite() async throws {
        let slowDir = try makeIsolatedSandbox(name: "slow_dir")
        for idx in 0..<40 {
            _ = try writeBytes(512, to: slowDir.appendingPathComponent("file_\(idx).txt"))
        }

        let fastDir = try makeIsolatedSandbox(name: "fast_dir")
        _ = try writeBytes(24_576, byte: 0x77, to: fastDir.appendingPathComponent("only_in_fast.bin"))

        // 1. Verify cooperative cancellation token stops actual directory enumeration mid-flight
        let token = StorageScanCancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) {
            token.cancel()
        }

        let cancelledOut = StorageDirectoryScanner.scanDirectory(
            rootURL: slowDir,
            cancelToken: token,
            perEntryDelayNanoseconds: 5_000_000 // 5ms per entry -> 40 entries would take 200ms if not stopped
        )
        XCTAssertEqual(cancelledOut.status, .cancelled, "Scanner must stop enumeration immediately when token is cancelled")

        // 2. Repeated "Scan -> Cancel -> Switch Directory -> Rescan" on ViewModel
        let vm = StorageInspectorViewModel(initialDirectory: slowDir)
        for _ in 0..<3 {
            vm.testPerEntryDelayNanoseconds = 4_000_000
            vm.setDirectory(slowDir)
            try await Task.sleep(nanoseconds: 15_000_000)
            vm.cancelScan()
            XCTAssertEqual(vm.state, .cancelled)

            vm.testPerEntryDelayNanoseconds = 0
            vm.setDirectory(fastDir)
            // Wait for fastDir scan task to finish
            for _ in 0..<50 {
                if case .completed = vm.state { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            XCTAssertEqual(vm.selectedDirectory.resolvingSymlinksInPath().path, fastDir.resolvingSymlinksInPath().path)
            XCTAssertEqual(vm.tiles.count, 1)
            XCTAssertEqual(vm.tiles.first?.name, "only_in_fast.bin")
        }
    }

    // MARK: - 6. Terminal States (Empty, Permission Denied, Completed) & Localization Keys

    func testTerminalStatesAndStorageLocaleKeyCompleteness() throws {
        let emptyDir = try makeIsolatedSandbox(name: "empty_root")
        let vm = StorageInspectorViewModel(initialDirectory: emptyDir)
        let out = vm.performSynchronousScan()
        XCTAssertEqual(out.status, .empty)
        XCTAssertEqual(vm.state, .empty(rootPath: emptyDir.resolvingSymlinksInPath().path))

        // Every StorageLocaleKey must provide non-empty zh-Hans, zh-Hant, and en translations
        for key in StorageLocaleKey.allCases {
            let en = key.resolve(for: .en)
            let zhHans = key.resolve(for: .zhHans)
            let zhHant = key.resolve(for: .zhHant)
            XCTAssertFalse(en.isEmpty, "English translation missing for \(key)")
            XCTAssertFalse(zhHans.isEmpty, "Simplified Chinese translation missing for \(key)")
            XCTAssertFalse(zhHant.isEmpty, "Traditional Chinese translation missing for \(key)")
            XCTAssertNotEqual(en, key.rawKey)
            XCTAssertNotEqual(zhHans, key.rawKey)
        }
    }

    // MARK: - 7. Deep Candidate Subtree Protection (node_modules/vendor/project/.git, Budget & Cancellation)

    func testDeepSubtreeProtectionBlocksNestedGitAndIncompleteSubtree() throws {
        let root = try makeIsolatedSandbox()
        let fakeTrash = try makeIsolatedSandbox(name: "subtree_trash")

        // Create sibling package.json + node_modules/vendor/project/.git and regular dependencies
        let pkgJSON = root.appendingPathComponent("package.json")
        let pkgJSONHash = try writeBytes(64, byte: 0x10, to: pkgJSON)
        let neighborSrc = root.appendingPathComponent("src/index.ts")
        let neighborSrcHash = try writeBytes(1_024, byte: 0x20, to: neighborSrc)

        let nmRoot = root.appendingPathComponent("node_modules")
        let regularDepFile = nmRoot.appendingPathComponent("lodash/index.js")
        let regularDepHash = try writeBytes(4_096, byte: 0x30, to: regularDepFile)
        let nestedGitHead = nmRoot.appendingPathComponent("vendor/project/.git/HEAD")
        let nestedGitHeadHash = try writeBytes(48, byte: 0x40, to: nestedGitHead)
        let nestedVendorSrc = nmRoot.appendingPathComponent("vendor/project/src/main.rs")
        let nestedVendorSrcHash = try writeBytes(2_048, byte: 0x50, to: nestedVendorSrc)

        // 1. Scan must detect deep `.git` inside `node_modules/vendor/project/.git` and refuse `.verified` status
        let scanOut = StorageDirectoryScanner.scanDirectory(rootURL: root)
        XCTAssertTrue(
            scanOut.verifiedCandidates.isEmpty,
            "node_modules containing deep vendor/project/.git must NEVER be marked as a verified candidate"
        )
        XCTAssertEqual(scanOut.unverifiedCandidates.count, 1)
        XCTAssertEqual(scanOut.unverifiedCandidates.first?.verification, .nameOnly)

        // 2. Even if `.git` is injected AFTER scan (or a verified item is forced into cleanup), pre-trash gate must reject the entire node_modules
        try FileManager.default.removeItem(at: nmRoot.appendingPathComponent("vendor/project/.git"))
        let vm = StorageInspectorViewModel(
            initialDirectory: root,
            trashHandler: { url in
                let dest = fakeTrash.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            }
        )
        vm.performSynchronousScan()
        XCTAssertEqual(vm.reclaimableItems.count, 1, "Without .git, node_modules is verified")

        // Re-create deep `node_modules/vendor/project/.git/HEAD` after scan before cleanup
        let postScanGitHash = try writeBytes(48, byte: 0x40, to: nestedGitHead)
        XCTAssertEqual(postScanGitHash, nestedGitHeadHash)

        vm.selectAllVerifiedCandidates()
        let report = vm.trashSelectedCandidates(rescanAfter: false)
        XCTAssertEqual(report.trashedCount, 0, "Entire candidate must be rejected when deep .git exists")
        XCTAssertEqual(report.rejectedOrFailedCount, 1)
        XCTAssertEqual(report.records.first?.outcome, .rejected(.subtreeContainsProtectedContent))

        // Verify ALL file hashes (neighbor, regular dep inside node_modules, vendor source, and .git/HEAD) are unchanged
        XCTAssertEqual(sha256Hex(of: pkgJSON), pkgJSONHash)
        XCTAssertEqual(sha256Hex(of: neighborSrc), neighborSrcHash)
        XCTAssertEqual(sha256Hex(of: regularDepFile), regularDepHash)
        XCTAssertEqual(sha256Hex(of: nestedGitHead), nestedGitHeadHash)
        XCTAssertEqual(sha256Hex(of: nestedVendorSrc), nestedVendorSrcHash)

        // 3. Subtree inspection budget exhaustion & cancellation must block cleanup (.subtreeInspectionIncomplete)
        try FileManager.default.removeItem(at: nmRoot.appendingPathComponent("vendor/project/.git"))
        for idx in 0..<15 {
            _ = try writeBytes(128, byte: UInt8(idx + 1), to: nmRoot.appendingPathComponent("pkg_\(idx)/index.js"))
        }
        vm.performSynchronousScan()
        XCTAssertEqual(vm.reclaimableItems.count, 1)

        // Set subtree inspection budget smaller than the candidate subtree entry count
        vm.maxSubtreeInspectionEntries = 4
        vm.selectAllVerifiedCandidates()
        let budgetReport = vm.trashSelectedCandidates(rescanAfter: false)
        XCTAssertEqual(budgetReport.trashedCount, 0, "Incomplete subtree inspection (budget exceeded) must block cleanup")
        XCTAssertEqual(budgetReport.records.first?.outcome, .rejected(.subtreeInspectionIncomplete))
        XCTAssertEqual(sha256Hex(of: regularDepFile), regularDepHash)

        // Pre-cancelled token during subtree inspection must return .incomplete
        let preCancelled = StorageScanCancelToken()
        preCancelled.cancel()
        let cancelCheck = ForensicPathGuard.inspectCandidateSubtreeSafety(
            atPath: nmRoot.path,
            cancelToken: preCancelled,
            maxEntries: 10_000
        )
        if case .incomplete = cancelCheck {
            // Expected
        } else {
            XCTFail("Cancelled subtree safety inspection must return .incomplete, got \(cancelCheck)")
        }
    }

    // MARK: - 8. Background Async Cleanup: Slow Trash, Duplicate Submission, Partial Failure & Mid-Cleanup Directory Switch

    func testBackgroundAsyncCleanupSlowTrashDuplicateClickDirectorySwitchAndPartialFailure() async throws {
        let root = try makeIsolatedSandbox()
        let otherRoot = try makeIsolatedSandbox(name: "other_switch_root")
        _ = try writeBytes(4_096, byte: 0x7E, to: otherRoot.appendingPathComponent("other_file.bin"))
        let fakeTrash = try makeIsolatedSandbox(name: "async_trash")

        for idx in 1...3 {
            let proj = root.appendingPathComponent("proj_\(idx)")
            _ = try writeBytes(64, to: proj.appendingPathComponent("package.json"))
            _ = try writeBytes(4_096, byte: UInt8(0x10 * idx), to: proj.appendingPathComponent("node_modules/mod_\(idx).js"))
        }

        // Part A: Slow trash + partial failure + duplicate click rejection while isCleaning == true
        let vm = StorageInspectorViewModel(
            initialDirectory: root,
            trashHandler: { url in
                Thread.sleep(forTimeInterval: 0.035)
                if url.path.contains("proj_2") {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [
                        NSLocalizedDescriptionKey: "Simulated permission error on proj_2"
                    ])
                }
                let dest = fakeTrash.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            }
        )
        vm.performSynchronousScan()
        XCTAssertEqual(vm.reclaimableItems.count, 3)
        vm.selectAllVerifiedCandidates()

        let firstTask = vm.startCleanupSelected(rescanAfter: false)
        XCTAssertNotNil(firstTask, "First cleanup submission must launch background task")
        XCTAssertTrue(vm.isCleaning, "ViewModel must immediately enter isCleaning state")

        // Duplicate click while isCleaning is true must be rejected
        let duplicateTask = vm.startCleanupSelected(rescanAfter: false)
        XCTAssertNil(duplicateTask, "Repeated cleanup click while isCleaning == true must return nil")

        let partialReport = await firstTask!.value
        XCTAssertFalse(vm.isCleaning, "isCleaning must reset to false upon completion")
        XCTAssertEqual(partialReport.trashedCount, 2)
        XCTAssertEqual(partialReport.rejectedOrFailedCount, 1)
        XCTAssertNotNil(vm.statusAlertMessage, "Partial failure must surface statusAlertMessage")

        // Part B: Mid-cleanup directory switch cancels remaining items without deleting them
        let rootSwitch = try makeIsolatedSandbox(name: "cleanup_switch_src")
        var itemHashes: [URL: String] = [:]
        for idx in 1...3 {
            let proj = rootSwitch.appendingPathComponent("app_\(idx)")
            _ = try writeBytes(64, to: proj.appendingPathComponent("package.json"))
            let modFile = proj.appendingPathComponent("node_modules/lib_\(idx).js")
            itemHashes[modFile] = try writeBytes(4_096, byte: UInt8(0x20 + idx), to: modFile)
        }

        let vmSwitch = StorageInspectorViewModel(
            initialDirectory: rootSwitch,
            trashHandler: { url in
                Thread.sleep(forTimeInterval: 0.06)
                let dest = fakeTrash.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            }
        )
        vmSwitch.performSynchronousScan()
        XCTAssertEqual(vmSwitch.reclaimableItems.count, 3)
        vmSwitch.selectAllVerifiedCandidates()

        let switchCleanupTask = vmSwitch.startCleanupSelected(rescanAfter: false)
        XCTAssertNotNil(switchCleanupTask)

        // Wait briefly so item 1 enters trashHandler, then switch directory to `otherRoot`
        try await Task.sleep(nanoseconds: 20_000_000)
        vmSwitch.setDirectory(otherRoot)

        let cancelledReport = await switchCleanupTask!.value
        XCTAssertGreaterThanOrEqual(cancelledReport.cancelledCount, 1, "Remaining items after directory switch must be cancelled")
        XCTAssertLessThan(cancelledReport.trashedCount, 3, "Cancelled cleanup must not trash all items")
        XCTAssertNil(vmSwitch.lastCleanupReport, "Stale cleanup from old directory must not overwrite active lastCleanupReport")
        XCTAssertNotNil(
            vmSwitch.cleanupReportsByGeneration[cancelledReport.cleanupGeneration],
            "Old task report must be archived by its cleanup generation"
        )

        // Any item recorded as .cancelled must still exist on disk with its original SHA-256 hash
        for record in cancelledReport.records where record.outcome == .cancelled {
            let dirURL = URL(fileURLWithPath: record.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dirURL.path), "Cancelled item \(record.path) must remain on disk")
        }
        for (fileURL, expectedHash) in itemHashes where FileManager.default.fileExists(atPath: fileURL.path) {
            XCTAssertEqual(sha256Hex(of: fileURL), expectedHash)
        }
    }

    // MARK: - 8b. Stale Cleanup Generation Isolation (A -> B New Task & A -> B -> A Rescan / Recreated Inode)

    private nonisolated static func awaitSemaphore(_ sem: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = sem.wait(timeout: .now() + 5.0)
                continuation.resume()
            }
        }
    }

    func testStaleCleanupIsolationAcrossDirectorySwitchAndABARescanNewInode() async throws {
        let dirA = try makeIsolatedSandbox(name: "stale_iso_A")
        let dirB = try makeIsolatedSandbox(name: "stale_iso_B")
        let fakeTrash = try makeIsolatedSandbox(name: "stale_iso_trash")

        for idx in 1...2 {
            let projA = dirA.appendingPathComponent("projA_\(idx)")
            _ = try writeBytes(64, to: projA.appendingPathComponent("package.json"))
            _ = try writeBytes(4_096 * idx, byte: UInt8(0x30 + idx), to: projA.appendingPathComponent("node_modules/a_\(idx).js"))
        }
        let projB = dirB.appendingPathComponent("projB_1")
        _ = try writeBytes(64, to: projB.appendingPathComponent("package.json"))
        _ = try writeBytes(4_096, byte: 0x41, to: projB.appendingPathComponent("node_modules/b_1.js"))

        let enteredTrashSem = DispatchSemaphore(value: 0)
        let releaseTrashSem = DispatchSemaphore(value: 0)

        let vm = StorageInspectorViewModel(
            initialDirectory: dirA,
            trashHandler: { url in
                let dest = fakeTrash.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: dest)
                if url.path.contains("projA_") {
                    enteredTrashSem.signal()
                    _ = releaseTrashSem.wait(timeout: .now() + 5.0)
                }
                return dest
            }
        )

        // 1. Slow cleanup on A -> switch to B -> run new task on B -> old task A finishes
        vm.performSynchronousScan()
        vm.selectAllVerifiedCandidates()
        let slowTaskA1 = try XCTUnwrap(vm.startCleanupSelected(rescanAfter: false))
        await Self.awaitSemaphore(enteredTrashSem)

        vm.setDirectory(dirB)
        vm.performSynchronousScan()
        vm.selectAllVerifiedCandidates()
        let reportB = vm.trashSelectedCandidates(rescanAfter: false)
        XCTAssertEqual(reportB.trashedCount, 1)

        releaseTrashSem.signal()
        let staleReportA1 = await slowTaskA1.value
        XCTAssertEqual(staleReportA1.trashedCount, 1)
        XCTAssertEqual(staleReportA1.cancelledCount, 1)
        XCTAssertEqual(vm.lastCleanupReport?.cleanupGeneration, reportB.cleanupGeneration)
        XCTAssertEqual(vm.cleanupReportsByGeneration[staleReportA1.cleanupGeneration]?.rootPath, dirA.resolvingSymlinksInPath().path)

        // 2. A -> B -> A + recreate same-path entry with new inode + rescan A before old slow cleanup finishes
        let firstNM = dirA.appendingPathComponent("projA_1/node_modules")
        _ = try writeBytes(8_192, byte: 0x51, to: firstNM.appendingPathComponent("a_1.js"))

        vm.setDirectory(dirA)
        vm.performSynchronousScan()
        XCTAssertEqual(vm.reclaimableItems.count, 2)
        let originalIdentity = try XCTUnwrap(vm.reclaimableItems.first(where: { $0.path.hasSuffix("projA_1/node_modules") })).identity

        vm.selectAllVerifiedCandidates()
        let slowTaskA2 = try XCTUnwrap(vm.startCleanupSelected(rescanAfter: false))
        await Self.awaitSemaphore(enteredTrashSem)

        // Item 1 (projA_1/node_modules) is now in fakeTrash; switch A -> B -> A, recreate projA_1/node_modules with new inode, and rescan A
        vm.setDirectory(dirB)
        vm.setDirectory(dirA)
        _ = try writeBytes(32, byte: 0xAA, to: dirA.appendingPathComponent(".inode_bump"))
        _ = try writeBytes(8_192, byte: 0x66, to: firstNM.appendingPathComponent("recreated_fresh.js"))
        vm.performSynchronousScan()

        let newRecreatedItem = try XCTUnwrap(vm.reclaimableItems.first(where: { $0.path.hasSuffix("projA_1/node_modules") }))
        XCTAssertNotEqual(newRecreatedItem.identity, originalIdentity, "Recreated same-path entry must have a new inode identity")

        releaseTrashSem.signal()
        let staleReportA2 = await slowTaskA2.value
        XCTAssertEqual(staleReportA2.trashedCount, 1, "First item in A2 completed trash move before cancellation")
        XCTAssertEqual(staleReportA2.cancelledCount, 1, "Second item in A2 was cooperatively cancelled")
        XCTAssertNil(vm.lastCleanupReport, "Stale task A2 must not write lastCleanupReport into rescanned A session")
        XCTAssertTrue(vm.reclaimableItems.contains(where: { $0.identity == newRecreatedItem.identity }))
        XCTAssertNotNil(vm.cleanupReportsByGeneration[staleReportA2.cleanupGeneration])
    }

    // MARK: - 9. Treemap Strict Allocated-Only Sizing (Zero-Block Sparse File + Hard Links + Regular Files)

    func testZeroAllocatedSparseFileHardlinksAndRegularFileTreemapConsistency() throws {
        let root = try makeIsolatedSandbox()

        // 1. Create a 1 MiB zero-allocated sparse file via open + ftruncate
        let sparseURL = root.appendingPathComponent("sparse_zero.bin")
        let fd = Darwin.open(sparseURL.path, O_CREAT | O_TRUNC | O_RDWR, mode_t(0o644))
        XCTAssertGreaterThanOrEqual(fd, 0, "Must open sparse test file")
        XCTAssertEqual(Darwin.ftruncate(fd, off_t(1_048_576)), 0, "ftruncate to 1 MiB must succeed")
        Darwin.close(fd)

        var sparseStat = Darwin.stat()
        XCTAssertEqual(Darwin.lstat(sparseURL.path, &sparseStat), 0)
        XCTAssertEqual(sparseStat.st_size, 1_048_576)
        XCTAssertEqual(sparseStat.st_blocks, 0, "Unwritten ftruncated file on APFS must have 0 allocated blocks")

        // 2. Hard-linked pair (32 KiB logical, counted once)
        let hardA = root.appendingPathComponent("hardlink_a.dat")
        let hardB = root.appendingPathComponent("hardlink_b.dat")
        _ = try writeBytes(32_768, byte: 0x61, to: hardA)
        XCTAssertEqual(Darwin.link(hardA.path, hardB.path), 0)

        // 3. Regular file (16 KiB)
        let regularURL = root.appendingPathComponent("regular.bin")
        _ = try writeBytes(16_384, byte: 0x62, to: regularURL)

        let output = StorageDirectoryScanner.scanDirectory(rootURL: root)
        XCTAssertEqual(output.status, .completed)
        XCTAssertEqual(output.summary.deduplicatedHardLinks, 1)
        XCTAssertEqual(output.summary.logicalBytes, 1_048_576 + 32_768 + 16_384)

        // Sparse file with 0 allocated blocks MUST NOT fall back to logicalBytes or produce a huge tile
        XCTAssertFalse(
            output.tiles.contains(where: { $0.name == "sparse_zero.bin" }),
            "Zero-allocated sparse file must not be drawn as a Treemap tile"
        )
        let tileBytesSum = output.tiles.reduce(0 as UInt64) { $0 &+ $1.bytes }
        XCTAssertEqual(
            tileBytesSum,
            output.summary.allocatedBytes,
            "Treemap tile bytes must strictly equal summary.allocatedBytes without mixing logicalBytes"
        )
    }

    // MARK: - 10. Streaming readdir Budget Enforcement ("Small Budget + Large Directory")

    func testStreamingReaddirBudgetEnforcedInRootAndSubdirectory() throws {
        // Case A: Root directory with 50 files scanned with maxVisitedEntries = 6
        let largeRoot = try makeIsolatedSandbox(name: "large_root_budget")
        for idx in 0..<50 {
            _ = try writeBytes(512, byte: UInt8(idx % 200), to: largeRoot.appendingPathComponent("root_file_\(idx).dat"))
        }

        let rootOut = StorageDirectoryScanner.scanDirectory(rootURL: largeRoot, maxVisitedEntries: 6)
        XCTAssertEqual(rootOut.status, .completed)
        XCTAssertTrue(rootOut.summary.isTruncated, "Root readdir exceeding maxVisitedEntries must set isTruncated = true")
        XCTAssertLessThanOrEqual(
            rootOut.summary.scannedFiles + rootOut.summary.scannedDirectories,
            6,
            "Scanner must enforce budget during readdir and visit at most maxVisitedEntries"
        )

        // Case B: Candidate subdirectory with 50 files scanned with maxVisitedEntries = 8
        let nestedRoot = try makeIsolatedSandbox(name: "nested_subdir_budget")
        _ = try writeBytes(64, to: nestedRoot.appendingPathComponent("package.json"))
        let nmDir = nestedRoot.appendingPathComponent("node_modules")
        for idx in 0..<50 {
            _ = try writeBytes(512, to: nmDir.appendingPathComponent("dep_\(idx).js"))
        }

        let nestedOut = StorageDirectoryScanner.scanDirectory(rootURL: nestedRoot, maxVisitedEntries: 8)
        XCTAssertEqual(nestedOut.status, .completed)
        XCTAssertTrue(nestedOut.summary.isTruncated, "Subdirectory readdir exceeding budget must set isTruncated = true")
        XCTAssertLessThanOrEqual(nestedOut.summary.scannedFiles + nestedOut.summary.scannedDirectories, 8)
        XCTAssertTrue(
            nestedOut.verifiedCandidates.isEmpty,
            "Candidate whose subtree traversal was truncated by budget must NOT be marked verified"
        )
    }

    // MARK: - 11. Cargo Target Rule Alignment & Multi-Window ViewModel Instance Isolation

    func testCargoEvidenceAlignmentAndMultiWindowViewModelIsolation() throws {
        let root1 = try makeIsolatedSandbox(name: "cargo_window1")
        let root2 = try makeIsolatedSandbox(name: "cargo_window2")

        // Window 1:
        // (a) Rust crate with Cargo.toml + target/debug/deps + target/debug/.fingerprint (verified)
        let validCrate = root1.appendingPathComponent("valid_crate")
        _ = try writeBytes(64, to: validCrate.appendingPathComponent("Cargo.toml"))
        try FileManager.default.createDirectory(at: validCrate.appendingPathComponent("target/debug/deps"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: validCrate.appendingPathComponent("target/debug/.fingerprint"), withIntermediateDirectories: true)
        _ = try writeBytes(8_192, to: validCrate.appendingPathComponent("target/debug/deps/libapp.rlib"))

        // (b) Rust crate with Cargo.toml + target/debug containing ONLY ordinary notes (MUST be rejected as .nameOnly!)
        let notesOnlyCrate = root1.appendingPathComponent("notes_only_crate")
        _ = try writeBytes(64, to: notesOnlyCrate.appendingPathComponent("Cargo.toml"))
        let notesFile = notesOnlyCrate.appendingPathComponent("target/debug/design_notes.md")
        let notesHash = try writeBytes(4_096, byte: 0x4E, to: notesFile)

        // Window 2:
        // (a) Rust crate with Cargo.toml + target/release/deps + target/release/.cargo-lock (verified)
        let releaseCrate = root2.appendingPathComponent("release_crate")
        _ = try writeBytes(64, to: releaseCrate.appendingPathComponent("Cargo.toml"))
        try FileManager.default.createDirectory(at: releaseCrate.appendingPathComponent("target/release/deps"), withIntermediateDirectories: true)
        _ = try writeBytes(16, to: releaseCrate.appendingPathComponent("target/release/.cargo-lock"))
        _ = try writeBytes(16_384, to: releaseCrate.appendingPathComponent("target/release/bin_out"))

        // (b) Rust crate with real Cargo markers but nested .git inside target (blocked -> unverified)
        let dirtyCrate = root2.appendingPathComponent("dirty_crate")
        _ = try writeBytes(64, to: dirtyCrate.appendingPathComponent("Cargo.toml"))
        try FileManager.default.createDirectory(at: dirtyCrate.appendingPathComponent("target/debug/deps"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirtyCrate.appendingPathComponent("target/debug/.fingerprint"), withIntermediateDirectories: true)
        _ = try writeBytes(32, to: dirtyCrate.appendingPathComponent("target/vendor/sub/.git/HEAD"))

        let vmWindow1 = StorageInspectorViewModel(initialDirectory: root1)
        let vmWindow2 = StorageInspectorViewModel(initialDirectory: root2)

        vmWindow1.performSynchronousScan()
        vmWindow2.performSynchronousScan()

        XCTAssertEqual(vmWindow1.reclaimableItems.count, 1, "Only valid_crate/target with real Cargo artifacts may be verified")
        XCTAssertEqual(
            vmWindow1.reclaimableItems.first?.path,
            validCrate.appendingPathComponent("target").resolvingSymlinksInPath().path
        )
        XCTAssertEqual(vmWindow1.unverifiedItems.count, 1, "Cargo.toml + target/debug with only ordinary notes must be rejected to unverifiedItems")
        XCTAssertEqual(
            vmWindow1.unverifiedItems.first?.path,
            notesOnlyCrate.appendingPathComponent("target").resolvingSymlinksInPath().path
        )

        // Pre-cleanup revalidation must also enforce the tightened Cargo rule if build markers disappear after scan
        let verifiedTargetItem = try XCTUnwrap(vmWindow1.reclaimableItems.first)
        try FileManager.default.removeItem(at: validCrate.appendingPathComponent("target/debug/deps"))
        let rejection = ForensicPathGuard.revalidateBeforeTrash(
            item: verifiedTargetItem,
            authorizedScanRootPath: root1.path
        )
        XCTAssertEqual(rejection, .evidenceNoLongerValid, "Removing deps/ must cause revalidateBeforeTrash to reject target")
        XCTAssertEqual(sha256Hex(of: notesFile), notesHash, "Ordinary notes inside target/debug must remain untouched")

        XCTAssertEqual(vmWindow2.reclaimableItems.count, 1)
        XCTAssertEqual(
            vmWindow2.reclaimableItems.first?.path,
            releaseCrate.appendingPathComponent("target").resolvingSymlinksInPath().path
        )
        XCTAssertEqual(vmWindow2.unverifiedItems.count, 1, "dirty_crate/target with nested .git must be downgraded to unverified")

        // Cancelling or mutating Window 1 must have zero effect on Window 2
        vmWindow1.selectAllVerifiedCandidates()
        vmWindow1.cancelScan()
        XCTAssertTrue(vmWindow2.selectedCandidateIds.isEmpty)
        XCTAssertEqual(vmWindow2.selectedDirectory.resolvingSymlinksInPath().path, root2.resolvingSymlinksInPath().path)
    }
}

