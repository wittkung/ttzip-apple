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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    private var openURLHandler: (@Sendable @MainActor (URL) -> Void)?
    
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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMicrokernelLoggingBridge()
        MainThreadHangWatchdog.shared.start()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        MainThreadHangWatchdog.shared.stop()
        TTLogFileWriter.shared.flushSync()
        TempDirectoryCleanUpManager.shared.cleanupAllTemporaryDirectories()
    }
    
    func registerHandler(_ handler: @escaping @Sendable @MainActor (URL) -> Void) {
        self.openURLHandler = handler
        let urlsToProcess = self.pendingURLs
        self.pendingURLs.removeAll()
        for url in urlsToProcess {
            handler(url)
        }
    }
    
    private func handleOpenedURL(_ url: URL) {
        if let handler = openURLHandler {
            handler(url)
        } else {
            pendingURLs.append(url)
        }
    }
}

// MARK: - Rust Microkernel Logging Bridge

private typealias TTZipCLogCallback = @convention(c) (
    Int32,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    Int32,
    UnsafeMutableRawPointer?
) -> Void

@_silgen_name("ttzip_rust_set_logger")
private func set_logger_callback(
    _ callback: TTZipCLogCallback?,
    _ minLevel: Int32,
    _ userData: UnsafeMutableRawPointer?
) -> Int32

private func setupMicrokernelLoggingBridge() {
    let callback: TTZipCLogCallback = { levelRaw, targetModule, cMessage, cFile, line, _ in
        let msg = cMessage.map { String(cString: $0) } ?? ""
        let file = cFile.map { String(cString: $0) } ?? "rust"
        let target = targetModule.map { String(cString: $0) } ?? "kernel"
        let level: TTLogger.Level
        switch levelRaw {
        case 0: level = .debug
        case 1: level = .info
        case 2: level = .warning
        case 3: level = .error
        default: level = .info
        }
        let formatted = target.isEmpty ? msg : "[\(target)] \(msg)"
        TTLogger.shared.log(
            level: level,
            category: .kernel,
            message: formatted,
            file: file,
            line: UInt(max(0, line))
        )
    }
    _ = set_logger_callback(callback, 0, nil)
}

struct TTZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        setupMicrokernelLoggingBridge()
        MainThreadHangWatchdog.shared.start()
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
                .frame(minWidth: 720, minHeight: 400)
                .background(WindowTabbingConfigurator())
                .background(Color.clear)
                .ignoresSafeArea()
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        
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
        window.isOpaque = false
        window.backgroundColor = .clear
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
