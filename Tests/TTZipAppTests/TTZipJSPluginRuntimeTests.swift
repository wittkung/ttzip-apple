// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
@testable import TTZipApp

final class TTZipJSPluginRuntimeTests: XCTestCase {
    
    @MainActor
    func testJSSandboxInjection() {
        let runtime = TTZipJSPluginRuntime(pluginID: "test-plugin-1")
        XCTAssertNotNil(runtime)
        
        let script = """
        var plugin = {
            onInitialize: function() {
                ttzip.host.log("info", "initialized");
                ttzip.host.setKeychain("token", "123");
            },
            renderWorkspace: function() {
                return {
                    "type": "vstack",
                    "children": [
                        { "type": "text", "text": "Hello JS", "color": "blue" },
                        { "type": "button", "title": "Click Me", "onTap": "btn1" }
                    ]
                };
            }
        };
        """
        
        runtime?.loadScript(script)
        runtime?.onInitialize()
        
        let view = runtime?.renderWorkspace()
        XCTAssertNotNil(view)
    }
    
    @MainActor
    func testDeclarativeUIErrorFallback() {
        let badJson: [String: Any] = ["type": "unknown_type"]
        let view = TTZipDeclarativeUI.render(json: badJson)
        XCTAssertNotNil(view) // Should return an error placeholder view without crashing
    }
}
