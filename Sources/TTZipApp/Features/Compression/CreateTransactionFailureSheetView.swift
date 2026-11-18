// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

/// Foreground inspection and acknowledgment sheet for incomplete archive creation transactions.
public struct CreateTransactionFailureSheetView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let l10n = AppLocalizationState.shared

    public let report: ArchiveCreateTransactionFailureReport
    public let onAcknowledgeAndClose: () -> Void

    public var renderedStageDir: String? {
        report.stageDirPreserved ? report.stageDir : nil
    }

    public var renderedCleanupFailures: [(path: String, reason: String)] {
        report.cleanupFailures.map { item in
            let resolvedPath = item.path ?? item.originalStagedPath ?? report.stageDir
            let reasonText = "\(item.disposition.rawValue): \(item.message)"
            return (path: resolvedPath, reason: reasonText)
        }
    }

    public var renderedRollbackFailures: [(targetPath: String, backupSourcePath: String, message: String)] {
        report.rollbackFailedEntries.map { entry in
            (
                targetPath: entry.targetPath,
                backupSourcePath: entry.backupSourcePath,
                message: entry.message
            )
        }
    }

    public init(
        report: ArchiveCreateTransactionFailureReport,
        onAcknowledgeAndClose: @escaping () -> Void
    ) {
        self.report = report
        self.onAcknowledgeAndClose = onAcknowledgeAndClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar
            Divider()
            summaryBanner
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let stageDir = renderedStageDir {
                        preservedStageSection(stageDir: stageDir)
                    }
                    if !report.cleanupFailures.isEmpty {
                        cleanupFailuresSection
                    }
                    if !report.rollbackFailedEntries.isEmpty {
                        rollbackFailuresSection
                    }
                }
            }
            .frame(maxHeight: 240)
            Divider()
            acknowledgeButton
        }
        .padding(20)
        .frame(width: 480)
        .background(modalBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(TTZipTheme.specularHairline, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.55 : 0.18), radius: 24, y: 12)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 24))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    l10n.uiString(
                        zh: "创建事务未完成（需检查残留路径）",
                        en: "Create Transaction Incomplete",
                        zhHant: "建立事務未完成（需檢查殘留路徑）",
                        ja: "作成トランザクション未完了",
                        ko: "생성 트랜잭션 미완료",
                        de: "Erstellungstransaktion unvollständig",
                        fr: "Transaction de création incomplète",
                        es: "Transacción de creación incompleta"
                    )
                )
                .font(.title3)
                .fontWeight(.bold)
                if report.wasPrimaryCancelled || report.isCancellationRequested {
                    Text(
                        l10n.uiString(
                            zh: "取消期间发生清理或回滚异常",
                            en: "Cleanup or rollback issue occurred during cancellation",
                            zhHant: "取消期間發生清理或回滾異常",
                            ja: "キャンセル中にクリーンアップまたはロールバックの問題が発生しました",
                            ko: "취소 중 정리 또는 롤백 문제가 발생했습니다",
                            de: "Bereinigungs- oder Rollback-Problem während des Abbruchs",
                            fr: "Problème de nettoyage ou d'annulation pendant l'interruption",
                            es: "Problema de limpieza o reversión durante la cancelación"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var summaryBanner: some View {
        Text(report.summaryMessage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(colorScheme == .dark ? 0.16 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func preservedStageSection(stageDir: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preserved Stage Directory")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(stageDir)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var cleanupFailuresSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Residual Cleanup Failures")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            ForEach(Array(renderedCleanupFailures.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.path)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text(item.reason)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(colorScheme == .dark ? 0.12 : 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private var rollbackFailuresSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rollback Recovery Failures")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            ForEach(Array(renderedRollbackFailures.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.targetPath)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text("Backup: \(entry.backupSourcePath)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(entry.message)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(colorScheme == .dark ? 0.12 : 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private var acknowledgeButton: some View {
        Button(action: onAcknowledgeAndClose) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                Text(
                    l10n.uiString(
                        zh: "已知悉残留路径并关闭",
                        en: "Acknowledge Residual Paths and Close",
                        zhHant: "已知悉殘留路徑並關閉",
                        ja: "残存パスを確認して閉じる",
                        ko: "잔여 경로 확인 및 닫기",
                        de: "Restpfade bestätigen und schließen",
                        fr: "Confirmer les chemins résiduels et fermer",
                        es: "Confirmar rutas residuales y cerrar"
                    )
                )
                .fontWeight(.bold)
            }
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.orange)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var modalBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(TTZipTheme.modalCardSurface(for: colorScheme))
        }
    }
}
