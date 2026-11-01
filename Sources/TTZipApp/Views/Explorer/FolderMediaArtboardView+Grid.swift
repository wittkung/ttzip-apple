// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
import Darwin

extension FolderMediaArtboardView {
    package var itemsSummaryText: String {
        if isCalculating {
            return l10n.t(L10n.Common.calculating)
        }
        guard analysisCoordinator.hasAnalyzedStats else {
            return "--"
        }
        return l10n.formatFilesAndDirectories(files: fileCount, directories: subfolderCount)
    }

    @ViewBuilder
    var overviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.t(L10n.Inspector.overviewFs))
                .font(.system(size: 9, weight: .bold, design: .serif))
                .tracking(2)
                .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)
            
            let fsName = analysisCoordinator.lightweightMetadata.fileSystemName
            let fsTooltip = fsName == "APFS" ? l10n.t(L10n.Inspector.appleFileSystemApfs) : fsName
            let ownerLabel = l10n.t(L10n.Inspector.owner)
            let permsValue = analysisCoordinator.lightweightMetadata.posixPermissions
            let permTooltip = permsValue == "0755" ? "0755 (drwxr-xr-x)" : permsValue
            
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                detailGridRow(label: l10n.t(L10n.Inspector.size), value: formattedFolderSize, isHighlight: true)
                detailGridRow(label: l10n.t(L10n.Inspector.items), value: itemsSummaryText)
                detailGridRow(label: l10n.t(L10n.Inspector.modified), value: formattedDate)
                detailGridRow(label: l10n.t(L10n.Inspector.fileSystem), value: fsName, tooltip: fsTooltip)
                detailGridRow(label: l10n.t(L10n.Inspector.permissions), value: permsValue, tooltip: permTooltip)
                detailGridRow(label: ownerLabel, value: ownerNameString, tooltip: ownerGroupTooltipString)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    @ViewBuilder
    var contentBreakdownSection: some View {
        Divider()
        switch analysisCoordinator.phase {
        case .idleSummary:
            idleSummaryPromptSection
        case .analyzing:
            analyzingBreakdownSection
        case .failed(let message):
            failedBreakdownSection(message: message)
        case .completed:
            completedBreakdownSection
        }
    }

    /// Header row of the content breakdown section.
    /// - Parameter showsMetricToggle: reveals the metric scope toggle (only meaningful once statistics exist).
    private func breakdownHeaderRow(showsMetricToggle: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(l10n.t(L10n.Inspector.contentBreakdown))
                .font(.system(size: 9, weight: .bold, design: .serif))
                .tracking(2)
                .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)

            Spacer(minLength: 4)

            if showsMetricToggle {
                metricScopeToggleButton
            }

            breakdownActionControl
        }
    }

    @ViewBuilder
    private var breakdownActionControl: some View {
        if isCalculating {
            Button {
                analysisCoordinator.cancelAnalysis()
            } label: {
                Text(l10n.t(L10n.Common.cancel))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("FolderCancelAnalysisButton")
        } else if analysisCoordinator.hasAnalyzedStats && analysisCoordinator.canAnalyzeSelectedTarget {
            Button {
                analysisCoordinator.startAnalysis()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("FolderReanalyzeButton")
            .accessibilityLabel(l10n.uiString(zh: "重新分析文件夹", en: "Re-analyze Folder"))
        }
    }

    /// Single-icon switch between the two statistic scopes (file size / item count).
    /// The symbol always depicts the currently active scope; clicking flips to the other one.
    /// VoiceOver reads the scope name from the label, the selected state from the value,
    /// and the destination scope from the hint.
    private var metricScopeToggleButton: some View {
        Button {
            withAnimation(.ttMicro) {
                distributionMetric = distributionMetric == .size ? .count : .size
            }
        } label: {
            Image(systemName: metricScopeSymbolName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(metricScopeToggleTooltip)
        .accessibilityLabel(metricScopeToggleAccessibilityLabel)
        .accessibilityValue(l10n.uiString(zh: "已选择", en: "Selected"))
        .accessibilityAddTraits(.isSelected)
        .accessibilityHint(metricScopeToggleAccessibilityHint)
        .accessibilityIdentifier("FolderDistributionMetricToggleButton")
    }

    private var metricScopeSymbolName: String {
        distributionMetric == .size ? "chart.bar.fill" : "square.grid.2x2.fill"
    }

    private var metricScopeToggleTooltip: String {
        switch distributionMetric {
        case .size:
            return l10n.uiString(
                zh: "统计口径：按文件大小 · 点击切换为按项数",
                en: "Metric: File Size · Click to switch to Item Count"
            )
        case .count:
            return l10n.uiString(
                zh: "统计口径：按项数 · 点击切换为按文件大小",
                en: "Metric: Item Count · Click to switch to File Size"
            )
        }
    }

    /// VoiceOver label: names the control and states the active scope, without the action clause.
    private var metricScopeToggleAccessibilityLabel: String {
        switch distributionMetric {
        case .size:
            return l10n.uiString(zh: "统计口径：按文件大小", en: "Metric: File Size")
        case .count:
            return l10n.uiString(zh: "统计口径：按项数", en: "Metric: Item Count")
        }
    }

    /// VoiceOver hint: states the scope the control switches to when activated.
    private var metricScopeToggleAccessibilityHint: String {
        switch distributionMetric {
        case .size:
            return l10n.uiString(zh: "切换为按项数", en: "Switches to Item Count")
        case .count:
            return l10n.uiString(zh: "切换为按文件大小", en: "Switches to File Size")
        }
    }

    @ViewBuilder
    private var idleSummaryPromptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            breakdownHeaderRow()

            if analysisCoordinator.canAnalyzeSelectedTarget {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        l10n.uiString(
                            zh: "分析已暂停。可以继续在后台统计文件夹内容。",
                            en: "Analysis paused. Resume background folder analysis."
                        )
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    FolderExplicitAnalyzeActionButton(
                        id: "FolderResumeAnalysisButton",
                        title: l10n.uiString(zh: "继续分析", en: "Resume Analysis"),
                        symbolName: "chart.pie.fill",
                        isProminent: false,
                        onTrigger: {
                            analysisCoordinator.startAnalysis()
                        }
                    )
                    .frame(maxWidth: .infinity, minHeight: 28, idealHeight: 28)
                    .accessibilityIdentifier("FolderResumeAnalysisButton")
                    .accessibilityLabel(l10n.uiString(zh: "继续分析", en: "Resume Analysis"))
                }
                .padding(12)
                .background(Color.primary.opacity(0.015))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(TTZipTheme.hairlineBorder, lineWidth: 0.5)
                )
            } else {
                Text(
                    l10n.uiString(
                        zh: "当前条目为虚拟或远端目录，不支持本机目录递归统计。",
                        en: "Virtual or remote folder identity is not eligible for local directory recursive analysis."
                    )
                )
                .font(.system(size: 10.5))
                .foregroundStyle(Color.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.015))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(TTZipTheme.hairlineBorder, lineWidth: 0.5)
                )
                .accessibilityIdentifier("FolderNonLocalSummaryNotice")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var analyzingBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            breakdownHeaderRow()

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.04),
                            Color.primary.opacity(0.08),
                            Color.primary.opacity(0.04)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 9)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func failedBreakdownSection(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            breakdownHeaderRow()

            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if analysisCoordinator.canAnalyzeSelectedTarget {
                    FolderExplicitAnalyzeActionButton(
                        id: "FolderRetryAnalyzeButton",
                        title: l10n.uiString(zh: "重试分析", en: "Retry Analysis"),
                        symbolName: "arrow.clockwise",
                        isProminent: false,
                        onTrigger: {
                            analysisCoordinator.startAnalysis()
                        }
                    )
                    .frame(minHeight: 26, idealHeight: 26)
                    .accessibilityIdentifier("FolderRetryAnalyzeButton")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.015))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(TTZipTheme.hairlineBorder, lineWidth: 0.5)
            )
            .accessibilityIdentifier("FolderAnalysisErrorCard")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var completedBreakdownSection: some View {
        if !fileTypeDistribution.isEmpty {
            let total = distributionMetric.total(sortedDistribution)
            let colors = resolvedCategoryColors
            VStack(alignment: .leading, spacing: 12) {
                breakdownHeaderRow(showsMetricToggle: true)

                if total > 0 {
                    GeometryReader { barGeo in
                        HStack(spacing: 0) {
                            ForEach(Array(sortedDistribution.enumerated()), id: \.element.category) { idx, item in
                                Rectangle()
                                    .fill(colors[idx])
                                    .frame(width: barGeo.size.width * CGFloat(distributionMetric.share(of: item, total: total) ?? 0))
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 9)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                }

                if distributionMetric == .size && fileTypeDistribution.contains(where: { $0.sizeBytes == nil }) {
                    Text(l10n.uiString(zh: "部分文件大小未知；百分比仅按大小完整的类型计算", en: "Some sizes are unknown; percentages use only complete categories"))
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
                if total == 0 {
                    Text(l10n.uiString(zh: "没有可计算的大小占比", en: "No size share available"))
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
                
                ViewThatFits(in: .horizontal) {
                    contentBreakdownRows(total: total, colors: colors, isCompact: false)
                    contentBreakdownRows(total: total, colors: colors, isCompact: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if fileCount == 0 && subfolderCount == 0 {
            VStack(alignment: .leading, spacing: 10) {
                breakdownHeaderRow()

                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .light))
                            .foregroundStyle(TTZipTheme.kintsugiGold.opacity(0.6))
                        Text(l10n.t(L10n.Inspector.emptyDirectory))
                            .font(.system(size: 11, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.primary.opacity(0.75))
                    }
                    
                    Text(l10n.t(L10n.Inspector.emptyDirectoryDesc))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
                .background(Color.primary.opacity(0.015))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(TTZipTheme.hairlineBorder, lineWidth: 0.5)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    @ViewBuilder
    private func contentBreakdownRows(total: Double, colors: [Color], isCompact: Bool) -> some View {
        VStack(spacing: isCompact ? 6 : 7) {
            ForEach(Array(sortedDistribution.enumerated()), id: \.element.category) { idx, item in
                let itemColor = colors[idx]
                let pct = distributionPercent(share: distributionMetric.share(of: item, total: total))
                HStack(spacing: isCompact ? 5 : 8) {
                    HStack(spacing: isCompact ? 5 : 6) {
                        Circle()
                            .fill(itemColor)
                            .frame(width: isCompact ? 7 : 7.5, height: isCompact ? 7 : 7.5)
                            .shadow(color: itemColor.opacity(0.4), radius: 2, x: 0, y: 1)
                        
                        Text(item.category)
                            .font(.system(size: isCompact ? 10.5 : 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    
                    Spacer(minLength: 4)
                    
                    Text(distributionMetric == .count
                         ? l10n.plural(key: L10n.Units.itemsCount, count: item.count)
                         : item.sizeBytes.map { ByteCountFormatterFlyweight.shared.string(fromByteCount: $0) } ?? "—")
                        .font(.system(size: isCompact ? 10.5 : 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: isCompact ? 68 : 86, alignment: .trailing)
                    
                    Text(pct)
                        .font(.system(size: isCompact ? 9.5 : 10, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                        .padding(.horizontal, isCompact ? 4.5 : 6)
                        .padding(.vertical, isCompact ? 1.5 : 2)
                        .background(TTZipTheme.kintsugiGold.opacity(0.12))
                        .clipShape(Capsule())
                        .frame(width: isCompact ? 35 : 42, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func distributionPercent(share: Double?) -> String {
        guard let share else { return "—" }
        let roundedPercent = Int((share * 100).rounded())
        return String(roundedPercent) + "%"
    }
    
    @ViewBuilder
    func detailGridRow(label: String, value: String, isHighlight: Bool = false, tooltip: String? = nil) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(alignment: .leading)
                .gridColumnAlignment(.leading)
            
            Text(value)
                .font(.system(size: isHighlight ? 12 : 11, weight: isHighlight ? .semibold : .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                .gridColumnAlignment(.trailing)
                .help(tooltip ?? value)
        }
    }
    
    private var ownerNameString: String {
        analysisCoordinator.lightweightMetadata.ownerName
    }
    
    private var ownerGroupTooltipString: String {
        let meta = analysisCoordinator.lightweightMetadata
        guard meta.ownerName != "--" else {
            return "--"
        }
        return l10n.format(L10n.Inspector.ownerGroupFormat, meta.ownerName, meta.groupName)
    }
    
    private static let categoryOpacityLadder: [Double] = [1.0, 0.72, 0.50]

    var resolvedCategoryColors: [Color] {
        return sortedDistribution.map { entry in
            let bucket = categoryColorBucket(entry.category)
            let hash = entry.category.utf8.reduce(UInt64(14695981039346656037)) {
                ($0 ^ UInt64($1)) &* 1099511628211
            }
            let stepOpacity = Self.categoryOpacityLadder[Int(hash % UInt64(Self.categoryOpacityLadder.count))]
            return baseCategoryColor(forBucket: bucket).opacity(stepOpacity)
        }
    }

    func categoryColorBucket(_ cat: String) -> Int {
        switch cat {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "svg", "bmp", "raw", "psd", "ai", "image", "图片":
            return 0
        case "pdf", "txt", "doc", "docx", "pages", "rtf", "md", "markdown", "swift", "rs", "c", "cpp", "h", "py", "js", "ts", "json", "yaml", "yml", "toml", "xml", "html", "css", "sh", "document", "code", "文档", "代码":
            return 1
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "video", "视频":
            return 2
        case "mp3", "m4a", "aac", "wav", "flac", "alac", "ogg", "opus", "audio", "音频":
            return 3
        case "zip", "7z", "tar", "gz", "bz2", "xz", "zst", "rar", "dmg", "iso", "pkg", "deb", "rpm", "ttzip", "archive", "压缩包", "归档包":
            return 4
        default:
            let hash = cat.utf8.reduce(UInt64(14695981039346656037)) {
                ($0 ^ UInt64($1)) &* 1099511628211
            }
            return Int(hash % 5)
        }
    }

    func baseCategoryColor(forBucket bucket: Int) -> Color {
        switch bucket {
        case 0: return TTZipUniversalTokens.Mineral.gold
        case 1: return TTZipUniversalTokens.Mineral.bamboo
        case 2: return TTZipUniversalTokens.Mineral.cinnabar
        case 3: return TTZipUniversalTokens.Mineral.amethyst
        default: return TTZipUniversalTokens.Mineral.amber
        }
    }
    
    func createNewFolder() {
        let parentPath = resolvedPhysicalPath
        let inputName = newSubfolderName
        newSubfolderName = "Untitled Folder"
        
        Task.detached(priority: .userInitiated) {
            let parentDir = URL(fileURLWithPath: parentPath, isDirectory: true)
            let trimmed = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = trimmed.isEmpty ? "Untitled Folder" : trimmed
            var targetURL = parentDir.appendingPathComponent(baseName)
            var counter = 2
            let fm = FileManager.default
            while fm.fileExists(atPath: targetURL.path) {
                targetURL = parentDir.appendingPathComponent("\(baseName) \(counter)")
                counter += 1
            }
            do {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
                await MainActor.run {
                    NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
                }
            } catch {
                TTLogger.shared.log(
                    level: .error,
                    category: .general,
                    message: "[FolderMediaArtboardView] Failed to create directory at \(targetURL.path): \(error)"
                )
            }
        }
    }
    
    func createNewFile() {
        let parentPath = resolvedPhysicalPath
        let inputName = newSubfileName
        newSubfileName = "Untitled.txt"
        
        Task.detached(priority: .userInitiated) {
            let parentDir = URL(fileURLWithPath: parentPath, isDirectory: true)
            let trimmed = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = trimmed.isEmpty ? "Untitled.txt" : trimmed
            let pathExtension = (baseName as NSString).pathExtension
            let nameWithoutExt = (baseName as NSString).deletingPathExtension
            var targetURL = parentDir.appendingPathComponent(baseName)
            var counter = 2
            let fm = FileManager.default
            while fm.fileExists(atPath: targetURL.path) {
                let nextName = pathExtension.isEmpty ? "\(baseName) \(counter)" : "\(nameWithoutExt) \(counter).\(pathExtension)"
                targetURL = parentDir.appendingPathComponent(nextName)
                counter += 1
            }
            let success = fm.createFile(atPath: targetURL.path, contents: Data(), attributes: nil)
            if success {
                await MainActor.run {
                    NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
                }
            } else {
                TTLogger.shared.log(
                    level: .error,
                    category: .general,
                    message: "[FolderMediaArtboardView] Failed to create file at \(targetURL.path)"
                )
            }
        }
    }
    
    package static func calculateFolderStats(
        at targetPath: String,
        maxDepth: Int = 16,
        cancellationBox: FolderScanCancellationBox? = nil
    ) async -> (totalSize: Int64, folderCount: Int, fileCount: Int, distribution: [(category: String, count: Int, sizeBytes: Int64?)]) {
        guard case .localDirectory(let validatedURL) = FolderSummaryAnalysisCoordinator.classifyPathIdentity(rawPath: targetPath) else {
            return (0, 0, 0, [])
        }
        if Task.isCancelled || cancellationBox?.isCancelled == true {
            return (0, 0, 0, [])
        }

        let detachedTask: Task<(Int64, Int, Int, [(category: String, count: Int, sizeBytes: Int64?)]), Never> = Task.detached(priority: .utility) {
            var folderCount = 0
            var accumulator = FolderDistributionAccumulator()
            
            let fm = FileManager.default
            let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
            
            if let enumerator = fm.enumerator(
                at: validatedURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if Task.isCancelled || cancellationBox?.isCancelled == true {
                        break
                    }
                    
                    let currentLevel = enumerator.level
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                        continue
                    }
                    
                    if resourceValues.isDirectory == true && resourceValues.isSymbolicLink != true {
                        folderCount += 1
                        if currentLevel >= maxDepth {
                            enumerator.skipDescendants()
                        }
                    } else {
                        if resourceValues.isSymbolicLink == true {
                            enumerator.skipDescendants()
                        }
                        accumulator.addFile(at: fileURL, values: resourceValues)
                    }
                }
            }

            return (accumulator.totalSize, folderCount, accumulator.fileCount, accumulator.entries)
        }

        cancellationBox?.registerOnCancel {
            detachedTask.cancel()
        }

        let result = await detachedTask.value
        return result
    }

    func calculateStats() async {
        await analysisCoordinator.requestAnalysis()
    }
}

private struct FolderDistributionAccumulator {
    private(set) var totalSize: Int64 = 0
    private(set) var fileCount = 0
    private var categories: [String: (count: Int, sizeBytes: Int64?)] = [:]

    mutating func addFile(at url: URL, values: URLResourceValues) {
        fileCount += 1
        let ext = url.pathExtension.lowercased()
        let category = ext.isEmpty ? "other" : ext
        var entry = categories[category] ?? (count: 0, sizeBytes: 0)
        entry.count += 1
        if values.isSymbolicLink == true {
            entry.sizeBytes = nil
        } else if let rawSize = values.fileSize, rawSize >= 0 {
            if let previous = entry.sizeBytes {
                let (sum, overflow) = previous.addingReportingOverflow(Int64(rawSize))
                entry.sizeBytes = overflow ? nil : sum
            }
            let (total, totalOverflow) = totalSize.addingReportingOverflow(Int64(rawSize))
            totalSize = totalOverflow ? Int64.max : total
        } else {
            entry.sizeBytes = nil
        }
        categories[category] = entry
    }

    var entries: [(category: String, count: Int, sizeBytes: Int64?)] {
        var result: [(category: String, count: Int, sizeBytes: Int64?)] = []
        result.reserveCapacity(categories.count)
        for (category, entry) in categories {
            result.append((category: category, count: entry.count, sizeBytes: entry.sizeBytes))
        }
        result.sort { lhs, rhs in
            if lhs.count == rhs.count { return lhs.category < rhs.category }
            return lhs.count > rhs.count
        }
        return result
    }
}

struct FolderExplicitAnalyzeActionButton: NSViewRepresentable {
    let id: String
    let title: String
    let symbolName: String
    let isProminent: Bool
    let onTrigger: @MainActor () -> Void

    final class Coordinator: NSObject {
        var onTrigger: @MainActor () -> Void

        init(onTrigger: @escaping @MainActor () -> Void) {
            self.onTrigger = onTrigger
        }

        @MainActor
        @objc func handleClick(_ sender: NSButton) {
            onTrigger()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTrigger: onTrigger)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.target = context.coordinator
        button.action = #selector(Coordinator.handleClick(_:))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.isBordered = true
        button.isTransparent = false
        button.isHidden = false
        button.isEnabled = true
        button.setButtonType(.momentaryPushIn)
        configureAppearance(of: button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.onTrigger = onTrigger
        configureAppearance(of: nsView)
    }

    private func configureAppearance(of button: NSButton) {
        button.title = title
        button.font = .systemFont(ofSize: 11.5, weight: .semibold)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            button.image = image.withSymbolConfiguration(config)
            button.imagePosition = .imageLeading
        }
        if isProminent {
            button.bezelColor = NSColor(srgbRed: 0.42, green: 0.56, blue: 0.35, alpha: 1.0)
        }
        button.setAccessibilityIdentifier(id)
        button.setAccessibilityLabel(title)
        button.toolTip = title
    }
}
