// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipPluginKit
@testable import TTZipApp

@MainActor
final class GenericPluginInstallerTests: XCTestCase {
    
    func testGenericPluginMarketplaceModelSchema() {
        let samplePlugin = TTZipMarketplacePlugin(
            id: "com.example.mock.plugin",
            name: "MockPlugin",
            displayName: "Mock Extensibility Plugin",
            version: "1.0.0",
            author: "Developer <dev@example.com>",
            description: "A generic mock plugin to test host installer lifecycle.",
            minHostVersion: "1.0.0",
            homepage: "https://example.com/mock",
            downloadUrl: "https://example.com/mock-v1.0.0.ttplugin.zip",
            size: 1024,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            signature: "",
            publicKey: "",
            permissions: ["FS-Read"],
            publishedAt: "2026-08-27T00:00:00Z"
        )
        
        XCTAssertEqual(samplePlugin.id, "com.example.mock.plugin")
        XCTAssertEqual(samplePlugin.name, "MockPlugin")
        XCTAssertFalse(samplePlugin.permissions.isEmpty)
    }
    
    func testAppMarketplaceServiceCatalogRefreshLifecycle() async {
        let service = TTZipAppMarketplaceService.shared
        await service.refreshIndex()
        
        let catalog = service.availablePlugins
        for item in catalog {
            XCTAssertFalse(item.id.isEmpty)
            XCTAssertFalse(item.downloadUrl.isEmpty)
        }
    }
}
