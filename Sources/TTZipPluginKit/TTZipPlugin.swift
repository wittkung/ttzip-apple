// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI

/// 插件根协议 (Root Plugin Protocol)
@MainActor
public protocol TTZipPlugin: AnyObject {
    /// 插件静态清单
    var manifest: TTZipPluginManifest { get }
    
    /// 生命周期钩子
    func onInitialize(context: TTZipHostContext) async throws
    func onTerminate() async
    
    /// 8 大标准扩展点贡献 (默认提供空实现，插件按需覆盖)
    var sidebarItem: TTZipSidebarContribution? { get }
    @ViewBuilder func makeWorkspaceView(tabIdentifier: String) -> AnyView?
    @ViewBuilder func makeInspectorView(selectedContext: Any?) -> AnyView?
    var previewProviders: [TTZipPreviewProvider] { get }
    var archiveSourceProviders: [TTZipArchiveSourceProvider] { get }
    var omnibarCommands: [TTZipCommandAction] { get }
    var contextMenuActions: [TTZipContextMenuAction] { get }
}

public extension TTZipPlugin {
    var sidebarItem: TTZipSidebarContribution? { nil }
    func makeWorkspaceView(tabIdentifier: String) -> AnyView? { nil }
    func makeInspectorView(selectedContext: Any?) -> AnyView? { nil }
    var previewProviders: [TTZipPreviewProvider] { [] }
    var archiveSourceProviders: [TTZipArchiveSourceProvider] { [] }
    var omnibarCommands: [TTZipCommandAction] { [] }
    var contextMenuActions: [TTZipContextMenuAction] { [] }
}

/// C-ABI 兼容的跨 Mach-O 虚函数表 (ABI v1)
public struct TTZipPluginVTable_v1: Sendable {
    public var structSize: Int
    public var version: UInt32
    
    public var initialize: (@convention(c) (UnsafeRawPointer, UnsafeMutableRawPointer?) -> Int32)?
    public var terminate: (@convention(c) (UnsafeRawPointer) -> Void)?
    public var getManifestJSON: (@convention(c) (UnsafeRawPointer) -> UnsafePointer<CChar>?)?
    public var releaseString: (@convention(c) (UnsafePointer<CChar>?) -> Void)?
    public var makeWorkspaceView: (@convention(c) (UnsafeRawPointer, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?)?
    public var makeInspectorView: (@convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?)?
    public var destroyInstance: (@convention(c) (UnsafeRawPointer) -> Void)?
    
    public init(
        structSize: Int = MemoryLayout<TTZipPluginVTable_v1>.size,
        version: UInt32 = 1,
        initialize: (@convention(c) (UnsafeRawPointer, UnsafeMutableRawPointer?) -> Int32)? = nil,
        terminate: (@convention(c) (UnsafeRawPointer) -> Void)? = nil,
        getManifestJSON: (@convention(c) (UnsafeRawPointer) -> UnsafePointer<CChar>?)? = nil,
        releaseString: (@convention(c) (UnsafePointer<CChar>?) -> Void)? = nil,
        makeWorkspaceView: (@convention(c) (UnsafeRawPointer, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?)? = nil,
        makeInspectorView: (@convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?)? = nil,
        destroyInstance: (@convention(c) (UnsafeRawPointer) -> Void)? = nil
    ) {
        self.structSize = structSize
        self.version = version
        self.initialize = initialize
        self.terminate = terminate
        self.getManifestJSON = getManifestJSON
        self.releaseString = releaseString
        self.makeWorkspaceView = makeWorkspaceView
        self.makeInspectorView = makeInspectorView
        self.destroyInstance = destroyInstance
    }
}
