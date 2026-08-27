// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipPluginKit

/// Service bridge in TTZipApp facilitating marketplace catalog and plugin enablement.
@MainActor
public final class TTZipAppMarketplaceService: ObservableObject {
    public static let shared = TTZipAppMarketplaceService()
    
    @Published public private(set) var availablePlugins: [TTZipMarketplacePlugin] = TTZipMarketplaceService.officialCatalog
    @Published public private(set) var isRefreshing: Bool = false
    
    private init() {}
    
    /// Refreshes marketplace index.
    public func refreshIndex() async {
        isRefreshing = true
        defer { isRefreshing = false }
        
        let plugins = await TTZipMarketplaceService.shared.fetchMarketplaceIndex()
        self.availablePlugins = plugins
    }
    
    /// Installs a marketplace plugin dynamically.
    public func installPlugin(_ plugin: TTZipMarketplacePlugin, context: TTZipHostContext) async throws {
        try await TTZipPluginInstaller.shared.install(plugin: plugin, context: context)
    }
}
