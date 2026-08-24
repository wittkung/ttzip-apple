// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine for macOS.

import SwiftUI
import TTZipCore

public struct CompressIntegratedConfigSectionView: View {
    @ObservedObject var l10n = AppLocalizationState.shared
    
    @Binding var selectedFormat: ArchiveCompressionFormat
    @Binding var compressionLevel: ArchiveCompressionLevel
    @Binding var outputName: String
    @Binding var targetDirectory: String
    @Binding var enableEncryption: Bool
    @Binding var password: String
    @Binding var encryptFileNames: Bool
    @Binding var skipMacJunk: Bool
    @Binding var deleteSourceAfterCompress: Bool
    @Binding var openFinderAfterCompress: Bool
    @Binding var createSeparateArchives: Bool
    @Binding var splitVolumeOption: Int64?
    @Binding var cpuThreadsOption: String
    
    // Format-specific advanced parameters
    @Binding var compressionAlgorithm: String
    @Binding var dictionarySizeMB: Int
    @Binding var enableSolidArchive: Bool
    @Binding var zipEncryptionMethod: String
    @Binding var zipEncodingUTF8: Bool
    @Binding var zstdLevel: Int
    @Binding var zstdEnableLDM: Bool
    @Binding var preservePosixAttributes: Bool
    
    var onPickDirectory: () -> Void
    var onShowMatrix: () -> Void
    var onOpenPasswordVault: () -> Void
    
    @Binding var isCustomVolumeSelected: Bool
    @Binding var customVolumeValueString: String
    @Binding var customVolumeUnit: String
    let cachedTotalCores: Int
    
    public init(
        outputName: Binding<String>,
        targetDirectory: Binding<String>,
        selectedFormat: Binding<ArchiveCompressionFormat>,
        compressionLevel: Binding<ArchiveCompressionLevel>,
        compressionAlgorithm: Binding<String>,
        dictionarySizeMB: Binding<Int>,
        zipEncryptionMethod: Binding<String>,
        zipEncodingUTF8: Binding<Bool>,
        zstdLevel: Binding<Int>,
        zstdEnableLDM: Binding<Bool>,
        preservePosixAttributes: Binding<Bool>,
        cpuThreadsOption: Binding<String>,
        splitVolumeOption: Binding<Int64?>,
        isCustomVolumeSelected: Binding<Bool>,
        customVolumeValueString: Binding<String>,
        customVolumeUnit: Binding<String>,
        enableEncryption: Binding<Bool>,
        password: Binding<String>,
        enableSolidArchive: Binding<Bool>,
        encryptFileNames: Binding<Bool>,
        skipMacJunk: Binding<Bool>,
        createSeparateArchives: Binding<Bool>,
        deleteSourceAfterCompress: Binding<Bool>,
        openFinderAfterCompress: Binding<Bool>,
        cachedTotalCores: Int,
        onPickDirectory: @escaping () -> Void,
        onOpenPasswordVault: @escaping () -> Void,
        onShowMatrix: @escaping () -> Void
    ) {
        self._outputName = outputName
        self._targetDirectory = targetDirectory
        self._selectedFormat = selectedFormat
        self._compressionLevel = compressionLevel
        self._compressionAlgorithm = compressionAlgorithm
        self._dictionarySizeMB = dictionarySizeMB
        self._zipEncryptionMethod = zipEncryptionMethod
        self._zipEncodingUTF8 = zipEncodingUTF8
        self._zstdLevel = zstdLevel
        self._zstdEnableLDM = zstdEnableLDM
        self._preservePosixAttributes = preservePosixAttributes
        self._cpuThreadsOption = cpuThreadsOption
        self._splitVolumeOption = splitVolumeOption
        self._isCustomVolumeSelected = isCustomVolumeSelected
        self._customVolumeValueString = customVolumeValueString
        self._customVolumeUnit = customVolumeUnit
        self._enableEncryption = enableEncryption
        self._password = password
        self._enableSolidArchive = enableSolidArchive
        self._encryptFileNames = encryptFileNames
        self._skipMacJunk = skipMacJunk
        self._createSeparateArchives = createSeparateArchives
        self._deleteSourceAfterCompress = deleteSourceAfterCompress
        self._openFinderAfterCompress = openFinderAfterCompress
        self.cachedTotalCores = cachedTotalCores
        self.onPickDirectory = onPickDirectory
        self.onOpenPasswordVault = onOpenPasswordVault
        self.onShowMatrix = onShowMatrix
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(l10n.t(L10n.Compress.targetParameters), systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .bold, design: .serif))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Spacer()
            }
            
            // 1. Output Settings
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    L10nText(L10n.Explorer.nameHeader)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                    TextField(l10n.t(L10n.Compress.archiveNamePlaceholder), text: $outputName)
                        .textFieldStyle(.plain).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                
                HStack(spacing: 12) {
                    L10nText(L10n.Compress.targetFolder)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                    HStack(spacing: 6) {
                        TextField(l10n.t(L10n.Compress.targetFolder), text: $targetDirectory)
                            .textFieldStyle(.plain).font(.system(size: 11.5)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Button(l10n.t(L10n.Common.browse)) { onPickDirectory() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                
                HStack(alignment: .top, spacing: 12) {
                    L10nText(L10n.Compress.format)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing).padding(.top, 4)
                    let all16Formats: [ArchiveCompressionFormat] = [
                        .sevenZip, .zip, .tar, .zst, .gz, .bz2, .xz, .lzip,
                        .lz4, .brotli, .lrzip, .aar, .snappy, .wim, .dmg, .iso
                    ]
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70, maximum: 120), spacing: 6)], spacing: 6) {
                        ForEach(all16Formats, id: \.rawValue) { fmt in
                            formatTile(format: fmt)
                        }
                    }
                }
                
                compressionLevelSection(fmt: selectedFormat)
            }
            
            Divider()
            
            // 2. Format specific parameters
            formatSpecificAdvancedSection
            
            Divider()
            
            // 3. Hardware & Automation policies
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    L10nText(L10n.Compress.cpuThreads)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                    Picker("", selection: $cpuThreadsOption) {
                        Text(l10n.format(L10n.Benchmark.hardwareCoresFormat, cachedTotalCores, cachedTotalCores, 0)).tag("all")
                        Text("50% Load").tag("half")
                        Text("1 Thread").tag("single")
                    }
                    .pickerStyle(.segmented).tint(TTZipTheme.bambooGreen)
                }
                
                HStack(alignment: .top, spacing: 12) {
                    L10nText(L10n.Compress.splitVolume)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            volTile(size: nil, name: l10n.t(L10n.Compress.splitVolumeNone))
                            volTile(size: 700 * 1024 * 1024, name: "700 MB")
                            volTile(size: 4700 * 1024 * 1024, name: "4.7 GB")
                            volTile(size: 4000 * 1024 * 1024, name: "4 GB (FAT32)")
                            volTile(size: -1, name: l10n.t(L10n.Compress.splitVolumeCustom))
                        }
                        if isCustomVolumeSelected {
                            HStack(spacing: 4) {
                                TextField("100", text: $customVolumeValueString).textFieldStyle(.plain).font(.system(size: 11))
                                    .padding(.horizontal, 6).padding(.vertical, 3).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6)).frame(width: 60)
                                Picker("", selection: $customVolumeUnit) { Text("MB").tag("MB"); Text("GB").tag("GB") }.pickerStyle(.segmented).tint(TTZipTheme.bambooGreen).frame(width: 70)
                            }
                        }
                    }
                }
                
                HStack(spacing: 12) {
                    L10nText(L10n.Compress.encryption)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                    HStack(spacing: 10) {
                        Toggle(l10n.t(L10n.Compress.encryption), isOn: $enableEncryption).font(.system(size: 11, weight: .bold)).tint(TTZipTheme.bambooGreen)
                        if enableEncryption {
                            TTSecureTextField(l10n.t(L10n.Vault.passwordPlaceholder), text: $password).font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6))
                            Button(action: onOpenPasswordVault) {
                                HStack(spacing: 3) { Image(systemName: "key.fill"); Text(l10n.t(L10n.Sidebar.vault)) }
                                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(TTZipTheme.kintsugiGold).padding(.horizontal, 7).padding(.vertical, 3).background(TTZipTheme.kintsugiGold.opacity(0.12)).clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    Toggle(l10n.t(L10n.Compress.filterMacJunk), isOn: $skipMacJunk).tint(TTZipTheme.bambooGreen)
                    Toggle(l10n.t(L10n.Compress.createSeparateArchives), isOn: $createSeparateArchives).tint(TTZipTheme.bambooGreen)
                    Toggle(l10n.t(L10n.Compress.deleteSource), isOn: $deleteSourceAfterCompress).tint(TTZipTheme.bambooGreen)
                    Toggle(l10n.t(L10n.Compress.openFinder), isOn: $openFinderAfterCompress).tint(TTZipTheme.bambooGreen)
                }
                .font(.system(size: 11)).padding(.top, 4)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
