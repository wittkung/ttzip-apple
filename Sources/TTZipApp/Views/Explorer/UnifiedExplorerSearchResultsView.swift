// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitDesign
import TTZipCore
import TTZipUI

/// Dual-group search workspace rendered over the explorer when `explorerState.searchQuery` is non-empty.
/// Simultaneously presents:
/// 1. Current Directory (including accessible subdirectories or current archive entries)
/// 2. Full Disk (accessible Spotlight system index + authorized/indexed semantic scopes)
public struct UnifiedExplorerSearchResultsView: View {
    public let coordinator: UnifiedExplorerSearchCoordinator
    public let viewModel: AppViewState

    public init(
        coordinator: UnifiedExplorerSearchCoordinator,
        viewModel: AppViewState
    ) {
        self.coordinator = coordinator
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchHeaderBar
            Divider().opacity(0.25)
            GeometryReader { geo in
                if geo.size.width >= 620 {
                    HStack(spacing: 0) {
                        searchGroupColumn(group: coordinator.currentDirectoryGroup)
                            .frame(width: floor(geo.size.width * 0.48))
                        Divider().opacity(0.25)
                        searchGroupColumn(group: coordinator.fullDiskGroup)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        searchGroupColumn(group: coordinator.currentDirectoryGroup)
                            .frame(maxHeight: .infinity)
                        Divider().opacity(0.25)
                        searchGroupColumn(group: coordinator.fullDiskGroup)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var searchHeaderBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(
                AppLocalizationState.shared.uiString(
                    zh: "搜索 “\(coordinator.activeQuery)”",
                    en: "Searching “\(coordinator.activeQuery)”"
                )
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

            Text("·")
                .foregroundStyle(.tertiary)

            Text(coordinator.activeScope.displayPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            semanticStatusBadge

            Button {
                viewModel.explorerState.searchQuery = ""
                coordinator.clearSearch()
            } label: {
                Label(
                    AppLocalizationState.shared.uiString(zh: "退出搜索", en: "Exit Search"),
                    systemImage: "xmark.circle.fill"
                )
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
    }

    @ViewBuilder
    private var semanticStatusBadge: some View {
        let coverage = coordinator.fullDiskGroup.coverage
        let (label, color): (String, Color) = {
            if !coverage.isModelReady {
                return (
                    AppLocalizationState.shared.uiString(
                        zh: "词法 + 系统索引（AI 模型未就绪）",
                        en: "Lexical + System Index (AI model not ready)"
                    ),
                    .secondary
                )
            }
            if coverage.hasSemanticContentHits {
                return (
                    AppLocalizationState.shared.uiString(
                        zh: "Gemma 语义内容 + 词法已融合",
                        en: "Gemma Semantic + Lexical Fused"
                    ),
                    .accentColor
                )
            }
            if coverage.isSemanticQueryEncoded {
                return (
                    AppLocalizationState.shared.uiString(
                        zh: "Gemma 已编码查询 · 当前范围无已索引正文段",
                        en: "Gemma Query Encoded · No indexed content segments in scope"
                    ),
                    .orange
                )
            }
            return (
                AppLocalizationState.shared.uiString(
                    zh: "词法结果已就绪 · 语义检索中",
                    en: "Lexical Ready · Semantic Searching"
                ),
                .secondary
            )
        }()

        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(color.opacity(0.10))
            )
    }

    private func searchGroupColumn(group: ExplorerSearchGroupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader(group: group)
            Divider().opacity(0.2)
            groupBody(group: group)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func groupHeader(group: ExplorerSearchGroupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(group.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("\(group.items.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))

                if group.phase.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }

                Spacer()
            }

            if !group.subtitle.isEmpty {
                Text(group.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if group.coverage.isTruncated
                || group.coverage.skippedUnauthorizedSubdirectoryCount > 0
                || group.coverage.skippedDatalessFileCount > 0 {
                Text(Self.coverageFootnote(for: group.coverage))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.015))
    }

    public static func coverageFootnote(for coverage: ExplorerSearchCoverageNote) -> String {
        var parts: [String] = []
        if coverage.isTruncated {
            var reasonNotes: [String] = []
            if coverage.truncationReasons.contains(.maxVisitedEntriesReached) {
                reasonNotes.append(
                    AppLocalizationState.shared.uiString(
                        zh: "已达 \(coverage.visitedEntryCount) 项扫描预算上限",
                        en: "reached \(coverage.visitedEntryCount)-entry scan budget"
                    )
                )
            }
            if coverage.truncationReasons.contains(.maxDepthReached) {
                reasonNotes.append(
                    AppLocalizationState.shared.uiString(
                        zh: "已达子目录深度上限 (\(coverage.maxDepthVisited) 层)",
                        en: "reached subfolder depth limit (\(coverage.maxDepthVisited) levels)"
                    )
                )
            }
            if coverage.truncationReasons.contains(.maxResultsReached) {
                reasonNotes.append(
                    AppLocalizationState.shared.uiString(
                        zh: "已达单组展示上限",
                        en: "reached group result cap"
                    )
                )
            }
            let detail = reasonNotes.joined(separator: " / ")
            parts.append(
                AppLocalizationState.shared.uiString(
                    zh: "当前仅搜索部分范围（\(detail)）",
                    en: "Only partial scope searched (\(detail))"
                )
            )
        }
        if coverage.skippedUnauthorizedSubdirectoryCount > 0 {
            parts.append(
                AppLocalizationState.shared.uiString(
                    zh: "跳过 \(coverage.skippedUnauthorizedSubdirectoryCount) 个无权限子目录",
                    en: "Skipped \(coverage.skippedUnauthorizedSubdirectoryCount) unauthorized subfolders"
                )
            )
        }
        if coverage.skippedDatalessFileCount > 0 {
            parts.append(
                AppLocalizationState.shared.uiString(
                    zh: "跳过 \(coverage.skippedDatalessFileCount) 个未下载云端占位文件",
                    en: "Skipped \(coverage.skippedDatalessFileCount) cloud placeholder files"
                )
            )
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func groupBody(group: ExplorerSearchGroupSnapshot) -> some View {
        switch group.phase {
        case .idle where group.items.isEmpty, .loading where group.items.isEmpty:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(
                    AppLocalizationState.shared.uiString(
                        zh: "正在检索…",
                        en: "Searching…"
                    )
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error(let message) where group.items.isEmpty:
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            SearchNoMatchesPlaceholderView(
                query: coordinator.activeQuery,
                scopeDisplayPath: group.title,
                isTruncatedScope: group.coverage.isTruncated,
                visitedEntryCount: group.coverage.visitedEntryCount,
                onClearQuery: {
                    viewModel.explorerState.searchQuery = ""
                    coordinator.clearSearch()
                }
            )

        case .idle, .completed, .loading, .error:
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(group.items) { item in
                        resultRow(item: item)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    private func resultRow(item: GlobalSearchResultItem) -> some View {
        let isSelected = coordinator.selectedResultID == item.id
        return Button {
            coordinator.activateResult(item, in: viewModel)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName(for: item))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor(for: item))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let badge = item.matchBadge, !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(badge == "AI" ? Color.accentColor : Color.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill((badge == "AI" ? Color.accentColor : Color.secondary).opacity(0.12))
                                )
                        }
                    }

                    Text(item.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconName(for item: GlobalSearchResultItem) -> String {
        switch item.targetKind {
        case .archiveFile:
            return "doc.zipper"
        case .archiveEntry:
            return item.isDirectory ? "folder.fill" : "doc.text.fill"
        case .diskItem:
            return item.isDirectory ? "folder.fill" : "doc.fill"
        case .quickAction:
            return "bolt.fill"
        }
    }

    private func iconColor(for item: GlobalSearchResultItem) -> Color {
        switch item.targetKind {
        case .archiveFile:
            return .orange
        case .archiveEntry:
            return item.isDirectory ? .blue : .secondary
        case .diskItem:
            return item.isDirectory ? .blue : .secondary
        case .quickAction:
            return .accentColor
        }
    }
}
