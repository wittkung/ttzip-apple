// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit

/// A sheet view for configuring plugin developer mode options
public struct DeveloperModeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var devWatcher = PluginDevWatcher()
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Plugin Developer Mode")
                .font(.headline)
            
            Toggle("Auto-reload on changes", isOn: $devWatcher.isAutoReloadEnabled)
                .help("Automatically relaunches the app when a .ttplugin file is modified in the plugins directory.")
            
            HStack {
                Button("Open Plugins Directory") {
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let dir = appSupport.appendingPathComponent("TTZip/Plugins", isDirectory: true)
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
                }
                
                Spacer()
                
                Button("Relaunch App") {
                    NSApplication.relaunch()
                }
                .buttonStyle(.borderedProminent)
            }
            
            Divider()
            
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(width: 400)
    }
}
