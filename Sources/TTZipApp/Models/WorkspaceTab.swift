// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

/// Workspace navigation tab classification.
public enum WorkspaceTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case home = "home"
    case compressWorkspace = "compressWorkspace"
    case presets = "presets"
    case benchmark = "benchmark"
    case vault = "vault"
    case plugins = "plugins"           // 插件中心 / 插件商店
    case larkSync = "larksync.workspace" // 飞书知识库同步插件
    case settings = "settings"

    public var id: String { rawValue }
}
