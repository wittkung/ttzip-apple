// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI

/// Root Plugin Protocol
@MainActor
public protocol TTZipPlugin: AnyObject {
    /// Static plugin manifest
    var manifest: TTZipPluginManifest { get }
    
    /// Lifecycle hooks
    func onInitialize(context: TTZipHostContext) async throws
    func onTerminate() async
    
    /// Standard extension point contributions (default no-op implementations provided)
    var sidebarItem: TTZipSidebarContribution? { get }
    @ViewBuilder func makeWorkspaceView(tabIdentifier: String) -> AnyView?
    @ViewBuilder func makeInspectorView(selectedContext: Any?) -> AnyView?
    var previewProviders: [TTZipPreviewProvider] { get }
    var archiveSourceProviders: [TTZipArchiveSourceProvider] { get }
    var omnibarCommands: [TTZipCommandAction] { get }
    var contextMenuActions: [TTZipContextMenuAction] { get }
    @ViewBuilder func makeSettingsView() -> AnyView?
}

public extension TTZipPlugin {
    var sidebarItem: TTZipSidebarContribution? { nil }
    func makeWorkspaceView(tabIdentifier: String) -> AnyView? { nil }
    func makeInspectorView(selectedContext: Any?) -> AnyView? { nil }
    var previewProviders: [TTZipPreviewProvider] { [] }
    var archiveSourceProviders: [TTZipArchiveSourceProvider] { [] }
    var omnibarCommands: [TTZipCommandAction] { [] }
    var contextMenuActions: [TTZipContextMenuAction] { [] }
    func makeSettingsView() -> AnyView? { nil }
}


