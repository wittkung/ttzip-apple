// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipCore
import TTZipUI
import TTZipBenchmarkKit

/// Unified modal sheet container for presenting secondary workspace tools.
public struct SecondaryToolSheetContainer: View {
    public let tab: WorkspaceTab
    public let onDismiss: () -> Void
    
    private var l10n = AppLocalizationState.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    
    public init(tab: WorkspaceTab, onDismiss: @escaping () -> Void) {
        self.tab = tab
        self.onDismiss = onDismiss
    }

    public var headerTitle: String {
        title
    }

    public var idealSheetSize: CGSize {
        tab == .settings ? CGSize(width: 680, height: 490) : CGSize(width: 880, height: 640)
    }
    
    private var title: String {
        switch tab {
        case .presets:
            return l10n.t(L10n.Sidebar.presets)
        case .benchmark:
            return l10n.t(L10n.Sidebar.benchmark)
        case .vault:
            return l10n.t(L10n.Sidebar.vault)
        case .settings:
            return l10n.t(L10n.Sidebar.settings)
        case .home, .compressWorkspace:
            return ""
        }
    }
    
    private var icon: String {
        switch tab {
        case .presets:
            return "slider.horizontal.3"
        case .benchmark:
            return "speedometer"
        case .vault:
            return "key.fill"
        case .settings:
            return "gearshape.fill"
        case .home, .compressWorkspace:
            return "app.fill"
        }
    }
    
    public var body: some View {
        let isSettings = (tab == .settings)
        VStack(spacing: 0) {
            topBar
            
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: 0.5)
            
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: isSettings ? 580 : 760,
            idealWidth: isSettings ? 680 : 880,
            maxWidth: isSettings ? 820 : 1040,
            minHeight: isSettings ? 420 : 540,
            idealHeight: isSettings ? 490 : 640,
            maxHeight: isSettings ? 640 : 800
        )
        .ttFloatingGlassPlate(tier: isSettings ? .base : .overlay, cornerRadius: 18)
        .presentationBackground(.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("secondaryToolSheet.container")
    }
    
    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(Color(nsColor: .labelColor))
                .accessibilityIdentifier("secondaryToolSheet.title")
            
            Spacer()
            
            SecondaryToolSheetCloseButton(
                helpText: l10n.t(L10n.Common.close),
                action: onDismiss
            )
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("secondaryToolSheet.topBar")
    }
    
    @ViewBuilder
    private var contentView: some View {
        switch tab {
        case .presets:
            PresetWorkspaceView()
        case .benchmark:
            BenchmarkView()
        case .vault:
            PasswordVaultView()
        case .settings:
            SettingsView()
        case .home, .compressWorkspace:
            EmptyView()
        }
    }
}

private struct SecondaryToolSheetCloseButton: NSViewRepresentable {
    let helpText: String
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @MainActor
        @objc func performClose(_ sender: NSButton) {
            action()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        button.target = context.coordinator
        button.action = #selector(Coordinator.performClose(_:))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.keyEquivalent = "\u{1b}"
        configure(button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        configure(nsView)
    }

    private func configure(_ button: NSButton) {
        if let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: helpText) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = image.withSymbolConfiguration(config)
        }
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = helpText
        button.setAccessibilityIdentifier("secondaryToolSheet.closeButton")
        button.setAccessibilityLabel(helpText)
    }
}
