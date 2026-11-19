// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTKitDesign
import TTMediaKit
import TTZipCoreTypes
import TTZipUI

@MainActor
extension TTZipCodeReadingTools {
    var popoverCardView: some View {
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
