// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipCore
import TTZipUI

public extension AccentMineralTheme {
    var swatchColor: Color {
        switch self {
        case .bamboo: return TTZipTheme.bambooGreen
        case .gold: return TTZipTheme.kintsugiGold
        case .amber: return TTZipTheme.archiveAmber
        case .cinnabar: return TTZipTheme.cinnabarRed
        case .purple: return TTZipTheme.celestialPurple
        }
    }

    var labelKey: SettingsLocaleKey {
        switch self {
        case .bamboo: return .accentBamboo
        case .gold: return .accentGold
        case .amber: return .accentAmber
        case .cinnabar: return .accentCinnabar
        case .purple: return .accentPurple
        }
    }
}

/// Resolved optical and accessibility tokens adapted from TTZipTheme / TTKitDesign semantic tokens.
public struct SettingsVisualStyle: Equatable, Sendable {
    public let isDark: Bool
    public let reduceTransparency: Bool
    public let increasedContrast: Bool

    public init(
        colorScheme: ColorScheme,
        reduceTransparency: Bool,
        colorSchemeContrast: ColorSchemeContrast
    ) {
        self.isDark = (colorScheme == .dark)
        self.reduceTransparency = reduceTransparency
        self.increasedContrast = (colorSchemeContrast == .increased)
    }

    public var borderWidth: CGFloat {
        increasedContrast
            ? (TTZipTheme.Layout.hairlineBorderWidth * 2.0)
            : TTZipTheme.Layout.hairlineBorderWidth
    }

    public var borderColor: Color {
        increasedContrast ? Color(nsColor: .separatorColor) : TTZipTheme.hairlineBorder
    }

    public var groupBackgroundColor: Color {
        if reduceTransparency {
            return Color(nsColor: .controlBackgroundColor)
        }
        return increasedContrast ? TTZipTheme.plateSurfaceL3 : TTZipTheme.cardBackground
    }

    public var contentCanvasColor: Color {
        reduceTransparency ? Color(nsColor: .windowBackgroundColor) : TTZipTheme.plateSurfaceL2
    }

    public var navigationCanvasColor: Color {
        reduceTransparency ? Color(nsColor: .underPageBackgroundColor) : TTZipTheme.plateSurfaceL1
    }

    public var primaryTextColor: Color {
        Color(nsColor: .labelColor)
    }

    public var inactiveNavTextColor: Color {
        Color(nsColor: increasedContrast ? .labelColor : .secondaryLabelColor)
    }

    public var selectedTabFillOpacity: Double {
        if increasedContrast {
            return isDark ? 0.28 : 0.20
        }
        return isDark ? 0.20 : 0.14
    }

    public var hoverTabFillOpacity: Double {
        isDark ? 0.08 : 0.05
    }

    public var secondaryTextColor: Color {
        Color(nsColor: increasedContrast ? .labelColor : .secondaryLabelColor)
    }
}

/// Editorial category header establishing visual hierarchy at the top of each settings pane.
public struct SettingsCategoryHeader: View {
    private let title: String
    private let subtitle: String
    private let systemImage: String
    private let style: SettingsVisualStyle

    public init(
        title: String,
        subtitle: String,
        systemImage: String,
        style: SettingsVisualStyle
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.style = style
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
                    .fill(TTZipTheme.bambooGreen.opacity(0.12))
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TTZipTheme.Typography.title2)
                    .foregroundStyle(style.primaryTextColor)
                Text(subtitle)
                    .font(TTZipTheme.Typography.callout)
                    .foregroundStyle(style.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.categoryHeader")
    }
}

/// Single-layer settings form group container without drop shadows or nested card borders.
public struct SettingsFormGroup<TrailingHeader: View, Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private let title: String
    private let systemImage: String
    private let trailingHeader: TrailingHeader
    private let content: Content

    public init(
        title: String,
        systemImage: String,
        @ViewBuilder trailingHeader: () -> TrailingHeader,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailingHeader = trailingHeader()
        self.content = content()
    }

    private var style: SettingsVisualStyle {
        SettingsVisualStyle(
            colorScheme: colorScheme,
            reduceTransparency: reduceTransparency,
            colorSchemeContrast: colorSchemeContrast
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(TTZipTheme.Typography.sectionHeader)
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Spacer(minLength: 8)
                trailingHeader
            }
            .padding(.horizontal, 2)
            .background(
                SettingsFormGroupAccessibilityMarker(
                    identifier: "settings.group.\(systemImage)",
                    title: title
                )
            )

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(style.groupBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style.borderColor, lineWidth: style.borderWidth)
            )
        }
    }
}

public extension SettingsFormGroup where TrailingHeader == EmptyView {
    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            trailingHeader: { EmptyView() },
            content: content
        )
    }
}

private struct SettingsFormGroupAccessibilityMarker: NSViewRepresentable {
    let identifier: String
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSView) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(title)
    }
}

/// Hairline row separator inside a `SettingsFormGroup`.
public struct SettingsFormDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init() {}

    public var body: some View {
        let style = SettingsVisualStyle(
            colorScheme: colorScheme,
            reduceTransparency: reduceTransparency,
            colorSchemeContrast: colorSchemeContrast
        )
        Rectangle()
            .fill(style.borderColor)
            .frame(height: style.borderWidth)
            .padding(.horizontal, 14)
    }
}

/// Capsule status indicator used in section headers and edition headers.
public struct SettingsStatusPill: View {
    private let text: String
    private let tint: Color
    private let identifier: String?

    public init(text: String, tint: Color, identifier: String? = nil) {
        self.text = text
        self.tint = tint
        self.identifier = identifier
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(text)
                .font(TTZipTheme.Typography.caption)
                .bold()
                .foregroundStyle(tint)
        }
        .padding(.horizontal, TTZipTheme.Spacing.xs)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .optionalAccessibilityIdentifier(identifier)
    }
}

private extension View {
    @ViewBuilder
    func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier, !identifier.isEmpty {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

/// Standard form row hosting a native AppKit `NSPopUpButton` on the trailing edge.
@MainActor
public struct SettingsPickerRow<Option: Hashable>: View {
    private let title: String
    private let subtitle: String?
    private let style: SettingsVisualStyle
    @Binding private var selection: Option
    private let options: [SettingsPopUpButtonOption<Option>]
    private let controlWidth: CGFloat
    private let accessibilityIdentifier: String

    public init(
        title: String,
        subtitle: String? = nil,
        style: SettingsVisualStyle,
        selection: Binding<Option>,
        options: [SettingsPopUpButtonOption<Option>],
        controlWidth: CGFloat = 186,
        accessibilityIdentifier: String
    ) {
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self._selection = selection
        self.options = options
        self.controlWidth = controlWidth
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TTZipTheme.Typography.bodyMedium)
                    .foregroundStyle(style.primaryTextColor)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(style.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            SettingsPopUpButtonControl(
                selection: $selection,
                options: options,
                accessibilityIdentifier: accessibilityIdentifier,
                accessibilityLabel: title,
                accessibilityHelp: subtitle
            )
            .frame(width: controlWidth, height: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// Standard form row hosting a native macOS switch toggle.
public struct SettingsToggleRow: View {
    private let title: String
    private let subtitle: String?
    private let style: SettingsVisualStyle
    @Binding private var isOn: Bool
    private let isDisabled: Bool
    private let accessibilityIdentifier: String

    public init(
        title: String,
        subtitle: String? = nil,
        style: SettingsVisualStyle,
        isOn: Binding<Bool>,
        isDisabled: Bool = false,
        accessibilityIdentifier: String
    ) {
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self._isOn = isOn
        self.isDisabled = isDisabled
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TTZipTheme.Typography.bodyMedium)
                    .foregroundStyle(style.primaryTextColor)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(style.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            SettingsSwitchControl(
                isOn: $isOn,
                isDisabled: isDisabled,
                accessibilityIdentifier: accessibilityIdentifier,
                accessibilityLabel: title,
                accessibilityHelp: subtitle
            )
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// Standard key-value metadata row inside a Settings form group.
public struct SettingsKeyValueRow: View {
    private let label: String
    private let value: String
    private let style: SettingsVisualStyle
    private let monospacedValue: Bool
    private let valueAccessibilityIdentifier: String?

    public init(
        label: String,
        value: String,
        style: SettingsVisualStyle,
        monospacedValue: Bool = false,
        valueAccessibilityIdentifier: String? = nil
    ) {
        self.label = label
        self.value = value
        self.style = style
        self.monospacedValue = monospacedValue
        self.valueAccessibilityIdentifier = valueAccessibilityIdentifier
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .font(TTZipTheme.Typography.subheadline)
                .foregroundStyle(style.secondaryTextColor)
            Spacer(minLength: 12)
            Text(value)
                .font(monospacedValue ? TTZipTheme.Typography.codeCaption : TTZipTheme.Typography.bodyMedium)
                .foregroundStyle(style.primaryTextColor)
                .multilineTextAlignment(.trailing)
                .optionalAccessibilityIdentifier(valueAccessibilityIdentifier)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Standard settings action row hosting a compact trailing button control.
public struct SettingsActionRow<TrailingButton: View>: View {
    private let title: String
    private let subtitle: String?
    private let style: SettingsVisualStyle
    private let trailingButton: TrailingButton

    public init(
        title: String,
        subtitle: String? = nil,
        style: SettingsVisualStyle,
        @ViewBuilder trailingButton: () -> TrailingButton
    ) {
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.trailingButton = trailingButton()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TTZipTheme.Typography.bodyMedium)
                    .foregroundStyle(style.primaryTextColor)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(style.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailingButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
