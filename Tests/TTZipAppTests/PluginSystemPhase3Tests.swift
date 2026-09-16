// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
@testable import TTZipApp
import TTZipPluginKit

@MainActor
final class PluginSystemPhase3Tests: XCTestCase {
    
    func testSafeModeCrashStateEvaluationAndReset() {
        let manager = TTZipPluginSafeModeManager.shared
        manager.resetSafeMode()
        XCTAssertFalse(manager.isSafeModeActive)
        
        // Initial launch establishes baseline timestamp
        manager.evaluateCrashState()
        XCTAssertFalse(manager.isSafeModeActive)
        
        // Simulating 3 consecutive rapid restarts / crashes within 8 seconds
        manager.evaluateCrashState() // crash 1
        manager.evaluateCrashState() // crash 2
        manager.evaluateCrashState() // crash 3 -> activates Safe Mode
        XCTAssertTrue(manager.isSafeModeActive)
        
        manager.resetSafeMode()
        XCTAssertFalse(manager.isSafeModeActive)
    }
    
    func testPluginScopedHostContextStorageDirectory() {
        let baseContext = TTZipHostContextImpl.shared
        let scopedContext = PluginScopedHostContext(
            pluginIdentifier: "com.test.phase3",
            baseContext: baseContext,
            masterKeychain: HostKeychainStore.shared
        )
        
        let storageURL = scopedContext.storageDirectory
        XCTAssertTrue(storageURL.path.contains("TTZip/PluginData/com.test.phase3"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))
        
        try? FileManager.default.removeItem(at: storageURL)
    }
    
    func testPluginScopedKeychainIsolationPrefixing() async throws {
        let mockMaster = MockKeychainStore()
        let scopedStore = ScopedKeychainStore(pluginPrefix: "com.plugin.test.", underlyingStore: mockMaster)
        
        try await scopedStore.set(key: "api_token", value: "secret_123")
        let retrieved = try await scopedStore.get(key: "api_token")
        XCTAssertEqual(retrieved, "secret_123")
        
        let rawUnderlying = try await mockMaster.get(key: "com.plugin.test.api_token")
        XCTAssertEqual(rawUnderlying, "secret_123")
        
        try await scopedStore.delete(key: "api_token")
        let deleted = try await scopedStore.get(key: "api_token")
        XCTAssertNil(deleted)
    }
    
    func testPluginScopedEventBusNamespacingAndCleanup() {
        let baseContext = TTZipHostContextImpl.shared
        let scopedContext = PluginScopedHostContext(
            pluginIdentifier: "com.test.events",
            baseContext: baseContext,
            masterKeychain: HostKeychainStore.shared
        )
        
        struct TestPayload: Codable, Sendable {
            let message: String
        }
        
        let exp = expectation(description: "Event received with scoped namespace")
        
        let token = scopedContext.subscribeEvent(TestPayload.self, name: "did_complete") { payload in
            XCTAssertEqual(payload.message, "hello_world")
            exp.fulfill()
        }
        
        scopedContext.publishEvent(name: "did_complete", event: TestPayload(message: "hello_world"))
        wait(for: [exp], timeout: 2.0)
        
        scopedContext.unsubscribeEvent(token: token)
        scopedContext.cleanupTokens()
    }
    
    func testTTZipArchiveEntryModel() throws {
        let entry = TTZipArchiveEntry(
            path: "docs/readme.txt",
            uncompressedSize: 1024,
            compressedSize: 512,
            isDirectory: false,
            modificationDate: Date(timeIntervalSince1970: 1700000000),
            isEncrypted: false,
            compressionMethod: "deflate"
        )
        
        XCTAssertEqual(entry.id, "docs/readme.txt")
        XCTAssertEqual(entry.uncompressedSize, 1024)
        XCTAssertEqual(entry.compressedSize, 512)
        XCTAssertFalse(entry.isDirectory)
        
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TTZipArchiveEntry.self, from: data)
        XCTAssertEqual(decoded.path, entry.path)
        XCTAssertEqual(decoded.uncompressedSize, entry.uncompressedSize)
    }
}

private actor MockKeychainStore: TTZipKeychainStore {
    private var storage: [String: String] = [:]
    
    func get(key: String) async throws -> String? {
        storage[key]
    }
    
    func set(key: String, value: String) async throws {
        storage[key] = value
    }
    
    func delete(key: String) async throws {
        storage.removeValue(forKey: key)
    }
}
