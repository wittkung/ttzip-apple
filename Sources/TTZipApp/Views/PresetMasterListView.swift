// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

public struct PresetMasterListView: View {
    public let presets: [CompressionPreset]
    @Binding public var selectedPresetID: UUID?
    public let onSelectPreset: (CompressionPreset) -> Void
    public let onCreateNewPreset: () -> Void
    public let onDuplicatePreset: ((CompressionPreset) -> Void)?
    public let onResetToDefaults: () -> Void
    private var l10n: AppLocalizationState { AppLocalizationState.shared }
    
    public init(
        presets: [CompressionPreset],
        selectedPresetID: Binding<UUID?>,
        onSelectPreset: @escaping (CompressionPreset) -> Void,
        onCreateNewPreset: @escaping () -> Void,
        onDuplicatePreset: ((CompressionPreset) -> Void)? = nil,
        onResetToDefaults: @escaping () -> Void
    ) {
        self.presets = presets
        self._selectedPresetID = selectedPresetID
        self.onSelectPreset = onSelectPreset
        self.onCreateNewPreset = onCreateNewPreset
        self.onDuplicatePreset = onDuplicatePreset
        self.onResetToDefaults = onResetToDefaults
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.uiString(zh: "预设方案", en: "SCHEMES"))
                            .font(.system(size: 9, weight: .bold, design: .serif))
                            .tracking(2)
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                        Text(l10n.uiString(zh: "压缩预设", en: "Presets"))
                            .font(.system(size: 16, weight: .bold, design: .serif))
                            .foregroundStyle(.primary)
                    }
                    
                    Spacer()
                    
                    Text(l10n.uiString(zh: "\(presets.count) 项", en: "\(presets.count) Items"))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(TTZipTheme.bambooGreen.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .frame(height: 52)
            
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: TTZipTheme.Layout.hairlineBorderWidth)
            
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(presets) { preset in
                        let isSelected = selectedPresetID == preset.id
                        Button(action: {
                            selectedPresetID = preset.id
                            onSelectPreset(preset)
                        }) {
                            HStack(spacing: 10) {
                                formatBadgeView(preset.format, isSelected: isSelected)
                                
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.name)
                                        .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    
                                    HStack(spacing: 6) {
                                        levelBadgeView(preset.level)
                                        
                                        Text(preset.splitVolumeDescription)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                isSelected
                                    ? TTZipTheme.bambooGreen.opacity(0.14)
                                    : Color.primary.opacity(0.02)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        isSelected
                                            ? TTZipTheme.bambooGreen.opacity(0.45)
                                            : Color.primary.opacity(0.05),
                                        lineWidth: isSelected ? 1 : 0.5
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(action: {
                                onDuplicatePreset?(preset)
                            }) {
                                Label(l10n.uiString(zh: "创建预设副本", en: "Duplicate Preset"), systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.hidden)
            
            Divider()
            
            VStack(spacing: 8) {
                Button(action: onCreateNewPreset) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(l10n.uiString(zh: "新建预设", en: "New Preset"))
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(TTZipTheme.bambooGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: TTZipTheme.bambooGreen.opacity(0.22), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                
                Button(action: onResetToDefaults) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                        Text(l10n.uiString(zh: "恢复默认预设", en: "Reset to Defaults"))
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
        .frame(width: 250)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }
    
    @ViewBuilder
    private func formatBadgeView(_ format: ArchiveCompressionFormat, isSelected: Bool) -> some View {
        let (title, bg, fg) = badgeStyle(for: format)
        Text(title)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    
    private func badgeStyle(for format: ArchiveCompressionFormat) -> (String, Color, Color) {
        switch format {
        case .sevenZip:
            return ("7Z", TTZipTheme.kintsugiGold.opacity(0.18), TTZipTheme.kintsugiGold)
        case .zip:
            return ("ZIP", TTZipTheme.bambooGreen.opacity(0.18), TTZipTheme.bambooGreen)
        case .tarGz, .gz:
            return ("GZ", Color.cyan.opacity(0.18), Color.cyan)
        case .tarZst, .zst:
            return ("ZST", Color.purple.opacity(0.18), Color.purple)
        default:
            return (format.rawValue.uppercased(), Color.blue.opacity(0.18), Color.blue)
        }
    }
    
    @ViewBuilder
    private func levelBadgeView(_ level: ArchiveCompressionLevel) -> some View {
        let (title, color) = levelStyle(for: level)
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
    
    private func levelStyle(for level: ArchiveCompressionLevel) -> (String, Color) {
        switch level {
        case .store:
            return ("Store", Color.secondary)
        case .fastest, .fast, .fast1, .fast2, .fast3, .fast4, .fast5:
            return ("Fast", TTZipTheme.bambooGreen)
        case .normal, .level5, .level6, .level7:
            return ("Normal", Color.blue)
        case .maximum, .ultra, .level8, .level9, .level10, .level11, .level12, .level13, .level14, .level15, .level16, .level17, .level18, .level19, .level20, .level21, .level22:
            return ("Ultra", TTZipTheme.kintsugiGold)
        default:
            return ("Normal", Color.blue)
        }
    }
}
