// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipPluginKit

/// 通用插件凭证键值对配置项 (Generic Plugin Configuration Item)
public struct PluginConfigEntry: Identifiable, Sendable, Hashable {
    public var id: String { key }
    public var key: String
    public var value: String
    public var isSecure: Bool
    public var label: String
    public var placeholder: String
    
    public init(
        key: String,
        value: String = "",
        isSecure: Bool = true,
        label: String = "",
        placeholder: String = ""
    ) {
        self.key = key
        self.value = value
        self.isSecure = isSecure
        self.label = label.isEmpty ? key : label
        self.placeholder = placeholder.isEmpty ? "Value for \(key)" : placeholder
    }
}

/// 通用插件配置状态与持久化适配器
@MainActor
public final class PluginConfigStore: ObservableObject {
    public let pluginId: String
    @Published public var entries: [PluginConfigEntry] = []
    @Published public var isLoading: Bool = false
    @Published public var isSaving: Bool = false
    
    public init(pluginId: String) {
        self.pluginId = pluginId
    }
    
    public func loadEntries() async {
        isLoading = true
        defer { isLoading = false }
        
        let prefix = "com.ttzip.plugin.\(pluginId)."
        var loaded: [PluginConfigEntry] = []
        let keychain = TTZipHostContextImpl.shared.keychain
        
        // 预设通用字段
        let standardKeys = ["app_id", "app_secret", "access_token", "api_endpoint"]
        for k in standardKeys {
            let val = (try? await keychain.get(key: prefix + k)) ?? ""
            if !val.isEmpty || k == "app_id" || k == "app_secret" {
                loaded.append(PluginConfigEntry(
                    key: k,
                    value: val,
                    isSecure: k.contains("secret") || k.contains("token"),
                    label: k.replacingOccurrences(of: "_", with: " ").capitalized,
                    placeholder: "Enter \(k)"
                ))
            }
        }
        
        self.entries = loaded
    }
    
    public func saveEntries() async throws {
        isSaving = true
        defer { isSaving = false }
        
        let prefix = "com.ttzip.plugin.\(pluginId)."
        let keychain = TTZipHostContextImpl.shared.keychain
        for entry in entries {
            if entry.value.isEmpty {
                try? await keychain.delete(key: prefix + entry.key)
            } else {
                try? await keychain.set(key: prefix + entry.key, value: entry.value)
            }
        }
    }
    
    public func addEntry(key: String, isSecure: Bool = true) {
        guard !key.isEmpty, !entries.contains(where: { $0.key == key }) else { return }
        entries.append(PluginConfigEntry(
            key: key,
            value: "",
            isSecure: isSecure,
            label: key.replacingOccurrences(of: "_", with: " ").capitalized,
            placeholder: "Enter \(key)"
        ))
    }
}
