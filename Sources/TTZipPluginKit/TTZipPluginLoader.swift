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
            PluginKitLogger.error("[TTZipPluginLoader] Failed to open bundle at: \(bundleURL.path)")
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
                    PluginKitLogger.debug("[TTZipPluginLoader] dlsym instance acquired: \(type(of: instance))")
                    if let plugin = instance as? TTZipPlugin {
                        resolvedPlugin = plugin
                    } else {
                        PluginKitLogger.error("[TTZipPluginLoader] instance \(type(of: instance)) failed to cast to TTZipPlugin protocol")
                    }
                } else {
                    if let err = dlerror() {
                        PluginKitLogger.error("[TTZipPluginLoader] dlsym failed: \(String(cString: err))")
                    }
                }
            } else {
                if let err = dlerror() {
                    PluginKitLogger.error("[TTZipPluginLoader] dlopen failed: \(String(cString: err))")
                }
            }
            
            // Mechanism 2: Fallback to principalClass reflection
            if resolvedPlugin == nil {
                if let principalClass = bundle.principalClass as? NSObject.Type {
                    let instance = principalClass.init()
                    if let pluginInstance = instance as? TTZipPlugin {
                        resolvedPlugin = pluginInstance
                    }
                }
            }
            
            guard let pluginInstance = resolvedPlugin else {
                PluginKitLogger.error("[TTZipPluginLoader] Could not resolve valid TTZipPlugin instance for: \(bundleURL.lastPathComponent)")
                return
            }
            
            // Version compatibility gate: minHostVersion verification
            if let minVersion = pluginInstance.manifest.minHostVersion {
                let hostVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                if hostVersion.compare(minVersion, options: .numeric) == .orderedAscending {
                    PluginKitLogger.error("[TTZipPluginLoader] Incompatible host version for plugin \(pluginInstance.manifest.id). Required: \(minVersion), current: \(hostVersion)")
                    return
                }
            }
            
            let scopedContext = PluginScopedHostContext(
                pluginIdentifier: pluginInstance.manifest.id,
                baseContext: context,
                masterKeychain: context.keychain
            )
            await TTZipPluginRegistry.shared.register(plugin: pluginInstance, context: scopedContext)
            PluginKitLogger.info("[TTZipPluginLoader] Successfully loaded plugin: \(pluginInstance.manifest.name) v\(pluginInstance.manifest.version)")
        } catch {
            PluginKitLogger.error("[TTZipPluginLoader] Soft-fail: Could not load plugin at \(bundleURL.lastPathComponent): \(error)")
        }
    }
}
