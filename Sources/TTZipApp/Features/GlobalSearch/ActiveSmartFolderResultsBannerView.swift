// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipSearchKit
import SwiftUI
import TTZipCore
import TTZipUI

/// Actionable row button for a single matched Smart Folder item inside `ActiveSmartFolderResultsBannerView`.
@MainActor
public struct SmartFolderResultItemRowButton: View {
    public let item: GlobalSearchResultItem
    public let action: () -> Void

    public init(item: GlobalSearchResultItem, action: @escaping () -> Void) {
        self.item = item
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.zipper")
                    .font(.system(size: 10))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("SmartFolderResultItem_\(item.title)")
    }
}

/// Active Smart Folder dynamic result header and live item list rendered in the main browser window.
@MainActor
public struct ActiveSmartFolderResultsBannerView: View {
    public var viewModel: AppViewState
    private var l10n = AppLocalizationState.shared

    public init(viewModel: AppViewState) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if let record = viewModel.overlayState.activeSmartFolderRecord {
            VStack(alignment: .leading, spacing: 6) {
                headerBar(record: record)
                if let result = viewModel.overlayState.activeSmartFolderResult,
                   result.recordID == record.id {
                    resultsList(result: result)
                } else if viewModel.overlayState.isEvaluatingSmartFolder {
                    Text(l10n.uiString(zh: "正在评估智能文件夹条件…", en: "Evaluating smart folder criteria…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.035))
            .overlay(alignment: .bottom) {
                Divider().opacity(0.35)
            }
            .accessibilityIdentifier("ActiveSmartFolderResultsBanner")
        }
    }

    private func headerBar(record: SmartFolderRecord) -> some View {
        let budget = viewModel.overlayState.activeSmartFolderResult?.scanBudget ?? .defaultBudget
        return HStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text(record.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(criteriaSummary(for: record))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(budgetDisclosureText(for: budget))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if viewModel.overlayState.isEvaluatingSmartFolder {
                ProgressView().controlSize(.small)
            }
            Button {
                viewModel.refreshActiveSmartFolder()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SmartFolderRefreshButton")

            Button {
                viewModel.overlayState.editingSmartFolderID = record.id
                viewModel.overlayState.showSmartFolderModal = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SmartFolderEditButton")

            Button {
                viewModel.deactivateSmartFolder()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SmartFolderCloseButton")
        }
    }

    @ViewBuilder
    private func resultsList(result: SmartFolderEvaluationResult) -> some View {
        let coverageNote = UnifiedExplorerSearchResultsView.coverageFootnote(for: result.coverage)
        if result.phase == .loading || viewModel.overlayState.isEvaluatingSmartFolder {
            Text(l10n.uiString(zh: "正在评估智能文件夹条件…", en: "Evaluating smart folder criteria…"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if result.isCancelled || result.isScopeUnauthorized || result.phase.errorMessage != nil {
            nonCompletedStatusView(result: result, coverageNote: coverageNote)
        } else if result.items.isEmpty {
            emptyResultsView(result: result, coverageNote: coverageNote)
        } else {
            matchedItemsScrollView(result: result, coverageNote: coverageNote)
        }
    }

    @ViewBuilder
    private func nonCompletedStatusView(result: SmartFolderEvaluationResult, coverageNote: String) -> some View {
        if result.isCancelled {
            Text(result.phase.errorMessage ?? l10n.uiString(zh: "智能文件夹扫描已取消。", en: "Smart folder scan cancelled."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if result.isScopeUnauthorized {
            statusMessageWithCoverage(
                message: result.phase.errorMessage ?? l10n.uiString(zh: "未获得目录访问授权", en: "Directory access not authorized"),
                color: .orange,
                coverageNote: coverageNote
            )
        } else if let errorMsg = result.phase.errorMessage {
            statusMessageWithCoverage(
                message: errorMsg,
                color: .red,
                coverageNote: coverageNote
            )
        }
    }

    private func statusMessageWithCoverage(message: String, color: Color, coverageNote: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
            if !coverageNote.isEmpty {
                Text(coverageNote)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func emptyResultsView(result: SmartFolderEvaluationResult, coverageNote: String) -> some View {
        if result.coverage.isTruncated || result.coverage.skippedUnauthorizedSubdirectoryCount > 0 {
            let fallback = l10n.uiString(
                zh: "在当前扫描预算内未命中结果（扫描已截断或部分目录跳过）",
                en: "No matches within current scan budget (truncated or partial scope)"
            )
            Text(coverageNote.isEmpty ? fallback : coverageNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Text(l10n.uiString(zh: "无匹配项目", en: "No matching items"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func matchedItemsScrollView(result: SmartFolderEvaluationResult, coverageNote: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 6) {
                    ForEach(result.items) { item in
                        SmartFolderResultItemRowButton(item: item) {
                            openMatchedItem(item)
                        }
                    }
                }
            }
            if !coverageNote.isEmpty {
                Text(coverageNote)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func budgetDisclosureText(for budget: SmartFolderScanBudget) -> String {
        l10n.uiString(
            zh: "扫描预算：最多访问 10,000 项 · 结果上限 \(budget.maxDirectoryResults) 项 · 深度 \(budget.maxDepth)",
            en: "Scan budget: up to 10,000 entries · cap \(budget.maxDirectoryResults) · depth \(budget.maxDepth)"
        )
    }

    private func criteriaSummary(for record: SmartFolderRecord) -> String {
        var parts: [String] = []
        if !record.criteria.nameQuery.isEmpty {
            parts.append("\"\(record.criteria.nameQuery)\"")
        }
        if !record.criteria.fileExtension.isEmpty {
            parts.append(".\(record.criteria.fileExtension)")
        }
        if record.criteria.kindFilter != .any {
            parts.append(record.criteria.kindFilter.rawValue)
        }
        return parts.joined(separator: " · ")
    }

    private func openMatchedItem(_ item: GlobalSearchResultItem) {
        if let archivePath = item.archivePath {
            viewModel.openArchiveAsFolder(url: URL(fileURLWithPath: archivePath))
        } else if let diskPath = item.diskPath {
            let url = URL(fileURLWithPath: diskPath)
            if item.isDirectory {
                viewModel.navigateToDirectory(url)
            } else {
                viewModel.revealItemInWindow(url)
            }
        }
    }
}
