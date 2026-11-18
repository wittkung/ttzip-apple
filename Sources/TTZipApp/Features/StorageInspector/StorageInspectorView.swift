// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTKitDesign
import TTZipCore
import TTZipUI

// MARK: - Main Storage Inspector Workspace View

/// Dedicated workspace view displaying volume capacity metrics, interactive squarified treemap,
/// and forensic safe trash cleaning review panel.
public struct StorageInspectorView: View {
    public static let storageInspectorURL = URL(string: "ttzip://storage-inspector")!
    public static let storageInspectorId = "ttzip://storage-inspector"

    @State var viewModel: StorageInspectorViewModel
    @Binding public var isPresented: Bool
    public var onClose: (() -> Void)?
    var l10n: AppLocalizationState { AppLocalizationState.shared }

    @State var showConfirmTrashSelected: Bool = false
    @State var pendingSingleTrashItem: ReclaimableStorageItem? = nil

    public init(
        isPresented: Binding<Bool> = .constant(true),
        viewModel: StorageInspectorViewModel? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self._viewModel = State(initialValue: viewModel ?? StorageInspectorViewModel.shared)
        self.onClose = onClose
    }

    public func closeInspector() {
        viewModel.handleExplicitClose()
        isPresented = false
        onClose?()
    }

    private var confirmTargetItems: [ReclaimableStorageItem] {
        if let single = pendingSingleTrashItem {
            return [single]
        }
        return viewModel.selectedCandidates
    }

    public var body: some View {
        let lang = l10n.currentLanguage
        VStack(spacing: 0) {
            topNavigationBar(language: lang)

            Divider()

            volumeMetricsBanner(language: lang)

            if let summary = viewModel.lastScanSummary {
                partialOrTruncatedWarningStrip(summary: summary, language: lang)
            }

            Divider()

            HSplitView {
                // Left/Center: Treemap Viewport + Terminal State Overlay
                VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
                    treemapHeaderBar(language: lang)

                    ZStack {
                        TTZipTreemapCanvasView(
                            tiles: viewModel.tiles,
                            selectedTileId: viewModel.selectedTile?.id,
                            onSelectTile: { tile in
                                viewModel.selectedTile = tile
                            },
                            onDrillDown: { tile in
                                guard !tile.flags.contains(.tailCollapsed),
                                      !tile.relativePath.isEmpty else { return }
                                var isDir: ObjCBool = false
                                if FileManager.default.fileExists(atPath: tile.relativePath, isDirectory: &isDir),
                                   isDir.boolValue {
                                    viewModel.setDirectory(URL(fileURLWithPath: tile.relativePath))
                                }
                            }
                        )

                        treemapTerminalStateOverlay(language: lang)
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    .background(TTZipUniversalTokens.Plate.surfaceL2.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("StorageInspectorTreemapCanvas")
                }
                .padding(TTZipTheme.Spacing.sm)
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

                // Right: Reclaimable Review & Safe Trash Panel
                reclaimReviewPanel(language: lang)
                    .frame(minWidth: 290, maxWidth: 400, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("StorageInspectorReclaimPanel")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TTZipUniversalTokens.Plate.surfaceL1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("StorageInspectorContainer")
        .onAppear {
            if viewModel.state == .idle || (viewModel.state == .cancelled && viewModel.rootTiles.isEmpty) {
                viewModel.handleViewAppear()
            }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented {
                viewModel.handleExplicitClose()
            }
        }
        .alert(
            StorageLocaleKey.confirmCleanTitle.resolve(for: lang),
            isPresented: $showConfirmTrashSelected,
            actions: {
                Button(StorageLocaleKey.confirmMoveAction.resolve(for: lang), role: .destructive) {
                    if let single = pendingSingleTrashItem {
                        pendingSingleTrashItem = nil
                        viewModel.startCleanupItem(single, rescanAfter: true)
                    } else {
                        viewModel.startCleanupSelected(rescanAfter: true)
                    }
                }
                Button(l10n.t(L10n.Common.cancel), role: .cancel) {
                    pendingSingleTrashItem = nil
                }
            },
            message: {
                let targets = confirmTargetItems
                let deduplicated = StorageInspectorViewModel.deduplicateOverlappingAncestors(targets).kept
                let estBytes = deduplicated.reduce(0 as UInt64) { $0 &+ $1.sizeBytes }
                let formattedSize = l10n.formatBytes(Int64(estBytes))
                let pathPreview = deduplicated.prefix(5).map { "• \($0.path)" }.joined(separator: "\n")
                    + (deduplicated.count > 5 ? "\n… (+\(deduplicated.count - 5))\n\n" : "\n\n")
                Text(StorageLocaleKey.confirmCleanMessageFormat.format(
                    for: lang,
                    deduplicated.count,
                    formattedSize,
                    pathPreview
                ))
            }
        )
        .alert(StorageLocaleKey.securityGuardAlertTitle.resolve(for: lang), isPresented: Binding(
            get: { viewModel.statusAlertMessage != nil },
            set: { if !$0 { viewModel.statusAlertMessage = nil } }
        )) {
            Button(l10n.t(L10n.Common.ok), role: .cancel) {}
        } message: {
            Text(viewModel.statusAlertMessage ?? "")
        }
    }

    // MARK: - Top Navigation Bar

    @ViewBuilder
    private func topNavigationBar(language: AppLanguage) -> some View {
        HStack(spacing: TTZipTheme.Spacing.sm) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(TTZipTheme.bambooGreen)

            Text(StorageLocaleKey.headerTitle.resolve(for: language))
                .font(.system(size: 13, weight: .bold))

            if viewModel.canNavigateUp {
                Button(action: { viewModel.navigateToParentDirectory() }) {
                    Label(StorageLocaleKey.upDirectory.resolve(for: language), systemImage: "arrow.up.backward")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("StorageInspectorUpButton")
            }

            Spacer()

            directorySelectionMenu(language: language)

            if viewModel.isCleaning {
                Button(l10n.t(L10n.Common.cancel)) {
                    viewModel.cancelCleanup()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("StorageInspectorScanActionButton")
            } else if case .scanning = viewModel.state {
                Button(l10n.t(L10n.Common.cancel)) {
                    viewModel.cancelScan()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("StorageInspectorScanActionButton")
            } else {
                Button(action: { viewModel.startScan() }) {
                    Label(StorageLocaleKey.rescan.resolve(for: language), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("StorageInspectorScanActionButton")
            }

            Button(action: {
                closeInspector()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .l10nHelp(L10n.Common.close)
            .accessibilityIdentifier("StorageInspectorCloseButton")
        }
        .padding(.horizontal, TTZipTheme.Spacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func directorySelectionMenu(language: AppLanguage) -> some View {
        Menu {
            Button(StorageLocaleKey.presetDownloads.resolve(for: language)) {
                if let d = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    viewModel.setDirectory(d)
                }
            }
            Button(StorageLocaleKey.presetProjects.resolve(for: language)) {
                let path = (NSHomeDirectory() as NSString).appendingPathComponent("Projects")
                viewModel.setDirectory(URL(fileURLWithPath: path))
            }
            Button(StorageLocaleKey.presetXcodeDeveloper.resolve(for: language)) {
                let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Developer")
                viewModel.setDirectory(URL(fileURLWithPath: path))
            }
            Divider()
            Button(StorageLocaleKey.chooseDirectory.resolve(for: language)) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    viewModel.setDirectory(url)
                }
            }
        } label: {
            HStack(spacing: TTZipTheme.Spacing.xxs) {
                Image(systemName: "folder")
                Text(viewModel.selectedDirectory.lastPathComponent)
                    .lineLimit(1)
            }
            .font(.system(size: 11.5, weight: .medium))
        }
        .menuStyle(.borderedButton)
        .accessibilityIdentifier("StorageInspectorDirectoryMenu")
    }

    // MARK: - Volume Metrics & Capacity Banner

    @ViewBuilder
    private func volumeMetricsBanner(language: AppLanguage) -> some View {
        HStack(spacing: TTZipTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xxs) {
                HStack(spacing: TTZipTheme.Spacing.xs) {
                    Text(StorageLocaleKey.scannedSizeLabel.resolve(for: language))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(l10n.formatBytes(Int64(viewModel.totalScannedBytes)))
                        .font(.system(size: 12, weight: .bold))

                    Text("·")
                        .foregroundColor(.secondary)
                    Text(StorageLocaleKey.logicalSizeFormat.format(
                        for: language,
                        l10n.formatBytes(Int64(viewModel.totalLogicalBytes))
                    ))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                    if let summary = viewModel.lastScanSummary, summary.deduplicatedHardLinks > 0 {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text(StorageLocaleKey.hardlinkNoteFormat.format(for: language, summary.deduplicatedHardLinks))
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                }

                GeometryReader { proxy in
                    let w = proxy.size.width
                    let reclaimRatio = viewModel.totalScannedBytes > 0
                        ? min(1.0, Double(viewModel.totalReclaimableBytes) / Double(viewModel.totalScannedBytes))
                        : 0.0

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(TTZipTheme.subtleFill)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(TTZipTheme.mineralLapis)
                            .frame(width: viewModel.totalScannedBytes > 0 ? w : 0)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(TTZipTheme.mineralAmber)
                            .frame(width: w * CGFloat(reclaimRatio))
                    }
                }
                .frame(height: 6)

                Text(StorageLocaleKey.estimatedNote.resolve(for: language))
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: TTZipTheme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: TTZipTheme.Spacing.xxs) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(TTZipTheme.mineralAmber)
                        Text(StorageLocaleKey.reclaimableCalloutTitle.resolve(for: language))
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(.secondary)
                    }

                    Text(l10n.formatBytes(Int64(viewModel.totalReclaimableBytes)))
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundColor(TTZipTheme.mineralAmber)
                }

                let selectedCount = viewModel.selectedCandidates.count
                Button(action: {
                    pendingSingleTrashItem = nil
                    showConfirmTrashSelected = true
                }) {
                    Text(StorageLocaleKey.cleanSelectedActionFormat.format(for: language, selectedCount))
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(TTZipTheme.mineralAmber)
                .disabled(selectedCount == 0 || viewModel.isCleaning)
                .accessibilityIdentifier("StorageInspectorCleanSelectedButton")
            }
            .padding(.horizontal, TTZipTheme.Spacing.sm)
            .padding(.vertical, TTZipTheme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
                    .fill(TTZipTheme.mineralAmber.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
                    .strokeBorder(TTZipTheme.mineralAmber.opacity(0.24), lineWidth: 1)
            )
        }
        .padding(.horizontal, TTZipTheme.Spacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func partialOrTruncatedWarningStrip(summary: StorageScanSummary, language: AppLanguage) -> some View {
        if !summary.inaccessibleDirectories.isEmpty || summary.isTruncated {
            HStack(spacing: TTZipTheme.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(TTZipTheme.statusWarning)

                if !summary.inaccessibleDirectories.isEmpty {
                    Text(StorageLocaleKey.partialAccessBannerFormat.format(
                        for: language,
                        summary.inaccessibleDirectories.count
                    ))
                    .font(.system(size: 11, weight: .medium))
                }

                if summary.isTruncated {
                    Text(StorageLocaleKey.truncatedBannerFormat.format(
                        for: language,
                        summary.scannedFiles + summary.scannedDirectories
                    ))
                    .font(.system(size: 11, weight: .medium))
                }

                Spacer()
            }
            .padding(.horizontal, TTZipTheme.Spacing.md)
            .padding(.vertical, 6)
            .background(TTZipTheme.statusWarning.opacity(0.10))
        }
    }

    // MARK: - Treemap Header & Terminal State Overlay

    @ViewBuilder
    private func treemapHeaderBar(language: AppLanguage) -> some View {
        HStack(spacing: TTZipTheme.Spacing.xs) {
            Text(StorageLocaleKey.treemapViewportTitle.resolve(for: language))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.secondary)

            if let selected = viewModel.selectedTile {
                Text("•")
                    .foregroundColor(.secondary)
                Text(selected.name)
                    .font(.system(size: 11.5, weight: .bold))
                Text("(\(l10n.formatBytes(Int64(selected.bytes))))")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if viewModel.isCleaning, let progress = viewModel.cleaningProgress {
                ProgressView()
                    .controlSize(.small)
                Text(StorageLocaleKey.cleaningInProgressFormat.format(for: language, progress.completed, progress.total))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if case .scanning(_, let count, _) = viewModel.state {
                ProgressView()
                    .controlSize(.small)
                Text(StorageLocaleKey.scanningProgressFormat.format(for: language, count))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func treemapTerminalStateOverlay(language: AppLanguage) -> some View {
        switch viewModel.state {
        case .idle where viewModel.tiles.isEmpty:
            stateCard(
                icon: "internaldrive",
                tint: .secondary,
                title: StorageLocaleKey.headerTitle.resolve(for: language),
                subtitle: StorageLocaleKey.stateIdleHint.resolve(for: language)
            )
        case .empty:
            stateCard(
                icon: "folder",
                tint: .secondary,
                title: StorageLocaleKey.stateEmptyTitle.resolve(for: language),
                subtitle: StorageLocaleKey.stateEmptySubtitle.resolve(for: language)
            )
        case .cancelled:
            stateCard(
                icon: "slash.circle",
                tint: TTZipTheme.statusWarning,
                title: StorageLocaleKey.stateCancelledTitle.resolve(for: language),
                subtitle: StorageLocaleKey.stateCancelledSubtitle.resolve(for: language)
            )
        case .permissionDenied(let path):
            stateCard(
                icon: "lock.shield.fill",
                tint: TTZipTheme.statusDanger,
                title: StorageLocaleKey.statePermissionDeniedTitle.resolve(for: language),
                subtitle: "\(StorageLocaleKey.statePermissionDeniedSubtitle.resolve(for: language))\n\(path)"
            )
        case .failed(let message):
            stateCard(
                icon: "exclamationmark.octagon.fill",
                tint: TTZipTheme.statusDanger,
                title: StorageLocaleKey.stateFailedTitle.resolve(for: language),
                subtitle: message
            )
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func stateCard(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: TTZipTheme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 13, weight: .bold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(TTZipTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: TTZipTheme.Radius.md, style: .continuous)
                .fill(TTZipUniversalTokens.Plate.surfaceL1.opacity(0.92))
        )
    }

    // MARK: - Reclaim Review Panel

    @ViewBuilder
    private func reclaimReviewPanel(language: AppLanguage) -> some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
            HStack {
                Text(StorageLocaleKey.reclaimPanelTitleFormat.format(for: language, viewModel.reclaimableItems.count))
                    .font(.system(size: 12, weight: .bold))

                Spacer()

                if !viewModel.reclaimableItems.isEmpty {
                    Button(StorageLocaleKey.selectAllVerified.resolve(for: language)) {
                        viewModel.selectAllVerifiedCandidates()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(TTZipTheme.bambooGreen)

                    if !viewModel.selectedCandidateIds.isEmpty {
                        Text("·")
                            .foregroundColor(.secondary)
                        Button(StorageLocaleKey.clearSelection.resolve(for: language)) {
                            viewModel.clearCandidateSelection()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                    }
                }
            }

            if viewModel.reclaimableItems.isEmpty && viewModel.unverifiedItems.isEmpty {
                reclaimReviewPlaceholder(language: language)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
                        ForEach(viewModel.reclaimableItems) { item in
                            verifiedCandidateRow(item: item, language: language)
                        }

                        if !viewModel.unverifiedItems.isEmpty {
                            Divider()
                                .padding(.vertical, TTZipTheme.Spacing.xxs)

                            Text(StorageLocaleKey.unverifiedSectionTitleFormat.format(for: language, viewModel.unverifiedItems.count))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                            Text(StorageLocaleKey.unverifiedHint.resolve(for: language))
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)

                            ForEach(viewModel.unverifiedItems) { item in
                                unverifiedCandidateRow(item: item, language: language)
                            }
                        }

                        if let report = viewModel.lastCleanupReport, !report.records.isEmpty {
                            Divider()
                                .padding(.vertical, TTZipTheme.Spacing.xxs)
                            cleanupReportSection(report: report, language: language)
                        }
                    }
                }
            }
        }
        .padding(TTZipTheme.Spacing.sm)
        .background(TTZipUniversalTokens.Plate.surfaceL1.opacity(0.6))
    }
}
