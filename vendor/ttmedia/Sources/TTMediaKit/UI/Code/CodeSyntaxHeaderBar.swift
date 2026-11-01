// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Header bar component for code syntax and text preview.
/// Provides 4-tier responsive width adaptation (never overlapping at the top-left even at 220pt)
/// and a 3-state reading background selector (`.black`, `.white`, `.fluidTransparent`) independent of W2 global app appearance.
public struct CodeSyntaxHeaderBar: View {
    @Environment(\.colorScheme) private var inheritedColorScheme
    private var sharedReadingPrefs = TTTextReadingPreferenceStore.shared

    public let isCompact: Bool
    public let fileName: String
    public let lineCount: Int
    public let byteCount: Int64
    public let isEdited: Bool
    public let isWritableFile: Bool
    public let isReadOnly: Bool
    public let encodingBadge: String?
    public let saveErrorMessage: String?
    public let isSavedToastPresented: Bool
    public let isCopiedToastPresented: Bool
    @Binding public var showLineNumbers: Bool
    private var explicitReadingBackgroundMode: Binding<TTTextReadingBackgroundMode>?
    private var explicitSoftWrapEnabled: Binding<Bool>?
    public let onCopy: () -> Void
    public let onSave: () -> Void

    public init(
        isCompact: Bool,
        fileName: String,
        lineCount: Int,
        byteCount: Int64,
        isEdited: Bool,
        isWritableFile: Bool,
        isReadOnly: Bool = false,
        encodingBadge: String? = nil,
        saveErrorMessage: String?,
        isSavedToastPresented: Bool,
        isCopiedToastPresented: Bool,
        showLineNumbers: Binding<Bool>,
        readingBackgroundMode: Binding<TTTextReadingBackgroundMode>? = nil,
        softWrapEnabled: Binding<Bool>? = nil,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) {
        self.isCompact = isCompact
        self.fileName = fileName
        self.lineCount = lineCount
        self.byteCount = byteCount
        self.isEdited = isEdited
        self.isWritableFile = isWritableFile
        self.isReadOnly = isReadOnly
        self.encodingBadge = encodingBadge
        self.saveErrorMessage = saveErrorMessage
        self.isSavedToastPresented = isSavedToastPresented
        self.isCopiedToastPresented = isCopiedToastPresented
        self._showLineNumbers = showLineNumbers
        self.explicitReadingBackgroundMode = readingBackgroundMode
        self.explicitSoftWrapEnabled = softWrapEnabled
        self.onCopy = onCopy
        self.onSave = onSave
    }

    @MainActor
    public var activeReadingBackgroundBinding: Binding<TTTextReadingBackgroundMode> {
        if let explicitReadingBackgroundMode {
            return explicitReadingBackgroundMode
        }
        return Binding(
            get: { sharedReadingPrefs.mode },
            set: { sharedReadingPrefs.mode = $0 }
        )
    }

    @MainActor
    public var activeReadingBackgroundMode: TTTextReadingBackgroundMode {
        activeReadingBackgroundBinding.wrappedValue
    }

    @MainActor
    public var activeSoftWrapBinding: Binding<Bool> {
        if let explicitSoftWrapEnabled {
            return explicitSoftWrapEnabled
        }
        return Binding(
            get: { sharedReadingPrefs.isSoftWrapEnabled },
            set: { sharedReadingPrefs.isSoftWrapEnabled = $0 }
        )
    }

    @MainActor
    public var activeSoftWrapEnabled: Bool {
        activeSoftWrapBinding.wrappedValue
    }

    /// Guaranteed maximum horizontal width of the trailing critical-action cluster in minimal sidebar mode (`< 260pt`).
    nonisolated public static func minimalActionClusterWidth(isWritableAndEdited: Bool) -> CGFloat {
        // 3-icon background capsule (68pt) + line numbers (24pt) + copy (24pt) + optional icon-save (26pt) + spacing
        isWritableAndEdited ? 148.0 : 120.0
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            fullHeaderBar
            mediumHeaderBar
            compactHeaderBar
            minimalHeaderBar
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        .environment(\.colorScheme, activeReadingBackgroundMode.effectiveIsDark(
            isAppDarkAppearance: inheritedColorScheme == .dark
        ) ? .dark : .light)
    }

    // MARK: - 4-Tier Responsive Layouts

    private var fullHeaderBar: some View {
        HStack(spacing: 8) {
            languageBadge(isCompact: false, fixedHorizontal: true)
            if let enc = encodingBadge, !enc.isEmpty {
                encodingTagBadge(enc)
            }
            fileMetricsCard
            statusBadgesView
            Spacer(minLength: 6)
            readingBackgroundSegmentPicker(showLabels: true)
            trailingActionButtons(saveStyle: .full)
        }
    }

    private var mediumHeaderBar: some View {
        HStack(spacing: 6) {
            languageBadge(isCompact: true, fixedHorizontal: true)
            if let enc = encodingBadge, !enc.isEmpty {
                encodingTagBadge(enc)
            }
            compactByteMetricsCard
            statusBadgesView
            Spacer(minLength: 4)
            readingBackgroundSegmentPicker(showLabels: false)
            trailingActionButtons(saveStyle: .compact)
        }
    }

    private var compactHeaderBar: some View {
        HStack(spacing: 5) {
            languageBadge(isCompact: true, fixedHorizontal: true)
            compactStatusIconBadge
            Spacer(minLength: 4)
            readingBackgroundSegmentPicker(showLabels: false)
            trailingActionButtons(saveStyle: .compact)
        }
    }

    private var minimalHeaderBar: some View {
        HStack(spacing: 4) {
            languageBadge(isCompact: true, fixedHorizontal: false)
                .layoutPriority(0)
            compactStatusIconBadge
            Spacer(minLength: 2)
            HStack(spacing: 3) {
                readingBackgroundSegmentPicker(showLabels: false)
                trailingActionButtons(saveStyle: .iconOnly)
            }
            .layoutPriority(1)
        }
    }

    // MARK: - Status & Action Clusters

    private enum SaveButtonStyle {
        case full
        case compact
        case iconOnly
    }

    @ViewBuilder
    private var statusBadgesView: some View {
        if isEdited && isWritableFile {
            unsavedBadge
        } else if isReadOnly || !isWritableFile {
            readOnlyBadgeView
        }
        if let errorMsg = saveErrorMessage {
            saveErrorNotice(errorMsg)
        } else if isSavedToastPresented {
            savedToastView
        }
    }

    @ViewBuilder
    private var compactStatusIconBadge: some View {
        if let errorMsg = saveErrorMessage {
            compactIconPill(icon: "exclamationmark.circle.fill", color: .red, helpText: errorMsg)
        } else if isSavedToastPresented {
            compactIconPill(
                icon: "checkmark.circle.fill",
                color: TTMediaTheme.bambooGreen,
                helpText: TextAndDocumentPreviewLocalization.text(.savedBadge)
            )
        } else if isEdited && isWritableFile {
            compactIconPill(
                icon: "circle.fill",
                color: .orange,
                helpText: TextAndDocumentPreviewLocalization.text(.unsavedBadge)
            )
        } else if isReadOnly || !isWritableFile {
            compactIconPill(
                icon: "lock.fill",
                color: .secondary,
                helpText: TextAndDocumentPreviewLocalization.text(.readOnlyBadge)
            )
        }
    }

    @ViewBuilder
    private func trailingActionButtons(saveStyle: SaveButtonStyle) -> some View {
        if saveStyle != .iconOnly {
            softWrapToggleButton
        }
        lineNumbersToggleButton
        copyButton
        if isWritableFile && isEdited {
            saveButton(style: saveStyle)
        }
    }

    // MARK: - 3-State Reading Background Picker

    private func readingBackgroundSegmentPicker(showLabels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(TTTextReadingBackgroundMode.allCases) { mode in
                readingBackgroundSegmentButton(mode: mode, showLabel: showLabels)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TextAndDocumentPreviewLocalization.text(.readingBackgroundLabel))
    }

    private func readingBackgroundSegmentButton(
        mode: TTTextReadingBackgroundMode,
        showLabel: Bool
    ) -> some View {
        let isSelected = activeReadingBackgroundMode == mode
        return Button(action: {
            activeReadingBackgroundBinding.wrappedValue = mode
        }) {
            HStack(spacing: 3.5) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                if showLabel {
                    Text(mode.localizedTitle)
                        .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? TTMediaTheme.bambooGreen : Color.primary.opacity(0.72))
            .padding(.horizontal, showLabel ? 6 : 5)
            .padding(.vertical, 3)
            .background(
                isSelected
                    ? TTMediaTheme.bambooGreen.opacity(0.16)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .ttButtonHelp(mode.localizedHelpText)
        .accessibilityLabel(mode.localizedTitle)
    }

    // MARK: - Subviews

    private var isPlainTextMode: Bool {
        !TTTextSyntaxRenderMode.resolve(fileName: fileName).isSyntaxHighlighted
    }

    private func languageBadge(isCompact: Bool, fixedHorizontal: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isPlainTextMode ? "doc.plaintext" : "curlybraces")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(TTMediaTheme.bambooGreen)
            Text(languageName(isCompact: isCompact))
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, isCompact ? 6 : 8)
        .padding(.vertical, 3.5)
        .background(TTMediaTheme.bambooGreen.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize(horizontal: fixedHorizontal, vertical: false)
    }

    private func encodingTagBadge(_ encodingText: String) -> some View {
        Text(encodingText)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var fileMetricsCard: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(
                TextAndDocumentPreviewLocalization.fileSizeAndLines(
                    sizeText: fileSizeDescription,
                    lineCount: lineCount
                )
            )
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactByteMetricsCard: some View {
        Text(fileSizeDescription)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var unsavedBadge: some View {
        headerBadge(
            icon: "circle.fill",
            text: TextAndDocumentPreviewLocalization.text(.unsavedBadge),
            color: .orange,
            bgColor: Color.orange.opacity(0.12)
        )
    }

    private var readOnlyBadgeView: some View {
        headerBadge(
            icon: "lock.fill",
            text: TextAndDocumentPreviewLocalization.text(.readOnlyBadge),
            color: .secondary,
            bgColor: Color.primary.opacity(0.06)
        )
    }

    private var savedToastView: some View {
        headerBadge(
            icon: "checkmark.circle.fill",
            text: TextAndDocumentPreviewLocalization.text(.savedBadge),
            color: TTMediaTheme.bambooGreen,
            bgColor: TTMediaTheme.bambooGreen.opacity(0.12)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private func saveErrorNotice(_ errorMsg: String) -> some View {
        headerBadge(
            icon: "exclamationmark.circle.fill",
            text: errorMsg,
            color: .red,
            bgColor: Color.red.opacity(0.1)
        )
    }

    private func compactIconPill(icon: String, color: Color, helpText: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .fixedSize(horizontal: true, vertical: false)
            .ttButtonHelp(helpText)
            .accessibilityLabel(helpText)
    }

    private func headerBadge(icon: String, text: String, color: Color, bgColor: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 10.5, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(bgColor)
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private var softWrapToggleButton: some View {
        let isWrapped = activeSoftWrapEnabled
        let label = TextAndDocumentPreviewLocalization.text(.softWrapLabel)
        let help = TextAndDocumentPreviewLocalization.text(isWrapped ? .disableSoftWrapHelp : .enableSoftWrapHelp)
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                activeSoftWrapBinding.wrappedValue.toggle()
            }
        }) {
            Image(systemName: "arrow.turn.down.left")
                .font(.system(size: 11, weight: isWrapped ? .bold : .regular))
                .foregroundStyle(isWrapped ? TTMediaTheme.bambooGreen : Color.primary.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(isWrapped ? TTMediaTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(help)
        .accessibilityLabel(label)
        .accessibilityValue(TextAndDocumentPreviewLocalization.text(isWrapped ? .softWrapStateOn : .softWrapStateOff))
    }

    private var lineNumbersToggleButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                showLineNumbers.toggle()
            }
        }) {
            Image(systemName: "list.number")
                .font(.system(size: 11, weight: showLineNumbers ? .bold : .regular))
                .foregroundStyle(showLineNumbers ? TTMediaTheme.bambooGreen : Color.primary.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(showLineNumbers ? TTMediaTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(TextAndDocumentPreviewLocalization.text(showLineNumbers ? .hideLineNumbersHelp : .showLineNumbersHelp))
    }

    private var copyButton: some View {
        Button(action: { onCopy() }) {
            Image(systemName: isCopiedToastPresented ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(isCopiedToastPresented ? TTMediaTheme.bambooGreen : Color.primary.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(isCopiedToastPresented ? TTMediaTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(TextAndDocumentPreviewLocalization.text(isCopiedToastPresented ? .copiedToClipboardHelp : .copySourceCodeHelp))
    }

    @ViewBuilder
    private func saveButton(style: SaveButtonStyle) -> some View {
        Button(action: { onSave() }) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .bold))
                if style != .iconOnly {
                    Text(
                        style == .compact
                            ? TextAndDocumentPreviewLocalization.text(.saveButton)
                            : TextAndDocumentPreviewLocalization.saveWithShortcut("⌘S")
                    )
                    .font(.system(size: style == .compact ? 10.5 : 11, weight: .bold))
                    .lineLimit(1)
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, style == .iconOnly ? 6 : (style == .compact ? 8 : 10))
            .padding(.vertical, 4)
            .background(TTMediaTheme.bambooGreen)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .keyboardShortcut("s", modifiers: [.command])
        .ttButtonHelp(TextAndDocumentPreviewLocalization.saveChangesHelp("⌘S"))
    }

    // MARK: - Formatters & Language Detection

    private var fileSizeDescription: String {
        ByteCountFormatterCache.shared.string(fromByteCount: byteCount)
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
    public static func resolveLanguageName(for fileName: String, isCompact: Bool) -> String {
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

    public func languageName(isCompact: Bool) -> String {
        Self.resolveLanguageName(for: fileName, isCompact: isCompact)
    }
}
