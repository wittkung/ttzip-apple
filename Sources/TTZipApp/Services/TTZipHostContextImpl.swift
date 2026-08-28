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

/// Production host capability implementation injected into TTZip plugins.
@MainActor
public final class TTZipHostContextImpl: TTZipHostContext, ObservableObject {
    public static let shared = TTZipHostContextImpl()
    
    public var pluginIdentifier: String { "com.ttzip.host" }
    
    public let keychain: TTZipKeychainStore = TTZipPluginKit.SystemKeychainStore.shared
    
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
}
