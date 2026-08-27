// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

/// Workspace navigation tab classification.
public enum WorkspaceTab: Hashable, Identifiable, Codable, Sendable, CaseIterable {
    case home
    case compressWorkspace
    case presets
    case benchmark
    case vault
    case plugins                                                 // 插件中心 / 插件商店
    case dynamicExtension(pluginId: String, tabId: String)       // 通用动态扩展工作区
    case settings

    public var id: String {
        switch self {
        case .home: return "home"
        case .compressWorkspace: return "compressWorkspace"
        case .presets: return "presets"
        case .benchmark: return "benchmark"
        case .vault: return "vault"
        case .plugins: return "plugins"
        case .dynamicExtension(let pluginId, let tabId):
            return "ext:\(pluginId):\(tabId)"
        case .settings: return "settings"
        }
    }

    public var rawValue: String {
        switch self {
        case .home: return "home"
        case .compressWorkspace: return "compressWorkspace"
        case .presets: return "presets"
        case .benchmark: return "benchmark"
        case .vault: return "vault"
        case .plugins: return "plugins"
        case .dynamicExtension(let pluginId, let tabId):
            return "dynamicExtension:\(pluginId):\(tabId)"
        case .settings: return "settings"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "home": self = .home
        case "compressWorkspace": self = .compressWorkspace
        case "presets": self = .presets
        case "benchmark": self = .benchmark
        case "vault": self = .vault
        case "plugins": self = .plugins
        case "settings": self = .settings
        default:
            if rawValue.hasPrefix("dynamicExtension:") {
                let parts = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3 {
                    self = .dynamicExtension(pluginId: String(parts[1]), tabId: String(parts[2]))
                    return
                }
            } else if rawValue.hasPrefix("ext:") {
                let parts = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3 {
                    self = .dynamicExtension(pluginId: String(parts[1]), tabId: String(parts[2]))
                    return
                }
            }
            if rawValue.contains(".") {
                self = .dynamicExtension(pluginId: rawValue, tabId: rawValue)
                return
            }
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let tab = WorkspaceTab(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown WorkspaceTab: \(raw)")
        }
        self = tab
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let allCases: [WorkspaceTab] = [
        .home,
        .compressWorkspace,
        .presets,
        .benchmark,
        .vault,
        .plugins,
        .settings
    ]
}
