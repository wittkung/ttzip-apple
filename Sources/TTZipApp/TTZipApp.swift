// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import AppKit
import TTZipPluginKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var pendingURLs: [URL] = []
    private var openURLHandler: (@Sendable (URL) -> Void)?
    private let lock = NSLock()
    
    override init() {
        super.init()
    }
    
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            handleOpenedURL(url)
        }
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        handleOpenedURL(url)
        return true
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        TempDirectoryCleanUpManager.shared.cleanupAllTemporaryDirectories()
    }
    
    func registerHandler(_ handler: @escaping @Sendable (URL) -> Void) {
        lock.withLock {
            self.openURLHandler = handler
            let urlsToProcess = self.pendingURLs
            self.pendingURLs.removeAll()
            if !urlsToProcess.isEmpty {
                DispatchQueue.main.async {
                    for url in urlsToProcess {
                        handler(url)
                    }
                }
            }
        }
    }
    
    private func handleOpenedURL(_ url: URL) {
        lock.withLock {
            if let handler = openURLHandler {
                DispatchQueue.main.async {
                    handler(url)
                }
            } else {
                pendingURLs.append(url)
            }
        }
    }
}

struct TTZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        TTZipEngineFacade.initializeSubsystems()
        
        TempDirectoryCleanUpManager.shared.cleanupAllTemporaryDirectories()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = true
        
        let possiblePaths = [
            Bundle.main.path(forResource: "TTZip_AppIcon_1024x1024_padded", ofType: "png"),
            Bundle.main.path(forResource: "AppIcon", ofType: "png"),
            Bundle.main.resourcePath.map { ($0 as NSString).appendingPathComponent("TTZip_AppIcon_1024x1024_padded.png") }
        ].compactMap { $0 }
        
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path), let iconImage = NSImage(contentsOfFile: path) {
                NSApplication.shared.applicationIconImage = iconImage
                break
            }
        }
        
        Task { @MainActor in
            await TTZipPluginLoader.loadInstalledPlugins(context: TTZipHostContextImpl.shared)
        }
    }
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 520, minHeight: 400)
                .background(WindowTabbingConfigurator())
                .background(Color.clear)
                .ignoresSafeArea()
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        
        Settings {
            SettingsView()
                .frame(width: 540, height: 420)
        }
        .commands {
            TTZipMenuCommands()
        }
    }
    
    private func handleIncomingURL(_ url: URL) {
        if let envelope = AppIntentParser.parse(url: url) {
            Task { @MainActor in
                AppIntentDispatcher.shared.dispatch(envelope)
            }
        }
    }
}

@MainActor
private final class WindowConfiguratorNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            Self.configure(window: window)
        }
    }
    
    static func configure(window: NSWindow) {
        window.tabbingMode = .preferred
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.styleMask.insert(.fullSizeContentView)
        window.hasShadow = true
        window.collectionBehavior.insert(.fullScreenPrimary)
    }
}

private struct WindowTabbingConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowConfiguratorNSView()
        Task { @MainActor [weak view] in
            if let window = view?.window {
                WindowConfiguratorNSView.configure(window: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            WindowConfiguratorNSView.configure(window: window)
        }
    }
}
