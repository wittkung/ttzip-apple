// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI
import TTKitUI

extension CompressIntegratedConfigSectionView {
    // MARK: - Legacy / Reused Format Components

    var shouldShowFormatSpecificSection: Bool {
        guard session.compressionLevel != .store else { return false }
        return session.selectedFormat == .sevenZip || session.selectedFormat == .zst || session.selectedFormat == .tarZst
    }

    @ViewBuilder
    package var formatSpecificAdvancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text("\(session.selectedFormat.rawValue.uppercased()) \(l10n.t(L10n.Compress.targetParameters))")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: { session.isAlgorithmMatrixPresented = true }) {
                    Text(l10n.t(L10n.Benchmark.benchmarkMatrixTitle))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            switch session.selectedFormat {
            case .sevenZip:
                sevenZipFormatOptions
            case .zst, .tarZst:
                zstdFormatOptions
            default:
                EmptyView()
            }
        }
        .padding(10)
        .background(TTZipTheme.bambooGreen.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var sevenZipFormatOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(l10n.t(L10n.Compress.algorithm))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 75, alignment: .trailing)
                Picker("", selection: $session.compressionAlgorithm) {
                    Text("LZMA2").tag("LZMA2")
                    Text("LZMA").tag("LZMA")
                    Text("PPMd").tag("PPMd")
                    Text("BZip2").tag("BZip2")
                }
                .pickerStyle(.menu)
                .controlSize(.small)

                Spacer()
            }

            HStack(spacing: 12) {
                L10nText(L10n.Compress.dictionarySize)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 75, alignment: .trailing)

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
                .pickerStyle(.menu)
                .controlSize(.small)

                Spacer()
            }

            Toggle(l10n.t(L10n.Compress.solidArchiveDesc), isOn: $session.enableSolidArchive)
                .font(.system(size: 11))
                .tint(TTZipTheme.bambooGreen)
        }
    }

    private var zstdFormatOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(l10n.t(L10n.Compress.zstdLevel))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 75, alignment: .trailing)
                TTSegmentedSwitch(
                    options: [1, 3, 9, 19],
                    selection: $session.zstdLevel,
                    title: { "\($0)" },
                    tint: TTZipTheme.bambooGreen,
                    size: .small
                )
            }
            Toggle(l10n.t(L10n.Compress.zstdLdm), isOn: $session.zstdEnableLDM)
                .font(.system(size: 11))
                .tint(TTZipTheme.bambooGreen)
        }
    }

    func volTile(size: Int64?, name: String) -> some View {
        let isSel = (size == -1) ? session.isCustomVolumeSelected : (!session.isCustomVolumeSelected && session.splitVolumeOption == size)
        return Button(action: {
            if size == -1 {
                session.isCustomVolumeSelected = true
                session.calculateCustomVolume()
                DispatchQueue.main.async {
                    focusedField = .customVolume
                }
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
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isSel ? TTZipTheme.bambooGreen.opacity(0.4) : Color.clear, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    func compressionLevelSection(fmt: ArchiveCompressionFormat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            L10nText(L10n.Compress.level)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .padding(.top, 4)

            CompressionLevelDualModeSelector(
                compressionLevel: $session.compressionLevel,
                format: fmt
            )
        }
    }
}
