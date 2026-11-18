// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

/// Strongly-typed localization keys for the Storage Space Inspector & Cleanup Safety domain (Q2).
/// Integrates with `TTZipLocalizationManager` (`TTI18n`) and provides built-in `zh-Hans`, `zh-Hant`,
/// and `en` translations with deterministic English fallback for other supported languages.
public enum StorageLocaleKey: String, LocaleKeyProtocol, CaseIterable, Sendable {
    // MARK: - 1. Header & Navigation
    case headerTitle = "storage.header.title"
    case presetDownloads = "storage.preset.downloads"
    case presetProjects = "storage.preset.projects"
    case presetXcodeDeveloper = "storage.preset.xcode_developer"
    case chooseDirectory = "storage.action.choose_directory"
    case rescan = "storage.action.rescan"
    case upDirectory = "storage.action.up_directory"

    // MARK: - 2. Metrics & Capacity Banner
    case scannedSizeLabel = "storage.metrics.scanned_size_label"
    case logicalSizeFormat = "storage.metrics.logical_size_format"
    case hardlinkNoteFormat = "storage.metrics.hardlink_note_format"
    case reclaimableCalloutTitle = "storage.metrics.reclaimable_callout_title"
    case estimatedNote = "storage.metrics.estimated_note"
    case cleanSelectedActionFormat = "storage.action.clean_selected_format"
    case cleaningInProgressFormat = "storage.action.cleaning_in_progress_format"

    // MARK: - 3. Treemap Viewport & States
    case treemapViewportTitle = "storage.treemap.viewport_title"
    case othersTileTitle = "storage.treemap.others_title"
    case scanningProgressFormat = "storage.state.scanning_progress_format"
    case stateIdleHint = "storage.state.idle_hint"
    case stateEmptyTitle = "storage.state.empty_title"
    case stateEmptySubtitle = "storage.state.empty_subtitle"
    case stateCancelledTitle = "storage.state.cancelled_title"
    case stateCancelledSubtitle = "storage.state.cancelled_subtitle"
    case statePermissionDeniedTitle = "storage.state.permission_denied_title"
    case statePermissionDeniedSubtitle = "storage.state.permission_denied_subtitle"
    case stateFailedTitle = "storage.state.failed_title"
    case partialAccessBannerFormat = "storage.banner.partial_access_format"
    case truncatedBannerFormat = "storage.banner.truncated_format"

    // MARK: - 4. Reclaim Review Panel & Candidate Verification
    case reclaimPanelTitleFormat = "storage.reclaim.panel_title_format"
    case unverifiedSectionTitleFormat = "storage.reclaim.unverified_section_title_format"
    case unverifiedHint = "storage.reclaim.unverified_hint"
    case noReclaimableFound = "storage.reclaim.none_found"
    case selectAllVerified = "storage.reclaim.select_all_verified"
    case clearSelection = "storage.reclaim.clear_selection"
    case moveSingleToTrashHelp = "storage.reclaim.move_single_help"
    case revealInFinderHelp = "storage.reclaim.reveal_in_finder_help"

    // MARK: - 5. Candidate Evidence Reasons
    case reasonNodeModules = "storage.reason.node_modules"
    case reasonDerivedData = "storage.reason.derived_data"
    case reasonCargoTarget = "storage.reason.cargo_target"
    case reasonSwiftBuild = "storage.reason.swift_build"
    case reasonGradleOrCMakeBuild = "storage.reason.gradle_cmake_build"
    case reasonGradleCache = "storage.reason.gradle_cache"
    case reasonPythonVenv = "storage.reason.python_venv"
    case reasonPycache = "storage.reason.pycache"
    case reasonCacheDirTag = "storage.reason.cachedir_tag"
    case reasonUnverifiedNameOnlyFormat = "storage.reason.unverified_name_only_format"

    // MARK: - 6. Cleanup Confirmation & Per-Item Report
    case confirmCleanTitle = "storage.confirm.clean_title"
    case confirmCleanMessageFormat = "storage.confirm.clean_message_format"
    case confirmMoveAction = "storage.confirm.move_action"
    case securityGuardAlertTitle = "storage.alert.security_guard_title"
    case cleanupReportTitle = "storage.report.title"
    case cleanupSummaryAllSuccessFormat = "storage.report.summary_all_success_format"
    case cleanupSummaryPartialFormat = "storage.report.summary_partial_format"
    case outcomeTrashed = "storage.outcome.trashed"
    case outcomeCoveredByParent = "storage.outcome.covered_by_parent"
    case outcomeCancelled = "storage.outcome.cancelled"
    case outcomeRejectedProtected = "storage.outcome.rejected_protected"
    case outcomeRejectedOutsideScope = "storage.outcome.rejected_outside_scope"
    case outcomeRejectedSymlinkOrParentChanged = "storage.outcome.rejected_symlink_or_parent"
    case outcomeRejectedIdentityChanged = "storage.outcome.rejected_identity_changed"
    case outcomeRejectedEvidenceLost = "storage.outcome.rejected_evidence_lost"
    case outcomeRejectedSubtreeProtected = "storage.outcome.rejected_subtree_protected"
    case outcomeRejectedSubtreeIncomplete = "storage.outcome.rejected_subtree_incomplete"
    case outcomeRejectedUnverified = "storage.outcome.rejected_unverified"
    case outcomeFailedFormat = "storage.outcome.failed_format"

    private struct TranslationTriple: Sendable {
        let en: String
        let zhHans: String
        let zhHant: String

        init(_ en: String, _ zhHans: String, _ zhHant: String) {
            self.en = en
            self.zhHans = zhHans
            self.zhHant = zhHant
        }
    }

    /// Built-in fallback translation covering Simplified Chinese, Traditional Chinese, and English.
    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let entry = Self.translations[self] else {
            return rawKey
        }
        switch language {
        case .zhHans:
            return entry.zhHans
        case .zhHant:
            return entry.zhHant
        case .en, .ja, .de, .fr, .es:
            return entry.en
        }
    }

    /// Resolves the localized string through `TTZipLocalizationManager`, honoring any compiled catalog
    /// override before falling back to the built-in translation table.
    public func resolve(
        for language: AppLanguage? = nil,
        manager: TTZipLocalizationManager = .shared
    ) -> String {
        let targetLanguage = language ?? manager.currentLanguage
        let catalogCandidate = manager.string(for: self as any LocaleKeyProtocol, language: targetLanguage)
        if !catalogCandidate.isEmpty && catalogCandidate != rawKey {
            return catalogCandidate
        }
        return fallbackTranslation(for: targetLanguage)
    }

    /// Resolves a formatted localized string with positional arguments.
    public func format(
        for language: AppLanguage? = nil,
        manager: TTZipLocalizationManager = .shared,
        _ args: CVarArg...
    ) -> String {
        let targetLanguage = language ?? manager.currentLanguage
        let template = resolve(for: targetLanguage, manager: manager)
        return String(format: template, locale: Locale(identifier: targetLanguage.bcp47), arguments: args)
    }

    private static let translations: [StorageLocaleKey: TranslationTriple] = [
        .headerTitle: TranslationTriple("Storage Space Inspector", "存储空间透视", "儲存空間透視"),
        .presetDownloads: TranslationTriple("Downloads (~/Downloads)", "下载目录 (~/Downloads)", "下載目錄 (~/Downloads)"),
        .presetProjects: TranslationTriple("Projects (~/Projects)", "项目目录 (~/Projects)", "專案目錄 (~/Projects)"),
        .presetXcodeDeveloper: TranslationTriple("Xcode Developer Caches", "Xcode 开发者缓存", "Xcode 開發者快取"),
        .chooseDirectory: TranslationTriple("Choose Other Directory...", "选择其他目录...", "選擇其他目錄..."),
        .rescan: TranslationTriple("Rescan", "重新扫描", "重新掃描"),
        .upDirectory: TranslationTriple("Parent Folder", "返回上级", "返回上級"),

        .scannedSizeLabel: TranslationTriple("Allocated Size:", "实际占用：", "實際佔用："),
        .logicalSizeFormat: TranslationTriple("Logical: %@", "逻辑大小：%@", "邏輯大小：%@"),
        .hardlinkNoteFormat: TranslationTriple("%d hard-linked files deduplicated", "已去重 %d 个硬链接文件", "已去重 %d 個硬連結檔案"),
        .reclaimableCalloutTitle: TranslationTriple("Verified Reclaimable (Est.)", "已验证可清理（估算）", "已驗證可清理（估算）"),
        .estimatedNote: TranslationTriple("Moving to Trash does not immediately free disk space; APFS clones/snapshots may also retain blocks", "移入废纸篓不会立即释放磁盘空间；清空废纸篓前及 APFS 克隆/快照存续期间仍占用空间", "移入垃圾桶不會立即釋放磁碟空間；清空垃圾桶前及 APFS 克隆/快照存續期間仍佔用空間"),
        .cleanSelectedActionFormat: TranslationTriple("Move Selected (%d) to Trash", "移入废纸篓 (%d)", "移入垃圾桶 (%d)"),
        .cleaningInProgressFormat: TranslationTriple("Cleaning (%d/%d)...", "正在清理 (%d/%d)...", "正在清理 (%d/%d)..."),

        .treemapViewportTitle: TranslationTriple("Squarified Treemap Viewport", "正方化矩形树图视图", "正方化矩形樹圖視圖"),
        .othersTileTitle: TranslationTriple("Others", "其他", "其他"),
        .scanningProgressFormat: TranslationTriple("Scanning %d items...", "正在扫描 %d 项...", "正在掃描 %d 項..."),
        .stateIdleHint: TranslationTriple("Select a directory to start storage analysis", "选择目录以开始空间分析", "選擇目錄以開始空間分析"),
        .stateEmptyTitle: TranslationTriple("Directory Is Empty", "目录为空", "目錄為空"),
        .stateEmptySubtitle: TranslationTriple("No files or subdirectories found in the selected folder.", "所选文件夹下没有文件或子目录。", "所選資料夾下沒有檔案或子目錄。"),
        .stateCancelledTitle: TranslationTriple("Scan Cancelled", "扫描已取消", "掃描已取消"),
        .stateCancelledSubtitle: TranslationTriple("Directory enumeration stopped immediately. Click Rescan to restart.", "目录遍历已立即停止。点击“重新扫描”可再次分析。", "目錄遍歷已立即停止。點擊「重新掃描」可再次分析。"),
        .statePermissionDeniedTitle: TranslationTriple("Permission Denied", "无访问权限", "無存取權限"),
        .statePermissionDeniedSubtitle: TranslationTriple("Cannot read the selected directory. Authorize access or choose another folder.", "无法读取所选目录，请授权访问或选择其他文件夹。", "無法讀取所選目錄，請授權存取或選擇其他資料夾。"),
        .stateFailedTitle: TranslationTriple("Scan Failed", "扫描失败", "掃描失敗"),
        .partialAccessBannerFormat: TranslationTriple("Partial scan: %d subdirectories could not be read due to permissions.", "部分完成：%d 个子目录因权限不足未能读取。", "部分完成：%d 個子目錄因權限不足未能讀取。"),
        .truncatedBannerFormat: TranslationTriple("Entry limit reached (%d items); totals shown are a lower bound.", "已达扫描条目上限（%d 项），统计值为下界。", "已達掃描條目上限（%d 項），統計值為下界。"),

        .reclaimPanelTitleFormat: TranslationTriple("Verified Candidates (%d)", "已验证候选 (%d)", "已驗證候選 (%d)"),
        .unverifiedSectionTitleFormat: TranslationTriple("Unverified Name Matches (%d)", "未验证同名目录 (%d)", "未驗證同名目錄 (%d)"),
        .unverifiedHint: TranslationTriple("Name matched without build manifest evidence or contains protected subtree items; excluded from cleanup.", "仅目录名命中但缺少工程旁证或子树含受保护内容，不纳入清理。", "僅目錄名命中但缺少工程旁證或子樹含受保護內容，不納入清理。"),
        .noReclaimableFound: TranslationTriple("No verified reclaimable caches found", "未发现已验证的可清理缓存", "未發現已驗證的可清理快取"),
        .selectAllVerified: TranslationTriple("Select All", "全选", "全選"),
        .clearSelection: TranslationTriple("Clear", "清空", "清空"),
        .moveSingleToTrashHelp: TranslationTriple("Review and move to Trash", "复核并移至废纸篓", "覆核並移至垃圾桶"),
        .revealInFinderHelp: TranslationTriple("Reveal in Finder", "在访达中显示", "在 Finder 中顯示"),

        .reasonNodeModules: TranslationTriple("Node.js package cache (verified by sibling package.json)", "Node.js 依赖包缓存（已核实同级 package.json）", "Node.js 依賴套件快取（已核實同級 package.json）"),
        .reasonDerivedData: TranslationTriple("Xcode DerivedData build and index cache", "Xcode DerivedData 构建与索引缓存", "Xcode DerivedData 建置與索引快取"),
        .reasonCargoTarget: TranslationTriple("Cargo build output (verified by Cargo.toml and CACHEDIR.TAG, .rustc_info.json, or deps/.fingerprint artifacts)", "Cargo 编译产物（已核实 Cargo.toml 及 CACHEDIR.TAG、.rustc_info.json 或 deps/.fingerprint 构建旁证）", "Cargo 編譯產物（已核實 Cargo.toml 及 CACHEDIR.TAG、.rustc_info.json 或 deps/.fingerprint 建置旁證）"),
        .reasonSwiftBuild: TranslationTriple("SwiftPM build cache (verified by sibling Package.swift)", "SwiftPM 构建缓存（已核实同级 Package.swift）", "SwiftPM 建置快取（已核實同級 Package.swift）"),
        .reasonGradleOrCMakeBuild: TranslationTriple("Build output (verified by Gradle/CMake project files)", "构建产物目录（已核实 Gradle/CMake 工程文件）", "建置產物目錄（已核實 Gradle/CMake 專案檔案）"),
        .reasonGradleCache: TranslationTriple("Gradle project cache (verified by sibling Gradle config)", "Gradle 项目缓存（已核实同级 Gradle 配置）", "Gradle 專案快取（已核實同級 Gradle 設定）"),
        .reasonPythonVenv: TranslationTriple("Python virtual environment (verified by pyvenv.cfg)", "Python 虚拟环境（已核实 pyvenv.cfg）", "Python 虛擬環境（已核實 pyvenv.cfg）"),
        .reasonPycache: TranslationTriple("Python bytecode cache (.pyc only)", "Python 字节码缓存（仅含 .pyc）", "Python 位元組碼快取（僅含 .pyc）"),
        .reasonCacheDirTag: TranslationTriple("Standard cache directory (verified CACHEDIR.TAG signature)", "标准缓存目录（已核实 CACHEDIR.TAG 签名）", "標準快取目錄（已核實 CACHEDIR.TAG 簽章）"),
        .reasonUnverifiedNameOnlyFormat: TranslationTriple("Unverified '%@' (missing project marker or contains protected subtree files)", "未验证“%@”（缺少工程标记或子树含受保护内容）", "未驗證「%@」（缺少專案標記或子樹含受保護內容）"),

        .confirmCleanTitle: TranslationTriple("Move Selected Caches to Trash", "将所选缓存移至废纸篓", "將所選快取移至垃圾桶"),
        .confirmCleanMessageFormat: TranslationTriple("Move %d selected candidate(s) (est. %@) to macOS Trash?\n\n%@You can restore them from Trash in Finder.", "确定将已勾选的 %d 个候选目录（估算 %@）移至废纸篓吗？\n\n%@可在访达废纸篓中放回原处。", "確定將已勾選的 %d 個候選目錄（估算 %@）移至垃圾桶嗎？\n\n%@可在 Finder 垃圾桶中放回原處。"),
        .confirmMoveAction: TranslationTriple("Move to Trash", "移至废纸篓", "移至垃圾桶"),
        .securityGuardAlertTitle: TranslationTriple("Cleanup Safety & Verification", "清理安全校验与结果", "清理安全校驗與結果"),
        .cleanupReportTitle: TranslationTriple("Last Cleanup Report", "最近一次清理报告", "最近一次清理報告"),
        .cleanupSummaryAllSuccessFormat: TranslationTriple("Moved %d item(s) to Trash (disk space is freed only after emptying Trash).", "已将 %d 项移入废纸篓（清空废纸篓后方会释放磁盘空间）。", "已將 %d 項移入垃圾桶（清空垃圾桶後方會釋放磁碟空間）。"),
        .cleanupSummaryPartialFormat: TranslationTriple("%d moved to Trash, %d skipped or failed.", "%d 项已移入废纸篓，%d 项被拒绝或失败。", "%d 項已移入垃圾桶，%d 項被拒絕或失敗。"),
        .outcomeTrashed: TranslationTriple("Moved to Trash", "已移入废纸篓", "已移入垃圾桶"),
        .outcomeCoveredByParent: TranslationTriple("Skipped (already covered by selected parent directory)", "已跳过（包含在已选父目录中）", "已略過（包含在已選父目錄中）"),
        .outcomeCancelled: TranslationTriple("Cancelled before execution", "已在执行前取消", "已在執行前取消"),
        .outcomeRejectedProtected: TranslationTriple("Blocked: protected system or credential path", "已拦截：受保护的系统或凭据路径", "已攔截：受保護的系統或憑證路徑"),
        .outcomeRejectedOutsideScope: TranslationTriple("Blocked: outside authorized scan root", "已拦截：超出当前扫描根目录授权范围", "已攔截：超出目前掃描根目錄授權範圍"),
        .outcomeRejectedSymlinkOrParentChanged: TranslationTriple("Blocked: symlink or parent path changed since scan", "已拦截：符号链接或父目录在扫描后发生变化", "已攔截：符號連結或父目錄在掃描後發生變化"),
        .outcomeRejectedIdentityChanged: TranslationTriple("Blocked: directory inode/device changed since scan", "已拦截：目录标识 (inode) 在扫描后已被替换", "已攔截：目錄識別 (inode) 在掃描後已被替換"),
        .outcomeRejectedEvidenceLost: TranslationTriple("Blocked: cache evidence no longer holds", "已拦截：缓存工程旁证已失效", "已攔截：快取工程旁證已失效"),
        .outcomeRejectedSubtreeProtected: TranslationTriple("Blocked: subtree contains VCS (.git/.hg/.svn) or credentials", "已拦截：候选子树内包含版本控制 (.git/.hg/.svn) 或凭据文件", "已攔截：候選子樹內包含版本控制 (.git/.hg/.svn) 或憑證檔案"),
        .outcomeRejectedSubtreeIncomplete: TranslationTriple("Blocked: subtree safety check incomplete (budget or permission limit)", "已拦截：子树安全检查未完成（超出预算或存在无权限子目录）", "已攔截：子樹安全檢查未完成（超出預算或存在無權限子目錄）"),
        .outcomeRejectedUnverified: TranslationTriple("Blocked: candidate is not verified", "已拦截：未验证的同名目录不可清理", "已攔截：未驗證的同名目錄不可清理"),
        .outcomeFailedFormat: TranslationTriple("Failed: %@", "失败：%@", "失敗：%@"),
    ]
}
