// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTKitDesign
import TTZipCore
import TTZipUI

// MARK: - Candidate Rows & Cleanup Report Sections

extension StorageInspectorView {
    @ViewBuilder
    func reclaimReviewPlaceholder(language: AppLanguage) -> some View {
        VStack(spacing: TTZipTheme.Spacing.xs) {
            Spacer()
            if viewModel.showsNoReclaimableFoundBadge {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28))
                    .foregroundColor(TTZipTheme.bambooGreen)
                Text(StorageLocaleKey.noReclaimableFound.resolve(for: language))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            } else if case .scanning(_, let count, _) = viewModel.state {
                ProgressView()
                    .controlSize(.regular)
                Text(StorageLocaleKey.scanningProgressFormat.format(for: language, count))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                let (iconName, statusText): (String, String) = {
                    switch viewModel.state {
                    case .cancelled:
                        return ("slash.circle", StorageLocaleKey.stateCancelledTitle.resolve(for: language))
                    case .permissionDenied:
                        return ("lock.shield.fill", StorageLocaleKey.statePermissionDeniedTitle.resolve(for: language))
                    case .failed:
                        return ("exclamationmark.octagon.fill", StorageLocaleKey.stateFailedTitle.resolve(for: language))
                    case .idle, .scanning, .completed, .empty:
                        return ("internaldrive", StorageLocaleKey.stateIdleHint.resolve(for: language))
                    }
                }()
                Image(systemName: iconName)
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    func verifiedCandidateRow(item: ReclaimableStorageItem, language: AppLanguage) -> some View {
        let isSelected = viewModel.selectedCandidateIds.contains(item.id)
        HStack(alignment: .center, spacing: TTZipTheme.Spacing.xs) {
            Button(action: { viewModel.toggleCandidateSelection(item) }) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? TTZipTheme.bambooGreen : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text(item.path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.localizedReason(for: language))
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(l10n.formatBytes(Int64(item.sizeBytes)))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            Button(action: {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(StorageLocaleKey.revealInFinderHelp.resolve(for: language))

            Button(action: {
                pendingSingleTrashItem = item
                showConfirmTrashSelected = true
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(TTZipTheme.statusDanger.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isCleaning)
            .help(StorageLocaleKey.moveSingleToTrashHelp.resolve(for: language))
        }
        .padding(.horizontal, TTZipTheme.Spacing.xs)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
                .fill(TTZipUniversalTokens.Plate.surfaceL2)
        )
    }

    @ViewBuilder
    func unverifiedCandidateRow(item: ReclaimableStorageItem, language: AppLanguage) -> some View {
        HStack(alignment: .center, spacing: TTZipTheme.Spacing.xs) {
            Image(systemName: "shield.slash")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(item.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(l10n.formatBytes(Int64(item.sizeBytes)))
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)

            Button(action: {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(StorageLocaleKey.revealInFinderHelp.resolve(for: language))
        }
        .padding(.horizontal, TTZipTheme.Spacing.xs)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
                .fill(TTZipUniversalTokens.Plate.surfaceL2.opacity(0.5))
        )
    }

    @ViewBuilder
    func cleanupReportSection(report: StorageCleanupReport, language: AppLanguage) -> some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xxs) {
            Text(StorageLocaleKey.cleanupReportTitle.resolve(for: language))
                .font(.system(size: 11, weight: .bold))
            ForEach(report.records) { rec in
                HStack(spacing: TTZipTheme.Spacing.xxs) {
                    Image(systemName: rec.outcome.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.system(size: 10))
                        .foregroundColor(rec.outcome.isSuccess ? TTZipTheme.statusSuccess : TTZipTheme.statusDanger)
                    Text(rec.name)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(rec.outcome.localizedStatus(for: language))
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(TTZipTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous)
                .fill(TTZipUniversalTokens.Plate.surfaceL2.opacity(0.6))
        )
    }
}
