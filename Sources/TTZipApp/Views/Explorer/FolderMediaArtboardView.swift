// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

package enum FolderDistributionMetric: String, CaseIterable {
    case size
    case count

    package func value(for entry: FolderDistributionEntry) -> Int64? {
        self == .count ? Int64(entry.count) : entry.sizeBytes
    }

    package func sorted(_ entries: [FolderDistributionEntry]) -> [FolderDistributionEntry] {
        entries.sorted { lhs, rhs in
            let lhsValue = value(for: lhs) ?? -1
            let rhsValue = value(for: rhs) ?? -1
            return lhsValue == rhsValue ? lhs.category < rhs.category : lhsValue > rhsValue
        }
    }

    package func total(_ entries: [FolderDistributionEntry]) -> Double {
        entries.reduce(0.0) { partial, entry in
            partial + Double(value(for: entry) ?? 0)
        }
    }

    package func share(of entry: FolderDistributionEntry, total: Double) -> Double? {
        guard let value = value(for: entry), total > 0 else { return nil }
        return Double(value) / total
    }
}

public struct FolderMediaArtboardView: View {
    public let item: DiskItemInfo
    public let onCompressPath: (String) -> Void
    public let onSelectArchive: ((String) -> Void)?
    var l10n = AppLocalizationState.shared
    
    @State package var analysisCoordinator: FolderSummaryAnalysisCoordinator
    @State var showCreateSubfolderAlert: Bool = false
    @State var newSubfolderName: String = "Untitled Folder"
    @State var showCreateFileAlert: Bool = false
    @State var newSubfileName: String = "Untitled.txt"
    @AppStorage("TTZip_FolderDistributionMetric") package var distributionMetric: FolderDistributionMetric = .count
    
    public init(
        item: DiskItemInfo,
        onCompressPath: @escaping (String) -> Void,
        onSelectArchive: ((String) -> Void)? = nil
    ) {
        self.item = item
        self.onCompressPath = onCompressPath
        self.onSelectArchive = onSelectArchive
        self._analysisCoordinator = State(initialValue: FolderSummaryAnalysisCoordinator(item: item))
    }

    package init(
        item: DiskItemInfo,
        coordinator: FolderSummaryAnalysisCoordinator,
        onCompressPath: @escaping (String) -> Void = { _ in },
        onSelectArchive: ((String) -> Void)? = nil
    ) {
        self.item = item
        self.onCompressPath = onCompressPath
        self.onSelectArchive = onSelectArchive
        self._analysisCoordinator = State(initialValue: coordinator)
    }

    package var totalSizeBytes: Int64 {
        analysisCoordinator.totalSizeBytes
    }

    package var subfolderCount: Int {
        analysisCoordinator.subfolderCount
    }

    package var fileCount: Int {
        analysisCoordinator.fileCount
    }

    package var isCalculating: Bool {
        analysisCoordinator.isCalculating
    }

    package var fileTypeDistribution: [FolderDistributionEntry] {
        analysisCoordinator.fileTypeDistribution
    }

    package var sortedDistribution: [FolderDistributionEntry] {
        distributionMetric.sorted(fileTypeDistribution)
    }
    
    package var formattedFolderSize: String {
        if isCalculating {
            return l10n.t(L10n.Common.calculating)
        }
        guard analysisCoordinator.hasAnalyzedStats else {
            return "--"
        }
        let formatted = ByteCountFormatterFlyweight.shared.string(fromByteCount: totalSizeBytes)
        var knownSum: Int64 = 0
        var isIncomplete = false
        for entry in fileTypeDistribution {
            guard let sizeBytes = entry.sizeBytes else {
                isIncomplete = true
                continue
            }
            let (sum, overflow) = knownSum.addingReportingOverflow(sizeBytes)
            if overflow {
                isIncomplete = true
            } else {
                knownSum = sum
            }
        }
        return isIncomplete ? "≥ " + formatted : formatted
    }
    
    package var formattedDate: String {
        guard let d = analysisCoordinator.lightweightMetadata.modificationDate ?? item.modificationDate else {
            return "--"
        }
        return DateFormatterCache.shared.string(fromShortDateTime: d)
    }
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                quickActionButtonsRow
                
                overviewSection
                
                contentBreakdownSection
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
        }
        .scrollContentBackground(.hidden)
        .background(ConfigureNSScrollView())
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .alert(l10n.t(L10n.Explorer.newFolder), isPresented: $showCreateSubfolderAlert) {
            TextField(l10n.t(L10n.Explorer.folderName), text: $newSubfolderName)
            Button(l10n.t(L10n.Common.cancel), role: .cancel) {
                newSubfolderName = "Untitled Folder"
            }
            Button(l10n.t(L10n.Explorer.create), action: createNewFolder)
        } message: {
            Text(l10n.format(L10n.Explorer.createFolderPrompt, resolvedPhysicalPath))
        }
        .alert(l10n.t(L10n.Explorer.newFile), isPresented: $showCreateFileAlert) {
            TextField(l10n.t(L10n.Explorer.fileName), text: $newSubfileName)
            Button(l10n.t(L10n.Common.cancel), role: .cancel) {
                newSubfileName = "Untitled.txt"
            }
            Button(l10n.t(L10n.Explorer.create), action: createNewFile)
        } message: {
            Text(l10n.format(L10n.Explorer.createFilePrompt, resolvedPhysicalPath))
        }
        .onChange(of: item.path, initial: true) { _, _ in
            analysisCoordinator.handleViewSelectionChange(item)
        }
        .onDisappear {
            analysisCoordinator.handleViewDisappear()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipArchiveUnlockedRefresh"))) { _ in
            analysisCoordinator.invalidateAfterDirectoryMutation()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipDirectoryRefreshNotification"))) { _ in
            analysisCoordinator.invalidateAfterDirectoryMutation()
        }
    }

    var resolvedPhysicalPath: String {
        if let localURL = analysisCoordinator.targetIdentity.localDirectoryURL {
            return localURL.path
        }
        let expanded = item.path.hasPrefix("~")
            ? (item.path as NSString).expandingTildeInPath
            : item.path
        return URL(fileURLWithPath: expanded).path
    }
    
    private var quickActionButtonsRow: some View {
        GeometryReader { btnGeo in
            let w = btnGeo.size.width
            let isCompact = w < 260
            HStack(spacing: isCompact ? 1 : 2) {
                QuickActionSegmentButton(
                    icon: "folder",
                    shortTitle: l10n.t(L10n.Common.revealShort),
                    fullTitle: l10n.t(L10n.Common.revealInFinder),
                    width: w,
                    help: l10n.t(L10n.Common.revealInFinder),
                    shortcut: nil,
                    action: {
                        NSWorkspace.shared.selectFile(resolvedPhysicalPath, inFileViewerRootedAtPath: "")
                    }
                )
                
                if item.isArchive {
                    QuickActionSegmentButton(
                        icon: "archivebox.and.arrow.trianglehead.down",
                        shortTitle: l10n.t(L10n.Extract.title),
                        fullTitle: l10n.t(L10n.Extract.title),
                        width: w,
                        help: l10n.t(L10n.Inspector.extractArchiveHelp),
                        shortcut: "⌘E",
                        action: {
                            onSelectArchive?(resolvedPhysicalPath)
                        }
                    )
                } else {
                    QuickActionSegmentButton(
                        icon: "folder.badge.plus",
                        shortTitle: l10n.t(L10n.Explorer.folderShort),
                        fullTitle: l10n.t(L10n.Explorer.newFolder),
                        width: w,
                        help: l10n.t(L10n.Explorer.newFolder),
                        shortcut: nil,
                        action: {
                            showCreateSubfolderAlert = true
                        }
                    )
                    
                    QuickActionSegmentButton(
                        icon: "doc.badge.plus",
                        shortTitle: l10n.t(L10n.Explorer.fileShort),
                        fullTitle: l10n.t(L10n.Explorer.newFile),
                        width: w,
                        help: l10n.t(L10n.Explorer.newFile),
                        shortcut: nil,
                        action: {
                            showCreateFileAlert = true
                        }
                    )
                    
                    QuickActionSegmentButton(
                        icon: "doc.zipper",
                        shortTitle: l10n.t(L10n.Compress.compressShort),
                        fullTitle: l10n.t(L10n.Compress.compressFolder),
                        width: w,
                        help: "\(l10n.t(L10n.Compress.compressFolder)) (⌘N)",
                        shortcut: "⌘N",
                        action: {
                            onCompressPath(resolvedPhysicalPath)
                        }
                    )
                }
                
                QuickActionSegmentButton(
                    icon: "doc.on.doc",
                    shortTitle: l10n.t(L10n.Common.copy),
                    fullTitle: l10n.t(L10n.Common.copyPath),
                    width: w,
                    help: l10n.t(L10n.Common.copyPath),
                    shortcut: nil,
                    action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(resolvedPhysicalPath, forType: .string)
                    }
                )
            }
            .padding(isCompact ? 1.5 : 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .clipped()
        .padding(.bottom, 8)
    }
}

// MARK: - Inset Segmented Quick Action Button

private struct QuickActionSegmentButton: View {
    let icon: String
    let shortTitle: String
    let fullTitle: String
    let width: CGFloat
    let help: String
    let shortcut: String?
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        let isCompact = width < 260
        Button(action: action) {
            HStack(spacing: width >= 320 ? 4 : 0) {
                Image(systemName: icon)
                    .font(.system(size: isCompact ? 10.5 : 11.5, weight: .semibold))
                    .foregroundStyle(isHovered ? TTZipTheme.bambooGreen : Color.secondary)
                
                if width >= 320 {
                    Text(shortTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .padding(.vertical, isCompact ? 3 : 4)
            .padding(.horizontal, isCompact ? 1.5 : 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isHovered ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
        .overlay(alignment: .top) {
            if isHovered {
                HStack(spacing: 4) {
                    Text(fullTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.primary)
                    
                    if let sc = shortcut {
                        Text(sc)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)
                .fixedSize()
                .offset(y: -28)
                .zIndex(999)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)),
                    removal: .opacity
                ))
                .allowsHitTesting(false)
            }
        }
        .help(help)
        .accessibilityLabel(fullTitle)
    }
}
