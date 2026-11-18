// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipAppComposition
import AppKit
import TTZipTaskKit
import TTZipUI
import TTZipBenchmarkKit

extension GlobalSearchPanelController: GlobalSearchOverlayPanel {}

public struct TTZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    nonisolated public static func shouldActivateOnLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        AppDelegate.shouldActivateOnLaunch(arguments: arguments, environment: environment)
    }
    
    public init() {
        LayoutStateMigration.migrateIfNeeded()
        _ = BrowserWindowRegistry.shared
        LocalModelManager.installAutoSemanticIndexingBridgeIfNeeded()
        ApplicationAppearanceStore.shared.applyCurrentPreference()
        AppStartup.initializeRuntime()
        DockProgressManager.install()
        DiagnosticsSupportService.registerManualUpdateHandler(AppChannelWiring.manualUpdateAction)
        
        NSApplication.shared.setActivationPolicy(.regular)
        if Self.shouldActivateOnLaunch() {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        
        let searchPanel = GlobalSearchPanelController.shared
        GlobalSearchOverlayComposition.install(
            panel: searchPanel,
            content: GlobalSearchPanelView(controller: searchPanel),
            routeResult: { item in
                _ = BrowserWindowRouter.shared.routeGlobalSearchResult(item)
            },
            openArchive: { path in
                BrowserWindowRouter.shared.routeGlobalSearchArchive(archivePath: path)
            },
            selectEntry: { archivePath, entrySubpath in
                _ = BrowserWindowRouter.shared.routeGlobalSearchArchiveEntry(
                    archivePath: archivePath,
                    entrySubpath: entrySubpath
                )
            },
            registerHotkey: { action in
                _ = CarbonHotkeyCenter.shared.register(combo: .defaultGlobalSearch, action: action)
            },
            attachTermination: { action in
                AppDelegate.shared?.onPrepareForTermination = action
            }
        )
        
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
    }
    
    public var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowSceneRootView()
                .background(WindowTabbingConfigurator())
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .handlesExternalEvents(preferring: ["main"], allowing: ["*"])
        }

        Settings {
            SettingsView()
                .frame(
                    minWidth: 480,
                    idealWidth: 720,
                    maxWidth: 860,
                    minHeight: 420,
                    idealHeight: 540,
                    maxHeight: 680
                )
        }
        .commands {
            TTZipMenuCommands(checkForUpdates: AppChannelWiring.manualUpdateAction)
        }
    }
    
    private func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            Task { @MainActor in
                _ = BrowserWindowRouter.shared.routeExternalOpen(urls: [url])
            }
            return
        }
        if let envelope = AppIntentParser.parse(url: url) {
            Task { @MainActor in
                AppIntentDispatcher.shared.dispatch(envelope)
            }
        }
    }
}

@MainActor
package final class WindowConfiguratorNSView: NSView {
    private var hasConfiguredWindowFrame = false

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            Self.configure(window: window, applyInitialFrame: !hasConfiguredWindowFrame)
            hasConfiguredWindowFrame = true
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                Task { @MainActor in
                    Self.hoistTrafficLights(window: window)
                }
            }
        }
    }
    
    package static func configure(window: NSWindow, applyInitialFrame: Bool = false) {
        window.tabbingMode = .disallowed
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        
        let screenFrame = window.screen?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1440, height: 900)
        if applyInitialFrame || window.frame.width < 1080 || window.frame.height < 650 {
            let targetWidth = min(1180, screenFrame.width * 0.85)
            let targetHeight = min(720, screenFrame.height * 0.82)
            let cascadeIndex = max(0, BrowserWindowRegistry.shared.windowCount - 1) % 6
            let cascadeOffset = CGFloat(cascadeIndex) * 26.0
            let originX = min(
                screenFrame.maxX - targetWidth,
                max(screenFrame.origin.x, screenFrame.origin.x + (screenFrame.width - targetWidth) / 2 + cascadeOffset)
            )
            let originY = max(
                screenFrame.origin.y,
                min(screenFrame.maxY - targetHeight, screenFrame.origin.y + (screenFrame.height - targetHeight) / 2 - cascadeOffset)
            )
            window.setFrame(NSRect(x: originX, y: originY, width: targetWidth, height: targetHeight), display: true)
        }
        
        // Explicitly unhide native traffic light buttons and hoist container above SwiftUI hosting view
        hoistTrafficLights(window: window)
        
        // Secondary pass after window layout finishes
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            Self.hoistTrafficLights(window: window)
        }
    }
    
    package static func hoistTrafficLights(window: NSWindow) {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview,
              let closeBtn = window.standardWindowButton(.closeButton),
              let titlebar = closeBtn.superview,
              let container = titlebar.superview else { return }
        
        themeFrame.wantsLayer = true
        unhideStandardButtons(window: window)
        configureTitlebarSurfaces(container: container, titlebar: titlebar)
        
        // Constrain container width strictly to the traffic light clearance (~76pt)
        // so it never occludes or intercepts clicks on interactive header controls to the right of traffic lights
        if !window.styleMask.contains(.fullScreen) {
            let maxButtonMaxX = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0)?.frame.maxX }
                .max() ?? 66.0
            let targetWidth = max(72.0, min(84.0, ceil(maxButtonMaxX + 8.0)))
            if abs(container.frame.width - targetWidth) > 0.5 {
                var r = container.frame
                r.size.width = targetWidth
                container.frame = r
            }
        }
        
        if container.superview === themeFrame && themeFrame.subviews.last !== container {
            pruneTitlebarArtifacts(container: container, titlebar: titlebar)
            themeFrame.addSubview(container, positioned: .above, relativeTo: contentView)
        }
    }

    private static func unhideStandardButtons(window: NSWindow) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for buttonType in buttons {
            if let button = window.standardWindowButton(buttonType) {
                button.isHidden = false
                button.alphaValue = 1.0
            }
        }
    }

    private static func configureTitlebarSurfaces(container: NSView, titlebar: NSView) {
        titlebar.isHidden = false
        titlebar.alphaValue = 1.0
        titlebar.wantsLayer = true
        titlebar.layer?.backgroundColor = NSColor.clear.cgColor

        container.isHidden = false
        container.alphaValue = 1.0
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private static func pruneTitlebarArtifacts(container: NSView, titlebar: NSView) {
        for subview in container.subviews where subview !== titlebar {
            subview.removeFromSuperview()
        }
        for subview in titlebar.subviews {
            let name = String(describing: type(of: subview))
            if name.contains("Background") || name.contains("Text") {
                subview.removeFromSuperview()
            }
        }
        stripHairlineLayers(from: container)
        stripHairlineLayers(from: titlebar)
    }

    private static func stripHairlineLayers(from view: NSView) {
        guard let sublayers = view.layer?.sublayers else { return }
        for sublayer in sublayers {
            let layerType = String(describing: type(of: sublayer))
            if layerType.contains("Backdrop") || sublayer.bounds.height <= 2.0 {
                sublayer.isHidden = true
                sublayer.opacity = 0.0
            }
        }
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
            WindowConfiguratorNSView.hoistTrafficLights(window: window)
        }
    }
}
