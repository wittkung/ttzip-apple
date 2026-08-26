// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore

/// Official Flagship IINAPlayer Video Playback Plugin
@MainActor
public final class IINAPlayerPlugin: TTZipPlugin, ObservableObject {
    public static let shared = IINAPlayerPlugin()
    
    public static let pluginId = "com.metastudyline.ttzip.plugin.iinaplayer"
    public static let pluginVersion = "1.0.0"
    
    public let manifest: TTZipPluginManifest
    private var hostContext: TTZipHostContext?
    @Published public private(set) var isInitialized: Bool = false
    
    public init() {
        self.manifest = TTZipPluginManifest(
            id: Self.pluginId,
            name: "IINAPlayer",
            version: Self.pluginVersion,
            author: "MetaStudyLine & TTZip Team",
            description: "Official embedded 16-bit Float Metal EDR 1600nits universal video playback engine with ASS vector subtitle rendering & zero-disk IO streaming.",
            iconSystemName: "play.tv.fill",
            homepage: URL(string: "https://github.com/metastudyline/iinaplayer"),
            permissions: [.fileSystemRead, .archiveEngine]
        )
    }
    
    // MARK: - Lifecycle Hooks
    
    public func onInitialize(context: TTZipHostContext) async throws {
        self.hostContext = context
        self.isInitialized = true
        context.showNotification(
            title: "IINAPlayer Plugin Active",
            message: "Metal HDR (1600 nits EDR) & ASS Subtitle engine initialized.",
            level: .info
        )
    }
    
    public func onTerminate() async {
        self.isInitialized = false
        self.hostContext = nil
    }
    
    // MARK: - TTZip Standard Extension Points
    
    public var previewProviders: [TTZipPreviewProvider] {
        [IINAPreviewProvider.shared]
    }
    
    public var sidebarItem: TTZipSidebarContribution? {
        TTZipSidebarContribution(
            id: "iinaplayer.sidebar",
            title: "IINAPlayer",
            icon: "play.tv.fill",
            badgeText: "HDR",
            targetTabIdentifier: "iinaplayer.workspace",
            priority: 50
        )
    }
    
    public var omnibarCommands: [TTZipCommandAction] {
        [
            TTZipCommandAction(
                id: "iinaplayer.open_video",
                title: "Play Video in IINAPlayer HDR Viewport",
                icon: "play.circle.fill",
                shortcut: "⌥⌘V"
            ) {
                // Command action trigger
            }
        ]
    }
    
    public var contextMenuActions: [TTZipContextMenuAction] {
        [
            TTZipContextMenuAction(
                id: "iinaplayer.play_media",
                title: "Play with IINAPlayer (Metal EDR)",
                icon: "play.tv.fill"
            ) { _ in
                // Context menu action trigger
            }
        ]
    }
    
    public func makeWorkspaceView(tabIdentifier: String) -> AnyView? {
        guard tabIdentifier == "iinaplayer.workspace" else { return nil }
        return AnyView(
            IINAPlayerWorkspaceView()
        )
    }
    
    public func makeInspectorView(selectedContext: Any?) -> AnyView? {
        if let url = selectedContext as? URL, IINAPreviewProvider.shared.canPreview(fileURL: url) {
            return AnyView(
                IINAPlayerInspectorView(fileURL: url)
            )
        }
        return nil
    }
}

// MARK: - Workspace & Inspector Views

public struct IINAPlayerWorkspaceView: View {
    public init() {}
    
    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("IINAPlayer Universal Video Engine")
                .font(.headline)
            Text("Select any media file (MKV, MP4, WebM, AVI, TS, etc.) or nested archive video to launch 16-bit Float Metal EDR playback.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

public struct IINAPlayerInspectorView: View {
    public let fileURL: URL
    
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "film.stack")
                    .foregroundStyle(Color.accentColor)
                Text("IINAPlayer Media Inspector")
                    .font(.subheadline.bold())
            }
            Divider()
            Text("Target: \(fileURL.lastPathComponent)")
                .font(.caption)
            Text("Format: \(fileURL.pathExtension.uppercased())")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("HDR EDR 1600 nits")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
                Text("ASS Vector Subtitles")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
            }
        }
        .padding(12)
    }
}

// MARK: - Entry Point for Dynamic Mach-O Plugin Loader
 
@_cdecl("createTTZipPlugin")
@MainActor
public func createTTZipPlugin() -> UnsafeMutableRawPointer {
    let instance = IINAPlayerPlugin.shared
    return Unmanaged.passRetained(instance).toOpaque()
}

