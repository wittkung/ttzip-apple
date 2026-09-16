// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI

/// Notification priority level
public enum TTZipNotificationLevel: String, Sendable {
    case info
    case success
    case warning
    case error
}

/// Plugin log severity level
public enum TTZipPluginLogLevel: String, Sendable, CaseIterable {
    case debug
    case info
    case warning
    case error
}

/// Strongly typed subscription token for event bus lifecycle management
public struct SubscriptionToken: Sendable, Hashable {
    public let id: UUID
    public init() {
        self.id = UUID()
    }
}

/// Keychain store capability interface
public protocol TTZipKeychainStore: Sendable {
    func get(key: String) async throws -> String?
    func set(key: String, value: String) async throws
    func delete(key: String) async throws
}

/// Archive entry metadata model exposed to plugins
public struct TTZipArchiveEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let uncompressedSize: UInt64
    public let compressedSize: UInt64?
    public let isDirectory: Bool
    public let modificationDate: Date?
    public let isEncrypted: Bool
    public let compressionMethod: String
    
    public init(
        path: String,
        uncompressedSize: UInt64,
        compressedSize: UInt64? = nil,
        isDirectory: Bool = false,
        modificationDate: Date? = nil,
        isEncrypted: Bool = false,
        compressionMethod: String = "deflate"
    ) {
        self.path = path
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.isEncrypted = isEncrypted
        self.compressionMethod = compressionMethod
    }
}

/// Host capability context protocol injected into TTZip plugins
@MainActor
public protocol TTZipHostContext: AnyObject {
    var pluginIdentifier: String { get }
    var keychain: TTZipKeychainStore { get }
    var storageDirectory: URL { get }
    
    func createArchive(sources: [URL], destination: URL, format: String, level: Int) async throws -> URL
    func inspectArchive(at url: URL, password: String?) async throws -> [TTZipArchiveEntry]
    func extractArchive(from url: URL, to destination: URL, password: String?, entries: [String]?) async throws
    func showNotification(title: String, message: String, level: TTZipNotificationLevel)
    func setGlobalProgress(progress: Double?, statusText: String?)
    func log(level: TTZipPluginLogLevel, message: String)
    
    // Strongly typed publish-subscribe event bus
    func subscribeEvent<T: Sendable & Codable>(_ type: T.Type, name: String, handler: @escaping @Sendable (T) -> Void) -> SubscriptionToken
    func unsubscribeEvent(token: SubscriptionToken)
    func publishEvent<T: Sendable & Codable>(name: String, event: T)
}

/// Scoped host context proxy enforcing tenant isolation, event namespacing, and token lifecycle cleanup
@MainActor
public final class PluginScopedHostContext: TTZipHostContext {
    public let pluginIdentifier: String
    private let masterKeychain: TTZipKeychainStore
    private let baseContext: TTZipHostContext
    private var registeredTokens: Set<SubscriptionToken> = []
    
    public init(pluginIdentifier: String, baseContext: TTZipHostContext, masterKeychain: TTZipKeychainStore) {
        self.pluginIdentifier = pluginIdentifier
        self.baseContext = baseContext
        self.masterKeychain = masterKeychain
    }
    
    /// Tenant-scoped keychain store preventing cross-plugin access
    public var keychain: TTZipKeychainStore {
        ScopedKeychainStore(pluginPrefix: "com.ttzip.plugin.\(pluginIdentifier).", underlyingStore: masterKeychain)
    }
    
    /// Dedicated managed storage directory: ~/Library/Application Support/TTZip/PluginData/<pluginId>
    public var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TTZip/PluginData/\(pluginIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    public func createArchive(sources: [URL], destination: URL, format: String, level: Int) async throws -> URL {
        try await baseContext.createArchive(sources: sources, destination: destination, format: format, level: level)
    }
    
    public func inspectArchive(at url: URL, password: String?) async throws -> [TTZipArchiveEntry] {
        try await baseContext.inspectArchive(at: url, password: password)
    }
    
    public func extractArchive(from url: URL, to destination: URL, password: String?, entries: [String]?) async throws {
        try await baseContext.extractArchive(from: url, to: destination, password: password, entries: entries)
    }
    
    public func showNotification(title: String, message: String, level: TTZipNotificationLevel) {
        baseContext.showNotification(title: title, message: message, level: level)
    }
    
    public func setGlobalProgress(progress: Double?, statusText: String?) {
        baseContext.setGlobalProgress(progress: progress, statusText: statusText)
    }
    
    public func log(level: TTZipPluginLogLevel, message: String) {
        baseContext.log(level: level, message: "[Plugin:\(pluginIdentifier)] \(message)")
    }
    
    /// Enforces tenant namespace prefix on event names (e.g., `plugin.<pluginId>.<eventName>`) to prevent event collision
    private func scopedEventName(_ name: String) -> String {
        let prefix = "plugin.\(pluginIdentifier)."
        if name.hasPrefix(prefix) {
            return name
        }
        return "\(prefix)\(name)"
    }
    
    public func subscribeEvent<T: Sendable & Codable>(_ type: T.Type, name: String, handler: @escaping @Sendable (T) -> Void) -> SubscriptionToken {
        let scopedName = scopedEventName(name)
        let token = baseContext.subscribeEvent(type, name: scopedName, handler: handler)
        registeredTokens.insert(token)
        return token
    }
    
    public func unsubscribeEvent(token: SubscriptionToken) {
        registeredTokens.remove(token)
        baseContext.unsubscribeEvent(token: token)
    }
    
    public func publishEvent<T: Sendable & Codable>(name: String, event: T) {
        let scopedName = scopedEventName(name)
        baseContext.publishEvent(name: scopedName, event: event)
    }
    
    /// Cleans up and unregisters all event subscription tokens created by this scoped context
    public func cleanupTokens() {
        for token in registeredTokens {
            baseContext.unsubscribeEvent(token: token)
        }
        registeredTokens.removeAll()
    }
}

/// Tenant namespace isolated Keychain proxy store
public final class ScopedKeychainStore: TTZipKeychainStore, Sendable {
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

/// Native macOS Keychain storage implementation (Internal to framework)
final class SystemKeychainStore: TTZipKeychainStore, Sendable {
    static let shared = SystemKeychainStore()
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
