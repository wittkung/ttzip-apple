// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipTaskKit
import TTZipUI

extension CompressionCompletedSummary {
    @MainActor
    public static func makeCleanupWarningMessage(outcome: ExtractionOutcome?) -> String? {
        guard let outcome, outcome.status == .completedWithFailures else { return nil }
        let count = outcome.failed.count
        return AppLocalizationState.shared.uiString(
            zh: "归档已创建，但有 \(count) 项提交后清理警告",
            en: "Archive created with \(count) post-commit cleanup warning(s)",
            zhHant: "歸檔已建立，但有 \(count) 項提交後清理警告",
            ja: "アーカイブを作成しましたが、コミット後のクリーンアップ警告が \(count) 件あります",
            ko: "아카이브가 생성되었으나 커밋 후 정리 경고 \(count)건이 발생했습니다",
            de: "Archiv erstellt mit \(count) Bereinigungswarnung(en) nach dem Commit",
            fr: "Archive créée avec \(count) avertissement(s) de nettoyage après validation",
            es: "Archivo creado con \(count) advertencia(s) de limpieza tras la confirmación"
        )
    }

    @MainActor
    public static func makeSourcePreservationNotice(shouldDeleteSource: Bool) -> String? {
        guard shouldDeleteSource else { return nil }
        return AppLocalizationState.shared.uiString(
            zh: "归档已创建；本次未自动删除源文件",
            en: "Archive created; source files were not automatically deleted",
            zhHant: "歸檔已建立；本次未自動刪除來源檔案",
            ja: "アーカイブを作成しました。元のファイルは自動削除されませんでした",
            ko: "아카이브가 생성되었으며 원본 파일은 자동으로 삭제되지 않았습니다",
            de: "Archiv erstellt; Quelldateien wurden nicht automatisch gelöscht",
            fr: "Archive créée ; les fichiers sources n'ont pas été supprimés automatiquement",
            es: "Archivo creado; los archivos de origen no se eliminaron automáticamente"
        )
    }
}

extension CompressFormSession {
    @MainActor
    public func presentCreateTransactionFailureInspection(
        report: ArchiveCreateTransactionFailureReport,
        taskId: UUID
    ) {
        self.currentProgress = ArchiveProgress(
            state: .failed(error: report.summaryMessage),
            currentFileName: report.summaryMessage
        )
        self.failedCreateTransactionReport = report
        self.failedCreateTransactionTaskId = taskId
        self.isCreateFailureSheetPresented = true
    }

    @MainActor
    public func acknowledgeFailedCreateTransaction() {
        if let id = failedCreateTransactionTaskId {
            ArchiveOperationsQueueCenter.shared.acknowledgeResult(id: id)
        }
        clearCreateFailureInspectionState()
    }

    @MainActor
    public func clearCreateFailureInspectionState() {
        self.isCreateFailureSheetPresented = false
        self.failedCreateTransactionReport = nil
        self.failedCreateTransactionTaskId = nil
    }
}
