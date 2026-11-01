// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import TTKitCore
import TTKitDesign

// MARK: - Resolution Decision Primitives

/// Four atomic decision primitives for file collision resolution during extraction.
/// Aligns with Feature 229 specifications (FR-004, FR-005).
public enum ConflictResolutionAction: String, Sendable, CaseIterable, Identifiable {
    /// Overwrite destination item with incoming source file.
    case replace = "REPLACE"
    /// Keep both items by saving incoming item alongside existing item.
    case keepBoth = "KEEP_BOTH"
    /// Skip incoming item and preserve existing destination file.
    case skip = "SKIP"
    /// Stop remaining extraction processing.
    case stop = "STOP"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .replace:
            return "Replace"
        case .keepBoth:
            return "Keep Both"
        case .skip:
            return "Skip"
        case .stop:
            return "Stop"
        }
    }

    public var subtitle: String {
        switch self {
        case .replace:
            return "Overwrite with incoming item"
        case .keepBoth:
            return "Rename incoming to keep both"
        case .skip:
            return "Keep existing item unchanged"
        case .stop:
            return "Stop remaining extraction"
        }
    }

    public var iconSystemName: String {
        switch self {
        case .replace:
            return "arrow.triangle.2.circlepath"
        case .keepBoth:
            return "doc.badge.plus"
        case .skip:
            return "forward.fill"
        case .stop:
            return "xmark.circle"
        }
    }

    public var accessibilityLabel: String {
        title
    }

    public var accessibilityHint: String {
        localizedCopy(using: .english).accessibilityHint
    }

    public func localizedCopy(using localization: ForensicCollisionLocalization) -> ForensicCollisionActionCopy {
        localization.copy(for: self)
    }
}

// MARK: - Conflict Kind Display

/// Display classification for extraction file collisions.
public enum ConflictKindDisplay: String, Sendable, Hashable, CaseIterable {
    case sameType = "SAME_TYPE"
    case typeMismatch = "TYPE_MISMATCH"

    public var title: String {
        switch self {
        case .sameType:
            return "Same Type"
        case .typeMismatch:
            return "Type Mismatch"
        }
    }

    public func localizedTitle(using localization: ForensicCollisionLocalization) -> String {
        localization.title(for: self)
    }
}

// MARK: - File Descriptor

/// Metadata payload describing a file in collision.
public struct ConflictFileDescriptor: Sendable, Hashable {
    public let fileName: String
    public let relativePath: String
    public let filePath: String
    public let byteSize: Int64
    public let modificationDate: Date
    public let isDirectory: Bool
    public let iconSystemName: String
    public let conflictKind: ConflictKindDisplay
    public let hasValidByteSize: Bool
    public let hasValidModificationDate: Bool

    public init(
        fileName: String,
        relativePath: String = "",
        filePath: String,
        byteSize: Int64,
        modificationDate: Date,
        isDirectory: Bool = false,
        iconSystemName: String = "doc.fill",
        conflictKind: ConflictKindDisplay = .sameType,
        hasValidByteSize: Bool = true,
        hasValidModificationDate: Bool = true
    ) {
        self.fileName = fileName
        self.relativePath = relativePath.isEmpty ? fileName : relativePath
        self.filePath = filePath
        self.byteSize = byteSize
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
        self.iconSystemName = iconSystemName
        self.conflictKind = conflictKind
        self.hasValidByteSize = hasValidByteSize
        self.hasValidModificationDate = hasValidModificationDate
    }

    public var formattedSize: String {
        if isDirectory {
            return "Directory"
        }
        guard hasValidByteSize, byteSize >= 0 else {
            return ForensicCollisionLocalization.english.unavailableValue
        }
        let countFormatter = NumberFormatter()
        countFormatter.numberStyle = .decimal
        countFormatter.locale = Locale(identifier: "en_US")
        let bytesFormatted = countFormatter.string(from: NSNumber(value: byteSize)) ?? "\(byteSize)"
        let readable = ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
        return "\(readable) (\(bytesFormatted) B)"
    }

    public var formattedTimestamp: String {
        guard ForensicCollisionLocalization.english.isTimestampValid(for: self) else {
            return ForensicCollisionLocalization.english.unavailableValue
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: modificationDate)
    }

    public func formattedSize(using localization: ForensicCollisionLocalization) -> String {
        localization.formatSize(for: self)
    }

    public func formattedTimestamp(
        using localization: ForensicCollisionLocalization,
        timeZone: TimeZone = .current
    ) -> String {
        localization.formatTimestamp(for: self, timeZone: timeZone)
    }
}

// MARK: - Dual-Card Forensic Collision Panel

/// Side-by-side card comparison panel for forensic conflict resolution.
/// Satisfies the TTKit 4-layer optical model sitting on Layer 3 Overlay Plate.
@MainActor
public struct ForensicCollisionPanel: View {
    public let sourceFile: ConflictFileDescriptor
    public let targetFile: ConflictFileDescriptor
    public let conflictIndex: Int
    public let totalConflicts: Int
    @Binding public var applyToAllRemaining: Bool
    public let explicitLocalization: ForensicCollisionLocalization?
    public let onResolve: @Sendable (ConflictResolutionAction, Bool) -> Void

    @Environment(\.forensicCollisionLocalization) private var environmentLocalization
    @Environment(\.locale) private var environmentLocale
    @Environment(\.colorScheme) private var colorScheme
    @State private var languageRefreshSequence: Int = 0

    public init(
        sourceFile: ConflictFileDescriptor,
        targetFile: ConflictFileDescriptor,
        conflictIndex: Int = 1,
        totalConflicts: Int = 1,
        applyToAllRemaining: Binding<Bool>,
        localization: ForensicCollisionLocalization? = nil,
        onResolve: @escaping @Sendable (ConflictResolutionAction, Bool) -> Void
    ) {
        self.sourceFile = sourceFile
        self.targetFile = targetFile
        self.conflictIndex = conflictIndex
        self.totalConflicts = totalConflicts
        self._applyToAllRemaining = applyToAllRemaining
        self.explicitLocalization = localization
        self.onResolve = onResolve
    }

    public var activeLocalization: ForensicCollisionLocalization {
        if let explicitLocalization {
            return explicitLocalization
        }
        if let environmentLocalization {
            return environmentLocalization
        }
        if let provider = ForensicCollisionLocalization.fallbackProvider {
            return provider()
        }
        return ForensicCollisionLocalization.resolved(for: environmentLocale)
    }

    public var isTypeMismatch: Bool {
        sourceFile.conflictKind == .typeMismatch ||
        targetFile.conflictKind == .typeMismatch ||
        sourceFile.isDirectory != targetFile.isDirectory
    }

    public var isSourceItemNewer: Bool {
        let loc = activeLocalization
        guard loc.isTimestampValid(for: sourceFile), loc.isTimestampValid(for: targetFile) else {
            return false
        }
        return sourceFile.modificationDate > targetFile.modificationDate
    }

    public var isTargetItemNewer: Bool {
        let loc = activeLocalization
        guard loc.isTimestampValid(for: sourceFile), loc.isTimestampValid(for: targetFile) else {
            return false
        }
        return targetFile.modificationDate > sourceFile.modificationDate
    }

    public var isSourceItemLarger: Bool {
        let loc = activeLocalization
        guard !sourceFile.isDirectory, !targetFile.isDirectory else { return false }
        guard loc.isSizeValid(for: sourceFile), loc.isSizeValid(for: targetFile) else { return false }
        return sourceFile.byteSize > targetFile.byteSize
    }

    public var isTargetItemLarger: Bool {
        let loc = activeLocalization
        guard !sourceFile.isDirectory, !targetFile.isDirectory else { return false }
        guard loc.isSizeValid(for: sourceFile), loc.isSizeValid(for: targetFile) else { return false }
        return targetFile.byteSize > sourceFile.byteSize
    }

    public var headerVoiceOverSummary: String {
        activeLocalization.formatHeaderVoiceOver(
            sourceFile: sourceFile,
            targetFile: targetFile,
            conflictIndex: conflictIndex,
            totalConflicts: totalConflicts,
            isTypeMismatch: isTypeMismatch
        )
    }

    public var incomingCardVoiceOverSummary: String {
        let loc = activeLocalization
        return loc.formatCardVoiceOver(
            title: loc.incomingCardTitle,
            descriptor: sourceFile,
            isNewer: isSourceItemNewer,
            isLarger: isSourceItemLarger,
            isTypeMismatch: isTypeMismatch
        )
    }

    public var existingCardVoiceOverSummary: String {
        let loc = activeLocalization
        return loc.formatCardVoiceOver(
            title: loc.existingCardTitle,
            descriptor: targetFile,
            isNewer: isTargetItemNewer,
            isLarger: isTargetItemLarger,
            isTypeMismatch: isTypeMismatch
        )
    }

    public var prefersTwoByTwoActionGrid: Bool {
        let loc = activeLocalization
        let subtitles = [
            loc.stopAction.subtitle,
            loc.skipAction.subtitle,
            loc.replaceAction.subtitle,
            loc.keepBothAction.subtitle
        ]
        return subtitles.contains { $0.count > 26 }
    }

    public func triggerAction(_ action: ConflictResolutionAction) {
        onResolve(action, applyToAllRemaining)
    }

    public var body: some View {
        let _ = languageRefreshSequence
        let loc = activeLocalization
        VStack(spacing: 16) {
            headerBar(loc: loc)

            dualComparisonCards(loc: loc)

            actionButtonsSection(loc: loc)

            bottomControls(loc: loc)
        }
        .padding(20)
        .frame(minWidth: 600, idealWidth: 640, maxWidth: 680)
        .ttOverlayGlassPlate(cornerRadius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc.dialogAccessibilityLabel)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TTZipLanguageChanged"))) { _ in
            languageRefreshSequence &+= 1
        }
    }

    // MARK: - Header Bar

    @ViewBuilder
    private func headerBar(loc: ForensicCollisionLocalization) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(TTKitTheme.archivalAmber)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(loc.panelTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)

                Text(loc.formatConflictProgress(index: conflictIndex, total: totalConflicts, fileName: sourceFile.fileName))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(sourceFile.fileName)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(headerVoiceOverSummary)

            Spacer(minLength: 8)

            if isTypeMismatch {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                    Text(loc.typeMismatchBadge)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(TTKitTheme.cinnabarRed.opacity(0.15))
                .foregroundStyle(TTKitTheme.cinnabarRed)
                .clipShape(Capsule())
                .help(loc.typeMismatchHelp)
                .accessibilityLabel(loc.typeMismatchAccessibilityLabel)
            }
        }
    }

    // MARK: - Comparison Cards

    @ViewBuilder
    private func dualComparisonCards(loc: ForensicCollisionLocalization) -> some View {
        HStack(alignment: .top, spacing: 14) {
            comparisonCard(
                loc: loc,
                title: loc.incomingCardTitle,
                descriptor: sourceFile,
                isNewer: isSourceItemNewer,
                isLarger: isSourceItemLarger,
                cardBorderColor: isSourceItemNewer ? TTKitTheme.bambooGreen : Color.clear,
                voiceOverSummary: incomingCardVoiceOverSummary
            )

            comparisonCard(
                loc: loc,
                title: loc.existingCardTitle,
                descriptor: targetFile,
                isNewer: isTargetItemNewer,
                isLarger: isTargetItemLarger,
                cardBorderColor: isTargetItemNewer ? TTKitTheme.bambooGreen : Color.clear,
                voiceOverSummary: existingCardVoiceOverSummary
            )
        }
    }

    @ViewBuilder
    private func comparisonCard(
        loc: ForensicCollisionLocalization,
        title: String,
        descriptor: ConflictFileDescriptor,
        isNewer: Bool,
        isLarger: Bool,
        cardBorderColor: Color,
        voiceOverSummary: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(loc: loc, title: title, descriptor: descriptor, isNewer: isNewer)

            cardFileRow(loc: loc, descriptor: descriptor)

            Divider()

            cardAttributes(loc: loc, descriptor: descriptor, isNewer: isNewer, isLarger: isLarger)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    cardBorderColor == .clear
                        ? Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.12)
                        : cardBorderColor.opacity(0.60),
                    lineWidth: UniversalTokens.Dimensions.hairlineWidth
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceOverSummary)
    }

    @ViewBuilder
    private func cardHeader(
        loc: ForensicCollisionLocalization,
        title: String,
        descriptor: ConflictFileDescriptor,
        isNewer: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(title)

            Spacer(minLength: 4)

            if isNewer {
                Text(loc.newerBadge)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(TTKitTheme.bambooGreen.opacity(0.18))
                    .foregroundStyle(TTKitTheme.bambooGreen)
                    .clipShape(Capsule())
            }

            if isTypeMismatch {
                Text(descriptor.isDirectory ? loc.directoryBadge : loc.fileBadge)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(TTKitTheme.cinnabarRed.opacity(0.18))
                    .foregroundStyle(TTKitTheme.cinnabarRed)
                    .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private func cardFileRow(
        loc: ForensicCollisionLocalization,
        descriptor: ConflictFileDescriptor
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: descriptor.iconSystemName)
                .font(.system(size: 20))
                .foregroundStyle(descriptor.isDirectory ? TTKitTheme.archivalAmber : TTKitTheme.kintsugiGold)
                .accessibilityHidden(true)

            Text(descriptor.fileName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .help(loc.fileRowHelpText(for: descriptor))
        }
    }

    @ViewBuilder
    private func cardAttributes(
        loc: ForensicCollisionLocalization,
        descriptor: ConflictFileDescriptor,
        isNewer: Bool,
        isLarger: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            attributeRow(
                label: loc.pathLabel,
                value: descriptor.relativePath,
                helpText: loc.pathRowHelpText(for: descriptor),
                badge: nil,
                badgeColor: .clear
            )

            attributeRow(
                label: loc.sizeLabel,
                value: loc.formatSize(for: descriptor),
                helpText: loc.formatSize(for: descriptor),
                badge: isLarger ? loc.largerBadge : nil,
                badgeColor: TTKitTheme.archivalAmber
            )

            attributeRow(
                label: loc.modifiedLabel,
                value: loc.formatTimestamp(for: descriptor),
                helpText: loc.formatTimestamp(for: descriptor),
                badge: isNewer ? loc.newerBadge : nil,
                badgeColor: TTKitTheme.bambooGreen
            )

            if isTypeMismatch {
                attributeRow(
                    label: loc.typeLabel,
                    value: loc.formatTypeValue(for: descriptor),
                    helpText: loc.typeMismatchHelp,
                    badge: loc.mismatchBadge,
                    badgeColor: TTKitTheme.cinnabarRed
                )
            }
        }
    }

    @ViewBuilder
    private func attributeRow(
        label: String,
        value: String,
        helpText: String,
        badge: String?,
        badgeColor: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 58, idealWidth: 64, alignment: .leading)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(helpText)

            Spacer(minLength: 4)

            if let badge {
                Text(badge)
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(badgeColor.opacity(0.18))
                    .foregroundStyle(badgeColor)
                    .clipShape(Capsule())
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Action Buttons Grid

    @ViewBuilder
    private func actionButtonsSection(loc: ForensicCollisionLocalization) -> some View {
        if prefersTwoByTwoActionGrid {
            twoByTwoActionButtonsGrid(loc: loc)
        } else {
            ViewThatFits(in: .horizontal) {
                fourColumnActionButtonsRow(loc: loc)
                twoByTwoActionButtonsGrid(loc: loc)
            }
        }
    }

    @ViewBuilder
    private func fourColumnActionButtonsRow(loc: ForensicCollisionLocalization) -> some View {
        HStack(alignment: .top, spacing: 10) {
            resolutionButton(loc: loc, for: .stop, prominence: .secondaryDestructive)
            resolutionButton(loc: loc, for: .skip, prominence: .standard)
            resolutionButton(loc: loc, for: .replace, prominence: .destructive)
            resolutionButton(loc: loc, for: .keepBoth, prominence: .prominent)
        }
    }

    @ViewBuilder
    private func twoByTwoActionButtonsGrid(loc: ForensicCollisionLocalization) -> some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                resolutionButton(loc: loc, for: .stop, prominence: .secondaryDestructive)
                resolutionButton(loc: loc, for: .skip, prominence: .standard)
            }
            GridRow {
                resolutionButton(loc: loc, for: .replace, prominence: .destructive)
                resolutionButton(loc: loc, for: .keepBoth, prominence: .prominent)
            }
        }
    }

    private enum ButtonProminence {
        case standard
        case prominent
        case destructive
        case secondaryDestructive
    }

    @ViewBuilder
    private func resolutionButton(
        loc: ForensicCollisionLocalization,
        for action: ConflictResolutionAction,
        prominence: ButtonProminence
    ) -> some View {
        let copy = loc.copy(for: action)
        let tint = buttonTintColor(for: prominence)
        Button {
            onResolve(action, applyToAllRemaining)
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: action.iconSystemName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(titleColor(for: prominence))
                    Text(copy.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(titleColor(for: prominence))
                        .lineLimit(1)
                }
                Text(copy.subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(subtitleColor(for: prominence))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.16 : 0.11))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        tint.opacity(colorScheme == .dark ? 0.45 : 0.35),
                        lineWidth: UniversalTokens.Dimensions.hairlineWidth
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(copy.helpTooltip)
        .modifier(ButtonShortcutModifier(action: action))
        .accessibilityLabel(copy.accessibilityLabel)
        .accessibilityHint(copy.accessibilityHint)
    }

    private func buttonTintColor(for prominence: ButtonProminence) -> Color {
        switch prominence {
        case .standard:
            return .secondary
        case .prominent:
            return TTKitTheme.kintsugiGold
        case .destructive:
            return TTKitTheme.cinnabarRed
        case .secondaryDestructive:
            return TTKitTheme.cinnabarRed.opacity(0.85)
        }
    }

    private func titleColor(for prominence: ButtonProminence) -> Color {
        switch prominence {
        case .standard, .prominent:
            return .primary
        case .destructive, .secondaryDestructive:
            return TTKitTheme.cinnabarRed
        }
    }

    private func subtitleColor(for prominence: ButtonProminence) -> Color {
        switch prominence {
        case .standard, .prominent:
            return .secondary
        case .destructive, .secondaryDestructive:
            return TTKitTheme.cinnabarRed.opacity(colorScheme == .dark ? 0.90 : 0.85)
        }
    }

    // MARK: - Bottom Controls

    @ViewBuilder
    private func bottomControls(loc: ForensicCollisionLocalization) -> some View {
        HStack {
            Toggle(loc.applyToAllTitle, isOn: $applyToAllRemaining)
                .toggleStyle(.checkbox)
                .font(.system(size: 11, weight: .medium))
                .help(loc.applyToAllAccessibilityHint)
                .accessibilityLabel(loc.applyToAllTitle)
                .accessibilityHint(loc.applyToAllAccessibilityHint)

            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - Keyboard Shortcut Modifier

private struct ButtonShortcutModifier: ViewModifier {
    let action: ConflictResolutionAction

    func body(content: Content) -> some View {
        switch action {
        case .keepBoth:
            content.keyboardShortcut(.defaultAction)
        case .stop:
            content.keyboardShortcut(.cancelAction)
        case .replace, .skip:
            content
        }
    }
}
