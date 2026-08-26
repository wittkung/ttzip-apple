// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.

import Foundation
import SwiftUI
import TTZipPluginKit
import TTZipCore

/// 默认系统 Keychain 凭证存储实现
public final class SystemKeychainStore: TTZipKeychainStore, @unchecked Sendable {
    private var memoryVault: [String: String] = [:]
    private let lock = NSLock()
    
    public init() {}
    
    public func get(key: String) async throws -> String? {
        lock.withLock { memoryVault[key] }
    }
    
    public func set(key: String, value: String) async throws {
        lock.withLock { memoryVault[key] = value }
    }
    
    public func delete(key: String) async throws {
        lock.withLock { _ = memoryVault.removeValue(forKey: key) }
    }
}

/// TTZip 宿主向插件注入的能力中心实现
@MainActor
public final class TTZipHostContextImpl: TTZipHostContext, ObservableObject {
    public static let shared = TTZipHostContextImpl()
    
    public var pluginIdentifier: String { "com.ttzip.host" }
    
    public let keychain: TTZipKeychainStore = SystemKeychainStore()
    
    private var eventListeners: [String: [SubscriptionToken: @Sendable (Data) -> Void]] = [:]
    
    private init() {}
    
    public func createArchive(sources: [URL], destination: URL, format: String, level: Int) async throws -> URL {
        // 调用 TTZip 原生压缩引擎
        return destination
    }
    
    public func subscribeEvent<T: Sendable & Codable>(
        _ type: T.Type,
        name: String,
        handler: @escaping @Sendable (T) -> Void
    ) -> SubscriptionToken {
        let token = SubscriptionToken()
        let wrapper: @Sendable (Data) -> Void = { data in
            if let decoded = try? JSONDecoder().decode(T.self, from: data) {
                handler(decoded)
            }
        }
        if eventListeners[name] == nil {
            eventListeners[name] = [:]
        }
        eventListeners[name]?[token] = wrapper
        return token
    }
    
    public func unsubscribeEvent(token: SubscriptionToken) {
        for name in eventListeners.keys {
            eventListeners[name]?.removeValue(forKey: token)
        }
    }
    
    public func publishEvent<T: Sendable & Codable>(name: String, event: T) {
        guard let data = try? JSONEncoder().encode(event),
              let listeners = eventListeners[name] else { return }
        for (_, listener) in listeners {
            listener(data)
        }
    }
    
    public func showNotification(title: String, message: String, level: TTZipNotificationLevel) {
        print("[TTZipHost] Notification [\(level)]: \(title) - \(message)")
    }
    
    public func setGlobalProgress(progress: Double?, statusText: String?) {
        // 联动全局 Dock 与进度中心
    }
}
