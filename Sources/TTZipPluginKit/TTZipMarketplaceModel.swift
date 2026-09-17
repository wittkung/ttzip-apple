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
    
    /// Embedded fallback marketplace manifest payload guaranteeing graceful offline/404 degradation.
    private static let fallbackManifestBase64 = "ewogICIkc2NoZW1hIjogImh0dHBzOi8vdHR6aXAuY29tL3NjaGVtYXMvbWFya2V0cGxhY2UtdjEuanNvbiIsCiAgInZlcnNpb24iOiAxLAogICJ1cGRhdGVkQXQiOiAiMjAyNi0wOC0yN1QwMDoxNTo0NFoiLAogICJwbHVnaW5zIjogWwogICAgewogICAgICAiaWQiOiAiY29tLnR0emlwLnBsdWdpbi5sYXJrc3luYyIsCiAgICAgICJuYW1lIjogIkxhcmtTeW5jIiwKICAgICAgImRpc3BsYXlOYW1lIjogIumjnuS5puefpeivhuW6k+WPjOWQkeWQjOatpSIsCiAgICAgICJ2ZXJzaW9uIjogIjEuMC4yIiwKICAgICAgImF1dGhvciI6ICJXaXR0IEt1bmcgJiBUVFppcCBUZWFtIiwKICAgICAgImRlc2NyaXB0aW9uIjogIuS4k+S4uiBUVFppcCDmiZPpgKDnmoTpo57kuabnn6Xor4blupPlj4zlkJHlop7ph4/lkIzmraXkuI7ljp/nlJ8gTWFya2Rvd24g5rKJ5rW45byP566h55CG5o+S5Lu244CC5Z+65LqO57qvIFJ1c3Qg5qC45b+D5LiOIDMtVHJlZSDlt67lvILnirbmgIHmnLrjgIIiLAogICAgICAibWluSG9zdFZlcnNpb24iOiAiMS4wLjAiLAogICAgICAiaG9tZXBhZ2UiOiAiaHR0cHM6Ly9naXRodWIuY29tL3dpdHRrdW5nL0xhcmtTeW5jIiwKICAgICAgImRvd25sb2FkVXJsIjogImh0dHBzOi8vZ2l0aHViLmNvbS93aXR0a3VuZy9MYXJrU3luYy9yZWxlYXNlcy9kb3dubG9hZC92MS4wLjIvTGFya1N5bmMtdjEuMC4yLnR0cGx1Z2luLnppcCIsCiAgICAgICJzaXplIjogMzE5MjQ3NywKICAgICAgInNoYTI1NiI6ICIwN2JkMzQ1OTVjYzM3Y2JmOGI4MmVhMDIzYjI3NmQ3YmUwNjBiNTA2ZThjYzFiNmI1OWI5YzQzYjAwZTQzNWE3IiwKICAgICAgInNpZ25hdHVyZSI6ICJ6SUNnOHRyM05mOEh5STZqTWcycFdBbUZiWFhWM0QvZjFZdjI1bmlTbGJsNjJNaEVHL3pxSGRpclhnVzZJWnJxUFdGYWlYWEMrT1BOWUpaNE4zdkdBUT09IiwKICAgICAgInB1YmxpY0tleSI6ICJmMVdadFRSNHhwNEVhbnBFMWhHcmpmU3d0N0ZmZnN5M012bUpOcmFLNmM4PSIsCiAgICAgICJwZXJtaXNzaW9ucyI6IFsKICAgICAgICAiTmV0d29yayIsCiAgICAgICAgIktleWNoYWluIiwKICAgICAgICAiRlMtV3JpdGUiLAogICAgICAgICJBcmNoaXZlRW5naW5lIgogICAgICBdLAogICAgICAicHVibGlzaGVkQXQiOiAiMjAyNi0wOC0yN1QwMDoxNTo0NFoiCiAgICB9CiAgXQp9Cg=="

    /// Official plugin catalog dynamically decoded from fallback manifest or populated from remote
    public static let officialCatalog: [TTZipMarketplacePlugin] = {
        guard let data = Data(base64Encoded: fallbackManifestBase64),
              let index = try? JSONDecoder().decode(TTZipMarketplaceIndex.self, from: data) else {
            return []
        }
        return index.plugins
    }()
    public static var defaultCatalog: [TTZipMarketplacePlugin] { officialCatalog }
    
    private init() {}
    
    /// Fetches the latest remote marketplace index with graceful fallback to official catalog
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
                if !index.plugins.isEmpty {
                    return index.plugins
                }
            } else if let httpResponse = response as? HTTPURLResponse {
                PluginKitLogger.warning("[TTZipMarketplaceService] Remote index returned status \(httpResponse.statusCode), using fallback catalog.")
            }
        } catch {
            PluginKitLogger.error("[TTZipMarketplaceService] Failed to fetch remote index: \(error), using fallback catalog.")
        }
        return Self.officialCatalog
    }
}
