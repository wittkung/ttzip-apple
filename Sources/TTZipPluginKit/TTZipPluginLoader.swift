// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Dynamic plugin discovery and secure bundle loading engine (Dynamic Bundle Plugin Loader)
public enum TTZipPluginLoader {
    /// User plugins directory: ~/Library/Application Support/TTZip/Plugins
    public static var userPluginsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TTZip/Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// Built-in plugins directory: TTZip.app/Contents/PlugIns
    public static var builtInPluginsDirectory: URL? {
        Bundle.main.builtInPlugInsURL
    }
    
    /// Scans and securely loads all installed plugins with isolation and soft-failure recovery
    @MainActor
    public static func loadInstalledPlugins(context: TTZipHostContext) async {
        var pluginURLs: [URL] = []
        
        // 1. Collect built-in plugins
        if let builtIn = builtInPluginsDirectory,
           let items = try? FileManager.default.contentsOfDirectory(at: builtIn, includingPropertiesForKeys: nil) {
            pluginURLs.append(contentsOf: items.filter { $0.pathExtension == "ttplugin" || $0.pathExtension == "bundle" })
        }
        
        // 2. Collect user-installed plugins
        if let userItems = try? FileManager.default.contentsOfDirectory(at: userPluginsDirectory, includingPropertiesForKeys: nil) {
            pluginURLs.append(contentsOf: userItems.filter { $0.pathExtension == "ttplugin" || $0.pathExtension == "bundle" })
        }
        
        // 3. Incrementally load each plugin bundle with fault isolation
        for bundleURL in pluginURLs {
            await loadPluginBundle(at: bundleURL, context: context)
        }
    }
    
    /// Loads a single .ttplugin Bundle
    @MainActor
    public static func loadPluginBundle(at bundleURL: URL, context: TTZipHostContext) async {
        guard let bundle = Bundle(url: bundleURL) else {
            print("[TTZipPluginLoader] Failed to open bundle at: \(bundleURL.path)")
            return
        }
        
        do {
            try bundle.loadAndReturnError()
            
            var resolvedPlugin: TTZipPlugin?
            
            // Mechanism 1: Attempt direct acquisition via exported C factory function (createTTZipPlugin / createTTZipPlugin_v1)
            let executableURL = bundle.executableURL ?? bundleURL.appendingPathComponent("Contents/MacOS/\(bundleURL.deletingPathExtension().lastPathComponent)")
            if let handle = dlopen(executableURL.path, RTLD_NOW) {
                if let sym = dlsym(handle, "createTTZipPlugin") ?? dlsym(handle, "createTTZipPlugin_v1") {
                    typealias CreatePluginFn = @convention(c) () -> UnsafeMutableRawPointer
                    let createFn = unsafeBitCast(sym, to: CreatePluginFn.self)
                    let rawPtr = createFn()
                    let instance = Unmanaged<AnyObject>.fromOpaque(rawPtr).takeRetainedValue()
                    print("[TTZipPluginLoader] dlsym instance acquired: \(type(of: instance))")
                    if let plugin = instance as? TTZipPlugin {
                        resolvedPlugin = plugin
                    } else if let dynamicPlugin = DynamicDuckTypePluginAdapter(rawInstance: instance) {
                        resolvedPlugin = dynamicPlugin
                    } else {
                        print("[TTZipPluginLoader] instance \(type(of: instance)) failed to cast to TTZipPlugin protocol")
                    }
                } else {
                    if let err = dlerror() {
                        print("[TTZipPluginLoader] dlsym failed: \(String(cString: err))")
                    }
                }
            } else {
                if let err = dlerror() {
                    print("[TTZipPluginLoader] dlopen failed: \(String(cString: err))")
                }
            }
            
            // Mechanism 2: Fallback to principalClass reflection
            if resolvedPlugin == nil {
                if let principalClass = bundle.principalClass as? NSObject.Type {
                    let instance = principalClass.init()
                    if let pluginInstance = instance as? TTZipPlugin {
                        resolvedPlugin = pluginInstance
                    } else if let dynamicPlugin = DynamicDuckTypePluginAdapter(rawInstance: instance) {
                        resolvedPlugin = dynamicPlugin
                    }
                }
            }
            
            guard let pluginInstance = resolvedPlugin else {
                print("[TTZipPluginLoader] Could not resolve valid TTZipPlugin instance for: \(bundleURL.lastPathComponent)")
                return
            }
            
            let scopedContext = PluginScopedHostContext(
                pluginIdentifier: pluginInstance.manifest.id,
                baseContext: context,
                masterKeychain: context.keychain
            )
            await TTZipPluginRegistry.shared.register(plugin: pluginInstance, context: scopedContext)
            print("[TTZipPluginLoader] Successfully loaded plugin: \(pluginInstance.manifest.name) v\(pluginInstance.manifest.version)")
        } catch {
            print("[TTZipPluginLoader] Soft-fail: Could not load plugin at \(bundleURL.lastPathComponent): \(error)")
        }
    }
}

/// Cross-dylib safe duck-type reflection adapter (bridges Swift protocol metadata across Mach-O image boundaries)
@MainActor
public final class DynamicDuckTypePluginAdapter: TTZipPlugin {
    public let rawInstance: AnyObject
    public let manifest: TTZipPluginManifest
    
    public init?(rawInstance: AnyObject) {
        self.rawInstance = rawInstance
        
        let mirror = Mirror(reflecting: rawInstance)
        if let manifestVal = mirror.children.first(where: { $0.label == "manifest" })?.value as? TTZipPluginManifest {
            self.manifest = manifestVal
        } else {
            return nil
        }
    }
    
    public func onInitialize(context: TTZipHostContext) async throws {
        if let plugin = rawInstance as? TTZipPlugin {
            try await plugin.onInitialize(context: context)
        }
    }
    
    public func onTerminate() async {
        if let plugin = rawInstance as? TTZipPlugin {
            await plugin.onTerminate()
        }
    }
    
    public var sidebarItem: TTZipSidebarContribution? {
        if let plugin = rawInstance as? TTZipPlugin {
            return plugin.sidebarItem
        }
        let mirror = Mirror(reflecting: rawInstance)
        if let item = mirror.children.first(where: { $0.label == "sidebarItem" })?.value as? TTZipSidebarContribution {
            return item
        }
        return nil
    }
    
    public func makeWorkspaceView(tabIdentifier: String) -> AnyView? {
        if let plugin = rawInstance as? TTZipPlugin,
           let view = plugin.makeWorkspaceView(tabIdentifier: tabIdentifier) {
            return view
        }
        
        // Attempt to acquire via exported standard C view factory function
        if let handle = dlopen(nil, RTLD_NOW),
           let sym = dlsym(handle, "createTTZipWorkspaceView") ?? dlsym(handle, "createTTZipWorkspaceView_v1") {
            typealias GetViewFn = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
            let fn = unsafeBitCast(sym, to: GetViewFn.self)
            let rawPtr = Unmanaged.passUnretained(rawInstance).toOpaque()
            if let resultPtr = tabIdentifier.withCString({ fn(rawPtr, $0) }) {
                let nsView = Unmanaged<NSView>.fromOpaque(resultPtr).takeRetainedValue()
                return AnyView(HostNativePluginViewWrapper(makeView: { nsView }))
            }
        }
        return nil
    }
}

#if os(macOS)
public struct HostNativePluginViewWrapper: NSViewRepresentable {
    public let makeView: () -> NSView?
    
    public init(makeView: @escaping () -> NSView?) {
        self.makeView = makeView
    }
    
    public func makeNSView(context: Context) -> NSView {
        makeView() ?? NSView()
    }
    
    public func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
