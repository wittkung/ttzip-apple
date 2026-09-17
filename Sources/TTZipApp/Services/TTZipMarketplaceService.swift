// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import Observation
import TTZipPluginKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Service bridge in TTZipApp facilitating marketplace catalog and plugin enablement.
@Observable
@MainActor
public final class TTZipAppMarketplaceService {
    public static let shared = TTZipAppMarketplaceService()
    
    public private(set) var availablePlugins: [TTZipMarketplacePlugin] = TTZipMarketplaceService.officialCatalog
    public private(set) var isRefreshing: Bool = false
    
    private init() {}
    
    /// Refreshes marketplace index with graceful fallback to official catalog.
    public func refreshIndex() async {
        isRefreshing = true
        defer { isRefreshing = false }
        
        let plugins = await TTZipMarketplaceService.shared.fetchMarketplaceIndex()
        self.availablePlugins = plugins.isEmpty ? TTZipMarketplaceService.officialCatalog : plugins
    }
    
    /// Installs a marketplace plugin dynamically.
    public func installPlugin(_ plugin: TTZipMarketplacePlugin, context: TTZipHostContext) async throws {
        try await TTZipPluginInstaller.shared.install(plugin: plugin, context: context)
    }
}
