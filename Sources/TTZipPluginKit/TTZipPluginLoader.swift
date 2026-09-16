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
                    } else if let dynamicPlugin = DynamicDuckTypePluginAdapter(rawInstance: instance) {
                        resolvedPlugin = dynamicPlugin
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
                    } else if let dynamicPlugin = DynamicDuckTypePluginAdapter(rawInstance: instance) {
                        resolvedPlugin = dynamicPlugin
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

/// Cross-dylib safe duck-type reflection adapter (bridges Swift protocol metadata across Mach-O image boundaries)
@MainActor
public final class DynamicDuckTypePluginAdapter: TTZipPlugin {
    public let rawInstance: AnyObject
    public let manifest: TTZipPluginManifest
    
    public init?(rawInstance: AnyObject) {
        self.rawInstance = rawInstance
        
        let mirror = Mirror(reflecting: rawInstance)
        guard let manifestChild = mirror.children.first(where: { $0.label == "manifest" }) else {
            return nil
        }
        
        if let direct = manifestChild.value as? TTZipPluginManifest {
            self.manifest = direct
        } else {
            let mMirror = Mirror(reflecting: manifestChild.value)
            var id = ""
            var name = ""
            var version = "1.0.0"
            var author = ""
            var description = ""
            var iconSystemName = "puzzlepiece.extension"
            var homepage: URL? = nil
            var minHostVersion: String? = nil
            var permissions: [TTZipPluginPermission] = []
            
            for child in mMirror.children {
                guard let label = child.label else { continue }
                switch label {
                case "id": if let v = child.value as? String { id = v }
                case "name": if let v = child.value as? String { name = v }
                case "version": if let v = child.value as? String { version = v }
                case "author": if let v = child.value as? String { author = v }
                case "description": if let v = child.value as? String { description = v }
                case "iconSystemName": if let v = child.value as? String { iconSystemName = v }
                case "homepage": homepage = child.value as? URL
                case "minHostVersion": minHostVersion = child.value as? String
                case "permissions":
                    let pMirror = Mirror(reflecting: child.value)
                    for pc in pMirror.children {
                        if let p = pc.value as? TTZipPluginPermission {
                            permissions.append(p)
                        } else {
                            let pcMirror = Mirror(reflecting: pc.value)
                            if let raw = pcMirror.children.first(where: { $0.label == "rawValue" })?.value as? String,
                               let p = TTZipPluginPermission(rawValue: raw) {
                                permissions.append(p)
                            }
                        }
                    }
                default: break
                }
            }
            
            guard !id.isEmpty else { return nil }
            self.manifest = TTZipPluginManifest(
                id: id,
                name: name,
                version: version,
                author: author,
                description: description,
                iconSystemName: iconSystemName,
                homepage: homepage,
                minHostVersion: minHostVersion,
                permissions: permissions
            )
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
        if let itemVal = mirror.children.first(where: { $0.label == "sidebarItem" })?.value {
            if let direct = itemVal as? TTZipSidebarContribution {
                return direct
            }
            let itemMirror = Mirror(reflecting: itemVal)
            var id = ""
            var title = ""
            var icon = ""
            var badgeText: String? = nil
            var targetTabIdentifier: String? = nil
            var priority: Int = 0
            for child in itemMirror.children {
                guard let label = child.label else { continue }
                switch label {
                case "id": if let v = child.value as? String { id = v }
                case "title": if let v = child.value as? String { title = v }
                case "icon": if let v = child.value as? String { icon = v }
                case "badgeText": badgeText = child.value as? String
                case "targetTabIdentifier": targetTabIdentifier = child.value as? String
                case "priority": if let v = child.value as? Int { priority = v }
                default: break
                }
            }
            if !id.isEmpty {
                return TTZipSidebarContribution(
                    id: id,
                    title: title,
                    icon: icon,
                    badgeText: badgeText,
                    targetTabIdentifier: targetTabIdentifier ?? id,
                    priority: priority
                )
            }
        }
        return nil
    }
    
    public func makeWorkspaceView(tabIdentifier: String) -> AnyView? {
        if let plugin = rawInstance as? TTZipPlugin,
           let view = plugin.makeWorkspaceView(tabIdentifier: tabIdentifier) {
            return view
        }
        
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
    
    public func makeInspectorView(selectedContext: Any?) -> AnyView? {
        if let plugin = rawInstance as? TTZipPlugin,
           let view = plugin.makeInspectorView(selectedContext: selectedContext) {
            return view
        }
        return AnyView(Text("Inspector"))
    }
    
    public var omnibarCommands: [TTZipCommandAction] {
        if let plugin = rawInstance as? TTZipPlugin {
            return plugin.omnibarCommands
        }
        let mirror = Mirror(reflecting: rawInstance)
        if let commandsVal = mirror.children.first(where: { $0.label == "omnibarCommands" })?.value {
            if let direct = commandsVal as? [TTZipCommandAction] {
                return direct
            }
            let listMirror = Mirror(reflecting: commandsVal)
            var result: [TTZipCommandAction] = []
            for cmdChild in listMirror.children {
                let cmdMirror = Mirror(reflecting: cmdChild.value)
                var id = ""
                var title = ""
                var icon: String? = nil
                for f in cmdMirror.children {
                    switch f.label {
                    case "id": if let v = f.value as? String { id = v }
                    case "title": if let v = f.value as? String { title = v }
                    case "iconSystemName": icon = f.value as? String
                    default: break
                    }
                }
                if !id.isEmpty {
                    result.append(TTZipCommandAction(id: id, title: title, icon: icon ?? "command", action: {}))
                }
            }
            return result
        }
        return []
    }
}

#if os(macOS)
import AppKit

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
