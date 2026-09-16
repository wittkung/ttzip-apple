// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import AppKit
import SwiftUI
import CoreServices

/// File watcher for plugin development auto-reload
@MainActor
public final class PluginDevWatcher: ObservableObject {
    @AppStorage("com.ttzip.developerMode.autoReload")
    public var isAutoReloadEnabled: Bool = false {
        didSet {
            if isAutoReloadEnabled {
                startWatching()
            } else {
                stopWatching()
            }
        }
    }
    
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private var debounceTimer: Timer?
    private let pluginsDirectory: URL
    
    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        pluginsDirectory = appSupport.appendingPathComponent("TTZip/Plugins", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        
        if isAutoReloadEnabled {
            startWatching()
        }
    }
    
    deinit {
        let currentStream = stream
        if let s = currentStream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
    
    private func startWatching() {
        guard stream == nil else { return }
        
        let path = pluginsDirectory.path as CFString
        let pathsToWatch = [path] as CFArray
        
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                guard let info = clientCallBackInfo else { return }
                let watcher = Unmanaged<PluginDevWatcher>.fromOpaque(info).takeUnretainedValue()
                
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
                for path in paths {
                    if path.hasSuffix(".ttplugin") {
                        Task { @MainActor in
                            watcher.triggerReload()
                        }
                        break
                    }
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // 500ms debounce internal to FSEvents
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )
        
        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }
    
    private func stopWatching() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debounceTimer?.invalidate()
        debounceTimer = nil
    }
    
    public func triggerReload() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            Task { @MainActor in
                print("[PluginDevWatcher] Detected plugin changes. Relaunching...")
                NSApplication.relaunch()
            }
        }
    }
}
