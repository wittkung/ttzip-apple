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

/// 动态插件扫描与安全加载引擎 (Dynamic Bundle Plugin Loader)
public enum TTZipPluginLoader {
    /// 用户插件目录: ~/Library/Application Support/TTZip/Plugins
    public static var userPluginsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TTZip/Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// 内置插件目录: TTZip.app/Contents/PlugIns
    public static var builtInPluginsDirectory: URL? {
        Bundle.main.builtInPlugInsURL
    }
    
    /// 扫描并安全动态加载所有插件 (具备异常隔离与软失败保护)
    @MainActor
    public static func loadInstalledPlugins(context: TTZipHostContext) async {
        var pluginURLs: [URL] = []
        
        // 1. 收集内置插件
        if let builtIn = builtInPluginsDirectory,
           let items = try? FileManager.default.contentsOfDirectory(at: builtIn, includingPropertiesForKeys: nil) {
            pluginURLs.append(contentsOf: items.filter { $0.pathExtension == "ttplugin" || $0.pathExtension == "bundle" })
        }
        
        // 2. 收集用户安装插件
        if let userItems = try? FileManager.default.contentsOfDirectory(at: userPluginsDirectory, includingPropertiesForKeys: nil) {
            pluginURLs.append(contentsOf: userItems.filter { $0.pathExtension == "ttplugin" || $0.pathExtension == "bundle" })
        }
        
        // 3. 逐个动态加载并容错隔离
        for bundleURL in pluginURLs {
            await loadPluginBundle(at: bundleURL, context: context)
        }
    }
    
    /// 加载单个 .ttplugin Bundle
    @MainActor
    public static func loadPluginBundle(at bundleURL: URL, context: TTZipHostContext) async {
        guard let bundle = Bundle(url: bundleURL) else {
            print("[TTZipPluginLoader] Failed to open bundle at: \(bundleURL.path)")
            return
        }
        
        do {
            try bundle.loadAndReturnError()
            
            var resolvedPlugin: TTZipPlugin?
            
            // 机制 1: 尝试通过 C 入口函数直接获取 (标准 createTTZipPlugin / createTTZipPlugin_v1)
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
            
            // 机制 2: Fallback 到 principalClass 反射
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

/// 跨 dylib 安全鸭子类型反射适配器 (消除 Swift 跨 Mach-O 镜像协议元数据隔离)
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
        
        // 尝试通过导出的标准 C 视图工厂函数获取 (标准动态入口)
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
