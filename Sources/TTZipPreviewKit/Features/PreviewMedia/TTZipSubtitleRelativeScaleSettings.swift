// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitDesign
import TTMediaKit
import TTZipUI

@MainActor
struct TTZipSubtitleRelativeScaleSettings: View {
    let style: SubtitleStyleConfiguration
    let activeSubtitleCodec: String?
    let onUpdateStyle: (SubtitleStyleConfiguration) -> Void
    let onUserInteraction: () -> Void

    private static let scaleRange: ClosedRange<Double> = 0.5...2.0
    static let scalePresets: [Double] = [0.75, 1.0, 1.25, 1.5]

    private static func clampScale(_ rawScale: Double) -> Double {
        guard rawScale.isFinite else { return 1.0 }
        return min(scaleRange.upperBound, max(scaleRange.lowerBound, rawScale))
    }

    var continuousScaleBinding: Binding<Double> {
        Binding(
            get: { Self.clampScale(style.scale) },
            set: { newScale in
                var updated = style
                updated.scale = Self.clampScale(newScale)
                onUpdateStyle(updated)
                onUserInteraction()
            }
        )
    }

    func applyScalePreset(_ preset: Double) {
        var updated = style
        updated.scale = Self.clampScale(preset)
        onUpdateStyle(updated)
        onUserInteraction()
    }

    func isPresetSelected(_ preset: Double) -> Bool {
        abs(style.scale - preset) < 0.005
    }

    private var capabilityKind: SubtitleRenderCapabilityKind {
        SubtitleRelativeSizingResolver.capability(forCodecOrFormat: activeSubtitleCodec)
    }

    private var badgeText: String {
        let scaleString = String(format: "%.2fx", style.scale)
        let percentString = String(format: "%.1f%%", style.effectiveRelativeFontRatio * 100.0)
        return TTZipSubtitlePresentationLocalization.formattedRelativeHeightBadge(
            scaleText: scaleString,
            percentText: percentString
        )
    }

    private var capabilityNoticeText: String {
        switch capabilityKind {
        case .textOverlay:
            return TTZipSubtitlePresentationLocalization.text(.capabilityTextActive)
        case .assPlainTextExtracts:
            return TTZipSubtitlePresentationLocalization.text(.capabilityAssExtractedText)
        case .bitmapUntouched:
            return TTZipSubtitlePresentationLocalization.text(.capabilityBitmapNotice)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(MediaLocalization.text(.subtitleFontSize))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(badgeText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }

            Slider(
                value: continuousScaleBinding,
                in: Self.scaleRange
            )
            .disabled(capabilityKind == .bitmapUntouched)

            HStack(spacing: 6) {
                ForEach(Self.scalePresets, id: \.self) { preset in
                    let isSelected = isPresetSelected(preset)
                    Button(String(format: preset.truncatingRemainder(dividingBy: 0.25) == 0 && preset * 10 == (preset * 10).rounded() ? "%.1fx" : "%.2fx", preset)) {
                        applyScalePreset(preset)
                    }
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium, design: .monospaced))
                    .buttonStyle(.bordered)
                    .tint(isSelected ? TTZipTheme.accentColor : nil)
                    .controlSize(.small)
                    .disabled(capabilityKind == .bitmapUntouched)
                }
            }

            Text(capabilityNoticeText)
                .font(.system(size: 10))
                .foregroundStyle(capabilityKind == .bitmapUntouched ? TTKitTheme.archivalAmber : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
