// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Observation
import TTZipCore
import TTZipUI

extension CompressIntegratedConfigSectionView {
    /// Compact smart codec recommendation control row with scenario selector, probe button, and status feedback.
    var smartRecommendationSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(smartSectionLabelTitle)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 6) {
                smartRecommendationControlBar
                smartRecommendationStatusRow
            }
        }
    }

    private var smartSectionLabelTitle: String {
        l10n.uiString(
            zh: "智能推荐",
            en: "Smart Tune",
            zhHant: "智慧推薦",
            ja: "スマート推奨",
            ko: "스마트 추천",
            de: "Smart-Wahl",
            fr: "Auto-Tune",
            es: "Ajuste inteligente"
        )
    }

    private var smartRecommendationControlBar: some View {
        HStack(spacing: 6) {
            ForEach(SmartCompressionScenario.allCases) { scenario in
                scenarioPill(scenario)
            }

            Spacer(minLength: 4)

            if case .sampling = session.smartRecommendationState {
                Button {
                    session.cancelSmartRecommendation()
                } label: {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(cancelProbeTitle)
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    session.requestSmartRecommendation()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10, weight: .semibold))
                        Text(probeTriggerTitle)
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(TTZipTheme.bambooGreen.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(session.itemsList.isEmpty)
            }
        }
    }

    private func scenarioPill(_ scenario: SmartCompressionScenario) -> some View {
        let isSelected = session.smartScenario == scenario
        return Button {
            session.smartScenario = scenario
        } label: {
            HStack(spacing: 4) {
                Image(systemName: scenario.iconName)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(scenario.localizedTitle)
                    .font(.system(size: 10.5, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? TTZipTheme.bambooGreen.opacity(0.14) : Color.primary.opacity(0.035))
            .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? TTZipTheme.bambooGreen.opacity(0.45) : Color.clear, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder
    private var smartRecommendationStatusRow: some View {
        switch session.smartRecommendationState {
        case .idle:
            EmptyView()
        case .sampling:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(samplingProgressTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .ready(let recommendation):
            smartRecommendationReadyBanner(recommendation)
        case .failed(let errorMessage):
            smartRecommendationFailedBanner(errorMessage)
        }
    }

    private func smartRecommendationReadyBanner(_ recommendation: SmartCodecRecommendation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text(recommendation.summaryText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                session.applySmartRecommendation()
            } label: {
                Text(applyRecommendationTitle)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(TTZipTheme.bambooGreen.opacity(0.14))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(TTZipTheme.bambooGreen.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func smartRecommendationFailedBanner(_ errorMessage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(errorMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var probeTriggerTitle: String {
        l10n.uiString(
            zh: "智能分析",
            en: "Analyze",
            zhHant: "智慧分析",
            ja: "分析",
            ko: "분석",
            de: "Analysieren",
            fr: "Analyser",
            es: "Analizar"
        )
    }

    private var cancelProbeTitle: String {
        l10n.uiString(
            zh: "取消采样",
            en: "Cancel",
            zhHant: "取消取樣",
            ja: "キャンセル",
            ko: "취소",
            de: "Abbrechen",
            fr: "Annuler",
            es: "Cancelar"
        )
    }

    private var samplingProgressTitle: String {
        l10n.uiString(
            zh: "正在后台采样计算信息熵与推荐编码参数...",
            en: "Sampling up to 256 KB in background to evaluate entropy...",
            zhHant: "正在背景取樣計算資訊熵與推薦編碼參數..."
        )
    }

    private var applyRecommendationTitle: String {
        l10n.uiString(
            zh: "应用推荐",
            en: "Apply",
            zhHant: "套用推薦",
            ja: "適用",
            ko: "적용",
            de: "Anwenden",
            fr: "Appliquer",
            es: "Aplicar"
        )
    }
}
