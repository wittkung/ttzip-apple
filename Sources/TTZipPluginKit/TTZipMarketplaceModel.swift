// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

public struct TTZipMarketplaceIndex: Codable, Sendable {
    public let version: Int
    public let updatedAt: String
    public let plugins: [TTZipMarketplacePlugin]
    
    public init(version: Int, updatedAt: String, plugins: [TTZipMarketplacePlugin]) {
        self.version = version
        self.updatedAt = updatedAt
        self.plugins = plugins
    }
}

public struct TTZipMarketplacePlugin: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let displayName: String
    public let version: String
    public let author: String
    public let description: String
    public let minHostVersion: String
    public let homepage: String
    public let downloadUrl: String
    public let size: Int64
    public let sha256: String
    public let signature: String
    public let publicKey: String
    public let permissions: [String]
    public let publishedAt: String
    
    public init(
        id: String,
        name: String,
        displayName: String,
        version: String,
        author: String,
        description: String,
        minHostVersion: String,
        homepage: String,
        downloadUrl: String,
        size: Int64,
        sha256: String,
        signature: String,
        publicKey: String,
        permissions: [String],
        publishedAt: String
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.version = version
        self.author = author
        self.description = description
        self.minHostVersion = minHostVersion
        self.homepage = homepage
        self.downloadUrl = downloadUrl
        self.size = size
        self.sha256 = sha256
        self.signature = signature
        self.publicKey = publicKey
        self.permissions = permissions
        self.publishedAt = publishedAt
    }
}

/// Official marketplace service and remote index fetcher
public actor TTZipMarketplaceService {
    public static let shared = TTZipMarketplaceService()
    
    public static let defaultMarketplaceURL = URL(string: "https://raw.githubusercontent.com/wittkung/ttzip-marketplace/main/marketplace.json")!
    
    /// Official plugin catalog (empty default list dynamically populated from remote or local bundles)
    public static let officialCatalog: [TTZipMarketplacePlugin] = []
    public static var defaultCatalog: [TTZipMarketplacePlugin] { officialCatalog }
    
    private init() {}
    
    /// Fetches the latest remote marketplace index
    public func fetchMarketplaceIndex(from url: URL = defaultMarketplaceURL) async -> [TTZipMarketplacePlugin] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                let index = try JSONDecoder().decode(TTZipMarketplaceIndex.self, from: data)
                return index.plugins
            }
        } catch {
            print("[TTZipMarketplaceService] Failed to fetch remote index: \(error)")
        }
        return Self.officialCatalog
    }
}
