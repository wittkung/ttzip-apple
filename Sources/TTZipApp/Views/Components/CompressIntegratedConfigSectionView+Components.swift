// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import Observation
import TTZipCore

extension CompressIntegratedConfigSectionView {
    var shouldShowFormatSpecificSection: Bool {
        guard session.compressionLevel != .store else { return false }
        return session.selectedFormat == .sevenZip || session.selectedFormat == .zst || session.selectedFormat == .tarZst
    }
    
    @ViewBuilder
    var formatSpecificAdvancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.2.fill").font(.system(size: 11)).foregroundStyle(TTZipTheme.bambooGreen)
                Text("\(session.selectedFormat.rawValue.uppercased()) \(l10n.t(L10n.Compress.targetParameters))")
                    .font(.system(size: 11.5, weight: .bold)).foregroundStyle(.primary)
                Spacer()
                Button(action: { session.isAlgorithmMatrixPresented = true }) {
                    Text(l10n.t(L10n.Benchmark.benchmarkMatrixTitle))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            
            switch session.selectedFormat {
            case .sevenZip:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text(l10n.t(L10n.Compress.algorithm)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 75, alignment: .trailing)
                        Picker("", selection: $session.compressionAlgorithm) {
                            Text("LZMA2").tag("LZMA2")
                            Text("LZMA").tag("LZMA")
                            Text("PPMd").tag("PPMd")
                            Text("BZip2").tag("BZip2")
                        }.pickerStyle(.menu).controlSize(.small)
                        
                        Spacer()
                    }
                    
                    HStack(spacing: 12) {
                        L10nText(L10n.Compress.dictionarySize)
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 75, alignment: .trailing)
                        
                        Picker("", selection: $session.customDictionarySizeMB) {
                            Text(l10n.format(L10n.Compress.dictAutoFormat, session.effectiveDictionarySizeMB)).tag(nil as Int?)
                            Text(l10n.t(L10n.Compress.dictSpeedUnit)).tag(Optional(16))
                            Text("32 MB").tag(Optional(32))
                            Text(l10n.t(L10n.Compress.dictStandardUnit)).tag(Optional(64))
                            Text("128 MB").tag(Optional(128))
                            Text("256 MB").tag(Optional(256))
                            Text(l10n.t(L10n.Compress.dictLargeMemoryUnit)).tag(Optional(512))
                            Text(l10n.t(L10n.Compress.dictUltraUnit)).tag(Optional(1024))
                            Text(l10n.t(L10n.Compress.dictPhysicalLimitUnit)).tag(Optional(1536))
                        }
                        .pickerStyle(.menu).controlSize(.small)
                        
                        Spacer()
                    }
                    
                    Toggle(l10n.t(L10n.Compress.solidArchiveDesc), isOn: $session.enableSolidArchive)
                        .font(.system(size: 11)).tint(TTZipTheme.bambooGreen)
                }
            case .zst, .tarZst:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text(l10n.t(L10n.Compress.zstdLevel)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 75, alignment: .trailing)
                        Picker("", selection: $session.zstdLevel) {
                            Text("1").tag(1); Text("3").tag(3); Text("9").tag(9); Text("19").tag(19)
                        }.pickerStyle(.segmented).tint(TTZipTheme.bambooGreen)
                    }
                    Toggle(l10n.t(L10n.Compress.zstdLdm), isOn: $session.zstdEnableLDM).font(.system(size: 11)).tint(TTZipTheme.bambooGreen)
                }
            default:
                EmptyView()
            }
        }
        .padding(10).background(TTZipTheme.bambooGreen.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    func formatTile(format: ArchiveCompressionFormat) -> some View {
        let isSel = session.selectedFormat == format
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                session.selectedFormat = format
                if !format.supportedLevels.contains(session.compressionLevel) {
                    session.compressionLevel = format.supportedLevels.first ?? .store
                }
            }
        }) {
            VStack(alignment: .center, spacing: 2) {
                Text(format.displayName).font(.system(size: 10.5, weight: .bold))
                Text(format.shortcutBadge).font(.system(size: 7.5, weight: .semibold)).foregroundStyle(isSel ? TTZipTheme.bambooGreen : Color.secondary.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4).padding(.vertical, 5)
            .background(isSel ? TTZipTheme.bambooGreen.opacity(0.14) : Color.primary.opacity(0.03))
            .foregroundStyle(isSel ? TTZipTheme.bambooGreen : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(isSel ? TTZipTheme.bambooGreen.opacity(0.5) : Color.clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    
    func volTile(size: Int64?, name: String) -> some View {
        let isSel = (size == -1) ? session.isCustomVolumeSelected : (!session.isCustomVolumeSelected && session.splitVolumeOption == size)
        return Button(action: {
            if size == -1 {
                session.isCustomVolumeSelected = true
                session.calculateCustomVolume()
            } else {
                session.isCustomVolumeSelected = false
                session.splitVolumeOption = size
            }
        }) {
            Text(name).font(.system(size: 10, weight: isSel ? .bold : .regular))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(isSel ? TTZipTheme.bambooGreen.opacity(0.14) : Color.primary.opacity(0.03))
                .foregroundStyle(isSel ? TTZipTheme.bambooGreen : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(isSel ? TTZipTheme.bambooGreen.opacity(0.4) : Color.clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    
    func compressionLevelSection(fmt: ArchiveCompressionFormat) -> some View {
        let levelsList = fmt.supportedLevels
        return HStack(alignment: .top, spacing: 12) {
            L10nText(L10n.Compress.level)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing).padding(.top, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 95, maximum: 180), spacing: 6)], spacing: 6) {
                ForEach(levelsList, id: \.rawValue) { lvl in
                    self.levelTileView(fmt: fmt, lvl: lvl)
                }
            }
        }
    }
    
    func levelTileView(fmt: ArchiveCompressionFormat, lvl: ArchiveCompressionLevel) -> some View {
        let ratioPct = Int(round(lvl.compressionRatioPercent(for: fmt)))
        let titleName: String
        switch lvl {
        case .store: titleName = "\(l10n.t(L10n.Compress.levelStore))"
        case .level1: titleName = "\(l10n.t(L10n.Compress.levelFastest)) (\(ratioPct)%)"
        case .level6: titleName = "\(l10n.t(L10n.Compress.levelNormal)) (\(ratioPct)%)"
        case .level9: titleName = "\(l10n.t(L10n.Compress.levelUltra)) (\(ratioPct)%)"
        default: titleName = "Level \(lvl.rawValue) (\(ratioPct)%)"
        }
        
        let isSel = session.compressionLevel == lvl
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                session.compressionLevel = lvl
            }
        }) {
            Text(titleName).font(.system(size: 10.5, weight: isSel ? .bold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(isSel ? TTZipTheme.bambooGreen.opacity(0.14) : Color.primary.opacity(0.03))
                .foregroundStyle(isSel ? TTZipTheme.bambooGreen : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(isSel ? TTZipTheme.bambooGreen.opacity(0.4) : Color.clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}
