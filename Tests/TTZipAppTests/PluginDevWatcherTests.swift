// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
@testable import TTZipApp
@testable import TTZipPluginKit

@MainActor
final class PluginDevWatcherTests: XCTestCase {
    
    func testMockHostContextKeychain() async throws {
        let context = MockHostContext(pluginIdentifier: "test.plugin")
        
        let val = try await context.keychain.get(key: "testKey")
        XCTAssertNil(val)
        
        try await context.keychain.set(key: "testKey", value: "secret")
        let newVal = try await context.keychain.get(key: "testKey")
        XCTAssertEqual(newVal, "secret")
        
        try await context.keychain.delete(key: "testKey")
        let delVal = try await context.keychain.get(key: "testKey")
        XCTAssertNil(delVal)
    }
    
    func testMockHostContextEventBus() async throws {
        let context = MockHostContext(pluginIdentifier: "test.plugin")
        
        struct TestEvent: Codable, Sendable, Equatable {
            let id: Int
            let message: String
        }
        
        let expectation = XCTestExpectation(description: "Event received")
        
        let token = context.subscribeEvent(TestEvent.self, name: "test.event") { event in
            XCTAssertEqual(event.id, 42)
            XCTAssertEqual(event.message, "hello")
            expectation.fulfill()
        }
        
        let event = TestEvent(id: 42, message: "hello")
        context.publishEvent(name: "test.event", event: event)
        
        await fulfillment(of: [expectation], timeout: 1.0)
        
        XCTAssertEqual(context.publishedEvents.count, 1)
        XCTAssertEqual(context.publishedEvents.first?.name, "test.event")
        
        context.unsubscribeEvent(token: token)
    }
    
    func testMockHostContextLoggingAndNotification() async throws {
        let context = MockHostContext(pluginIdentifier: "test.plugin")
        
        context.log(level: .info, message: "Test log")
        XCTAssertEqual(context.loggedMessages.count, 1)
        XCTAssertEqual(context.loggedMessages[0].level, .info)
        XCTAssertEqual(context.loggedMessages[0].message, "Test log")
        
        context.showNotification(title: "Alert", message: "Warning", level: .warning)
        XCTAssertEqual(context.postedNotifications.count, 1)
        XCTAssertEqual(context.postedNotifications[0].title, "Alert")
        XCTAssertEqual(context.postedNotifications[0].message, "Warning")
        XCTAssertEqual(context.postedNotifications[0].level, .warning)
    }
    
    func testPluginDevWatcherStateToggle() throws {
        let watcher = PluginDevWatcher()
        // Reset defaults
        UserDefaults.standard.removeObject(forKey: "com.ttzip.developerMode.autoReload")
        
        XCTAssertFalse(watcher.isAutoReloadEnabled)
        
        watcher.isAutoReloadEnabled = true
        XCTAssertTrue(watcher.isAutoReloadEnabled)
        
        watcher.isAutoReloadEnabled = false
        XCTAssertFalse(watcher.isAutoReloadEnabled)
    }
}
