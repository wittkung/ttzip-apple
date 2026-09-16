// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

/// In-memory thread-safe keychain store for testing
public actor InMemoryKeychainStore: TTZipKeychainStore {
    private var data: [String: String] = [:]
    
    public init() {}
    
    public func get(key: String) async throws -> String? {
        return data[key]
    }
    
    public func set(key: String, value: String) async throws {
        data[key] = value
    }
    
    public func delete(key: String) async throws {
        data.removeValue(forKey: key)
    }
}

/// Mock Host Context for isolated plugin testing and developer experience
@MainActor
open class MockHostContext: TTZipHostContext {
    public var pluginIdentifier: String
    public var keychain: TTZipKeychainStore
    public var storageDirectory: URL
    
    public var mockArchiveEntries: [TTZipArchiveEntry] = []
    public private(set) var publishedEvents: [(name: String, data: Data)] = []
    public private(set) var loggedMessages: [(level: TTZipPluginLogLevel, message: String)] = []
    public private(set) var postedNotifications: [(title: String, message: String, level: TTZipNotificationLevel)] = []
    public private(set) var reportedProgress: (progress: Double?, statusText: String?) = (nil, nil)
    
    private var eventHandlers: [UUID: (String, @Sendable (Data) -> Void)] = [:]
    
    public init(pluginIdentifier: String = "com.mock.plugin") {
        self.pluginIdentifier = pluginIdentifier
        self.keychain = InMemoryKeychainStore()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.storageDirectory = tempDir
    }
    
    open func createArchive(sources: [URL], destination: URL, format: String, level: Int) async throws -> URL {
        return destination
    }
    
    open func inspectArchive(at url: URL, password: String?) async throws -> [TTZipArchiveEntry] {
        return mockArchiveEntries
    }
    
    open func extractArchive(from url: URL, to destination: URL, password: String?, entries: [String]?) async throws {
        // No-op for mock
    }
    
    open func showNotification(title: String, message: String, level: TTZipNotificationLevel) {
        postedNotifications.append((title, message, level))
    }
    
    open func setGlobalProgress(progress: Double?, statusText: String?) {
        reportedProgress = (progress, statusText)
    }
    
    open func log(level: TTZipPluginLogLevel, message: String) {
        loggedMessages.append((level, message))
    }
    
    open func subscribeEvent<T: Sendable & Codable>(_ type: T.Type, name: String, handler: @escaping @Sendable (T) -> Void) -> SubscriptionToken {
        let token = SubscriptionToken()
        let wrapper: @Sendable (Data) -> Void = { data in
            if let decoded = try? JSONDecoder().decode(T.self, from: data) {
                handler(decoded)
            }
        }
        eventHandlers[token.id] = (name, wrapper)
        return token
    }
    
    open func unsubscribeEvent(token: SubscriptionToken) {
        eventHandlers.removeValue(forKey: token.id)
    }
    
    open func publishEvent<T: Sendable & Codable>(name: String, event: T) {
        if let data = try? JSONEncoder().encode(event) {
            publishedEvents.append((name, data))
            
            // Dispatch to matching handlers
            for (_, (handlerName, handler)) in eventHandlers where handlerName == name {
                handler(data)
            }
        }
    }
}
