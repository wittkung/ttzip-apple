// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import SwiftUI
import TTKitDesign
import TTZipCore
import TTZipUI

/// Encapsulated, non-blocking execution gateway for system actions on sidebar rows.
@MainActor
public enum SidebarRowSystemActions {
    /// Reveals the file or folder at the specified POSIX path in macOS Finder.
    public static func revealInFinder(path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    /// Asynchronously opens the macOS Finder Get Info inspection panel for the specified path
    /// without blocking the MainActor.
    public static func showFinderGetInfo(path: String) {
        let script = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(path)" as alias)
        end tell
        """
        Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
            }
        }
    }

    /// Launches or activates Terminal.app anchored at the specified POSIX directory path.
    public static func openTerminal(at path: String) {
        let url = URL(fileURLWithPath: path)
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([url], withApplicationAt: terminalURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Copies the full filesystem path into the general pasteboard.
    public static func copyFullPath(path: String) {
        copyFullPath(path: path, pasteboard: .general)
    }

    /// Copies the full filesystem path into the specified pasteboard (used by isolated tests to avoid mutating `NSPasteboard.general`).
    package static func copyFullPath(path: String, pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let fileURL = URL(fileURLWithPath: path)
        pasteboard.writeObjects([fileURL as NSURL, path as NSString])
    }

    /// Copies the folder display name into the general pasteboard.
    public static func copyFolderName(title: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(title, forType: .string)
    }
}

/// Dedicated ViewModifier providing native context menu actions for sidebar favorite and shortcut rows.
public struct SidebarRowContextMenuModifier: ViewModifier {
    public let path: String
    public let title: String
    public let isCustomPinned: Bool
    public let healthState: SidebarItemHealthState
    public let isSelected: Bool
    public let onOpen: (() -> Void)?
    public let onOpenInNewTab: (() -> Void)?
    public let onSelect: (() -> Void)?
    public let onRemove: (() -> Void)?
    public let onStartRename: (() -> Void)?
    public let onQuickLook: (() -> Void)?
    public let onOpenInNewWindow: (() -> Void)?
    public let onRelink: (() -> Void)?

    @State private var isContextMenuActive: Bool = false
    private var l10n = AppLocalizationState.shared

    public init(
        path: String,
        title: String,
        isCustomPinned: Bool,
        healthState: SidebarItemHealthState,
        isSelected: Bool = false,
        onOpen: (() -> Void)? = nil,
        onOpenInNewTab: (() -> Void)? = nil,
        onSelect: (() -> Void)? = nil,
        onRemove: (() -> Void)? = nil,
        onStartRename: (() -> Void)? = nil,
        onQuickLook: (() -> Void)? = nil,
        onOpenInNewWindow: (() -> Void)? = nil,
        onRelink: (() -> Void)? = nil
    ) {
        self.path = path
        self.title = title
        self.isCustomPinned = isCustomPinned
        self.healthState = healthState
        self.isSelected = isSelected
        self.onOpen = onOpen
        self.onOpenInNewTab = onOpenInNewTab
        self.onSelect = onSelect
        self.onRemove = onRemove
        self.onStartRename = onStartRename
        self.onQuickLook = onQuickLook
        self.onOpenInNewWindow = onOpenInNewWindow
        self.onRelink = onRelink
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isContextMenuActive ? TTZipTheme.bambooGreen.opacity(0.16) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isContextMenuActive ? TTZipTheme.bambooGreen.opacity(0.28) : Color.clear,
                        lineWidth: TTZipUniversalTokens.Border.width
                    )
            )
            .overlay(
                Group {
                    if let onSelect {
                        RightClickSelectRepresentable(onRightClick: {
                            isContextMenuActive = true
                            onSelect()
                        })
                    }
                }
            )
            .contextMenu {
                menuContent
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                if isContextMenuActive {
                    withAnimation(.ttMicro) {
                        isContextMenuActive = false
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                if isContextMenuActive {
                    isContextMenuActive = false
                }
            }
    }

    @ViewBuilder
    private var menuContent: some View {
        if healthState.isBroken {
            brokenMenu
        } else if healthState.isVolumeOffline {
            offlineMenu
        } else {
            standardMenu
        }
    }

    @ViewBuilder
    private var brokenMenu: some View {
        Button {
            onRelink?()
        } label: {
            Label(String(localized: "Locate in Finder..."), systemImage: "magnifyingglass")
        }

        Divider()

        if let onRemove {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label(String(localized: "Remove from Favorites"), systemImage: "trash")
                    .foregroundStyle(TTKitTheme.cinnabarRed)
            }
        }
    }

    @ViewBuilder
    private var offlineMenu: some View {
        if let onRemove {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label(String(localized: "Remove from Favorites"), systemImage: "trash")
                    .foregroundStyle(TTKitTheme.cinnabarRed)
            }
        }
    }

    @ViewBuilder
    private var standardMenu: some View {
        Button {
            if let onOpen {
                onOpen()
            } else {
                onSelect?()
            }
        } label: {
            Label(String(localized: "Open"), systemImage: "arrow.up.forward.app")
        }

        if let onOpenInNewTab {
            Button {
                onOpenInNewTab()
            } label: {
                Label(String(localized: "Open in New Tab"), systemImage: "plus.rectangle.on.rectangle")
            }
        }

        if let onOpenInNewWindow {
            Button {
                onOpenInNewWindow()
            } label: {
                Label(l10n.t(MultiWindowLocaleKey.openInNewWindow), systemImage: "macwindow")
            }
        }

        if let onQuickLook {
            Button {
                onQuickLook()
            } label: {
                Label(String(localized: "Quick Look"), systemImage: "eye")
            }
        }

        Divider()

        Button {
            SidebarRowSystemActions.revealInFinder(path: path)
        } label: {
            Label(l10n.t(L10n.Common.revealInFinder), systemImage: "folder")
        }

        Button {
            SidebarRowSystemActions.showFinderGetInfo(path: path)
        } label: {
            Label(String(localized: "Get Info"), systemImage: "info.circle")
        }

        Button {
            SidebarRowSystemActions.openTerminal(at: path)
        } label: {
            Label(String(localized: "Open in Terminal"), systemImage: "terminal")
        }

        Divider()

        Button {
            SidebarRowSystemActions.copyFullPath(path: path)
        } label: {
            Label(String(localized: "Copy Full Path"), systemImage: "doc.on.doc")
        }

        Button {
            SidebarRowSystemActions.copyFolderName(title: title)
        } label: {
            Label(String(localized: "Copy Folder Name"), systemImage: "doc.on.clipboard")
        }

        if isCustomPinned {
            Divider()

            if onStartRename != nil {
                Button {
                    onStartRename?()
                } label: {
                    Label(String(localized: "Rename Shortcut..."), systemImage: "pencil")
                }
            }

            if let onRemove {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label(String(localized: "Remove Shortcut"), systemImage: "trash")
                        .foregroundStyle(TTKitTheme.cinnabarRed)
                }
            }
        } else if let onRemove {
            Divider()

            Button(role: .destructive) {
                onRemove()
            } label: {
                Label(String(localized: "Remove from Favorites"), systemImage: "trash")
                    .foregroundStyle(TTKitTheme.cinnabarRed)
            }
        }
    }
}

/// Transparent AppKit view overlay that intercepts right-click events to select the row
/// before the system presents the context menu, matching macOS Finder source list behavior.
public struct RightClickSelectRepresentable: NSViewRepresentable {
    public let onRightClick: () -> Void

    public init(onRightClick: @escaping () -> Void) {
        self.onRightClick = onRightClick
    }

    public func makeNSView(context: Context) -> RightClickInterceptingView {
        let view = RightClickInterceptingView()
        view.onRightClick = onRightClick
        return view
    }

    public func updateNSView(_ nsView: RightClickInterceptingView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    public final class RightClickInterceptingView: NSView {
        var onRightClick: (() -> Void)?

        public override func hitTest(_ point: NSPoint) -> NSView? {
            // Only capture hit-tests when the triggering event is a right-click.
            // Left-clicks, hovers, scroll wheel events, and drags pass through to SwiftUI undisturbed.
            if let event = NSApp.currentEvent, event.type == .rightMouseDown {
                return self
            }
            return nil
        }

        public override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
            super.rightMouseDown(with: event)
        }
    }
}

extension View {
    /// Seamlessly activates selection when right-clicking the view before presenting a context menu.
    public func onRightClickSelect(perform action: @escaping () -> Void) -> some View {
        overlay(RightClickSelectRepresentable(onRightClick: action))
    }

    /// Applies the standard native context menu to a sidebar favorite or custom shortcut row.
    public func sidebarRowContextMenu(
        path: String,
        title: String,
        isCustomPinned: Bool,
        healthState: SidebarItemHealthState,
        isSelected: Bool = false,
        onOpen: (() -> Void)? = nil,
        onOpenInNewTab: (() -> Void)? = nil,
        onSelect: (() -> Void)? = nil,
        onRemove: (() -> Void)? = nil,
        onStartRename: (() -> Void)? = nil,
        onQuickLook: (() -> Void)? = nil,
        onOpenInNewWindow: (() -> Void)? = nil,
        onRelink: (() -> Void)? = nil
    ) -> some View {
        modifier(
            SidebarRowContextMenuModifier(
                path: path,
                title: title,
                isCustomPinned: isCustomPinned,
                healthState: healthState,
                isSelected: isSelected,
                onOpen: onOpen,
                onOpenInNewTab: onOpenInNewTab,
                onSelect: onSelect,
                onRemove: onRemove,
                onStartRename: onStartRename,
                onQuickLook: onQuickLook,
                onOpenInNewWindow: onOpenInNewWindow,
                onRelink: onRelink
            )
        )
    }
}


