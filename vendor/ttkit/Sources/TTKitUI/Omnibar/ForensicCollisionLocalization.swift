// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI

// MARK: - Byte Count Formatting Style

/// Product-agnostic byte unit standard for collision panel metadata formatting.
public enum ForensicCollisionByteCountStyle: String, Sendable, Hashable, CaseIterable {
    /// Base-1000 decimal units (KB, MB, GB).
    case file = "FILE_SI"
    /// Base-1024 binary units (KiB, MiB, GiB).
    case binary = "BINARY_IEC"
}

// MARK: - Action Button Copy

/// Localized text and accessibility metadata for a single collision resolution action.
public struct ForensicCollisionActionCopy: Sendable, Hashable {
    public let title: String
    public let subtitle: String
    public let accessibilityLabel: String
    public let accessibilityHint: String

    public init(
        title: String,
        subtitle: String,
        accessibilityLabel: String? = nil,
        accessibilityHint: String
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessibilityLabel = accessibilityLabel ?? title
        self.accessibilityHint = accessibilityHint
    }

    public var helpTooltip: String {
        "\(title) — \(subtitle)"
    }
}

// MARK: - Forensic Collision Localization Model

/// Product-agnostic localization and locale-aware formatting model for `ForensicCollisionPanel`.
public struct ForensicCollisionLocalization: Sendable, Hashable {
    /// Optional host-registered provider invoked when a panel caller omits an explicit `localization` parameter.
    @MainActor public static var fallbackProvider: (@MainActor () -> ForensicCollisionLocalization)?

    public let localeIdentifier: String
    public let byteCountStyle: ForensicCollisionByteCountStyle

    public let panelTitle: String
    public let conflictProgressFormat: String
    public let sameTypeTitle: String
    public let typeMismatchBadge: String
    public let typeMismatchHelp: String

    public let incomingCardTitle: String
    public let existingCardTitle: String
    public let newerBadge: String
    public let largerBadge: String
    public let mismatchBadge: String
    public let directoryBadge: String
    public let fileBadge: String

    public let pathLabel: String
    public let sizeLabel: String
    public let modifiedLabel: String
    public let typeLabel: String
    public let directoryTypeValue: String
    public let fileTypeValue: String
    public let unavailableValue: String
    public let bytesExactFormat: String
    public let bytesOnlyFormat: String

    public let stopAction: ForensicCollisionActionCopy
    public let skipAction: ForensicCollisionActionCopy
    public let replaceAction: ForensicCollisionActionCopy
    public let keepBothAction: ForensicCollisionActionCopy
    public let applyToAllTitle: String
    public let applyToAllAccessibilityHint: String

    public let dialogAccessibilityLabel: String
    public let headerSummaryVoiceOverFormat: String
    public let headerTypeMismatchClause: String
    public let typeMismatchAccessibilityLabel: String
    public let cardAccessibilityFormat: String

    public var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    public init(
        localeIdentifier: String,
        byteCountStyle: ForensicCollisionByteCountStyle = .file,
        panelTitle: String,
        conflictProgressFormat: String,
        sameTypeTitle: String,
        typeMismatchBadge: String,
        typeMismatchHelp: String,
        incomingCardTitle: String,
        existingCardTitle: String,
        newerBadge: String,
        largerBadge: String,
        mismatchBadge: String,
        directoryBadge: String,
        fileBadge: String,
        pathLabel: String,
        sizeLabel: String,
        modifiedLabel: String,
        typeLabel: String,
        directoryTypeValue: String,
        fileTypeValue: String,
        unavailableValue: String,
        bytesExactFormat: String,
        bytesOnlyFormat: String,
        stopAction: ForensicCollisionActionCopy,
        skipAction: ForensicCollisionActionCopy,
        replaceAction: ForensicCollisionActionCopy,
        keepBothAction: ForensicCollisionActionCopy,
        applyToAllTitle: String,
        applyToAllAccessibilityHint: String,
        dialogAccessibilityLabel: String,
        headerSummaryVoiceOverFormat: String,
        headerTypeMismatchClause: String,
        typeMismatchAccessibilityLabel: String,
        cardAccessibilityFormat: String
    ) {
        self.localeIdentifier = localeIdentifier
        self.byteCountStyle = byteCountStyle
        self.panelTitle = panelTitle
        self.conflictProgressFormat = conflictProgressFormat
        self.sameTypeTitle = sameTypeTitle
        self.typeMismatchBadge = typeMismatchBadge
        self.typeMismatchHelp = typeMismatchHelp
        self.incomingCardTitle = incomingCardTitle
        self.existingCardTitle = existingCardTitle
        self.newerBadge = newerBadge
        self.largerBadge = largerBadge
        self.mismatchBadge = mismatchBadge
        self.directoryBadge = directoryBadge
        self.fileBadge = fileBadge
        self.pathLabel = pathLabel
        self.sizeLabel = sizeLabel
        self.modifiedLabel = modifiedLabel
        self.typeLabel = typeLabel
        self.directoryTypeValue = directoryTypeValue
        self.fileTypeValue = fileTypeValue
        self.unavailableValue = unavailableValue
        self.bytesExactFormat = bytesExactFormat
        self.bytesOnlyFormat = bytesOnlyFormat
        self.stopAction = stopAction
        self.skipAction = skipAction
        self.replaceAction = replaceAction
        self.keepBothAction = keepBothAction
        self.applyToAllTitle = applyToAllTitle
        self.applyToAllAccessibilityHint = applyToAllAccessibilityHint
        self.dialogAccessibilityLabel = dialogAccessibilityLabel
        self.headerSummaryVoiceOverFormat = headerSummaryVoiceOverFormat
        self.headerTypeMismatchClause = headerTypeMismatchClause
        self.typeMismatchAccessibilityLabel = typeMismatchAccessibilityLabel
        self.cardAccessibilityFormat = cardAccessibilityFormat
    }

    public func withLocale(
        identifier: String,
        byteCountStyle: ForensicCollisionByteCountStyle? = nil
    ) -> ForensicCollisionLocalization {
        ForensicCollisionLocalization(
            localeIdentifier: identifier,
            byteCountStyle: byteCountStyle ?? self.byteCountStyle,
            panelTitle: panelTitle,
            conflictProgressFormat: conflictProgressFormat,
            sameTypeTitle: sameTypeTitle,
            typeMismatchBadge: typeMismatchBadge,
            typeMismatchHelp: typeMismatchHelp,
            incomingCardTitle: incomingCardTitle,
            existingCardTitle: existingCardTitle,
            newerBadge: newerBadge,
            largerBadge: largerBadge,
            mismatchBadge: mismatchBadge,
            directoryBadge: directoryBadge,
            fileBadge: fileBadge,
            pathLabel: pathLabel,
            sizeLabel: sizeLabel,
            modifiedLabel: modifiedLabel,
            typeLabel: typeLabel,
            directoryTypeValue: directoryTypeValue,
            fileTypeValue: fileTypeValue,
            unavailableValue: unavailableValue,
            bytesExactFormat: bytesExactFormat,
            bytesOnlyFormat: bytesOnlyFormat,
            stopAction: stopAction,
            skipAction: skipAction,
            replaceAction: replaceAction,
            keepBothAction: keepBothAction,
            applyToAllTitle: applyToAllTitle,
            applyToAllAccessibilityHint: applyToAllAccessibilityHint,
            dialogAccessibilityLabel: dialogAccessibilityLabel,
            headerSummaryVoiceOverFormat: headerSummaryVoiceOverFormat,
            headerTypeMismatchClause: headerTypeMismatchClause,
            typeMismatchAccessibilityLabel: typeMismatchAccessibilityLabel,
            cardAccessibilityFormat: cardAccessibilityFormat
        )
    }
}

// MARK: - Built-in Language Presets & Resolution

extension ForensicCollisionLocalization {
    public static let `default`: ForensicCollisionLocalization = .english

    public static let english = ForensicCollisionLocalization(
        localeIdentifier: "en",
        byteCountStyle: .file,
        panelTitle: "File Collision Resolution",
        conflictProgressFormat: "Conflict %1$@ of %2$@ — \"%3$@\"",
        sameTypeTitle: "Same Type",
        typeMismatchBadge: "Type Mismatch",
        typeMismatchHelp: "The incoming item and existing item have different types (file vs. folder)",
        incomingCardTitle: "Incoming Item (From Archive)",
        existingCardTitle: "Existing Item (At Destination)",
        newerBadge: "Newer",
        largerBadge: "Larger",
        mismatchBadge: "Mismatch",
        directoryBadge: "Folder",
        fileBadge: "File",
        pathLabel: "Path",
        sizeLabel: "Size",
        modifiedLabel: "Modified",
        typeLabel: "Type",
        directoryTypeValue: "Folder",
        fileTypeValue: "File",
        unavailableValue: "Unavailable",
        bytesExactFormat: "%1$@ (%2$@ B)",
        bytesOnlyFormat: "%1$@ B",
        stopAction: ForensicCollisionActionCopy(
            title: "Stop",
            subtitle: "Stop remaining extraction",
            accessibilityHint: "Stop remaining conflict and extraction processing. Press Escape."
        ),
        skipAction: ForensicCollisionActionCopy(
            title: "Skip",
            subtitle: "Keep existing item unchanged",
            accessibilityHint: "Preserve existing item at destination and skip incoming item."
        ),
        replaceAction: ForensicCollisionActionCopy(
            title: "Replace",
            subtitle: "Overwrite with incoming item",
            accessibilityHint: "Overwrite existing item at destination with incoming item."
        ),
        keepBothAction: ForensicCollisionActionCopy(
            title: "Keep Both",
            subtitle: "Rename incoming to keep both",
            accessibilityHint: "Save incoming item with a numbered name alongside existing item. Default action, press Return."
        ),
        applyToAllTitle: "Apply this resolution to all remaining conflicts",
        applyToAllAccessibilityHint: "Applies the selected action to all remaining conflicts in this extraction.",
        dialogAccessibilityLabel: "File collision resolution dialog",
        headerSummaryVoiceOverFormat: "File collision resolution. Conflict %1$@ of %2$@. Item name: %3$@%4$@. Incoming item path: %5$@, size: %6$@, modified: %7$@. Existing item path: %8$@, size: %9$@, modified: %10$@.",
        headerTypeMismatchClause: ", type mismatch between incoming and existing items",
        typeMismatchAccessibilityLabel: "Type mismatch between incoming item and existing item",
        cardAccessibilityFormat: "%1$@: %2$@, type: %3$@, path: %4$@, size: %5$@, modified: %6$@%7$@"
    )

    public static let simplifiedChinese = ForensicCollisionLocalization(
        localeIdentifier: "zh-Hans",
        byteCountStyle: .file,
        panelTitle: "发现同名项目冲突",
        conflictProgressFormat: "第 %1$@ 项，共 %2$@ 项冲突 — “%3$@”",
        sameTypeTitle: "相同类型",
        typeMismatchBadge: "类型不同",
        typeMismatchHelp: "待解压项目与目标已有项目类型不同（例如一方为文件，另一方为文件夹）",
        incomingCardTitle: "待解压项目（来自归档）",
        existingCardTitle: "目标已有项目（当前位置）",
        newerBadge: "时间较新",
        largerBadge: "体积较大",
        mismatchBadge: "类型冲突",
        directoryBadge: "文件夹",
        fileBadge: "文件",
        pathLabel: "路径",
        sizeLabel: "大小",
        modifiedLabel: "修改时间",
        typeLabel: "类型",
        directoryTypeValue: "文件夹",
        fileTypeValue: "文件",
        unavailableValue: "未提供",
        bytesExactFormat: "%1$@（%2$@ 字节）",
        bytesOnlyFormat: "%1$@ 字节",
        stopAction: ForensicCollisionActionCopy(
            title: "停止",
            subtitle: "停止后续解压处理",
            accessibilityHint: "停止后续冲突与解压处理。快捷键 Escape"
        ),
        skipAction: ForensicCollisionActionCopy(
            title: "跳过",
            subtitle: "保留目标已有项目",
            accessibilityHint: "跳过当前待解压项目，保留目标位置已有项目不变"
        ),
        replaceAction: ForensicCollisionActionCopy(
            title: "替换",
            subtitle: "用待解压项目覆盖",
            accessibilityHint: "用待解压项目覆盖目标位置的已有项目"
        ),
        keepBothAction: ForensicCollisionActionCopy(
            title: "保留两者",
            subtitle: "待解压项目重命名共存",
            accessibilityHint: "保留目标已有项目，将待解压项目自动重命名后一并保存。默认操作，快捷键 Return"
        ),
        applyToAllTitle: "对其余冲突使用相同操作",
        applyToAllAccessibilityHint: "勾选后，所选操作将应用于本次解压其余全部同名冲突",
        dialogAccessibilityLabel: "同名文件冲突处理对话框",
        headerSummaryVoiceOverFormat: "发现同名项目冲突，第 %1$@ 项，共 %2$@ 项。项目名称：%3$@%4$@。待解压项目路径：%5$@，大小：%6$@，修改时间：%7$@。目标已有项目路径：%8$@，大小：%9$@，修改时间：%10$@。",
        headerTypeMismatchClause: "，待解压项目与目标已有项目类型不同",
        typeMismatchAccessibilityLabel: "待解压项目与目标已有项目类型不同",
        cardAccessibilityFormat: "%1$@：%2$@，类型：%3$@，路径：%4$@，大小：%5$@，修改时间：%6$@%7$@"
    )

    public static let traditionalChinese = ForensicCollisionLocalization(
        localeIdentifier: "zh-Hant",
        byteCountStyle: .file,
        panelTitle: "發現同名項目衝突",
        conflictProgressFormat: "第 %1$@ 項，共 %2$@ 項衝突 — 「%3$@」",
        sameTypeTitle: "相同類型",
        typeMismatchBadge: "類型不同",
        typeMismatchHelp: "待解壓項目與目標已有項目類型不同（例如一方為檔案，另一方為資料夾）",
        incomingCardTitle: "待解壓項目（來自歸檔）",
        existingCardTitle: "目標已有項目（目前位置）",
        newerBadge: "時間較新",
        largerBadge: "體積較大",
        mismatchBadge: "類型衝突",
        directoryBadge: "資料夾",
        fileBadge: "檔案",
        pathLabel: "路徑",
        sizeLabel: "大小",
        modifiedLabel: "修改時間",
        typeLabel: "類型",
        directoryTypeValue: "資料夾",
        fileTypeValue: "檔案",
        unavailableValue: "未提供",
        bytesExactFormat: "%1$@（%2$@ 位元組）",
        bytesOnlyFormat: "%1$@ 位元組",
        stopAction: ForensicCollisionActionCopy(
            title: "停止",
            subtitle: "停止後續解壓處理",
            accessibilityHint: "停止後續衝突與解壓處理。快速鍵 Escape"
        ),
        skipAction: ForensicCollisionActionCopy(
            title: "略過",
            subtitle: "保留目標已有項目",
            accessibilityHint: "略過目前待解壓項目，保留目標位置已有項目不變"
        ),
        replaceAction: ForensicCollisionActionCopy(
            title: "取代",
            subtitle: "以待解壓項目覆蓋",
            accessibilityHint: "以待解壓項目覆蓋目標位置的已有項目"
        ),
        keepBothAction: ForensicCollisionActionCopy(
            title: "保留兩者",
            subtitle: "待解壓項目重新命名共存",
            accessibilityHint: "保留目標已有項目，將待解壓項目自動重新命名後一併儲存。預設操作，快速鍵 Return"
        ),
        applyToAllTitle: "對其餘衝突使用相同操作",
        applyToAllAccessibilityHint: "勾選後，所選操作將套用於本次解壓其餘全部同名衝突",
        dialogAccessibilityLabel: "同名項目衝突處理對話框",
        headerSummaryVoiceOverFormat: "發現同名項目衝突，第 %1$@ 項，共 %2$@ 項。項目名稱：%3$@%4$@。待解壓項目路徑：%5$@，大小：%6$@，修改時間：%7$@。目標已有項目路徑：%8$@，大小：%9$@，修改時間：%10$@。",
        headerTypeMismatchClause: "，待解壓項目與目標已有項目類型不同",
        typeMismatchAccessibilityLabel: "待解壓項目與目標已有項目類型不同",
        cardAccessibilityFormat: "%1$@：%2$@，類型：%3$@，路徑：%4$@，大小：%5$@，修改時間：%6$@%7$@"
    )

    public static func resolved(
        for locale: Locale,
        byteCountStyle: ForensicCollisionByteCountStyle = .file
    ) -> ForensicCollisionLocalization {
        resolved(forLanguageIdentifier: locale.identifier, byteCountStyle: byteCountStyle)
    }

    public static func resolved(
        forLanguageIdentifier identifier: String,
        byteCountStyle: ForensicCollisionByteCountStyle = .file
    ) -> ForensicCollisionLocalization {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        let lower = normalized.lowercased()

        if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") {
            return simplifiedOrTraditional(isTraditional: true, localeIdentifier: "zh-Hant", byteCountStyle: byteCountStyle)
        }
        if lower.hasPrefix("zh") {
            return simplifiedOrTraditional(isTraditional: false, localeIdentifier: "zh-Hans", byteCountStyle: byteCountStyle)
        }
        let targetLocaleID = normalized.isEmpty ? "en" : normalized
        return english.withLocale(identifier: targetLocaleID, byteCountStyle: byteCountStyle)
    }

    private static func simplifiedOrTraditional(
        isTraditional: Bool,
        localeIdentifier: String,
        byteCountStyle: ForensicCollisionByteCountStyle
    ) -> ForensicCollisionLocalization {
        let base = isTraditional ? traditionalChinese : simplifiedChinese
        return base.withLocale(identifier: localeIdentifier, byteCountStyle: byteCountStyle)
    }
}

// MARK: - Formatting & Domain Helpers

extension ForensicCollisionLocalization {
    public func copy(for action: ConflictResolutionAction) -> ForensicCollisionActionCopy {
        switch action {
        case .stop:
            return stopAction
        case .skip:
            return skipAction
        case .replace:
            return replaceAction
        case .keepBoth:
            return keepBothAction
        }
    }

    public func title(for kind: ConflictKindDisplay) -> String {
        switch kind {
        case .sameType:
            return sameTypeTitle
        case .typeMismatch:
            return typeMismatchBadge
        }
    }

    public func formatNumber(_ value: Int) -> String {
        formatNumber(Int64(value))
    }

    public func formatNumber(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public func formatConflictProgress(index: Int, total: Int, fileName: String) -> String {
        let safeIndex = max(1, index)
        let safeTotal = max(safeIndex, max(1, total))
        let indexStr = formatNumber(safeIndex)
        let totalStr = formatNumber(safeTotal)
        return String(format: conflictProgressFormat, locale: locale, indexStr, totalStr, fileName)
    }

    public func isSizeValid(for descriptor: ConflictFileDescriptor) -> Bool {
        descriptor.hasValidByteSize && descriptor.byteSize >= 0
    }

    public func isTimestampValid(for descriptor: ConflictFileDescriptor) -> Bool {
        guard descriptor.hasValidModificationDate else { return false }
        let seconds = descriptor.modificationDate.timeIntervalSince1970
        guard seconds.isFinite, seconds > 0 else { return false }
        return descriptor.modificationDate != .distantPast && descriptor.modificationDate != .distantFuture
    }

    public func formatTypeValue(for descriptor: ConflictFileDescriptor) -> String {
        descriptor.isDirectory ? directoryTypeValue : fileTypeValue
    }

    public func formatSize(for descriptor: ConflictFileDescriptor) -> String {
        if descriptor.isDirectory {
            return directoryTypeValue
        }
        guard isSizeValid(for: descriptor) else {
            return unavailableValue
        }
        let exactBytes = formatNumber(descriptor.byteSize)
        let threshold: Int64 = byteCountStyle == .binary ? 1024 : 1000
        if descriptor.byteSize < threshold {
            return String(format: bytesOnlyFormat, locale: locale, exactBytes)
        }
        let readable = formatHumanReadableByteCount(descriptor.byteSize)
        return String(format: bytesExactFormat, locale: locale, readable, exactBytes)
    }

    private func formatHumanReadableByteCount(_ bytes: Int64) -> String {
        let base: Double = byteCountStyle == .binary ? 1024.0 : 1000.0
        let units = byteCountStyle == .binary
            ? ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
            : ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= base && unitIndex < units.count - 1 {
            value /= base
            unitIndex += 1
        }
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.locale = locale
        numberFormatter.minimumFractionDigits = unitIndex == 0 ? 0 : 1
        numberFormatter.maximumFractionDigits = unitIndex == 0 ? 0 : 2
        let formattedValue = numberFormatter.string(from: NSNumber(value: value))
            ?? String(format: "%.1f", value)
        return "\(formattedValue) \(units[unitIndex])"
    }

    public func formatTimestamp(
        for descriptor: ConflictFileDescriptor,
        timeZone: TimeZone = .current
    ) -> String {
        guard isTimestampValid(for: descriptor) else {
            return unavailableValue
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: descriptor.modificationDate)
    }

    public func fileRowHelpText(for descriptor: ConflictFileDescriptor) -> String {
        descriptor.fileName
    }

    public func pathRowHelpText(for descriptor: ConflictFileDescriptor) -> String {
        if descriptor.filePath.isEmpty || descriptor.filePath == descriptor.relativePath {
            return descriptor.relativePath
        }
        return "\(descriptor.relativePath)\n\(descriptor.filePath)"
    }

    public func formatHeaderVoiceOver(
        sourceFile: ConflictFileDescriptor,
        targetFile: ConflictFileDescriptor,
        conflictIndex: Int,
        totalConflicts: Int,
        isTypeMismatch: Bool,
        timeZone: TimeZone = .current
    ) -> String {
        let safeIndex = max(1, conflictIndex)
        let safeTotal = max(safeIndex, max(1, totalConflicts))
        let mismatchText = isTypeMismatch ? headerTypeMismatchClause : ""
        return String(
            format: headerSummaryVoiceOverFormat,
            locale: locale,
            formatNumber(safeIndex),
            formatNumber(safeTotal),
            sourceFile.fileName,
            mismatchText,
            sourceFile.relativePath,
            formatSize(for: sourceFile),
            formatTimestamp(for: sourceFile, timeZone: timeZone),
            targetFile.relativePath,
            formatSize(for: targetFile),
            formatTimestamp(for: targetFile, timeZone: timeZone)
        )
    }

    public func formatCardVoiceOver(
        title: String,
        descriptor: ConflictFileDescriptor,
        isNewer: Bool,
        isLarger: Bool,
        isTypeMismatch: Bool,
        timeZone: TimeZone = .current
    ) -> String {
        var tags: [String] = []
        if isNewer {
            tags.append(newerBadge)
        }
        if isLarger {
            tags.append(largerBadge)
        }
        if isTypeMismatch {
            tags.append(mismatchBadge)
        }
        let suffix = tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))"
        return String(
            format: cardAccessibilityFormat,
            locale: locale,
            title,
            descriptor.fileName,
            formatTypeValue(for: descriptor),
            descriptor.relativePath,
            formatSize(for: descriptor),
            formatTimestamp(for: descriptor, timeZone: timeZone),
            suffix
        )
    }
}

// MARK: - SwiftUI Environment Support

private struct ForensicCollisionLocalizationKey: EnvironmentKey {
    static let defaultValue: ForensicCollisionLocalization? = nil
}

public extension EnvironmentValues {
    var forensicCollisionLocalization: ForensicCollisionLocalization? {
        get { self[ForensicCollisionLocalizationKey.self] }
        set { self[ForensicCollisionLocalizationKey.self] = newValue }
    }
}
