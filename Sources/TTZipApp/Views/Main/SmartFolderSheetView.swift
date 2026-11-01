// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTKitUI
import TTKitDesign

/// Modal sheet for creating, editing, renaming, deleting, and dynamically evaluating Smart Folders (saved searches).
///
/// Smart Folders persist query criteria and scope without copying or moving physical files,
/// and evaluate dynamically without requiring the Gemma semantic model.
@MainActor
public struct SmartFolderSheetView: View {
    public var viewModel: AppViewState
    public let onDismiss: () -> Void

    @State private var folderName: String = ""
    @State private var nameQuery: String = ""
    @State private var fileExtension: String = ""
    @State private var kindFilter: SmartFolderKindFilter = .any
    @State private var isFullDiskScope: Bool = false
    @State private var scopeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory())
    @State private var editingRecordID: UUID? = nil

    @State private var errorMessage: String? = nil
    @State private var isEvaluatingPreview: Bool = false
    @State private var previewResult: SmartFolderEvaluationResult? = nil

    private var store = SmartFolderStore.shared
    private var l10n = AppLocalizationState.shared

    public init(viewModel: AppViewState, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().opacity(0.4)
            HStack(alignment: .top, spacing: 0) {
                savedFoldersSidebar
                Divider().opacity(0.4)
                editorAndPreviewPane
            }
            .frame(height: 410)
            Divider().opacity(0.4)
            footerBar
        }
        .frame(width: 720)
        .ttOverlayGlassPlate(cornerRadius: 16)
        .onAppear {
            loadInitialEditorState()
        }
        .onExitCommand {
            onDismiss()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TTZipTheme.kintsugiGold)
            Text(
                editingRecordID == nil
                    ? l10n.t(MultiWindowLocaleKey.newSmartFolder)
                    : l10n.uiString(zh: "编辑智能文件夹", en: "Edit Smart Folder")
            )
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)

            Spacer()

            Text(
                l10n.uiString(
                    zh: "动态搜索视图 · 不复制或移动原始文件",
                    en: "Dynamic saved search · Never copies or moves physical files"
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Saved Smart Folders Sidebar

    private var savedFoldersSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(l10n.t(MultiWindowLocaleKey.smartFoldersHeader))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    resetToNewDraft()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
                .buttonStyle(.plain)
                .ttButtonHelp(l10n.uiString(zh: "新建智能文件夹", en: "New Smart Folder"))
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if store.records.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text(l10n.uiString(zh: "暂无已保存的智能文件夹", en: "No saved smart folders"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(store.records) { record in
                            savedFolderRow(record)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(width: 210)
        .background(Color.primary.opacity(0.02))
    }

    private func savedFolderRow(_ record: SmartFolderRecord) -> some View {
        let isSelected = (editingRecordID == record.id)
        return HStack(spacing: 6) {
            Button {
                populateEditor(from: record)
                runDynamicPreview(for: record)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? TTZipTheme.kintsugiGold : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.name)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(scopeSummaryText(for: record.scope))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                deleteRecord(record)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .ttButtonHelp(l10n.uiString(zh: "删除智能文件夹（不删除真实文件）", en: "Delete Smart Folder (keeps real files)"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? TTZipTheme.kintsugiGold.opacity(0.14) : Color.clear)
        )
    }

    // MARK: - Editor & Live Dynamic Results Pane

    private var editorAndPreviewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            formFieldsSection

            if let err = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier("SmartFolderErrorLabel")
            }

            Divider().opacity(0.35)

            dynamicResultsSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var formFieldsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.uiString(zh: "智能文件夹名称", en: "Smart Folder Name"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(l10n.uiString(zh: "例如：近期归档", en: "e.g. Project Archives"), text: $folderName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .accessibilityIdentifier("SmartFolderNameField")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.uiString(zh: "搜索范围", en: "Search Scope"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $isFullDiskScope) {
                        Text(
                            l10n.uiString(
                                zh: "当前文件夹 (\(scopeDirectoryURL.lastPathComponent))",
                                en: "Current Folder (\(scopeDirectoryURL.lastPathComponent))"
                            )
                        ).tag(false)
                        Text(l10n.uiString(zh: "全盘已授权范围", en: "Full Disk (Authorized)")).tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.uiString(zh: "文件名包含", en: "Filename Contains"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(l10n.uiString(zh: "输入名称关键字", en: "Filename keyword"), text: $nameQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .accessibilityIdentifier("SmartFolderQueryField")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.uiString(zh: "文件扩展名（可选）", en: "Extension (Optional)"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("zip / pdf / md", text: $fileExtension)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 120)
                        .accessibilityIdentifier("SmartFolderExtensionField")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.uiString(zh: "类型过滤", en: "Kind Filter"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $kindFilter) {
                        Text(l10n.uiString(zh: "全部", en: "Any")).tag(SmartFolderKindFilter.any)
                        Text(l10n.uiString(zh: "归档", en: "Archives")).tag(SmartFolderKindFilter.archivesOnly)
                        Text(l10n.uiString(zh: "文件夹", en: "Folders")).tag(SmartFolderKindFilter.foldersOnly)
                        Text(l10n.uiString(zh: "普通文件", en: "Files")).tag(SmartFolderKindFilter.filesOnly)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
        }
    }

    @ViewBuilder
    private var dynamicResultsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l10n.uiString(zh: "动态匹配结果预览", en: "Dynamic Match Results"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(l10n.uiString(zh: "立即重查", en: "Refresh Query")) {
                    triggerDraftPreview()
                }
                .controlSize(.small)
            }

            if isEvaluatingPreview {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(l10n.uiString(zh: "正在检索匹配项…", en: "Querying matching items…"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = previewResult {
                if case .error(let msg) = result.phase {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                if result.items.isEmpty {
                    Text(l10n.uiString(zh: "无匹配项目", en: "No matching items found"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(result.items) { item in
                                matchedItemRow(item)
                            }
                        }
                    }
                }
            } else {
                Text(
                    l10n.uiString(
                        zh: "设置条件后点击“立即重查”或“保存并打开”查看实时结果。",
                        en: "Configure criteria and click Refresh Query or Save & Open to inspect live results."
                    )
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func matchedItemRow(_ item: GlobalSearchResultItem) -> some View {
        let resolvedPath = item.diskPath ?? item.archivePath ?? ""
        return Button {
            guard !resolvedPath.isEmpty else { return }
            let url = URL(fileURLWithPath: resolvedPath)
            if item.isDirectory {
                viewModel.navigateToDirectory(url)
            } else if item.archivePath != nil {
                viewModel.openArchiveAsFolder(url: url)
            } else {
                viewModel.revealItemInWindow(url)
            }
            onDismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.isDirectory ? "folder.fill" : (item.archivePath != nil ? "doc.zipper" : "doc"))
                    .font(.system(size: 11))
                    .foregroundStyle(item.isDirectory ? TTZipTheme.bambooGreen : .secondary)
                    .frame(width: 16)
                Text(item.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(resolvedPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.03)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Button(l10n.t(L10n.Common.cancel)) {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(l10n.uiString(zh: "保存并打开", en: "Save & Open")) {
                saveAndOpenSmartFolder()
            }
            .buttonStyle(.borderedProminent)
            .tint(TTZipTheme.bambooGreen)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("SmartFolderSaveButton")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func loadInitialEditorState() {
        let initialScope = viewModel.overlayState.smartFolderInitialScopeURL ?? viewModel.effectiveDisplayDirectory
        scopeDirectoryURL = initialScope

        if let editID = viewModel.overlayState.editingSmartFolderID,
           let record = store.record(for: editID) {
            populateEditor(from: record)
            runDynamicPreview(for: record)
        } else {
            resetToNewDraft()
            if !viewModel.explorerState.searchQuery.isEmpty {
                nameQuery = viewModel.explorerState.searchQuery
                folderName = viewModel.explorerState.searchQuery
            }
        }
    }

    private func resetToNewDraft() {
        editingRecordID = nil
        folderName = ""
        nameQuery = ""
        fileExtension = ""
        kindFilter = .any
        isFullDiskScope = false
        scopeDirectoryURL = viewModel.overlayState.smartFolderInitialScopeURL ?? viewModel.effectiveDisplayDirectory
        errorMessage = nil
        previewResult = nil
    }

    private func populateEditor(from record: SmartFolderRecord) {
        editingRecordID = record.id
        folderName = record.name
        nameQuery = record.criteria.nameQuery
        fileExtension = record.criteria.fileExtension
        kindFilter = record.criteria.kindFilter
        switch record.scope {
        case .directory(let path, _):
            isFullDiskScope = false
            scopeDirectoryURL = URL(fileURLWithPath: path)
        case .fullDisk:
            isFullDiskScope = true
        }
        errorMessage = nil
    }

    private func buildCurrentScope() -> SmartFolderSearchScope {
        if isFullDiskScope {
            return .fullDisk
        }
        let bm = RootFolderAccessManager.shared.persistBookmark(for: scopeDirectoryURL)
        return .directory(path: scopeDirectoryURL.standardizedFileURL.path, bookmarkData: bm)
    }

    private func buildCurrentCriteria() -> SmartFolderCriteria {
        SmartFolderCriteria(
            nameQuery: nameQuery,
            fileExtension: fileExtension,
            kindFilter: kindFilter
        )
    }

    private func triggerDraftPreview() {
        let criteria = buildCurrentCriteria()
        guard !criteria.isEmptyCondition else {
            errorMessage = l10n.uiString(
                zh: "请至少填写文件名关键字、扩展名或选择文件类型。",
                en: "Please specify at least a filename keyword, extension, or kind filter."
            )
            return
        }
        errorMessage = nil
        let draft = SmartFolderRecord(
            id: editingRecordID ?? UUID(),
            name: folderName.isEmpty ? "Draft" : folderName,
            criteria: criteria,
            scope: buildCurrentScope()
        )
        runDynamicPreview(for: draft)
    }

    private func runDynamicPreview(for record: SmartFolderRecord) {
        isEvaluatingPreview = true
        Task { @MainActor in
            let res = await store.evaluate(record: record)
            isEvaluatingPreview = false
            previewResult = res
        }
    }

    private func saveAndOpenSmartFolder() {
        let criteria = buildCurrentCriteria()
        let scope = buildCurrentScope()

        do {
            let saved = try viewModel.saveAndActivateSmartFolder(
                editingID: editingRecordID,
                name: folderName,
                criteria: criteria,
                scope: scope,
                store: store,
                onDismiss: onDismiss
            )
            errorMessage = nil
            editingRecordID = saved.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRecord(_ record: SmartFolderRecord) {
        store.deleteSmartFolder(id: record.id)
        if viewModel.overlayState.activeSmartFolderID == record.id {
            viewModel.deactivateSmartFolder()
        }
        if editingRecordID == record.id {
            resetToNewDraft()
        }
    }

    private func scopeSummaryText(for scope: SmartFolderSearchScope) -> String {
        switch scope {
        case .directory(let path, _):
            return (path as NSString).lastPathComponent
        case .fullDisk:
            return l10n.uiString(zh: "全盘范围", en: "Full Disk")
        }
    }
}

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
