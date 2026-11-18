// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Workspace navigation tab classification.
public enum WorkspaceTab: Hashable, Identifiable, Codable, Sendable, CaseIterable {
    case home
    case compressWorkspace
    case presets
    case benchmark
    case vault
    case settings

    public var id: String {
        switch self {
        case .home: return "home"
        case .compressWorkspace: return "compressWorkspace"
        case .presets: return "presets"
        case .benchmark: return "benchmark"
        case .vault: return "vault"
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
        case "settings": self = .settings
        default:
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
        .settings
    ]
}
