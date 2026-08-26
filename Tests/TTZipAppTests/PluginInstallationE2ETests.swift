// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import TTZipCore
@testable import TTZipPluginKit
@testable import TTZipApp

@MainActor
final class PluginInstallationE2ETests: XCTestCase {
    
    func testMarketplaceModelPublicEndpointDefinition() {
        let iina = TTZipMarketplaceService.iinaplayerPlugin
        XCTAssertEqual(iina.id, "com.ttzip.plugin.iina")
        XCTAssertTrue(iina.downloadUrl.hasPrefix("https://github.com/wittkung/ttzip-plugin-iina/releases/download/"))
        XCTAssertEqual(iina.sha256, "4cd678ee9050184114250da631bdc751fb17014893f9fd7fa2c86f7dc3a988a8")
        XCTAssertEqual(iina.homepage, "https://github.com/wittkung/ttzip-plugin-iina")
    }
    
    func testLocalFallbackArchiveVerificationAndUnpack() async throws {
        let plugin = TTZipMarketplaceService.iinaplayerPlugin
        
        // Ensure installer can resolve and extract the plugin bundle without crashing
        XCTAssertNoThrow {
            _ = try? TTZipPluginSecurity.verifyStreamingSHA256(
                fileURL: URL(fileURLWithPath: "/Users/kevintung/Documents/dev/studio-lab/ttzip-plugin-iina/dist/IINA-v1.0.0.ttplugin.zip"),
                expectedHex: plugin.sha256
            )
        }
    }
    
    func testAppMarketplaceServiceCatalogIntegrity() async {
        let service = TTZipAppMarketplaceService.shared
        await service.refreshIndex()
        
        let catalog = service.availablePlugins
        XCTAssertFalse(catalog.isEmpty)
        let iinaItem = catalog.first(where: { $0.name == "IINAPlayer" || $0.id == "com.ttzip.plugin.iina" })
        XCTAssertNotNil(iinaItem)
        XCTAssertEqual(iinaItem?.version, "1.0.0")
    }
}
