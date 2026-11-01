// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import TTLogKit
import TTZipCore
import TTZipPreviewKit
import TTZipUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationState {
        case running
        case shuttingDown(Task<Void, Never>)
        case terminated
    }

    public static private(set) weak var shared: AppDelegate?
    public let modelManager: LocalModelManager
    public var onPrepareForTermination: (@MainActor () -> Void)?
    private let terminationReplyHandler: (@MainActor (Bool) -> Void)?
    private var terminationState: TerminationState = .running
    private var pendingURLs: [URL] = []
    private var openURLHandlers: [UUID: @Sendable @MainActor (URL) -> Void] = [:]
    
    public override convenience init() {
        self.init(
            modelManager: .shared,
            terminationReplyHandler: nil,
            onPrepareForTermination: nil,
            registerAsShared: true
        )
    }

    public init(
        modelManager: LocalModelManager,
        terminationReplyHandler: (@MainActor (Bool) -> Void)? = nil,
        onPrepareForTermination: (@MainActor () -> Void)? = nil,
        registerAsShared: Bool = false
    ) {
        self.modelManager = modelManager
        self.terminationReplyHandler = terminationReplyHandler
        self.onPrepareForTermination = onPrepareForTermination
        super.init()
        if registerAsShared {
            LayoutStateMigration.migrateIfNeeded()
            Self.shared = self
        }
    }
    
    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        _ = BrowserWindowRouter.shared.routeExternalOpen(urls: urls)
        sender.reply(toOpenOrPrint: .success)
    }
    
    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        _ = BrowserWindowRouter.shared.routeExternalOpen(urls: [url])
        return true
    }
    
    public func application(_ application: NSApplication, open urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        if !fileURLs.isEmpty {
            _ = BrowserWindowRouter.shared.routeExternalOpen(urls: fileURLs)
        }
        let nonFileURLs = urls.filter { !$0.isFileURL }
        for url in nonFileURLs {
            handleCustomSchemeURL(url)
        }
    }
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        TTZipCore.enableMicrokernelLoggingBridge()
        TTLogKit.MainThreadHangWatchdog.shared.start()
        TTZipEngineFacade.initializeSubsystems()
        _ = AppMemoryPressureCoordinator.shared
        Task.detached(priority: .utility) {
            ExtractionStagingRegistry.shared.sweepOnLaunch()
        }
        
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
        
        AppLocalizationState.onLanguageChanged = { language in
            AppKitMenuSynchronizer.shared.synchronize(language: language)
        }
        AppKitMenuSynchronizer.shared.synchronize(language: AppLocalizationState.shared.currentLanguage)
    }
    
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch terminationState {
        case .terminated:
            return .terminateNow
        case .shuttingDown:
            return .terminateLater
        case .running:
            onPrepareForTermination?()
            let replyHandler = self.terminationReplyHandler ?? { shouldTerminate in
                sender.reply(toApplicationShouldTerminate: shouldTerminate)
            }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                let didReleaseCleanly = await self.modelManager.shutdown()
                if didReleaseCleanly {
                    self.terminationState = .terminated
                    replyHandler(true)
                } else {
                    self.terminationState = .running
                    replyHandler(false)
                }
            }
            terminationState = .shuttingDown(task)
            return .terminateLater
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
    }

    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockMenuController.shared.buildDockMenu(language: AppLocalizationState.shared.currentLanguage)
    }
    
    @objc public func openWindowForPath(_ path: String) {
        let url = URL(fileURLWithPath: path)
        openNewWindow(for: url)
    }

    public func openNewWindow() {
        _ = BrowserWindowRouter.shared.openNewWindow()
    }

    public func openNewWindow(for url: URL) {
        _ = BrowserWindowRouter.shared.openInNewWindow(url: url)
    }
    
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        let registry = BrowserWindowRegistry.shared
        let applicationWindows = sender.windows
        if let window = registry.restorableBrowserWindow(in: applicationWindows)
            ?? restorableStandaloneWindow(in: applicationWindows) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            registry.activateNSWindow(window)
            window.makeKeyAndOrderFront(nil)
        } else {
            _ = BrowserWindowRouter.shared.openNewWindow()
        }
        return true
    }

    private func restorableStandaloneWindow(in applicationWindows: [NSWindow]) -> NSWindow? {
        if let player = StandalonePlaybackWindowManager.shared.playerWindow,
           applicationWindows.contains(where: { $0 === player }),
           player.canBecomeMain {
            return player
        }
        return applicationWindows.first {
            !($0 is NSPanel)
                && $0.canBecomeMain
                && $0.delegate === StandalonePreviewWindowManager.shared
        }
    }
    
    public final class RegistrationToken: @unchecked Sendable {
        private let onCancel: () -> Void
        fileprivate init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }
        public func cancel() {
            onCancel()
        }
        deinit {
            onCancel()
        }
    }

    public func registerHandler(_ handler: @escaping @Sendable @MainActor (URL) -> Void) -> RegistrationToken {
        let id = UUID()
        openURLHandlers[id] = handler
        if !pendingURLs.isEmpty {
            let queued = pendingURLs
            pendingURLs.removeAll()
            for url in queued {
                handler(url)
            }
        }
        return RegistrationToken { [weak self] in
            Task { @MainActor in
                self?.openURLHandlers.removeValue(forKey: id)
            }
        }
    }
    
    private func handleCustomSchemeURL(_ url: URL) {
        if let firstHandler = openURLHandlers.values.first {
            firstHandler(url)
        } else {
            pendingURLs.append(url)
        }
        if let window = BrowserWindowRegistry.shared.activeController.flatMap({ BrowserWindowRegistry.shared.nsWindow(for: $0.windowID) })
            ?? NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
