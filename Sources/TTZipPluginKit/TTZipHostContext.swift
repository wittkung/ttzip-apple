// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI

/// 通知重要级别
public enum TTZipNotificationLevel: String, Sendable {
    case info
    case success
    case warning
    case error
}

/// 强类型安全事件订阅令牌 (防内存泄漏)
public struct SubscriptionToken: Sendable, Hashable {
    public let id: UUID
    public init() {
        self.id = UUID()
    }
}

/// 凭证保险箱能力接口
public protocol TTZipKeychainStore: Sendable {
    func get(key: String) async throws -> String?
    func set(key: String, value: String) async throws
    func delete(key: String) async throws
}

/// TTZip 宿主向插件注入的核心能力上下文协议
@MainActor
public protocol TTZipHostContext: AnyObject {
    var pluginIdentifier: String { get }
    var keychain: TTZipKeychainStore { get }
    
    func createArchive(sources: [URL], destination: URL, format: String, level: Int) async throws -> URL
    func showNotification(title: String, message: String, level: TTZipNotificationLevel)
    func setGlobalProgress(progress: Double?, statusText: String?)
    
    // 强类型发布-订阅事件总线 (支持反注册与内存回收)
    func subscribeEvent<T: Sendable & Codable>(_ type: T.Type, name: String, handler: @escaping @Sendable (T) -> Void) -> SubscriptionToken
    func unsubscribeEvent(token: SubscriptionToken)
    func publishEvent<T: Sendable & Codable>(name: String, event: T)
}

/// 带有租户隔离保护的 Scoped Host Context 代理实现
@MainActor
public final class PluginScopedHostContext: TTZipHostContext {
    public let pluginIdentifier: String
    private let masterKeychain: TTZipKeychainStore
    private let baseContext: TTZipHostContext
    
    public init(pluginIdentifier: String, baseContext: TTZipHostContext, masterKeychain: TTZipKeychainStore) {
        self.pluginIdentifier = pluginIdentifier
        self.baseContext = baseContext
        self.masterKeychain = masterKeychain
    }
    
    /// 强制增加租户命名空间前缀，彻底阻断跨插件越权访问
    public var keychain: TTZipKeychainStore {
        ScopedKeychainStore(pluginPrefix: "com.ttzip.plugin.\(pluginIdentifier).", underlyingStore: masterKeychain)
    }
    
    public func createArchive(sources: [URL], destination: URL, format: String, level: Int) async throws -> URL {
        try await baseContext.createArchive(sources: sources, destination: destination, format: format, level: level)
    }
    
    public func showNotification(title: String, message: String, level: TTZipNotificationLevel) {
        baseContext.showNotification(title: title, message: message, level: level)
    }
    
    public func setGlobalProgress(progress: Double?, statusText: String?) {
        baseContext.setGlobalProgress(progress: progress, statusText: statusText)
    }
    
    public func subscribeEvent<T: Sendable & Codable>(_ type: T.Type, name: String, handler: @escaping @Sendable (T) -> Void) -> SubscriptionToken {
        baseContext.subscribeEvent(type, name: name, handler: handler)
    }
    
    public func unsubscribeEvent(token: SubscriptionToken) {
        baseContext.unsubscribeEvent(token: token)
    }
    
    public func publishEvent<T: Sendable & Codable>(name: String, event: T) {
        baseContext.publishEvent(name: name, event: event)
    }
}

/// 租户命名空间隔离的 Keychain 代理
public final class ScopedKeychainStore: TTZipKeychainStore, @unchecked Sendable {
    private let pluginPrefix: String
    private let underlyingStore: TTZipKeychainStore
    
    public init(pluginPrefix: String, underlyingStore: TTZipKeychainStore) {
        self.pluginPrefix = pluginPrefix
        self.underlyingStore = underlyingStore
    }
    
    public func get(key: String) async throws -> String? {
        try await underlyingStore.get(key: pluginPrefix + key)
    }
    
    public func set(key: String, value: String) async throws {
        try await underlyingStore.set(key: pluginPrefix + key, value: value)
    }
    
    public func delete(key: String) async throws {
        try await underlyingStore.delete(key: pluginPrefix + key)
    }
}

/// 原生 macOS Keychain 存储实现 (基于 Security.framework)
public final class SystemKeychainStore: TTZipKeychainStore, @unchecked Sendable {
    public static let shared = SystemKeychainStore()
    private let service = "com.metastudyline.ttzip.plugins"
    
    public init() {}
    
    public func get(key: String) async throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    public func set(key: String, value: String) async throws {
        guard let data = value.data(using: .utf8) else { return }
        try? await delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }
    
    public func delete(key: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
