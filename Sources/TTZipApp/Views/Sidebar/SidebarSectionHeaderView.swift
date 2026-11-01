// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTKitDesign
import TTZipUI

/// An Apple HIG-compliant button style applying spring damping physics to pressed states using ttMicro.
public struct SidebarHeaderDampedButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(reduceMotion ? nil : .ttMicro, value: configuration.isPressed)
    }
}

/// An ergonomic action button designed for sidebar section header trailing accessory slots,
/// enforcing a minimum 28pt hit target, hover illumination, and ttMicro spring damping.
public struct SidebarSectionHeaderActionButton: View {
    public let iconName: String
    public let tooltip: String?
    public let tintColor: Color
    public let action: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        iconName: String,
        tooltip: String? = nil,
        tintColor: Color = .secondary,
        action: @escaping () -> Void
    ) {
        self.iconName = iconName
        self.tooltip = tooltip
        self.tintColor = tintColor
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isHovered ? (tintColor == .secondary ? Color.primary : tintColor) : tintColor)
                .frame(minWidth: 28, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? TTZipUniversalTokens.Plate.surfaceL3.opacity(0.8) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isHovered ? TTZipUniversalTokens.Border.specularHairline : Color.clear,
                            lineWidth: TTZipUniversalTokens.Dimensions.hairlineWidth
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarHeaderDampedButtonStyle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .ttMicro) {
                isHovered = hovering
            }
        }
        .help(tooltip ?? "")
    }
}

/// View modifier ensuring trailing accessory buttons in section headers
/// conform to Apple HIG with a >= 28pt touch target, hover highlight, and damping.
public struct SidebarHeaderTrailingActionModifier: ViewModifier {
    @State private var isHovered: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func body(content: Content) -> some View {
        content
            .buttonStyle(SidebarHeaderDampedButtonStyle())
            .frame(minWidth: 28, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? TTZipUniversalTokens.Plate.surfaceL3.opacity(0.8) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isHovered ? TTZipUniversalTokens.Border.specularHairline : Color.clear,
                        lineWidth: TTZipUniversalTokens.Dimensions.hairlineWidth
                    )
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .ttMicro) {
                    isHovered = hovering
                }
            }
    }
}

/// Reusable sidebar section header with smooth 90-degree chevron toggle,
/// Apple HIG standard typography, and trailing action slot.
public struct SidebarSectionHeaderView<Trailing: View>: View {
    public let title: String
    @Binding public var isCollapsed: Bool
    @ViewBuilder public let trailing: () -> Trailing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isChevronHovered: Bool = false
    @State private var isTitleHovered: Bool = false
    @State private var springLoadTask: Task<Void, Never>?
    private var l10n = AppLocalizationState.shared

    public init(
        title: String,
        isCollapsed: Binding<Bool>,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self._isCollapsed = isCollapsed
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleCollapse) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isChevronHovered ? Color.primary : Color.secondary.opacity(0.8))
                    .rotationEffect(isCollapsed ? .zero : .degrees(90))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isChevronHovered ? TTZipUniversalTokens.Plate.surfaceL3.opacity(0.8) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(
                                isChevronHovered ? TTZipUniversalTokens.Border.specularHairline : Color.clear,
                                lineWidth: TTZipUniversalTokens.Dimensions.hairlineWidth
                            )
                    )
                    .contentShape(Rectangle().inset(by: -5))
            }
            .buttonStyle(SidebarHeaderDampedButtonStyle())
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .ttMicro) {
                    isChevronHovered = hovering
                }
            }
            .accessibilityLabel(isCollapsed
                ? String(localized: "Expand \(title)")
                : String(localized: "Collapse \(title)"))
            .accessibilityHint(isCollapsed
                ? String(localized: "Double-tap to expand")
                : String(localized: "Double-tap to collapse"))

            Button(action: toggleCollapse) {
                Text(title.localizedUppercase)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(isTitleHovered ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SidebarHeaderDampedButtonStyle())
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .ttMicro) {
                    isTitleHovered = hovering
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isCollapsed
                ? String(localized: "Collapsed")
                : String(localized: "Expanded"))

            Spacer()

            if Trailing.self != EmptyView.self {
                trailing()
                    .modifier(SidebarHeaderTrailingActionModifier())
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .dropDestination(for: SidebarDropPayload.self) { _, _ in
            false
        } isTargeted: { targeted in
            springLoadTask?.cancel()
            if targeted && isCollapsed {
                springLoadTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, isCollapsed else { return }
                    withAnimation(reduceMotion ? nil : .ttMicro) {
                        isCollapsed = false
                    }
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
                }
            }
        }
        .onDisappear {
            springLoadTask?.cancel()
            springLoadTask = nil
        }
    }

    private func toggleCollapse() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        withAnimation(reduceMotion ? nil : .ttMicro) {
            isCollapsed.toggle()
        }
    }
}

