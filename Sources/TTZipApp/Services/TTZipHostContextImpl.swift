// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
import TTZipPluginKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Host-side Keychain store implementation backing TTZipHostContext
public final class HostKeychainStore: TTZipKeychainStore, Sendable {
    public static let shared = HostKeychainStore()
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

/// Production host capability implementation injected into TTZip plugins.
@MainActor
public final class TTZipHostContextImpl: TTZipHostContext {
    public static let shared = TTZipHostContextImpl()
    
    public var pluginIdentifier: String { "com.ttzip.host" }
    
    public let keychain: TTZipKeychainStore = HostKeychainStore.shared
    
    public var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TTZip/HostData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private var eventListeners: [String: [SubscriptionToken: @Sendable (Data) -> Void]] = [:]
    
    private init() {}
    
    public func createArchive(sources: [URL], destination: URL, format: String, level: Int) async throws -> URL {
        let compressionFormat = ArchiveCompressionFormat(rawValue: format.lowercased()) ?? .zip
        let compressionLevel = ArchiveCompressionLevel(rawValue: level) ?? .normal
        let inputPaths = sources.map { $0.path }
        
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: destination.path,
            format: compressionFormat,
            level: compressionLevel,
            inputPaths: inputPaths
        )
        return destination
    }
    
    public func inspectArchive(at url: URL, password: String?) async throws -> [TTZipArchiveEntry] {
        let entries = try inspectArchiveEntries(archivePath: url.path, password: password)
        return entries.map { entry in
            TTZipArchiveEntry(
                path: entry.path,
                uncompressedSize: entry.uncompressedSize,
                compressedSize: entry.compressedSize,
                isDirectory: entry.isDirectory,
                modificationDate: entry.modificationDate,
                isEncrypted: entry.isEncrypted,
                compressionMethod: entry.compressionMethod
            )
        }
    }
    
    public func extractArchive(from url: URL, to destination: URL, password: String?, entries: [String]?) async throws {
        let extractor = ArchiveExtractor()
        _ = try await Task.detached(priority: .userInitiated) {
            try extractor.extractSync(
                archivePath: url.path,
                destinationDir: destination.path
            )
        }.value
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
        let listenerSnapshots = Array(listeners.values)
        // Dispatches asynchronously detached to ensure slow plugin listeners never stall the MainActor
        Task.detached(priority: .userInitiated) {
            for listener in listenerSnapshots {
                listener(data)
            }
        }
    }
    
    public func showNotification(title: String, message: String, level: TTZipNotificationLevel) {
        let isError = (level == .error || level == .warning)
        SystemNotificationManager.shared.postNotification(
            title: title,
            body: message,
            isError: isError
        )
    }
    
    public func setGlobalProgress(progress: Double?, statusText: String?) {
        if let progress = progress {
            DockProgressManager.shared.updateProgress(fraction: progress, activeCount: 1)
        } else {
            DockProgressManager.shared.clearProgress()
        }
    }
    
    public func log(level: TTZipPluginLogLevel, message: String) {
        let mappedLevel: TTLogger.Level
        switch level {
        case .debug:
            mappedLevel = .debug
        case .info:
            mappedLevel = .info
        case .warning:
            mappedLevel = .warning
        case .error:
            mappedLevel = .error
        }
        let formattedMessage = message.hasPrefix("[Plugin:") ? message : "[Plugin:\(pluginIdentifier)] \(message)"
        TTLogger.shared.log(level: mappedLevel, category: .general, message: formattedMessage)
    }
}
