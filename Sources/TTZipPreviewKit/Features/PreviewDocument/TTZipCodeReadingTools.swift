// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTZipCoreTypes
import SwiftUI
import AppKit
import TTKitDesign
import TTMediaKit
import TTZipUI

@MainActor
struct TTZipCodeReadingTools: View {
    @Environment(\.colorScheme) private var ambientColorScheme
    @Environment(\.accessibilityReduceTransparency) private var envReduceTransparency
    @Environment(\.colorSchemeContrast) private var envColorSchemeContrast

    let fileName: String
    let lineCount: Int
    let byteCount: Int64
    let isEdited: Bool
    let isWritableFile: Bool
    let isEditing: Bool
    let encodingBadge: String
    let isTruncatedForPreview: Bool
    let isNonUTF8ReadOnly: Bool
    let saveErrorMessage: String?
    let isSavedToastPresented: Bool
    let isCopiedToastPresented: Bool
    let presentationState: TTTextFloatingToolsPresentationState
    let bottomTrailingReservedWidth: CGFloat
    let availableHostWidth: CGFloat

    @Binding var showLineNumbers: Bool
    @Binding var fontSize: CGFloat
    @Binding var isPopoverPresented: Bool
    @Binding var readingBackgroundMode: TTTextReadingBackgroundMode
    @Binding var softWrapEnabled: Bool
    let onEnableEditing: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onHoverChange: (Bool) -> Void
    let onFocusChange: (Bool) -> Void
    var focusCoordinator: TTZipCodeToolsFocusCoordinator?

    @State private var isAllowEditingHovered: Bool = false
    @State private var isAaHovered: Bool = false
    @State private var isCopyHovered: Bool = false
    @State private var isSaveHovered: Bool = false
    @State private var focusedControl: FocusedControl?

    private enum FocusedControl: Hashable {
        case allowEditing
        case aaTools
        case copy
        case save
        case theme(TTTextReadingBackgroundMode)
        case fontDecrease
        case fontIncrease
        case softWrap
        case lineNumbers

        var isInsidePopover: Bool {
            switch self {
            case .allowEditing, .aaTools, .copy, .save:
                return false
            case .theme, .fontDecrease, .fontIncrease, .softWrap, .lineNumbers:
                return true
            }
        }
    }

    private func focusHandler(for control: FocusedControl) -> (TTZipCodeToolNSButton, Bool) -> Void {
        { button, focused in
            if control.isInsidePopover {
                focusCoordinator?.updatePopoverFocus(button, isFocused: focused)
            }
            if focused {
                focusedControl = control
            } else if focusedControl == control {
                focusedControl = nil
            }
            onFocusChange(focusedControl != nil)
        }
    }

    static let minFontSize: CGFloat = 10.0
    static let maxFontSize: CGFloat = 20.0
    private static let popoverAnimation = Animation.spring(response: 0.22, dampingFraction: 0.85)
    static let defaultFontSize: CGFloat = 12.5
    static let fontSizeStep: CGFloat = 1.0
    static let preferredPopoverWidth: CGFloat = 248.0
    private static let popoverEdgeInset: CGFloat = 10.0
    static let clusterCapsuleCornerRadius: CGFloat = 14.0
    private static let clusterSpacing: CGFloat = 2.0
    private static let clusterInset: CGFloat = 2.0
    private static let aaButtonWidth: CGFloat = 42.0
    private static let copyButtonWidth: CGFloat = 28.0

    static func resolvedPopoverWidth(forAvailableWidth availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite && availableWidth > 0 else {
            return preferredPopoverWidth
        }
        return min(preferredPopoverWidth, max(0, availableWidth - 2 * popoverEdgeInset))
    }

    // On narrow hosts, keep the card inside the viewport even when the corner button reserves space.
    static func resolvedPopoverTrailingPadding(
        forAvailableWidth availableWidth: CGFloat,
        bottomTrailingReservedWidth: CGFloat
    ) -> CGFloat {
        let clusterTrailing = 12.0 + bottomTrailingReservedWidth
        let cardWidth = resolvedPopoverWidth(forAvailableWidth: availableWidth)
        if availableWidth.isFinite && availableWidth > 0 && (cardWidth + clusterTrailing + popoverEdgeInset > availableWidth) {
            return min(popoverEdgeInset, availableWidth / 2)
        }
        return clusterTrailing
    }

    private var usesHighContrastOrReducedTransparency: Bool {
        envReduceTransparency
            || envColorSchemeContrast == .increased
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private var isDarkReadingCanvas: Bool {
        switch readingBackgroundMode {
        case .black:
            return true
        case .white:
            return false
        case .fluidTransparent:
            return ambientColorScheme == .dark
        }
    }

    var usesDarkClusterSurface: Bool {
        usesHighContrastOrReducedTransparency || isDarkReadingCanvas
    }

    private func clusterPrimaryForegroundColor(
        isHighlighted: Bool,
        restingAlpha: CGFloat = 0.88
    ) -> NSColor {
        let alpha: CGFloat = isHighlighted ? 0.98 : restingAlpha
        if usesDarkClusterSurface {
            return NSColor.white.withAlphaComponent(alpha)
        }
        return NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: alpha)
    }

    private var clusterSelectedForegroundColor: NSColor {
        usesDarkClusterSurface
            ? Self.bambooNSColor
            : clusterPrimaryForegroundColor(isHighlighted: true)
    }

    private var clusterHoverHighlightColor: NSColor {
        usesDarkClusterSurface
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.10)
    }

    private func clusterHoverBackgroundColor(isHighlighted: Bool) -> NSColor {
        isHighlighted ? clusterHoverHighlightColor : .clear
    }

    private var effectivePopoverWidth: CGFloat {
        Self.resolvedPopoverWidth(forAvailableWidth: availableHostWidth)
    }

    private var effectivePopoverTrailingPadding: CGFloat {
        Self.resolvedPopoverTrailingPadding(
            forAvailableWidth: availableHostWidth,
            bottomTrailingReservedWidth: bottomTrailingReservedWidth
        )
    }

    private var clusterTrailingPadding: CGFloat { 12.0 + bottomTrailingReservedWidth }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if presentationState.isPopoverOpen {
                popoverCardView
                    .padding(.trailing, effectivePopoverTrailingPadding)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }

            compactFloatingCluster
                .padding(.trailing, clusterTrailingPadding)
        }
        .padding(.bottom, 12.0)
        .onHover { hovering in
            guard presentationState.showsControlsCluster || presentationState.isPopoverOpen else { return }
            onHoverChange(hovering)
        }
        .onExitCommand {
            if isPopoverPresented {
                withAnimation(Self.popoverAnimation) {
                    isPopoverPresented = false
                }
            }
        }
    }

    // MARK: - Compact Bottom-Right Floating Button Group (`[ Aa ⎘ ]`)

    private var compactFloatingCluster: some View {
        let isVisible = presentationState.showsControlsCluster
        let shape = RoundedRectangle(cornerRadius: Self.clusterCapsuleCornerRadius, style: .continuous)
        return HStack(spacing: Self.clusterSpacing) {
            if isVisible && (saveErrorMessage != nil || isSavedToastPresented) {
                activeCompactStatusBadge
                    .padding(.leading, 4)
            }

            if isWritableFile && !isEditing {
                compactAllowEditingButton
            }

            if isWritableFile && isEditing && isEdited {
                compactSaveButton
            }

            aaPopoverToggleButton
            quickCopyButton
        }
        .padding(.horizontal, Self.clusterInset)
        .frame(height: 28)
        .background {
            if isVisible {
                clusterSurfacePlate(in: shape)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CodeFloatingReadingToolsCluster")
    }

    @ViewBuilder
    private func clusterSurfacePlate(in shape: RoundedRectangle) -> some View {
        if usesHighContrastOrReducedTransparency {
            shape
                .fill(UniversalTokens.Mineral.inkCharcoal.opacity(0.96))
                .overlay(
                    shape.strokeBorder(
                        Color.white.opacity(0.38),
                        lineWidth: UniversalTokens.Dimensions.hairlineWidth
                    )
                )
        } else {
            Color.clear
                .ttOverlayGlassPlate(cornerRadius: Self.clusterCapsuleCornerRadius)
                .environment(\.colorScheme, isDarkReadingCanvas ? .dark : .light)
        }
    }

    private static let bambooNSColor = NSColor(srgbRed: 0.42, green: 0.56, blue: 0.35, alpha: 1.0)

    private var aaPopoverToggleButton: some View {
        let isOpen = presentationState.isPopoverOpen
        let isHighlighted = isAaHovered || focusedControl == .aaTools || isOpen
        let label = TextAndDocumentPreviewLocalization.text(.epubTypographyTitle)
        let toggleAction = {
            withAnimation(Self.popoverAnimation) {
                isPopoverPresented.toggle()
            }
        }
        return TTZipCodeToolButton(
            id: "CodeFloatingAaToolsButton",
            accessibilityLabel: label,
            helpText: label,
            isChromeVisible: presentationState.showsControlsCluster,
            style: TTZipCodeToolButtonStyle(
                title: "Aa",
                trailingSymbolName: "ellipsis",
                fontSize: 11.0,
                fontWeight: .semibold,
                fontDesign: .rounded,
                foregroundColor: isOpen
                    ? clusterSelectedForegroundColor
                    : clusterPrimaryForegroundColor(isHighlighted: isHighlighted),
                backgroundColor: isOpen
                    ? Self.bambooNSColor.withAlphaComponent(0.22)
                    : clusterHoverBackgroundColor(isHighlighted: isHighlighted),
                hoverBackgroundColor: clusterHoverHighlightColor,
                minWidth: Self.aaButtonWidth
            ),
            onMount: { focusCoordinator?.triggerButton = $0 },
            onHoverChange: { hovering in
                isAaHovered = hovering
                onHoverChange(hovering)
            },
            onFocusChange: focusHandler(for: .aaTools),
            action: toggleAction
        )
        .frame(width: Self.aaButtonWidth, height: 28)
        .accessibilityIdentifier("CodeFloatingAaToolsButton")
    }

    private var quickCopyButton: some View {
        let isHighlighted = isCopyHovered || focusedControl == .copy
        let help = TextAndDocumentPreviewLocalization.text(isCopiedToastPresented ? .copiedToClipboardHelp : .copySourceCodeHelp)
        return TTZipCodeToolButton(
            id: "CodeFloatingCopyButton",
            accessibilityLabel: help,
            helpText: help,
            isChromeVisible: presentationState.showsControlsCluster,
            style: TTZipCodeToolButtonStyle(
                symbolName: isCopiedToastPresented ? "checkmark" : "doc.on.doc",
                fontSize: 11.0,
                fontWeight: .semibold,
                foregroundColor: isCopiedToastPresented
                    ? clusterSelectedForegroundColor
                    : clusterPrimaryForegroundColor(isHighlighted: isHighlighted),
                backgroundColor: isCopiedToastPresented
                    ? Self.bambooNSColor.withAlphaComponent(0.20)
                    : clusterHoverBackgroundColor(isHighlighted: isHighlighted),
                hoverBackgroundColor: clusterHoverHighlightColor,
                minWidth: Self.copyButtonWidth
            ),
            onHoverChange: { hovering in
                isCopyHovered = hovering
                onHoverChange(hovering)
            },
            onFocusChange: focusHandler(for: .copy),
            action: onCopy
        )
        .frame(width: Self.copyButtonWidth, height: 28)
        .accessibilityIdentifier("CodeFloatingCopyButton")
    }

    private var compactAllowEditingButton: some View {
        let isHighlighted = isAllowEditingHovered || focusedControl == .allowEditing
        let label = TextAndDocumentPreviewLocalization.text(.allowEditingButton)
        let help = TextAndDocumentPreviewLocalization.text(.allowEditingHelp)
        let preferredWidth = Self.allowEditingButtonWidth(for: label)
        let labelBudget = availableHostWidth - clusterTrailingPadding - Self.aaButtonWidth - Self.copyButtonWidth
            - 2 * Self.clusterSpacing - 2 * Self.clusterInset
        let showsSymbol = availableHostWidth <= 0 || preferredWidth <= labelBudget
        let width = showsSymbol ? preferredWidth : max(28, labelBudget)
        return TTZipCodeToolButton(
            id: "CodeFloatingAllowEditingButton",
            accessibilityLabel: label,
            helpText: help,
            isChromeVisible: presentationState.showsControlsCluster,
            style: TTZipCodeToolButtonStyle(
                title: label,
                symbolName: showsSymbol ? "pencil" : nil,
                fontSize: 10.5,
                fontWeight: .semibold,
                foregroundColor: clusterPrimaryForegroundColor(isHighlighted: isHighlighted, restingAlpha: 0.90),
                backgroundColor: clusterHoverBackgroundColor(isHighlighted: isHighlighted),
                hoverBackgroundColor: clusterHoverHighlightColor,
                minWidth: width
            ),
            onHoverChange: { hovering in
                isAllowEditingHovered = hovering
                onHoverChange(hovering)
            },
            onFocusChange: focusHandler(for: .allowEditing),
            action: onEnableEditing
        )
        .frame(width: width, height: 28)
        .accessibilityIdentifier("CodeFloatingAllowEditingButton")
    }

    private static func allowEditingButtonWidth(for title: String) -> CGFloat {
        let titleWidth = (title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold)]
        ).width
        return max(64.0, min(104.0, ceil(titleWidth) + 24.0))
    }

    private var compactSaveButton: some View {
        let isHighlighted = isSaveHovered || focusedControl == .save
        let help = TextAndDocumentPreviewLocalization.saveChangesHelp("⌘S")
        let label = TextAndDocumentPreviewLocalization.text(.saveButton)
        return TTZipCodeToolButton(
            id: "CodeFloatingSaveButton",
            accessibilityLabel: label,
            helpText: help,
            isChromeVisible: presentationState.showsControlsCluster,
            keyEquivalent: "s",
            keyEquivalentModifierMask: [.command],
            style: TTZipCodeToolButtonStyle(
                symbolName: "square.and.arrow.down.fill",
                showsLeadingDot: true,
                fontSize: 10.5,
                fontWeight: .bold,
                foregroundColor: .white,
                backgroundColor: Self.bambooNSColor.withAlphaComponent(isHighlighted ? 0.95 : 0.82),
                hoverBackgroundColor: Self.bambooNSColor.withAlphaComponent(0.95),
                minWidth: 34.0
            ),
            onHoverChange: { hovering in
                isSaveHovered = hovering
                onHoverChange(hovering)
            },
            onFocusChange: focusHandler(for: .save),
            action: onSave
        )
        .frame(width: 34, height: 28)
        .accessibilityIdentifier("CodeFloatingSaveButton")
    }

    @ViewBuilder
    private var activeCompactStatusBadge: some View {
        if let err = saveErrorMessage {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(TTZipTheme.cinnabarRed)
                .frame(width: 20, height: 24)
                .ttButtonHelp(err)
                .accessibilityLabel(err)
        } else if isSavedToastPresented {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(TTZipTheme.bambooGreen)
                .frame(width: 20, height: 24)
                .ttButtonHelp(TextAndDocumentPreviewLocalization.text(.savedBadge))
                .accessibilityLabel(TextAndDocumentPreviewLocalization.text(.savedBadge))
        }
    }

    // MARK: - Compact Reading Tools & Info Popover Card

    private var popoverCardView: some View {
        let cardShape = RoundedRectangle(cornerRadius: TTZipTheme.Radius.md, style: .continuous)
        let cardWidth = effectivePopoverWidth
        let isCompactCard = cardWidth < 236.0
        return VStack(alignment: .leading, spacing: isCompactCard ? 8 : 10) {
            popoverThemeSection
            popoverTypographyAndLineNumbersRow
            Divider().overlay(Color.white.opacity(0.14))
            popoverMetadataSection
            if isWritableFile && isEditing && isEdited {
                popoverSaveActionRow
            }
        }
        .padding(isCompactCard ? 10 : 12)
        .frame(width: cardWidth)
        .background(localPopoverCardBackdrop(in: cardShape))
        .overlay(
            cardShape.strokeBorder(
                Color.white.opacity(usesHighContrastOrReducedTransparency ? 0.36 : 0.22),
                lineWidth: UniversalTokens.Dimensions.hairlineWidth
            )
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CodeFloatingReadingPopoverCard")
    }

    @ViewBuilder
    private func localPopoverCardBackdrop(in shape: RoundedRectangle) -> some View {
        if usesHighContrastOrReducedTransparency {
            shape.fill(UniversalTokens.Mineral.inkCharcoal)
        } else {
            ZStack {
                VisualEffectBlurRepresentable(material: .popover, blendingMode: .withinWindow)
                UniversalTokens.Plate.surfaceL3
                UniversalTokens.Mineral.inkCharcoal.opacity(0.68)
                LinearGradient(
                    colors: [
                        UniversalTokens.Fluid.sheenDispersion.opacity(0.45),
                        UniversalTokens.Mineral.bamboo.opacity(0.06),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(shape)
        }
    }

    private var popoverThemeSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(TextAndDocumentPreviewLocalization.text(.readingBackgroundLabel))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.68))

            HStack(spacing: 3) {
                ForEach(TTTextReadingBackgroundMode.allCases) { mode in
                    popoverThemeButton(mode: mode, showsSymbol: effectivePopoverWidth >= 210)
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func popoverThemeButton(mode: TTTextReadingBackgroundMode, showsSymbol: Bool) -> some View {
        let isSelected = readingBackgroundMode == mode
        let selectAction = { readingBackgroundMode = mode }
        let buttonID = "CodeFloatingThemeButton_\(mode.rawValue)"
        return TTZipCodeToolButton(
            id: buttonID,
            accessibilityLabel: mode.localizedTitle,
            helpText: mode.localizedHelpText,
            style: TTZipCodeToolButtonStyle(
                title: mode.localizedTitle,
                symbolName: showsSymbol ? mode.iconName : nil,
                fontSize: 10.0,
                fontWeight: isSelected ? .bold : .medium,
                foregroundColor: isSelected ? Self.bambooNSColor : NSColor.white.withAlphaComponent(0.86),
                backgroundColor: isSelected ? Self.bambooNSColor.withAlphaComponent(0.22) : .clear,
                minWidth: showsSymbol ? 60.0 : 50.0
            ),
            onFocusChange: focusHandler(for: .theme(mode)),
            action: selectAction
        )
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        .accessibilityIdentifier(buttonID)
    }

    private var popoverTypographyAndLineNumbersRow: some View {
        let isCompactCard = effectivePopoverWidth < 236.0
        let canFitSingleRow = effectivePopoverWidth >= 220.0
        let spacing: CGFloat = isCompactCard ? 3 : 4
        let layout = canFitSingleRow
            ? AnyLayout(HStackLayout(spacing: spacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        return layout {
            popoverFontStepperCluster(isCompactCard: isCompactCard)
            HStack(spacing: spacing) {
                popoverSoftWrapToggleButton(isCompactCard: isCompactCard)
                popoverLineNumbersToggleButton(isCompactCard: isCompactCard)
            }
            .frame(maxWidth: .infinity, alignment: canFitSingleRow ? .trailing : .leading)
        }
    }

    private func popoverFontStepperCluster(isCompactCard: Bool) -> some View {
        let decreaseAction = { fontSize = max(Self.minFontSize, fontSize - Self.fontSizeStep) }
        let increaseAction = { fontSize = min(Self.maxFontSize, fontSize + Self.fontSizeStep) }
        let decreaseHelp = TextAndDocumentPreviewLocalization.text(.epubDecreaseFontSizeHelp)
        let increaseHelp = TextAndDocumentPreviewLocalization.text(.epubIncreaseFontSizeHelp)
        let btnWidth: CGFloat = isCompactCard ? 28.0 : 30.0
        return HStack(spacing: 2) {
            TTZipCodeToolButton(
                id: "CodeFloatingFontDecreaseButton",
                accessibilityLabel: decreaseHelp,
                helpText: decreaseHelp,
                isEnabled: fontSize > Self.minFontSize,
                style: TTZipCodeToolButtonStyle(
                    title: "A−",
                    fontSize: 11.0,
                    fontWeight: .semibold,
                    fontDesign: .rounded,
                    foregroundColor: NSColor.white.withAlphaComponent(0.92),
                    backgroundColor: .clear,
                    minWidth: btnWidth
                ),
                onFocusChange: focusHandler(for: .fontDecrease),
                action: decreaseAction
            )
            .frame(width: btnWidth, height: 28)
            .accessibilityIdentifier("CodeFloatingFontDecreaseButton")

            Text("\(Int(fontSize.rounded()))pt")
                .font(.system(size: 10.0, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.80))
                .frame(minWidth: isCompactCard ? 26 : 30)

            TTZipCodeToolButton(
                id: "CodeFloatingFontIncreaseButton",
                accessibilityLabel: increaseHelp,
                helpText: increaseHelp,
                isEnabled: fontSize < Self.maxFontSize,
                style: TTZipCodeToolButtonStyle(
                    title: "A+",
                    fontSize: 11.0,
                    fontWeight: .semibold,
                    fontDesign: .rounded,
                    foregroundColor: NSColor.white.withAlphaComponent(0.92),
                    backgroundColor: .clear,
                    minWidth: btnWidth
                ),
                onFocusChange: focusHandler(for: .fontIncrease),
                action: increaseAction
            )
            .frame(width: btnWidth, height: 28)
            .accessibilityIdentifier("CodeFloatingFontIncreaseButton")
        }
        .padding(.horizontal, 2)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func popoverSoftWrapToggleButton(isCompactCard: Bool) -> some View {
        let isWrapped = softWrapEnabled
        let label = TextAndDocumentPreviewLocalization.text(.softWrapLabel)
        let stateValue = TextAndDocumentPreviewLocalization.text(isWrapped ? .softWrapStateOn : .softWrapStateOff)
        let help = TextAndDocumentPreviewLocalization.text(isWrapped ? .disableSoftWrapHelp : .enableSoftWrapHelp)
        let width: CGFloat = isCompactCard ? 66.0 : 76.0
        let toggleAction = {
            withAnimation(Self.popoverAnimation) {
                softWrapEnabled.toggle()
            }
        }
        return TTZipCodeToolButton(
            id: "CodeFloatingSoftWrapToggle",
            accessibilityLabel: label,
            accessibilityValue: stateValue,
            helpText: help,
            style: TTZipCodeToolButtonStyle(
                title: label,
                symbolName: "arrow.turn.down.left",
                fontSize: isCompactCard ? 9.5 : 10.0,
                fontWeight: isWrapped ? .bold : .medium,
                foregroundColor: isWrapped ? Self.bambooNSColor : NSColor.white.withAlphaComponent(0.82),
                backgroundColor: isWrapped
                    ? Self.bambooNSColor.withAlphaComponent(0.22)
                    : NSColor.white.withAlphaComponent(0.08),
                hoverBackgroundColor: NSColor.white.withAlphaComponent(0.16),
                cornerRadius: 6.0,
                minWidth: width
            ),
            onFocusChange: focusHandler(for: .softWrap),
            action: toggleAction
        )
        .frame(width: width, height: 28)
        .accessibilityIdentifier("CodeFloatingSoftWrapToggle")
    }

    private func popoverLineNumbersToggleButton(isCompactCard: Bool) -> some View {
        let lineNumAction = { withAnimation(Self.popoverAnimation) { showLineNumbers.toggle() } }
        let lineNumHelp = TextAndDocumentPreviewLocalization.text(showLineNumbers ? .hideLineNumbersHelp : .showLineNumbersHelp)
        let stateValue = TextAndDocumentPreviewLocalization.text(showLineNumbers ? .softWrapStateOn : .softWrapStateOff)
        let width: CGFloat = isCompactCard ? 38.0 : 44.0
        return TTZipCodeToolButton(
            id: "CodeFloatingLineNumbersToggle",
            accessibilityLabel: lineNumHelp,
            accessibilityValue: stateValue,
            helpText: lineNumHelp,
            style: TTZipCodeToolButtonStyle(
                title: "#",
                symbolName: "list.number",
                fontSize: 10.0,
                fontWeight: .bold,
                fontDesign: .monospaced,
                foregroundColor: showLineNumbers ? Self.bambooNSColor : NSColor.white.withAlphaComponent(0.82),
                backgroundColor: showLineNumbers
                    ? Self.bambooNSColor.withAlphaComponent(0.22)
                    : NSColor.white.withAlphaComponent(0.08),
                hoverBackgroundColor: NSColor.white.withAlphaComponent(0.16),
                cornerRadius: 6.0,
                minWidth: width
            ),
            onFocusChange: focusHandler(for: .lineNumbers),
            action: lineNumAction
        )
        .frame(width: width, height: 28)
        .accessibilityIdentifier("CodeFloatingLineNumbersToggle")
    }

    private var popoverMetadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                popoverBadgePill(
                    icon: isPlainTextMode ? "doc.plaintext" : "curlybraces",
                    text: resolvedLanguageLabel,
                    fg: TTZipTheme.bambooGreen,
                    bg: TTZipTheme.bambooGreen.opacity(0.18)
                )

                popoverBadgePill(
                    icon: nil,
                    text: encodingBadge,
                    fg: Color.white.opacity(0.86),
                    bg: Color.white.opacity(0.12)
                )

                if isEdited {
                    popoverBadgePill(
                        icon: "circle.fill",
                        text: TextAndDocumentPreviewLocalization.text(.unsavedBadge),
                        fg: .orange,
                        bg: Color.orange.opacity(0.18)
                    )
                } else if !isEditing || !isWritableFile {
                    popoverBadgePill(
                        icon: "lock.fill",
                        text: TextAndDocumentPreviewLocalization.text(.readOnlyBadge),
                        fg: Color.white.opacity(0.76),
                        bg: Color.white.opacity(0.12)
                    )
                }
            }

            Text(
                TextAndDocumentPreviewLocalization.fileSizeAndLines(
                    sizeText: ByteCountFormatterCache.shared.string(fromByteCount: byteCount),
                    lineCount: lineCount
                )
            )
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.72))
            .lineLimit(1)

            if isTruncatedForPreview {
                Text(TextAndDocumentPreviewLocalization.truncationBanner())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isNonUTF8ReadOnly {
                Text(TextAndDocumentPreviewLocalization.encodingReadOnlyBanner(encodingName: encodingBadge))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saveErrorMessage {
                Text(saveErrorMessage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TTZipTheme.cinnabarRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var popoverSaveActionRow: some View {
        Button(action: onSave) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(TextAndDocumentPreviewLocalization.saveWithShortcut("⌘S"))
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(TTZipTheme.bambooGreen)
            )
        }
        .buttonStyle(.plain)
        .ttButtonHelp(TextAndDocumentPreviewLocalization.saveChangesHelp("⌘S"))
        .accessibilityIdentifier("CodeFloatingPopoverSaveButton")
    }

    private func popoverBadgePill(icon: String?, text: String, fg: Color, bg: Color) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(text)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 5)
        .padding(.vertical, 2.5)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
    }

    private var isPlainTextMode: Bool {
        !TTTextSyntaxRenderMode.resolve(fileName: fileName).isSyntaxHighlighted
    }

    private var resolvedLanguageLabel: String {
        Self.resolveLanguageName(for: fileName, isCompact: true)
    }

    private static let extensionMap: [String: String] = [
        "swift": "Swift", "kt": "Kotlin", "kts": "Kotlin", "java": "Java",
        "py": "Python", "js": "JavaScript", "jsx": "JavaScript", "ts": "TypeScript",
        "tsx": "TypeScript", "c": "C", "h": "C", "rs": "Rust", "go": "Go",
        "sh": "Shell", "bash": "Shell", "zsh": "Shell", "fish": "Shell", "command": "Shell", "html": "HTML", "htm": "HTML",
        "css": "CSS", "scss": "CSS", "less": "CSS", "json": "JSON", "json5": "JSON",
        "yaml": "YAML", "yml": "YAML", "md": "Markdown", "markdown": "Markdown", "sql": "SQL",
        "toml": "TOML", "proto": "Protobuf", "cmake": "CMake", "makefile": "Makefile",
        "dockerfile": "Dockerfile", "bazel": "Bazel", "bzl": "Starlark"
    ]

    @MainActor
    static func resolveLanguageName(for fileName: String, isCompact: Bool) -> String {
        let mode = TTTextSyntaxRenderMode.resolve(fileName: fileName)
        if !mode.isSyntaxHighlighted {
            return TextAndDocumentPreviewLocalization.text(.plainTextLabel)
        }
        let ext = mode.languageExtension ?? (fileName as NSString).pathExtension.lowercased()
        if let mapped = extensionMap[ext] {
            return mapped
        }
        switch ext {
        case "cpp", "hpp", "cc", "cxx", "m", "mm":
            return isCompact ? "C++" : "C++ / ObjC"
        case "xml", "plist", "svg":
            return isCompact ? "XML" : "XML / Plist"
        default:
            return ext.isEmpty ? TextAndDocumentPreviewLocalization.text(.plainTextLabel) : ext.uppercased()
        }
    }
}
