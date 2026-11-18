// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipCore
import TTZipUI

/// Typed option pair for AppKit `NSPopUpButton` rows inside Settings.
public struct SettingsPopUpButtonOption<Option: Hashable>: Equatable {
    public let value: Option
    public let title: String

    public init(value: Option, title: String) {
        self.value = value
        self.title = title
    }
}

/// Native AppKit `NSPopUpButton` wrapper for Settings form rows.
@MainActor
public struct SettingsPopUpButtonControl<Option: Hashable>: NSViewRepresentable {
    @Binding public var selection: Option
    public let options: [SettingsPopUpButtonOption<Option>]
    public let accessibilityIdentifier: String
    public let accessibilityLabel: String
    public let accessibilityHelp: String?

    public init(
        selection: Binding<Option>,
        options: [SettingsPopUpButtonOption<Option>],
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        accessibilityHelp: String? = nil
    ) {
        self._selection = selection
        self.options = options
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHelp = accessibilityHelp
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, options: options.map(\.value))
    }

    public func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 24), pullsDown: false)
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let cell = button.cell as? NSPopUpButtonCell {
            cell.lineBreakMode = .byTruncatingTail
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionDidChange(_:))
        configure(button, coordinator: context.coordinator)
        return button
    }

    public func updateNSView(_ nsView: NSPopUpButton, context: Context) {
        configure(nsView, coordinator: context.coordinator)
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSPopUpButton,
        context: Context
    ) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(
            width: proposal.width ?? intrinsic.width,
            height: proposal.height ?? intrinsic.height
        )
    }

    private func configure(_ button: NSPopUpButton, coordinator: Coordinator) {
        let newValues = options.map(\.value)
        let newTitles = options.map(\.title)
        coordinator.selection = $selection
        if coordinator.options != newValues || button.itemTitles != newTitles {
            coordinator.options = newValues
            button.removeAllItems()
            for title in newTitles {
                button.addItem(withTitle: title)
            }
        }
        if let selectedIndex = newValues.firstIndex(of: selection),
           button.indexOfSelectedItem != selectedIndex {
            button.selectItem(at: selectedIndex)
        }
        button.isEnabled = !options.isEmpty
        button.toolTip = accessibilityHelp ?? accessibilityLabel
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityHelp(accessibilityHelp ?? accessibilityLabel)
    }

    @MainActor
    public final class Coordinator: NSObject {
        var selection: Binding<Option>
        var options: [Option]

        init(selection: Binding<Option>, options: [Option]) {
            self.selection = selection
            self.options = options
        }

        @MainActor
        @objc func selectionDidChange(_ sender: NSPopUpButton) {
            let selectedIndex = sender.indexOfSelectedItem
            guard options.indices.contains(selectedIndex) else { return }
            let nextValue = options[selectedIndex]
            if selection.wrappedValue != nextValue {
                selection.wrappedValue = nextValue
            }
        }
    }
}

private final class SettingsInteractiveNSButton: NSButton {
    var onStep: ((Int) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool {
        isEnabled
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        guard onHoverChange != nil else {
            hoverTrackingArea = nil
            return
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }

    override func keyDown(with event: NSEvent) {
        if let onStep {
            switch event.keyCode {
            case 126, 123:
                onStep(-1)
                return
            case 125, 124:
                onStep(1)
                return
            default:
                break
            }
        }
        switch event.keyCode {
        case 36, 49:
            performClick(self)
        default:
            super.keyDown(with: event)
        }
    }
}

/// Native `NSButton` hit-testing overlay ensuring deterministic AppKit focus, hover, and accessibility discovery.
public struct SettingsNativeButtonBridge: NSViewRepresentable {
    public let identifier: String
    public let title: String
    public let isSelected: Bool
    public let isEnabled: Bool
    public let onPress: () -> Void
    public let onStep: ((Int) -> Void)?
    public let onHoverChange: ((Bool) -> Void)?

    public init(
        identifier: String,
        title: String,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        onPress: @escaping () -> Void,
        onStep: ((Int) -> Void)? = nil,
        onHoverChange: ((Bool) -> Void)? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.onPress = onPress
        self.onStep = onStep
        self.onHoverChange = onHoverChange
    }

    @MainActor
    public final class Coordinator: NSObject {
        var onPress: () -> Void

        init(onPress: @escaping () -> Void) {
            self.onPress = onPress
        }

        @MainActor
        @objc func handlePress(_ sender: NSButton) {
            onPress()
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onPress: onPress)
    }

    public func makeNSView(context: Context) -> NSButton {
        let button = SettingsInteractiveNSButton(frame: .zero)
        button.target = context.coordinator
        button.action = #selector(Coordinator.handlePress(_:))
        button.isBordered = false
        button.title = ""
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.focusRingType = .default
        configure(button)
        return button
    }

    public func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.onPress = onPress
        if let interactive = nsView as? SettingsInteractiveNSButton {
            configure(interactive)
        }
    }

    private func configure(_ button: SettingsInteractiveNSButton) {
        button.onStep = onStep
        button.onHoverChange = onHoverChange
        button.isEnabled = isEnabled
        button.toolTip = title
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.setAccessibilitySelected(isSelected)
    }
}

/// Compact capsule action button backed by a native AppKit `NSButton` hit surface.
public struct SettingsCapsuleButton: View {
    public enum Tone {
        case neutral
        case prominent
        case destructive
    }

    private let title: String
    private let systemImage: String?
    private let tone: Tone
    private let identifier: String
    private let isEnabled: Bool
    private let action: () -> Void

    public init(
        title: String,
        systemImage: String? = nil,
        tone: Tone = .neutral,
        identifier: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
        self.identifier = identifier
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(title)
                .font(TTZipTheme.Typography.callout)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(foregroundStyle)
        .padding(.horizontal, TTZipTheme.Spacing.sm)
        .padding(.vertical, 6)
        .background(backgroundStyle)
        .clipShape(Capsule())
        .opacity(isEnabled ? 1.0 : 0.45)
        .overlay(
            SettingsNativeButtonBridge(
                identifier: identifier,
                title: title,
                isEnabled: isEnabled,
                onPress: action
            )
        )
        .contentShape(Capsule())
    }

    private var foregroundStyle: Color {
        switch tone {
        case .neutral: return Color(nsColor: .labelColor)
        case .prominent: return .white
        case .destructive: return TTZipTheme.cinnabarRed
        }
    }

    @ViewBuilder
    private var backgroundStyle: some View {
        switch tone {
        case .neutral:
            Color.primary.opacity(0.08)
        case .prominent:
            TTZipTheme.bambooGradient
        case .destructive:
            TTZipTheme.cinnabarRed.opacity(0.11)
        }
    }
}

/// Native AppKit `NSSwitch` wrapper for Settings toggle rows.
@MainActor
public struct SettingsSwitchControl: NSViewRepresentable {
    @Binding public var isOn: Bool
    public let isDisabled: Bool
    public let accessibilityIdentifier: String
    public let accessibilityLabel: String
    public let accessibilityHelp: String?

    public init(
        isOn: Binding<Bool>,
        isDisabled: Bool = false,
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        accessibilityHelp: String? = nil
    ) {
        self._isOn = isOn
        self.isDisabled = isDisabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHelp = accessibilityHelp
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(isOn: $isOn)
    }

    public func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .regular
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .vertical)
        control.target = context.coordinator
        control.action = #selector(Coordinator.valueChanged(_:))
        configure(control, coordinator: context.coordinator)
        return control
    }

    public func updateNSView(_ nsView: NSSwitch, context: Context) {
        configure(nsView, coordinator: context.coordinator)
    }

    private func configure(_ control: NSSwitch, coordinator: Coordinator) {
        coordinator.isOn = $isOn
        let desiredState: NSControl.StateValue = isOn ? .on : .off
        if control.state != desiredState {
            control.state = desiredState
        }
        control.isEnabled = !isDisabled
        control.toolTip = accessibilityHelp ?? accessibilityLabel
        control.setAccessibilityIdentifier(accessibilityIdentifier)
        control.setAccessibilityLabel(accessibilityLabel)
        control.setAccessibilityHelp(accessibilityHelp ?? accessibilityLabel)
    }

    @MainActor
    public final class Coordinator: NSObject {
        var isOn: Binding<Bool>

        init(isOn: Binding<Bool>) {
            self.isOn = isOn
        }

        @MainActor
        @objc func valueChanged(_ sender: NSSwitch) {
            let nextValue = (sender.state == .on)
            if isOn.wrappedValue != nextValue {
                isOn.wrappedValue = nextValue
            }
        }
    }
}
