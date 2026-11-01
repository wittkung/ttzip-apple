// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

final class AppStorePackageAuditTests: XCTestCase {
    
    private var repoRoot: URL {
        if let srcDir = ProcessInfo.processInfo.environment["RUNFILES_DIR"] ?? ProcessInfo.processInfo.environment["TEST_SRCDIR"] {
            let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] ?? "_main"
            let runfilesTarget = URL(fileURLWithPath: srcDir)
                .appendingPathComponent(workspace)
                .appendingPathComponent("products/ttzip/apple")
            if FileManager.default.fileExists(atPath: runfilesTarget.appendingPathComponent("Sources/TTZipApp/Info.plist").path) {
                return runfilesTarget
            }
        }
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: currentDir.appendingPathComponent("Package.swift").path) {
            return currentDir
        }
        let workspaceCandidate = currentDir.appendingPathComponent("products/ttzip/apple")
        if FileManager.default.fileExists(atPath: workspaceCandidate.appendingPathComponent("Sources/TTZipApp/Info.plist").path) {
            return workspaceCandidate
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
    
    func testPrivacyInfoManifestCompliance() throws {
        let privacyFile = repoRoot.appendingPathComponent("Sources/TTZipApp/PrivacyInfo.xcprivacy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: privacyFile.path), "PrivacyInfo.xcprivacy must exist in Sources/TTZipApp/")
        
        let data = try Data(contentsOf: privacyFile)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            XCTFail("PrivacyInfo.xcprivacy must be a valid Apple Property List")
            return
        }
        
        let tracking = plist["NSPrivacyTracking"] as? Bool
        XCTAssertEqual(tracking, false, "TTZip must not track user activity (NSPrivacyTracking must be false)")
        
        let collected = plist["NSPrivacyCollectedDataTypes"] as? [Any]
        XCTAssertNotNil(collected)
        XCTAssertTrue(collected?.isEmpty == true, "TTZip must not collect or upload user data (NSPrivacyCollectedDataTypes must be empty)")
        
        let accessedAPIs = plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        XCTAssertNotNil(accessedAPIs)
        XCTAssertTrue(accessedAPIs?.contains { ($0["NSPrivacyAccessedAPIType"] as? String) == "NSPrivacyAccessedAPICategoryFileTimestamp" } == true, "Must legally declare archive timestamp access category")
    }
    
    func testAppSandboxEntitlementsCompliance() throws {
        let entitlementsFile = repoRoot.appendingPathComponent("Sources/TTZipApp/TTZip.entitlements")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entitlementsFile.path), "TTZip.entitlements must exist")
        
        let data = try Data(contentsOf: entitlementsFile)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            XCTFail("TTZip.entitlements must be a valid Property List")
            return
        }
        
        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true, "MAS build must enable App Sandbox")
        XCTAssertEqual(plist["com.apple.security.files.user-selected.read-write"] as? Bool, true, "Must request user-selected file read-write permissions")
        XCTAssertEqual(plist["com.apple.security.files.bookmarks.app-scope"] as? Bool, true, "Must enable security-scoped app bookmarks")
    }

    func testQuickLookExtensionEntitlementsCompliance() throws {
        let qlEntitlementsFile = repoRoot.appendingPathComponent("Sources/TTZipQuickLook/TTZipQuickLook.entitlements")
        XCTAssertTrue(FileManager.default.fileExists(atPath: qlEntitlementsFile.path), "TTZipQuickLook.entitlements must exist")

        let data = try Data(contentsOf: qlEntitlementsFile)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            XCTFail("TTZipQuickLook.entitlements must be a valid Property List")
            return
        }

        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true, "QuickLook extension must enable App Sandbox")
        let groups = plist["com.apple.security.application-groups"] as? [String]
        XCTAssertTrue(groups?.contains("group.com.metastudyline.ttzip") == true, "QuickLook extension must declare group.com.metastudyline.ttzip for language preference access")
    }

    func testFinderSyncExtensionEntitlementsCompliance() throws {
        let fsEntitlementsFile = repoRoot.appendingPathComponent("Sources/TTZipFinderSync/TTZipFinderSync.entitlements")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fsEntitlementsFile.path), "TTZipFinderSync.entitlements must exist")

        let data = try Data(contentsOf: fsEntitlementsFile)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            XCTFail("TTZipFinderSync.entitlements must be a valid Property List")
            return
        }

        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true, "FinderSync extension must enable App Sandbox")
        let groups = plist["com.apple.security.application-groups"] as? [String]
        XCTAssertTrue(groups?.contains("group.com.metastudyline.ttzip") == true, "FinderSync extension must declare group.com.metastudyline.ttzip")
    }

    func testArchiveWorkerHelperEntitlementsCompliance() throws {
        let workerEntitlementsFile = repoRoot
            .deletingLastPathComponent()
            .appendingPathComponent("workers/ttarchive-worker/Worker.entitlements")
        guard FileManager.default.fileExists(atPath: workerEntitlementsFile.path) else {
            return
        }

        let data = try Data(contentsOf: workerEntitlementsFile)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            XCTFail("Worker.entitlements must be a valid Property List")
            return
        }

        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true, "ttarchive-worker must enable App Sandbox")
        XCTAssertEqual(plist["com.apple.security.inherit"] as? Bool, true, "ttarchive-worker must enable com.apple.security.inherit for posix_spawn sandbox inheritance")
    }
    
    func testInfoPlistFormatAndUTICoverage() throws {
        let infoPlistFile = repoRoot.appendingPathComponent("Sources/TTZipApp/Info.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: infoPlistFile.path), "Info.plist must exist")
        
        let data = try Data(contentsOf: infoPlistFile)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            XCTFail("Info.plist must be a valid Property List")
            return
        }
        
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "TTZip")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.metastudyline.ttzip")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist["LSApplicationCategoryType"] as? String, "public.app-category.utilities")
        
        guard let docTypes = plist["CFBundleDocumentTypes"] as? [[String: Any]],
              let firstType = docTypes.first,
              let extensions = firstType["CFBundleTypeExtensions"] as? [String] else {
            XCTFail("CFBundleDocumentTypes must declare supported file extensions list")
            return
        }
        
        let requiredFormats = ["zip", "7z", "tar", "gz", "bz2", "xz", "zst", "lz4", "lzip", "wim", "dmg", "iso", "rar", "001"]
        for fmt in requiredFormats {
            XCTAssertTrue(extensions.contains(fmt), "Info.plist must declare support for .\(fmt) archive extension")
        }
    }
    
    func testAppIconICNSAssetExists() {
        let iconFile = repoRoot.appendingPathComponent("Sources/TTZipApp/Resources/AppIcon.icns")
        let exists = FileManager.default.fileExists(atPath: iconFile.path)
        XCTAssertTrue(exists, "AppIcon.icns asset file must exist")
        let attrs = (try? FileManager.default.attributesOfItem(atPath: iconFile.resolvingSymlinksInPath().path))
            ?? (try? FileManager.default.attributesOfItem(atPath: iconFile.path))
        let size = attrs?[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 10000, "AppIcon.icns must contain full multi-resolution icon layers")
    }

    func testZeroPrivateSandboxExtensionAPIsInProductionPipeline() throws {
        let ttzipRoot = repoRoot.deletingLastPathComponent()
        let clientFile = ttzipRoot.appendingPathComponent("core/Sources/TTZipCore/Pipeline/QuarantineWorkerClient.swift")
        let workerMain = ttzipRoot.appendingPathComponent("workers/ttarchive-worker/src/main.rs")
        let workerBookmark = ttzipRoot.appendingPathComponent("workers/ttarchive-worker/src/bookmark_macos.rs")

        if FileManager.default.fileExists(atPath: clientFile.path) {
            let content = try String(contentsOf: clientFile, encoding: .utf8)
            XCTAssertFalse(content.contains("sandbox_extension_issue_file"), "Production QuarantineWorkerClient must not use private sandbox_extension_issue_file API")
            XCTAssertTrue(content.contains("bookmarkData"), "Production QuarantineWorkerClient must use public Foundation URL.bookmarkData API")
        }
        if FileManager.default.fileExists(atPath: workerMain.path) {
            let content = try String(contentsOf: workerMain, encoding: .utf8)
            XCTAssertFalse(content.contains("sandbox_extension_consume"), "Production ttarchive-worker must not use private sandbox_extension_consume API")
            XCTAssertFalse(content.contains("sandbox_extension_release"), "Production ttarchive-worker must not use private sandbox_extension_release API")
        }
        if FileManager.default.fileExists(atPath: workerBookmark.path) {
            let content = try String(contentsOf: workerBookmark, encoding: .utf8)
            XCTAssertTrue(content.contains("CFURLCreateByResolvingBookmarkData"), "ttarchive-worker bookmark bridge must use public CoreFoundation CFURLCreateByResolvingBookmarkData")
            XCTAssertTrue(content.contains("CFURLStartAccessingSecurityScopedResource"), "ttarchive-worker bookmark bridge must use public CFURLStartAccessingSecurityScopedResource")
        }
    }

    func testAcknowledgementsPlistFullClosureAndVerbatimLicenseTexts() throws {
        let ackFile = repoRoot.appendingPathComponent("Sources/TTZipApp/Resources/Acknowledgements.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ackFile.path), "Acknowledgements.plist must exist")
        let data = try Data(contentsOf: ackFile)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let components = try XCTUnwrap(plist["Components"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(components.count, 180, "Acknowledgements.plist must contain the full build dependency closure")
        for comp in components {
            let name = try XCTUnwrap(comp["name"] as? String)
            let version = try XCTUnwrap(comp["version"] as? String)
            let spdx = try XCTUnwrap(comp["spdx"] as? String)
            let licenseText = try XCTUnwrap(comp["license_text"] as? String)
            XCTAssertFalse(name.contains("&") || name.contains("/"), "Component \(name) must not merge multiple crates")
            XCTAssertFalse(version.isEmpty || version == "unspecified" || version == "workspace", "Component \(name) must have an exact version")
            XCTAssertNotEqual(spdx, "Custom-Permissive", "Component \(name) must have a verified SPDX identifier, not Custom-Permissive")
            if name == "lzfse" || name == "fast-lzma2" {
                XCTAssertTrue(version.contains("@"), "Vendored library \(name) version (\(version)) must include traceable upstream tag@commit provenance")
            }
            XCTAssertGreaterThan(licenseText.count, 200, "Component \(name) must include verbatim upstream license text, not a short placeholder")
        }
    }
}

