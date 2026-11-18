// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitCore
import TTKitDesign

/// Semantic size tiers for `TTSegmentedSwitch` across compact toolbars and primary workspace headers.
public enum TTSegmentedSwitchSize: String, CaseIterable, Sendable {
    case mini
    case small
    case regular

    public var trackCornerRadius: CGFloat {
        switch self {
        case .mini: return 6.0
        case .small: return 7.0
        case .regular: return 8.0
        }
    }

    public var indicatorCornerRadius: CGFloat {
        switch self {
        case .mini: return 4.5
        case .small: return 5.5
        case .regular: return 6.0
        }
    }

    public var trackPadding: CGFloat {
        2.0
    }

    public var segmentSpacing: CGFloat {
        2.0
    }

    public var horizontalPadding: CGFloat {
        switch self {
        case .mini: return 6.0
        case .small: return 8.0
        case .regular: return 10.0
        }
    }

    public var verticalPadding: CGFloat {
        switch self {
        case .mini: return 3.0
        case .small: return 4.0
        case .regular: return 5.0
        }
    }

    public var minHitHeight: CGFloat {
        #if os(macOS)
        switch self {
        case .mini:
            return UniversalTokens.SegmentedSwitch.minHitTargetCompactMacOS
        case .small, .regular:
            return UniversalTokens.SegmentedSwitch.minHitTargetMacOS
        }
        #else
        return UniversalTokens.SegmentedSwitch.minHitTargetIOS
        #endif
    }

    public var minSegmentWidth: CGFloat {
        #if os(macOS)
        return UniversalTokens.SegmentedSwitch.minHitTargetMacOS
        #else
        return UniversalTokens.SegmentedSwitch.minHitTargetIOS
        #endif
    }

    public func semanticFont(isSelected: Bool) -> Font {
        let weight: Font.Weight = isSelected ? .semibold : .regular
        switch self {
        case .mini:
            return .caption2.weight(weight).monospacedDigit()
        case .small:
            return .caption.weight(weight).monospacedDigit()
        case .regular:
            return .subheadline.weight(weight).monospacedDigit()
        }
    }
}

/// Unified, brand-injectable segmented control conforming to the 4-layer optical glass hierarchy.
public struct TTSegmentedSwitch<Value: Hashable>: View {
    public let options: [Value]
    @Binding public var selection: Value
    public let title: (Value) -> String
    public let icon: ((Value) -> String)?
    public let tint: Color
    public let size: TTSegmentedSwitchSize
    public let isIconOnly: Bool
    public let shortcut: ((Value) -> KeyEquivalent)?
    public let helpText: ((Value) -> String)?

    @Namespace private var indicatorNamespace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var focusedOption: Value?
    @State private var hoveredOption: Value?

    public init(
        options: [Value],
        selection: Binding<Value>,
        title: @escaping (Value) -> String,
        icon: ((Value) -> String)? = nil,
        tint: Color = TTKitTheme.kintsugiGold,
        size: TTSegmentedSwitchSize = .regular,
        isIconOnly: Bool = false,
        shortcut: ((Value) -> KeyEquivalent)? = nil,
        helpText: ((Value) -> String)? = nil
    ) {
        self.options = options
        self._selection = selection
        self.title = title
        self.icon = icon
        self.tint = tint
        self.size = size
        self.isIconOnly = isIconOnly
        self.shortcut = shortcut
        self.helpText = helpText
    }

    public func shouldShowTextLabel(for option: Value) -> Bool {
        !isIconOnly && !title(option).isEmpty
    }

    public func resolvedAccessibilityLabel(for option: Value) -> String {
        let primaryTitle = title(option).trimmingCharacters(in: .whitespacesAndNewlines)
        if !primaryTitle.isEmpty {
            return primaryTitle
        }
        if let helpValue = helpText?(option).trimmingCharacters(in: .whitespacesAndNewlines),
           !helpValue.isEmpty {
            return helpValue
        }
        return String(describing: option)
    }

    public func nextOption(from current: Value, offset: Int) -> Value? {
        guard !options.isEmpty else { return nil }
        guard let currentIndex = options.firstIndex(of: current) else {
            return options.first
        }
        let targetIndex = min(max(currentIndex + offset, 0), options.count - 1)
        return options[targetIndex]
    }

    public func selectOption(_ option: Value) {
        guard options.contains(option) else { return }
        withAnimation(.ttMicro) {
            selection = option
        }
    }

    public func resolvedNavigationAnchor(focusedOverride: Value? = nil) -> Value {
        focusedOverride ?? focusedOption ?? selection
    }

    public func selectAdjacentOption(offset: Int, focusedOverride: Value? = nil) {
        let anchor = resolvedNavigationAnchor(focusedOverride: focusedOverride)
        guard let target = nextOption(from: anchor, offset: offset) else { return }
        withAnimation(.ttMicro) {
            selection = target
            focusedOption = target
        }
    }

    public var body: some View {
        HStack(spacing: size.segmentSpacing) {
            ForEach(options, id: \.self) { option in
                segmentButton(for: option)
            }
        }
        .padding(size.trackPadding)
        .background(trackBackground)
        .overlay(trackBorder)
        .accessibilityElement(children: .contain)
        #if os(macOS)
        .onMoveCommand { direction in
            switch direction {
            case .left:
                selectAdjacentOption(offset: -1)
            case .right:
                selectAdjacentOption(offset: 1)
            default:
                break
            }
        }
        #endif
    }

    private var trackBackground: some View {
        RoundedRectangle(cornerRadius: size.trackCornerRadius, style: .continuous)
            .fill(UniversalTokens.SegmentedSwitch.trackSurface)
    }

    private var trackBorder: some View {
        RoundedRectangle(cornerRadius: size.trackCornerRadius, style: .continuous)
            .strokeBorder(
                UniversalTokens.SegmentedSwitch.hairlineBorder,
                lineWidth: UniversalTokens.SegmentedSwitch.hairlineWidth
            )
    }

    @ViewBuilder
    private func segmentButton(for option: Value) -> some View {
        let isSelected = selection == option
        let baseButton = Button {
            selectOption(option)
        } label: {
            segmentLabel(for: option, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: size.indicatorCornerRadius, style: .continuous))
        .focused($focusedOption, equals: option)
        .onHover { isHovering in
            withAnimation(.ttMicro) {
                if isHovering {
                    hoveredOption = option
                } else if hoveredOption == option {
                    hoveredOption = nil
                }
            }
        }
        .accessibilityLabel(resolvedAccessibilityLabel(for: option))
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])

        if let shortcutKey = shortcut?(option), let helpString = helpText?(option) {
            baseButton
                .keyboardShortcut(shortcutKey, modifiers: [.command])
                .help(helpString)
        } else if let shortcutKey = shortcut?(option) {
            baseButton
                .keyboardShortcut(shortcutKey, modifiers: [.command])
        } else if let helpString = helpText?(option) {
            baseButton
                .help(helpString)
        } else {
            baseButton
        }
    }

    private func segmentLabel(for option: Value, isSelected: Bool) -> some View {
        let showsText = shouldShowTextLabel(for: option)
        return HStack(spacing: 4) {
            if let iconName = icon?(option), !iconName.isEmpty {
                Image(systemName: iconName)
                    .imageScale(size == .mini ? .small : .medium)
            }
            if showsText {
                Text(title(option))
                    .lineLimit(1)
            }
        }
        .font(size.semanticFont(isSelected: isSelected))
        .foregroundStyle(
            isSelected
                ? UniversalTokens.SegmentedSwitch.activeText
                : UniversalTokens.SegmentedSwitch.inactiveText
        )
        .padding(.horizontal, showsText ? size.horizontalPadding : size.verticalPadding)
        .padding(.vertical, size.verticalPadding)
        .frame(minWidth: size.minSegmentWidth, minHeight: size.minHitHeight)
        .background(segmentBackground(for: option, isSelected: isSelected))
        .overlay(focusRingOverlay(for: option))
    }

    @ViewBuilder
    private func segmentBackground(for option: Value, isSelected: Bool) -> some View {
        if isSelected {
            activeIndicatorCapsule
        } else if hoveredOption == option {
            RoundedRectangle(cornerRadius: size.indicatorCornerRadius, style: .continuous)
                .fill(UniversalTokens.SegmentedSwitch.hoverSurface)
        }
    }

    private var activeIndicatorCapsule: some View {
        let shape = RoundedRectangle(cornerRadius: size.indicatorCornerRadius, style: .continuous)
        let borderColor = resolvedActiveBorderColor
        return shape
            .fill(UniversalTokens.SegmentedSwitch.activeIndicatorSurface)
            .overlay(
                shape.fill(
                    UniversalTokens.SegmentedSwitch.activeIndicatorTintFill(
                        for: tint,
                        colorScheme: colorScheme
                    )
                )
            )
            .overlay(
                shape.strokeBorder(
                    borderColor,
                    lineWidth: UniversalTokens.SegmentedSwitch.hairlineWidth
                )
            )
            .matchedGeometryEffect(id: "TT_SEGMENT_INDICATOR", in: indicatorNamespace)
    }

    private var resolvedActiveBorderColor: Color {
        if colorSchemeContrast == .increased || differentiateWithoutColor {
            return tint
        }
        return UniversalTokens.SegmentedSwitch.activeIndicatorTintBorder(
            for: tint,
            colorScheme: colorScheme
        )
    }

    @ViewBuilder
    private func focusRingOverlay(for option: Value) -> some View {
        if focusedOption == option {
            RoundedRectangle(cornerRadius: size.indicatorCornerRadius, style: .continuous)
                .strokeBorder(
                    tint.opacity(0.85),
                    lineWidth: UniversalTokens.SegmentedSwitch.hairlineWidth
                )
        }
    }
}
