// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import Foundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

final class AppStorePackageAuditTests: XCTestCase {
    
    private var repoRoot: URL {
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: currentDir.appendingPathComponent("Package.swift").path) {
            return currentDir
        }
        return URL(fileURLWithPath: #file)
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: iconFile.path), "AppIcon.icns asset file must exist")
        let attrs = try? FileManager.default.attributesOfItem(atPath: iconFile.path)
        let size = attrs?[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 10000, "AppIcon.icns must contain full multi-resolution icon layers")
    }
}
