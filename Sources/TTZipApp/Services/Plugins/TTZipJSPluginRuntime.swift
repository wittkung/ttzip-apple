// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import JavaScriptCore
import SwiftUI

/// 沙盒版 JavaScriptCore 运行时
public final class TTZipJSPluginRuntime: @unchecked Sendable {
    private let context: JSContext
    private let pluginID: String
    private var observers: [NSObjectProtocol] = []
    
    public init?(pluginID: String) {
        self.pluginID = pluginID
        guard let ctx = JSContext() else {
            return nil
        }
        self.context = ctx
        setupSandbox()
    }
    
    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setupSandbox() {
        context.exceptionHandler = { [weak self] _, exception in
            if let exception = exception, let pid = self?.pluginID {
                print("JS Error in plugin \(pid): \(exception)")
            }
        }
        
        guard let ttzipHost = JSValue(newObjectIn: context) else { return }
        
        let log: @convention(block) (String, String) -> Void = { level, message in
            print("[\(level.uppercased())] \(message)")
        }
        ttzipHost.setValue(log, forProperty: "log")
        
        let showNotification: @convention(block) (String, String, String) -> Void = { title, message, level in
            print("Notification (\(level)): \(title) - \(message)")
        }
        ttzipHost.setValue(showNotification, forProperty: "showNotification")
        
        let getKeychain: @convention(block) (String, JSValue) -> Void = { key, callback in
            // Mock keychain read
            callback.call(withArguments: ["mock_value_\(key)"])
        }
        ttzipHost.setValue(getKeychain, forProperty: "getKeychain")
        
        let setKeychain: @convention(block) (String, String) -> Void = { key, value in
            print("Keychain SET: \(key) = \(value)")
        }
        ttzipHost.setValue(setKeychain, forProperty: "setKeychain")
        
        let inspectArchive: @convention(block) (String, JSValue) -> Void = { path, callback in
            callback.call(withArguments: [["status": "success", "files": ["file1.txt"]]])
        }
        ttzipHost.setValue(inspectArchive, forProperty: "inspectArchive")
        
        let extractArchive: @convention(block) (String, String, JSValue) -> Void = { path, dest, callback in
            callback.call(withArguments: [true])
        }
        ttzipHost.setValue(extractArchive, forProperty: "extractArchive")
        
        let onEvent: @convention(block) (String, JSValue) -> Void = { [weak self] name, callback in
            let token = NotificationCenter.default.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { notification in
                if let userInfo = notification.userInfo {
                    callback.call(withArguments: [userInfo])
                } else {
                    callback.call(withArguments: [])
                }
            }
            self?.observers.append(token)
        }
        ttzipHost.setValue(onEvent, forProperty: "onEvent")
        
        let publishEvent: @convention(block) (String, [String: Any]) -> Void = { name, data in
            NotificationCenter.default.post(name: NSNotification.Name(name), object: nil, userInfo: data)
        }
        ttzipHost.setValue(publishEvent, forProperty: "publishEvent")
        
        guard let ttzipObj = JSValue(newObjectIn: context) else { return }
        ttzipObj.setValue(ttzipHost, forProperty: "host")
        context.setObject(ttzipObj, forKeyedSubscript: "ttzip" as NSString)
    }
    
    public func loadScript(_ script: String) {
        context.evaluateScript(script)
    }
    
    public func onInitialize() {
        if let plugin = context.objectForKeyedSubscript("plugin") {
            plugin.invokeMethod("onInitialize", withArguments: [])
        }
    }
    
    @MainActor
    public func renderSettings() -> AnyView {
        guard let plugin = context.objectForKeyedSubscript("plugin"),
              plugin.hasProperty("renderSettings"),
              let jsonValue = plugin.invokeMethod("renderSettings", withArguments: []),
              let dict = jsonValue.toDictionary() as? [String: Any] else {
            return AnyView(Text("No Settings UI").foregroundColor(.secondary))
        }
        
        return TTZipDeclarativeUI.render(json: dict)
    }
    
    @MainActor
    public func renderWorkspace() -> AnyView {
        guard let plugin = context.objectForKeyedSubscript("plugin"),
              plugin.hasProperty("renderWorkspace"),
              let jsonValue = plugin.invokeMethod("renderWorkspace", withArguments: []),
              let dict = jsonValue.toDictionary() as? [String: Any] else {
            return AnyView(Text("No Workspace UI").foregroundColor(.secondary))
        }
        
        return TTZipDeclarativeUI.render(json: dict)
    }
}
