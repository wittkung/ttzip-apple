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

/// 官方市场服务与索引拉取器
public actor TTZipMarketplaceService {
    public static let shared = TTZipMarketplaceService()
    
    public static let defaultMarketplaceURL = URL(string: "https://raw.githubusercontent.com/wittkung/LarkSync/main/marketplace.json")!
    
    /// 内置官方 Fallback 索引，确保即使离线/弱网环境下也能瞬时呈现官方生态
    public static let fallbackPlugin = TTZipMarketplacePlugin(
        id: "com.ttzip.plugin.larksync",
        name: "LarkSync",
        displayName: "飞书知识库双向同步",
        version: "1.0.1",
        author: "Witt Kung & TTZip Team",
        description: "专为 TTZip 打造的飞书知识库双向增量同步与原生 Markdown 沉浸式管理插件。基于纯 Rust 核心与 3-Tree 差异状态机。",
        minHostVersion: "1.0.0",
        homepage: "https://github.com/wittkung/LarkSync",
        downloadUrl: "https://github.com/wittkung/LarkSync/releases/download/v1.0.1/LarkSync-v1.0.1.ttplugin.zip",
        size: 3002099,
        sha256: "cde1dc50d84eebdb2b2946f993e99fba7ffb7ed0ab0904026299b2c50b21ad05",
        signature: "a5j34HPSDRkr6eh0diSEaezN0XLCvPTIT8L9fPRoiP6YmfXk2+AjQzDhAl76fNw4b4Rl0TWKSdj0TCRmVkYGDg==",
        publicKey: "f1WZtTR4xp4EanpE1hGrjfSwt7Fffsy3MvmJNraK6c8=",
        permissions: ["Network", "Keychain", "FS-Write", "ArchiveEngine"],
        publishedAt: "2026-08-26T07:10:24Z"
    )
    
    private init() {}
    
    /// 拉取云端最新索引（带超时与 Fallback 保护）
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
            print("[TTZipMarketplaceService] Failed to fetch remote index, using fallback: \(error)")
        }
        return [Self.fallbackPlugin]
    }
}
