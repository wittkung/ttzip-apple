// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

// MARK: - AppLocalizationState Typed Extensions for LocalModelLocaleKey

public extension AppLocalizationState {
    /// Resolves a localized `LocalModelLocaleKey` string for the current active language.
    func t(_ key: LocalModelLocaleKey) -> String {
        TTZipLocalizationManager.shared.string(for: key, language: currentLanguage)
    }

    /// Formats a localized `LocalModelLocaleKey` string template using the current active language `Locale`.
    func format(_ key: LocalModelLocaleKey, _ args: CVarArg...) -> String {
        let formatStr = TTZipLocalizationManager.shared.string(for: key, language: currentLanguage)
        return String(format: formatStr, locale: Locale(identifier: currentLanguage.bcp47), arguments: args)
    }
}

// MARK: - Pure Presentation Snapshot

/// Pure presentation snapshot computed directly from `LocalModelManager` without duplicating state truth.
public struct LocalModelSettingsPresentation: Equatable, Sendable {
    public let modelName: String
    public let purposeText: String
    public let downloadSizeText: String
    public let diskUsageText: String
    public let statusBadgeText: String
    public let searchCapabilityBannerText: String
    public let basicSearchFallbackNotice: String?
    public let failureReasonText: String?
    public let progressFraction: Double?
    public let canDownload: Bool
    public let canCancel: Bool
    public let canRetry: Bool
    public let canDelete: Bool
    public let isSemanticAvailable: Bool

    public init(
        modelName: String,
        purposeText: String,
        downloadSizeText: String,
        diskUsageText: String,
        statusBadgeText: String,
        searchCapabilityBannerText: String,
        basicSearchFallbackNotice: String?,
        failureReasonText: String?,
        progressFraction: Double?,
        canDownload: Bool,
        canCancel: Bool,
        canRetry: Bool,
        canDelete: Bool,
        isSemanticAvailable: Bool
    ) {
        self.modelName = modelName
        self.purposeText = purposeText
        self.downloadSizeText = downloadSizeText
        self.diskUsageText = diskUsageText
        self.statusBadgeText = statusBadgeText
        self.searchCapabilityBannerText = searchCapabilityBannerText
        self.basicSearchFallbackNotice = basicSearchFallbackNotice
        self.failureReasonText = failureReasonText
        self.progressFraction = progressFraction
        self.canDownload = canDownload
        self.canCancel = canCancel
        self.canRetry = canRetry
        self.canDelete = canDelete
        self.isSemanticAvailable = isSemanticAvailable
    }

    /// Computes the presentation snapshot directly from `LocalModelManager`.
    @MainActor
    public static func make(from manager: LocalModelManager) -> LocalModelSettingsPresentation {
        let l10n = AppLocalizationState.shared
        let state = manager.installState
        let isReady = manager.isSemanticSearchAvailable

        let downloadSizeText = l10n.formatBytes(manager.expectedDownloadBytes)
        let diskUsageText: String = {
            if manager.diskUsageBytes <= 0 {
                return l10n.t(L10n.LocalModel.diskUsageZeroValue)
            }
            return l10n.formatBytes(manager.diskUsageBytes)
        }()

        let statusBadgeText = Self.resolveStatusBadgeText(from: manager, l10n: l10n)
        let capabilityText = isReady
            ? l10n.t(L10n.LocalModel.capabilitySemanticAndLexical)
            : l10n.t(L10n.LocalModel.capabilityBasicLexicalOnly)
        let fallbackNotice: String? = isReady ? nil : l10n.t(L10n.LocalModel.basicSearchFallbackNotice)
        let failureReason = Self.sanitizedFailureReason(for: state, lastReason: manager.lastFailureReason)
        let effectiveBusy = manager.isBusy || manager.isDisabling
        let actionFlags = Self.actionFlags(
            for: state,
            isBusy: effectiveBusy,
            isModelInstalled: manager.isModelInstalled,
            isDisabling: manager.isDisabling
        )

        return LocalModelSettingsPresentation(
            modelName: manager.modelDisplayName,
            purposeText: l10n.t(L10n.LocalModel.purposeValue),
            downloadSizeText: downloadSizeText,
            diskUsageText: diskUsageText,
            statusBadgeText: statusBadgeText,
            searchCapabilityBannerText: capabilityText,
            basicSearchFallbackNotice: fallbackNotice,
            failureReasonText: failureReason,
            progressFraction: manager.downloadProgressFraction,
            canDownload: actionFlags.canDownload,
            canCancel: actionFlags.canCancel,
            canRetry: actionFlags.canRetry,
            canDelete: actionFlags.canDelete,
            isSemanticAvailable: isReady
        )
    }

    @MainActor
    private static func resolveStatusBadgeText(
        from manager: LocalModelManager,
        l10n: AppLocalizationState
    ) -> String {
        if manager.isDisabling {
            return l10n.t(L10n.LocalModel.statusDisabling)
        }
        if manager.isModelInstalled && !manager.isPluginEnabled {
            return l10n.t(L10n.LocalModel.statusInstalledDisabled)
        }
        if manager.isModelInstalled && manager.isPluginEnabled && manager.installState == .notInstalled {
            return l10n.t(L10n.LocalModel.statusInstalledReadyOnDemand)
        }
        return Self.statusBadgeText(for: manager.installState, l10n: l10n)
    }

    private static func actionFlags(
        for state: SemanticModelInstallState,
        isBusy: Bool,
        isModelInstalled: Bool,
        isDisabling: Bool
    ) -> (canDownload: Bool, canCancel: Bool, canRetry: Bool, canDelete: Bool) {
        let base: (canDownload: Bool, canCancel: Bool, canRetry: Bool, canDelete: Bool)
        switch state {
        case .notInstalled:
            base = (!isBusy, false, false, false)
        case .downloading:
            base = (false, true, false, false)
        case .verifying:
            base = (false, false, false, false)
        case .ready:
            base = (false, false, false, !isBusy)
        case .failed, .engineUnlinked:
            base = (false, false, !isBusy, false)
        }
        return (
            canDownload: base.canDownload && !isModelInstalled && !isBusy,
            canCancel: base.canCancel && !isDisabling,
            canRetry: base.canRetry && !isBusy,
            canDelete: (base.canDelete || isModelInstalled) && !isBusy
        )
    }

    @MainActor
    private static func statusBadgeText(
        for state: SemanticModelInstallState,
        l10n: AppLocalizationState
    ) -> String {
        switch state {
        case .notInstalled:
            return l10n.t(L10n.LocalModel.statusNotInstalled)
        case .downloading:
            return l10n.t(L10n.LocalModel.statusDownloading)
        case .verifying:
            return l10n.t(L10n.LocalModel.statusVerifying)
        case .ready:
            return l10n.t(L10n.LocalModel.statusAvailable)
        case .failed, .engineUnlinked:
            return l10n.t(L10n.LocalModel.statusFailed)
        }
    }

    private static func sanitizedFailureReason(
        for state: SemanticModelInstallState,
        lastReason: String?
    ) -> String? {
        let rawReason: String?
        switch state {
        case .failed(let reason):
            rawReason = reason
        case .engineUnlinked(let reason):
            rawReason = reason
        default:
            rawReason = nil
        }
        guard let candidate = (rawReason ?? lastReason)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return nil
        }
        var cleaned = candidate
        // Strip any internal paths, .gguf filenames, or internal backend identifiers from user-facing text.
        let pathRegex = try? NSRegularExpression(pattern: #"(/[^\s]+)+"#)
        if let regex = pathRegex {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }
        cleaned = cleaned
            .replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "GGUF", with: "Model")
            .replacingOccurrences(of: "llama.cpp", with: "local runtime", options: .caseInsensitive)
            .replacingOccurrences(of: "CoreML", with: "local runtime", options: .caseInsensitive)
            .replacingOccurrences(of: "Core ML", with: "local runtime", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? candidate : cleaned
    }
}

// MARK: - Local Models Settings Section View

/// Settings section view for managing on-demand local semantic search models.
/// Consumes `LocalModelManager` directly as the single source of truth.
public struct LocalModelSettingsSectionView: View {
    @Bindable var l10n = AppLocalizationState.shared
    let modelManager: LocalModelManager

    public init(modelManager: LocalModelManager = .shared) {
        self.modelManager = modelManager
    }

    private var presentation: LocalModelSettingsPresentation {
        let _ = l10n.currentLanguage
        let _ = l10n.byteUnitStandard
        return LocalModelSettingsPresentation.make(from: modelManager)
    }

    public var body: some View {
        let snapshot = presentation
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.lg) {
            capabilityOverviewCard(snapshot: snapshot)
            Toggle(isOn: Binding(
                get: { modelManager.isPluginEnabled },
                set: { enabled in Task { await modelManager.setPluginEnabled(enabled) } }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.currentLanguage.bcp47.hasPrefix("zh") ? "启用 Gemma 可选组件" : "Enable optional Gemma component")
                    Text(l10n.currentLanguage.bcp47.hasPrefix("zh")
                         ? "默认关闭。下载只安装模型；启用后才加载模型并运行语义索引。"
                         : "Off by default. Downloading only installs the model; enabling loads it and runs semantic indexing.")
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled((!modelManager.isModelInstalled && !modelManager.isPluginEnabled) || modelManager.isDisabling)
            .accessibilityIdentifier("settings.localModels.enableToggle")
            metadataAndControlsCard(snapshot: snapshot)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.localModels.section")
        .task {
            await modelManager.refreshState()
        }
    }

    // MARK: - 1. Capability Overview Card

    @ViewBuilder
    private func capabilityOverviewCard(snapshot: LocalModelSettingsPresentation) -> some View {
        SettingsFormGroup(
            title: l10n.t(L10n.LocalModel.sectionTitle),
            systemImage: "square.stack.3d.up.fill",
            trailingHeader: {
                capabilityStatusPill(snapshot: snapshot)
            },
            content: {
                VStack(alignment: .leading, spacing: TTZipTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n.t(L10n.LocalModel.purposeDescription))
                            .font(TTZipTheme.Typography.body)
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .fixedSize(horizontal: false, vertical: true)

                        Text(l10n.t(L10n.LocalModel.sectionSubtitle))
                            .font(TTZipTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let fallbackNotice = snapshot.basicSearchFallbackNotice {
                        HStack(alignment: .top, spacing: TTZipTheme.Spacing.xs) {
                            Image(systemName: "info.circle.fill")
                                .font(TTZipTheme.Typography.callout)
                                .foregroundStyle(TTZipTheme.statusInfo)
                            Text(fallbackNotice)
                                .font(TTZipTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, TTZipTheme.Spacing.sm)
                        .padding(.vertical, TTZipTheme.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(TTZipTheme.statusInfo.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous))
                        .accessibilityIdentifier("settings.localModels.fallbackNotice")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        )
    }

    @ViewBuilder
    private func capabilityStatusPill(snapshot: LocalModelSettingsPresentation) -> some View {
        let tintColor = snapshot.isSemanticAvailable ? TTZipTheme.bambooGreen : Color.secondary
        HStack(spacing: 6) {
            Circle()
                .fill(tintColor)
                .frame(width: 7, height: 7)
            Text(snapshot.searchCapabilityBannerText)
                .font(TTZipTheme.Typography.caption)
                .bold()
                .foregroundStyle(tintColor)
        }
        .padding(.horizontal, TTZipTheme.Spacing.xs)
        .padding(.vertical, 4)
        .background(tintColor.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityIdentifier("settings.localModels.capabilityBanner")
    }

    // MARK: - 2. Model Metadata & Interactive Controls Card

    @ViewBuilder
    private func metadataAndControlsCard(snapshot: LocalModelSettingsPresentation) -> some View {
        SettingsFormGroup(
            title: l10n.t(L10n.LocalModel.metadataHeader),
            systemImage: "internaldrive",
            trailingHeader: {
                statusBadgeView(snapshot: snapshot)
            },
            content: {
                metadataGridView(snapshot: snapshot)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                SettingsFormDivider()

                interactiveControlsRow(snapshot: snapshot)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        )
    }

    @ViewBuilder
    private func statusBadgeView(snapshot: LocalModelSettingsPresentation) -> some View {
        let badgeColor = modelManager.isPluginEnabled ? statusBadgeColor(for: modelManager.installState) : .secondary
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(snapshot.statusBadgeText)
                .font(TTZipTheme.Typography.caption)
                .bold()
                .foregroundStyle(badgeColor)
        }
        .padding(.horizontal, TTZipTheme.Spacing.xs)
        .padding(.vertical, 4)
        .background(badgeColor.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityIdentifier("settings.localModels.statusBadge")
    }

    private func statusBadgeColor(for state: SemanticModelInstallState) -> Color {
        switch state {
        case .notInstalled:
            return .secondary
        case .downloading, .verifying:
            return TTZipTheme.kintsugiGold
        case .ready:
            return TTZipTheme.bambooGreen
        case .failed, .engineUnlinked:
            return TTZipTheme.cinnabarRed
        }
    }

    @ViewBuilder
    private func metadataGridView(snapshot: LocalModelSettingsPresentation) -> some View {
        let primaryLabel = Color(nsColor: .labelColor)
        let secondaryLabel = Color(nsColor: .secondaryLabelColor)
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            GridRow {
                Text(l10n.t(L10n.LocalModel.modelNameLabel) + ":")
                    .font(TTZipTheme.Typography.subheadline)
                    .foregroundStyle(secondaryLabel)
                Text(snapshot.modelName)
                    .font(TTZipTheme.Typography.bodyMedium)
                    .foregroundStyle(primaryLabel)
                    .accessibilityIdentifier("settings.localModels.modelNameValue")
            }

            GridRow {
                Text(l10n.t(L10n.LocalModel.purposeLabel) + ":")
                    .font(TTZipTheme.Typography.subheadline)
                    .foregroundStyle(secondaryLabel)
                Text(snapshot.purposeText)
                    .font(TTZipTheme.Typography.body)
                    .foregroundStyle(primaryLabel)
                    .accessibilityIdentifier("settings.localModels.purposeValue")
            }

            GridRow {
                Text(l10n.t(L10n.LocalModel.downloadSizeLabel) + ":")
                    .font(TTZipTheme.Typography.subheadline)
                    .foregroundStyle(secondaryLabel)
                Text(snapshot.downloadSizeText)
                    .font(TTZipTheme.Typography.body)
                    .foregroundStyle(primaryLabel)
                    .accessibilityIdentifier("settings.localModels.downloadSizeValue")
            }

            GridRow {
                Text(l10n.t(L10n.LocalModel.diskUsageLabel) + ":")
                    .font(TTZipTheme.Typography.subheadline)
                    .foregroundStyle(secondaryLabel)
                Text(snapshot.diskUsageText)
                    .font(TTZipTheme.Typography.body)
                    .foregroundStyle(primaryLabel)
                    .accessibilityIdentifier("settings.localModels.diskUsageValue")
            }

            GridRow {
                Text(l10n.t(L10n.LocalModel.statusLabel) + ":")
                    .font(TTZipTheme.Typography.subheadline)
                    .foregroundStyle(secondaryLabel)
                Text(snapshot.statusBadgeText)
                    .font(TTZipTheme.Typography.bodyMedium)
                    .foregroundStyle(primaryLabel)
            }
        }
    }

    // MARK: - 3. Interactive Controls & Progress / Error Feedback

    @ViewBuilder
    private func interactiveControlsRow(snapshot: LocalModelSettingsPresentation) -> some View {
        if modelManager.isDisabling {
            verifyingControls()
        } else if modelManager.isModelInstalled && (!modelManager.isPluginEnabled || modelManager.installState == .notInstalled) {
            readyControls(snapshot: snapshot)
        } else {
            switch modelManager.installState {
            case .notInstalled:
                notInstalledControls(snapshot: snapshot)
            case .downloading:
                downloadingControls(snapshot: snapshot)
            case .verifying:
                verifyingControls()
            case .ready:
                readyControls(snapshot: snapshot)
            case .failed, .engineUnlinked:
                failedControls(snapshot: snapshot)
            }
        }
    }

    @ViewBuilder
    private func notInstalledControls(snapshot: LocalModelSettingsPresentation) -> some View {
        HStack {
            Button(action: { modelManager.startDownload() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(l10n.t(L10n.LocalModel.actionDownload))
                }
                .font(TTZipTheme.Typography.callout)
                .foregroundStyle(Color.white)
                .padding(.horizontal, TTZipTheme.Spacing.md)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .background(TTZipTheme.bambooGradient)
            .clipShape(Capsule())
            .disabled(!snapshot.canDownload)
            .accessibilityIdentifier("settings.localModels.downloadButton")

            Spacer()
        }
    }

    @ViewBuilder
    private func downloadingControls(snapshot: LocalModelSettingsPresentation) -> some View {
        let fraction = snapshot.progressFraction ?? 0.0
        let percentString = l10n.formatPercent(fraction)
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
            HStack(spacing: TTZipTheme.Spacing.sm) {
                ProgressView(value: fraction, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(TTZipTheme.bambooGreen)
                    .accessibilityIdentifier("settings.localModels.progressBar")

                Text(percentString)
                    .font(TTZipTheme.Typography.codeCaption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .trailing)

                Button(action: { modelManager.cancelDownload() }) {
                    Text(l10n.t(L10n.LocalModel.actionCancel))
                        .font(TTZipTheme.Typography.caption)
                        .bold()
                        .padding(.horizontal, TTZipTheme.Spacing.sm)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.08))
                .clipShape(Capsule())
                .disabled(!snapshot.canCancel)
                .accessibilityIdentifier("settings.localModels.cancelButton")
            }

            Text(l10n.format(L10n.LocalModel.downloadingProgressFormat, percentString))
                .font(TTZipTheme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func verifyingControls() -> some View {
        HStack(spacing: TTZipTheme.Spacing.xs) {
            ProgressView()
                .controlSize(.small)
            Text(l10n.t(L10n.LocalModel.verifyingProgressNotice))
                .font(TTZipTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityIdentifier("settings.localModels.verifyingIndicator")
    }

    @ViewBuilder
    private func readyControls(snapshot: LocalModelSettingsPresentation) -> some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: modelManager.isPluginEnabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(modelManager.isPluginEnabled ? TTZipTheme.bambooGreen : Color.secondary)
                Text(snapshot.statusBadgeText)
                    .font(TTZipTheme.Typography.bodyMedium)
                    .foregroundStyle(modelManager.isPluginEnabled ? TTZipTheme.bambooGreen : Color.secondary)
            }

            Spacer()

            Button(action: {
                Task {
                    try? await modelManager.deleteModel()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text(l10n.t(L10n.LocalModel.actionDelete))
                }
                .font(TTZipTheme.Typography.caption)
                .bold()
                .foregroundStyle(TTZipTheme.cinnabarRed)
                .padding(.horizontal, TTZipTheme.Spacing.sm)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(TTZipTheme.cinnabarRed.opacity(0.10))
            .clipShape(Capsule())
            .disabled(!snapshot.canDelete)
            .accessibilityIdentifier("settings.localModels.deleteButton")
        }
    }

    @ViewBuilder
    private func failedControls(snapshot: LocalModelSettingsPresentation) -> some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.sm) {
            if let reason = snapshot.failureReasonText {
                HStack(alignment: .top, spacing: TTZipTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.t(L10n.LocalModel.failureBannerTitle))
                            .font(TTZipTheme.Typography.caption)
                            .bold()
                            .foregroundStyle(TTZipTheme.cinnabarRed)
                        Text(reason)
                            .font(TTZipTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(TTZipTheme.Spacing.xs)
                .background(TTZipTheme.cinnabarRed.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.sm, style: .continuous))
                .accessibilityIdentifier("settings.localModels.errorBanner")
            }

            HStack {
                Button(action: { modelManager.retryDownload() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text(l10n.t(L10n.LocalModel.actionRetry))
                    }
                    .font(TTZipTheme.Typography.callout)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, TTZipTheme.Spacing.md)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .background(TTZipTheme.bambooGradient)
                .clipShape(Capsule())
                .disabled(!snapshot.canRetry)
                .accessibilityIdentifier("settings.localModels.retryButton")

                Spacer()
            }
        }
    }
}
