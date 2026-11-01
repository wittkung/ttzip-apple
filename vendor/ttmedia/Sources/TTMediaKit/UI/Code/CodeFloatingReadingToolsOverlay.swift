// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Compact floating glass reading-tools cluster (`[ Aa ⎘ ]`) and expandable popover card
/// for content-first text and code previews.
/// The glass surface wraps strictly around the compact control cluster and popover card;
/// no full-width header bar, divider, or full-width backdrop ever spans the window.
@MainActor
public struct CodeFloatingReadingToolsOverlay: View {
    @Environment(\.colorScheme) private var inheritedColorScheme
    @Environment(\.accessibilityReduceTransparency) private var envReduceTransparency
    @Environment(\.colorSchemeContrast) private var envColorSchemeContrast
    private var sharedReadingPrefs = TTTextReadingPreferenceStore.shared

    public let fileName: String
    public let lineCount: Int
    public let byteCount: Int64
    public let isEdited: Bool
    public let isWritableFile: Bool
    public let isReadOnly: Bool
    public let encodingBadge: String
    public let isTruncatedForPreview: Bool
    public let isNonUTF8ReadOnly: Bool
    public let saveErrorMessage: String?
    public let isSavedToastPresented: Bool
    public let isCopiedToastPresented: Bool
    public let presentationState: TTTextFloatingToolsPresentationState
    public let bottomTrailingReservedWidth: CGFloat
    public let availableHostWidth: CGFloat

    @Binding public var showLineNumbers: Bool
    @Binding public var fontSize: CGFloat
    @Binding public var isPopoverPresented: Bool
    private var explicitReadingBackgroundMode: Binding<TTTextReadingBackgroundMode>?
    private var explicitSoftWrapEnabled: Binding<Bool>?
    public let onCopy: () -> Void
    public let onSave: () -> Void
    public let onHoverChange: (Bool) -> Void
    public let onFocusChange: (Bool) -> Void

    @State private var isAaHovered: Bool = false
    @State private var isCopyHovered: Bool = false
    @State private var isSaveHovered: Bool = false
    @FocusState private var focusedControl: FocusedControl?

    private enum FocusedControl: Hashable {
        case aaTools
        case copy
        case save
        case fontDecrease
        case fontIncrease
        case softWrap
        case lineNumbers
    }

    public static let minFontSize: CGFloat = 10.0
    public static let maxFontSize: CGFloat = 20.0
    public static let defaultFontSize: CGFloat = 12.5
    public static let fontSizeStep: CGFloat = 1.0
    public static let preferredPopoverWidth: CGFloat = 248.0
    public static let minCompactPopoverWidth: CGFloat = 216.0

    /// Computes the adaptive popover card width and horizontal trailing margin for a given host width.
    /// Ensures the popover never overflows narrow Inspector widths (`240pt`) while keeping every button `>= 28pt`.
    public static func resolvedPopoverWidth(forAvailableWidth availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite && availableWidth > 0 else {
            return preferredPopoverWidth
        }
        return max(minCompactPopoverWidth, min(preferredPopoverWidth, availableWidth - 20.0))
    }

    /// Computes the trailing padding for the popover card so that in narrow hosts (`<= 284pt`)
    /// the card aligns cleanly inside the window's right margin (`10pt`) above `[ Aa ⎘ ] [ ↙↗ ]`
    /// instead of being pushed off the left edge by `bottomTrailingReservedWidth`.
    public static func resolvedPopoverTrailingPadding(
        forAvailableWidth availableWidth: CGFloat,
        bottomTrailingReservedWidth: CGFloat
    ) -> CGFloat {
        let clusterTrailing = 12.0 + bottomTrailingReservedWidth
        let cardWidth = resolvedPopoverWidth(forAvailableWidth: availableWidth)
        if availableWidth.isFinite && availableWidth > 0 && (cardWidth + clusterTrailing + 10.0 > availableWidth) {
            return 10.0
        }
        return clusterTrailing
    }

    public init(
        fileName: String,
        lineCount: Int,
        byteCount: Int64,
        isEdited: Bool,
        isWritableFile: Bool,
        isReadOnly: Bool,
        encodingBadge: String,
        isTruncatedForPreview: Bool = false,
        isNonUTF8ReadOnly: Bool = false,
        saveErrorMessage: String? = nil,
        isSavedToastPresented: Bool = false,
        isCopiedToastPresented: Bool = false,
        presentationState: TTTextFloatingToolsPresentationState,
        bottomTrailingReservedWidth: CGFloat = 0,
        availableHostWidth: CGFloat = 880.0,
        showLineNumbers: Binding<Bool>,
        fontSize: Binding<CGFloat>,
        isPopoverPresented: Binding<Bool>,
        readingBackgroundMode: Binding<TTTextReadingBackgroundMode>? = nil,
        softWrapEnabled: Binding<Bool>? = nil,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onHoverChange: @escaping (Bool) -> Void = { _ in },
        onFocusChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.fileName = fileName
        self.lineCount = lineCount
        self.byteCount = byteCount
        self.isEdited = isEdited
        self.isWritableFile = isWritableFile
        self.isReadOnly = isReadOnly
        self.encodingBadge = encodingBadge
        self.isTruncatedForPreview = isTruncatedForPreview
        self.isNonUTF8ReadOnly = isNonUTF8ReadOnly
        self.saveErrorMessage = saveErrorMessage
        self.isSavedToastPresented = isSavedToastPresented
        self.isCopiedToastPresented = isCopiedToastPresented
        self.presentationState = presentationState
        self.bottomTrailingReservedWidth = bottomTrailingReservedWidth
        self.availableHostWidth = availableHostWidth
        self._showLineNumbers = showLineNumbers
        self._fontSize = fontSize
        self._isPopoverPresented = isPopoverPresented
        self.explicitReadingBackgroundMode = readingBackgroundMode
        self.explicitSoftWrapEnabled = softWrapEnabled
        self.onCopy = onCopy
        self.onSave = onSave
        self.onHoverChange = onHoverChange
        self.onFocusChange = onFocusChange
    }

    public var activeReadingBackgroundBinding: Binding<TTTextReadingBackgroundMode> {
        if let explicitReadingBackgroundMode {
            return explicitReadingBackgroundMode
        }
        return Binding(
            get: { sharedReadingPrefs.mode },
            set: { sharedReadingPrefs.mode = $0 }
        )
    }

    public var activeReadingBackgroundMode: TTTextReadingBackgroundMode {
        activeReadingBackgroundBinding.wrappedValue
    }

    public var activeSoftWrapBinding: Binding<Bool> {
        if let explicitSoftWrapEnabled {
            return explicitSoftWrapEnabled
        }
        return Binding(
            get: { sharedReadingPrefs.isSoftWrapEnabled },
            set: { sharedReadingPrefs.isSoftWrapEnabled = $0 }
        )
    }

    public var activeSoftWrapEnabled: Bool {
        activeSoftWrapBinding.wrappedValue
    }

    private var usesHighContrastOrReducedTransparency: Bool {
        envReduceTransparency
            || envColorSchemeContrast == .increased
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
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

    public var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if presentationState.isPopoverOpen {
                popoverCardView
                    .padding(.trailing, effectivePopoverTrailingPadding)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }

            if presentationState.showsControlsCluster {
                compactFloatingCluster
                    .padding(.trailing, 12.0 + bottomTrailingReservedWidth)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
        .padding(.bottom, 12.0)
        .onHover { hovering in
            onHoverChange(hovering)
        }
        .onChange(of: focusedControl) { _, newValue in
            onFocusChange(newValue != nil)
        }
        .onExitCommand {
            if isPopoverPresented {
                withAnimation(TTMediaTheme.Motion.micro) {
                    isPopoverPresented = false
                }
            }
        }
    }

    // MARK: - Compact Bottom-Right Floating Button Group (`[ Aa ⎘ ]`)

    private var compactFloatingCluster: some View {
        let shape = RoundedRectangle(cornerRadius: TTMediaTheme.Radius.sm, style: .continuous)
        return HStack(spacing: 2) {
            if saveErrorMessage != nil || isSavedToastPresented {
                activeCompactStatusBadge
                    .padding(.leading, 4)
            }

            if isWritableFile && isEdited {
                compactSaveButton
            }

            aaPopoverToggleButton
            quickCopyButton
        }
        .padding(.horizontal, 2)
        .frame(height: 28)
        .background(localFloatingClusterBackdrop(in: shape))
        .overlay(
            shape.strokeBorder(
                Color.white.opacity(usesHighContrastOrReducedTransparency ? 0.38 : 0.24),
                lineWidth: UniversalTokens.Dimensions.hairlineWidth
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CodeFloatingReadingToolsCluster")
    }

    @ViewBuilder
    private func localFloatingClusterBackdrop(in shape: RoundedRectangle) -> some View {
        if usesHighContrastOrReducedTransparency {
            shape.fill(UniversalTokens.Mineral.inkCharcoal.opacity(0.96))
        } else {
            ZStack {
                VisualEffectBlurRepresentable(material: .hudWindow, blendingMode: .withinWindow)
                UniversalTokens.Plate.surfaceL2
                UniversalTokens.Mineral.inkCharcoal.opacity(0.46)
            }
            .clipShape(shape)
        }
    }

    private static let bambooNSColor = NSColor(srgbRed: 0.42, green: 0.56, blue: 0.35, alpha: 1.0)

    private var aaPopoverToggleButton: some View {
        let isOpen = presentationState.isPopoverOpen
        let isHighlighted = isAaHovered || focusedControl == .aaTools || isOpen
        let label = TextAndDocumentPreviewLocalization.text(.epubTypographyTitle)
        let toggleAction = {
            withAnimation(TTMediaTheme.Motion.micro) {
                isPopoverPresented.toggle()
            }
        }
        return NativeFloatingToolButtonRepresentable(
            id: "CodeFloatingAaToolsButton",
            accessibilityLabel: label,
            helpText: label,
            style: NativeFloatingToolButtonStyle(
                title: "Aa",
                trailingSymbolName: "ellipsis",
                fontSize: 11.0,
                fontWeight: .semibold,
                fontDesign: .rounded,
                foregroundColor: isOpen
                    ? Self.bambooNSColor
                    : NSColor.white.withAlphaComponent(isHighlighted ? 0.98 : 0.88),
                backgroundColor: isOpen
                    ? Self.bambooNSColor.withAlphaComponent(0.22)
                    : (isHighlighted ? NSColor.white.withAlphaComponent(0.14) : .clear),
                hoverBackgroundColor: NSColor.white.withAlphaComponent(0.14),
                cornerRadius: 4.5,
                horizontalPadding: 4.0,
                minWidth: 42.0,
                minHeight: 28.0
            ),
            onHoverChange: { hovering in
                isAaHovered = hovering
                onHoverChange(hovering)
            },
            onFocusChange: { focused in
                focusedControl = focused ? .aaTools : nil
                onFocusChange(focused)
            },
            action: toggleAction
        )
        .frame(width: 42, height: 28)
        .accessibilityIdentifier("CodeFloatingAaToolsButton")
    }

    private var quickCopyButton: some View {
        let isHighlighted = isCopyHovered || focusedControl == .copy
        let help = TextAndDocumentPreviewLocalization.text(isCopiedToastPresented ? .copiedToClipboardHelp : .copySourceCodeHelp)
        return NativeFloatingToolButtonRepresentable(
            id: "CodeFloatingCopyButton",
            accessibilityLabel: help,
            helpText: help,
            style: NativeFloatingToolButtonStyle(
                symbolName: isCopiedToastPresented ? "checkmark" : "doc.on.doc",
                fontSize: 11.0,
                fontWeight: .semibold,
                foregroundColor: isCopiedToastPresented
                    ? Self.bambooNSColor
                    : NSColor.white.withAlphaComponent(isHighlighted ? 0.98 : 0.88),
                backgroundColor: isCopiedToastPresented
                    ? Self.bambooNSColor.withAlphaComponent(0.20)
                    : (isHighlighted ? NSColor.white.withAlphaComponent(0.14) : .clear),
                hoverBackgroundColor: NSColor.white.withAlphaComponent(0.14),
                cornerRadius: 4.5,
                minWidth: 28.0,
                minHeight: 28.0
            ),
            onHoverChange: { hovering in
                isCopyHovered = hovering
                onHoverChange(hovering)
            },
            onFocusChange: { focused in
                focusedControl = focused ? .copy : nil
                onFocusChange(focused)
            },
            action: onCopy
        )
        .frame(width: 28, height: 28)
        .accessibilityIdentifier("CodeFloatingCopyButton")
    }

    private var compactSaveButton: some View {
        let isHighlighted = isSaveHovered || focusedControl == .save
        let help = TextAndDocumentPreviewLocalization.saveChangesHelp("⌘S")
        let label = TextAndDocumentPreviewLocalization.text(.saveButton)
        return NativeFloatingToolButtonRepresentable(
            id: "CodeFloatingSaveButton",
            accessibilityLabel: label,
            helpText: help,
            keyEquivalent: "s",
            keyEquivalentModifierMask: [.command],
            style: NativeFloatingToolButtonStyle(
                symbolName: "square.and.arrow.down.fill",
                showsLeadingDot: true,
                leadingDotColor: .systemOrange,
                fontSize: 10.5,
                fontWeight: .bold,
                foregroundColor: .white,
                backgroundColor: Self.bambooNSColor.withAlphaComponent(isHighlighted ? 0.95 : 0.82),
                hoverBackgroundColor: Self.bambooNSColor.withAlphaComponent(0.95),
                cornerRadius: 4.5,
                minWidth: 34.0,
                minHeight: 28.0
            ),
            onHoverChange: { hovering in
                isSaveHovered = hovering
                onHoverChange(hovering)
            },
            onFocusChange: { focused in
                focusedControl = focused ? .save : nil
                onFocusChange(focused)
            },
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
                .foregroundStyle(TTMediaTheme.cinnabarRed)
                .frame(width: 20, height: 24)
                .ttButtonHelp(err)
                .accessibilityLabel(err)
        } else if isSavedToastPresented {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(TTMediaTheme.bambooGreen)
                .frame(width: 20, height: 24)
                .ttButtonHelp(TextAndDocumentPreviewLocalization.text(.savedBadge))
                .accessibilityLabel(TextAndDocumentPreviewLocalization.text(.savedBadge))
        }
    }

    // MARK: - Compact Reading Tools & Info Popover Card

    private var popoverCardView: some View {
        let cardShape = RoundedRectangle(cornerRadius: TTMediaTheme.Radius.md, style: .continuous)
        let cardWidth = effectivePopoverWidth
        let isCompactCard = cardWidth < 236.0
        return VStack(alignment: .leading, spacing: isCompactCard ? 8 : 10) {
            popoverThemeSection
            popoverTypographyAndLineNumbersRow
            Divider().overlay(Color.white.opacity(0.14))
            popoverMetadataSection
            if isWritableFile && isEdited {
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
                    popoverThemeButton(mode: mode)
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func popoverThemeButton(mode: TTTextReadingBackgroundMode) -> some View {
        let isSelected = activeReadingBackgroundMode == mode
        let selectAction = { activeReadingBackgroundBinding.wrappedValue = mode }
        let buttonID = "CodeFloatingThemeButton_\(mode.rawValue)"
        return NativeFloatingToolButtonRepresentable(
            id: buttonID,
            accessibilityLabel: mode.localizedTitle,
            helpText: mode.localizedHelpText,
            style: NativeFloatingToolButtonStyle(
                title: mode.localizedTitle,
                symbolName: mode.iconName,
                fontSize: 10.0,
                fontWeight: isSelected ? .bold : .medium,
                foregroundColor: isSelected ? Self.bambooNSColor : NSColor.white.withAlphaComponent(0.86),
                backgroundColor: isSelected ? Self.bambooNSColor.withAlphaComponent(0.22) : .clear,
                hoverBackgroundColor: NSColor.white.withAlphaComponent(0.14),
                cornerRadius: 4.5,
                minWidth: 60.0,
                minHeight: 28.0
            ),
            action: selectAction
        )
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        .accessibilityIdentifier(buttonID)
    }

    private var popoverTypographyAndLineNumbersRow: some View {
        let isCompactCard = effectivePopoverWidth < 236.0
        return HStack(spacing: isCompactCard ? 3 : 4) {
            popoverFontStepperCluster(isCompactCard: isCompactCard)
            Spacer(minLength: 2)
            popoverSoftWrapToggleButton(isCompactCard: isCompactCard)
            popoverLineNumbersToggleButton(isCompactCard: isCompactCard)
        }
    }

    private func popoverFontStepperCluster(isCompactCard: Bool) -> some View {
        let decreaseAction = { fontSize = max(Self.minFontSize, fontSize - Self.fontSizeStep) }
        let increaseAction = { fontSize = min(Self.maxFontSize, fontSize + Self.fontSizeStep) }
        let decreaseHelp = TextAndDocumentPreviewLocalization.text(.epubDecreaseFontSizeHelp)
        let increaseHelp = TextAndDocumentPreviewLocalization.text(.epubIncreaseFontSizeHelp)
        let btnWidth: CGFloat = isCompactCard ? 28.0 : 30.0
        return HStack(spacing: 2) {
            NativeFloatingToolButtonRepresentable(
                id: "CodeFloatingFontDecreaseButton",
                accessibilityLabel: decreaseHelp,
                helpText: decreaseHelp,
                isEnabled: fontSize > Self.minFontSize,
                style: NativeFloatingToolButtonStyle(
                    title: "A−",
                    fontSize: 11.0,
                    fontWeight: .semibold,
                    fontDesign: .rounded,
                    foregroundColor: NSColor.white.withAlphaComponent(0.92),
                    backgroundColor: .clear,
                    hoverBackgroundColor: NSColor.white.withAlphaComponent(0.14),
                    cornerRadius: 4.5,
                    minWidth: btnWidth,
                    minHeight: 28.0
                ),
                onFocusChange: { focused in
                    focusedControl = focused ? .fontDecrease : nil
                    onFocusChange(focused)
                },
                action: decreaseAction
            )
            .frame(width: btnWidth, height: 28)
            .accessibilityIdentifier("CodeFloatingFontDecreaseButton")

            Text("\(Int(fontSize.rounded()))pt")
                .font(.system(size: 10.0, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.80))
                .frame(minWidth: isCompactCard ? 26 : 30)

            NativeFloatingToolButtonRepresentable(
                id: "CodeFloatingFontIncreaseButton",
                accessibilityLabel: increaseHelp,
                helpText: increaseHelp,
                isEnabled: fontSize < Self.maxFontSize,
                style: NativeFloatingToolButtonStyle(
                    title: "A+",
                    fontSize: 11.0,
                    fontWeight: .semibold,
                    fontDesign: .rounded,
                    foregroundColor: NSColor.white.withAlphaComponent(0.92),
                    backgroundColor: .clear,
                    hoverBackgroundColor: NSColor.white.withAlphaComponent(0.14),
                    cornerRadius: 4.5,
                    minWidth: btnWidth,
                    minHeight: 28.0
                ),
                onFocusChange: { focused in
                    focusedControl = focused ? .fontIncrease : nil
                    onFocusChange(focused)
                },
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
        let isWrapped = activeSoftWrapEnabled
        let label = TextAndDocumentPreviewLocalization.text(.softWrapLabel)
        let stateValue = TextAndDocumentPreviewLocalization.text(isWrapped ? .softWrapStateOn : .softWrapStateOff)
        let help = TextAndDocumentPreviewLocalization.text(isWrapped ? .disableSoftWrapHelp : .enableSoftWrapHelp)
        let width: CGFloat = isCompactCard ? 66.0 : 76.0
        let toggleAction = {
            withAnimation(TTMediaTheme.Motion.micro) {
                activeSoftWrapBinding.wrappedValue.toggle()
            }
        }
        return NativeFloatingToolButtonRepresentable(
            id: "CodeFloatingSoftWrapToggle",
            accessibilityLabel: label,
            accessibilityValue: stateValue,
            helpText: help,
            style: NativeFloatingToolButtonStyle(
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
                minWidth: width,
                minHeight: 28.0
            ),
            onFocusChange: { focused in
                focusedControl = focused ? .softWrap : nil
                onFocusChange(focused)
            },
            action: toggleAction
        )
        .frame(width: width, height: 28)
        .accessibilityIdentifier("CodeFloatingSoftWrapToggle")
    }

    private func popoverLineNumbersToggleButton(isCompactCard: Bool) -> some View {
        let lineNumAction = { withAnimation(TTMediaTheme.Motion.micro) { showLineNumbers.toggle() } }
        let lineNumHelp = TextAndDocumentPreviewLocalization.text(showLineNumbers ? .hideLineNumbersHelp : .showLineNumbersHelp)
        let stateValue = TextAndDocumentPreviewLocalization.text(showLineNumbers ? .softWrapStateOn : .softWrapStateOff)
        let width: CGFloat = isCompactCard ? 38.0 : 44.0
        return NativeFloatingToolButtonRepresentable(
            id: "CodeFloatingLineNumbersToggle",
            accessibilityLabel: lineNumHelp,
            accessibilityValue: stateValue,
            helpText: lineNumHelp,
            style: NativeFloatingToolButtonStyle(
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
                minWidth: width,
                minHeight: 28.0
            ),
            onFocusChange: { focused in
                focusedControl = focused ? .lineNumbers : nil
                onFocusChange(focused)
            },
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
                    fg: TTMediaTheme.bambooGreen,
                    bg: TTMediaTheme.bambooGreen.opacity(0.18)
                )

                popoverBadgePill(
                    icon: nil,
                    text: encodingBadge,
                    fg: Color.white.opacity(0.86),
                    bg: Color.white.opacity(0.12)
                )

                if isEdited && isWritableFile {
                    popoverBadgePill(
                        icon: "circle.fill",
                        text: TextAndDocumentPreviewLocalization.text(.unsavedBadge),
                        fg: .orange,
                        bg: Color.orange.opacity(0.18)
                    )
                } else if isReadOnly || !isWritableFile {
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
                Text(CodeTextEditorContainerView.truncationBannerMessage)
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
                    .foregroundStyle(TTMediaTheme.cinnabarRed)
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
                    .fill(TTMediaTheme.bambooGreen)
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
        CodeSyntaxHeaderBar.resolveLanguageName(for: fileName, isCompact: true)
    }
}
