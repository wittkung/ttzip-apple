// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
@testable import TTZipApp
import TTZipPluginKit
import SwiftUI

@MainActor
final class LarkSyncBundleE2ETests: XCTestCase {
    
    override func setUp() async throws {
        try await super.setUp()
        // Reset registry state if needed before test
    }
    
    func testLarkSyncBundlePhysicalLayout() throws {
        let bundleURL = TTZipPluginLoader.userPluginsDirectory.appendingPathComponent("LarkSync.ttplugin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path), "LarkSync.ttplugin should exist in user plugins directory")
        
        let execURL = bundleURL.appendingPathComponent("Contents/MacOS/LarkSync")
        XCTAssertTrue(FileManager.default.fileExists(atPath: execURL.path), "Contents/MacOS/LarkSync executable should exist")
        
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path), "Contents/Info.plist should exist")
        
        let manifestURL = bundleURL.appendingPathComponent("Contents/Resources/plugin.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path), "Contents/Resources/plugin.json should exist")
        
        let ffiURL = bundleURL.appendingPathComponent("Contents/Frameworks/liblarksync_ffi.dylib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ffiURL.path), "Contents/Frameworks/liblarksync_ffi.dylib should exist")
        
        // Verify plugin.json contents
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(TTZipPluginManifest.self, from: manifestData)
        XCTAssertEqual(manifest.id, "com.ttzip.plugin.larksync")
        XCTAssertEqual(manifest.name, "飞书知识库同步")
        XCTAssertEqual(manifest.version, "1.0.2")
        XCTAssertEqual(manifest.minHostVersion, "1.0.0")
        XCTAssertTrue(manifest.permissions.contains(.networkAccess))
        XCTAssertTrue(manifest.permissions.contains(.keychainAccess))
        XCTAssertTrue(manifest.permissions.contains(.fileSystemWrite))
        XCTAssertTrue(manifest.permissions.contains(.archiveEngine))
    }
    
    func testLarkSyncBundleDynamicLoadingAndExtensionMounting() async throws {
        let bundleURL = TTZipPluginLoader.userPluginsDirectory.appendingPathComponent("LarkSync.ttplugin")
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            XCTFail("LarkSync.ttplugin not found at \(bundleURL.path)")
            return
        }
        
        let baseContext = TTZipHostContextImpl.shared
        
        // Exercise dynamic bundle loading via TTZipPluginLoader
        await TTZipPluginLoader.loadPluginBundle(at: bundleURL, context: baseContext)
        
        // Verify plugin registration in TTZipPluginRegistry
        guard let plugin = TTZipPluginRegistry.shared.installedPlugins.first(where: { $0.manifest.id == "com.ttzip.plugin.larksync" }) else {
            XCTFail("LarkSync plugin failed to register in TTZipPluginRegistry")
            return
        }
        
        // 1. Verify manifest
        XCTAssertEqual(plugin.manifest.id, "com.ttzip.plugin.larksync")
        XCTAssertEqual(plugin.manifest.name, "飞书知识库同步")
        XCTAssertEqual(plugin.manifest.version, "1.0.2")
        XCTAssertEqual(plugin.manifest.minHostVersion, "1.0.0")
        
        // 2. Verify sidebar extension point
        guard let sidebar = plugin.sidebarItem else {
            XCTFail("LarkSync should provide sidebar item contribution")
            return
        }
        XCTAssertEqual(sidebar.id, "larksync.sidebar")
        XCTAssertEqual(sidebar.title, "飞书知识库")
        XCTAssertEqual(sidebar.targetTabIdentifier, "larksync.workspace")
        XCTAssertEqual(sidebar.priority, 20)
        
        // 3. Verify workspace view contribution
        let workspaceView = plugin.makeWorkspaceView(tabIdentifier: "larksync.workspace")
        XCTAssertNotNil(workspaceView, "Workspace view contribution should be non-nil for 'larksync.workspace'")
        
        let unrelatedWorkspace = plugin.makeWorkspaceView(tabIdentifier: "unrelated.tab")
        XCTAssertNil(unrelatedWorkspace, "Workspace view contribution should be nil for unmatched tab")
        
        // 4. Verify inspector view contribution
        let inspectorView = plugin.makeInspectorView(selectedContext: nil)
        XCTAssertNotNil(inspectorView, "Inspector view contribution should be non-nil")
        
        // 5. Verify settings view contribution (safe fallback or view)
        _ = plugin.makeSettingsView()
        
        // 6. Verify omnibar command action contribution
        let commands = plugin.omnibarCommands
        XCTAssertFalse(commands.isEmpty, "Omnibar commands should not be empty")
        XCTAssertEqual(commands.first?.id, "larksync.sync_now")
        XCTAssertEqual(commands.first?.title, "飞书: 立即增量同步知识库")
    }
}
