// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import Observation
import TTZipCore

public struct CompressIntegratedConfigSectionView: View {
    @ObservedObject var l10n = AppLocalizationState.shared
    
    @Bindable public var session: CompressFormSession
    
    public init(session: CompressFormSession) {
        self.session = session
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
                    TextField(l10n.t(L10n.Compress.archiveNamePlaceholder), text: $session.outputName)
                        .textFieldStyle(.plain).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                
                HStack(spacing: 12) {
                    L10nText(L10n.Compress.targetFolder)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                    HStack(spacing: 6) {
                        TextField(l10n.t(L10n.Compress.targetFolder), text: $session.targetDirectory)
                            .textFieldStyle(.plain).font(.system(size: 11.5)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Button(l10n.t(L10n.Common.browse)) { session.pickDirectory() }
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
                
                compressionLevelSection(fmt: session.selectedFormat)
            }
            
            // 2. Format specific parameters (Only for formats with active compression algorithms when not store)
            if shouldShowFormatSpecificSection {
                Divider()
                formatSpecificAdvancedSection
            }
            
            Divider()
            
            // 3. Hardware & Automation policies
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    L10nText(L10n.Compress.cpuThreads)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
                    Picker("", selection: $session.cpuThreadsOption) {
                        Text(l10n.format(L10n.Benchmark.hardwareCoresFormat, session.cachedTotalCores, session.cachedTotalCores, 0)).tag("all")
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
                        if session.isCustomVolumeSelected {
                            HStack(spacing: 4) {
                                TextField("100", text: $session.customVolumeValueString).textFieldStyle(.plain).font(.system(size: 11))
                                    .padding(.horizontal, 6).padding(.vertical, 3).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6)).frame(width: 60)
                                    .onChange(of: session.customVolumeValueString) { _, _ in session.calculateCustomVolume() }
                                Picker("", selection: $session.customVolumeUnit) { Text("MB").tag("MB"); Text("GB").tag("GB") }.pickerStyle(.segmented).tint(TTZipTheme.bambooGreen).frame(width: 70)
                                    .onChange(of: session.customVolumeUnit) { _, _ in session.calculateCustomVolume() }
                            }
                        }
                    }
                }
                
                HStack(alignment: .top, spacing: 12) {
                    L10nText(L10n.Compress.encryption)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Toggle(l10n.t(L10n.Compress.encryption), isOn: $session.enableEncryption.animation(.easeInOut(duration: 0.2)))
                                .font(.system(size: 11, weight: .bold)).tint(TTZipTheme.bambooGreen)
                            if session.enableEncryption {
                                TTSecureTextField(l10n.t(L10n.Vault.passwordPlaceholder), text: $session.password)
                                    .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 6))
                                Button(action: { session.isPasswordVaultPresented = true }) {
                                    HStack(spacing: 3) { Image(systemName: "key.fill"); Text(l10n.t(L10n.Sidebar.vault)) }
                                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(TTZipTheme.kintsugiGold).padding(.horizontal, 7).padding(.vertical, 3).background(TTZipTheme.kintsugiGold.opacity(0.12)).clipShape(Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                        
                        if session.enableEncryption {
                            HStack(spacing: 16) {
                                if session.selectedFormat == .sevenZip {
                                    Toggle(l10n.t(L10n.Compress.encryptFileNames7z), isOn: $session.encryptFileNames)
                                        .font(.system(size: 11)).tint(TTZipTheme.bambooGreen)
                                } else if session.selectedFormat == .zip {
                                    HStack(spacing: 6) {
                                        Text(l10n.t(L10n.Compress.zipMethod)).font(.system(size: 11)).foregroundStyle(.secondary)
                                        Picker("", selection: $session.zipEncryptionMethod) {
                                            Text(l10n.t(L10n.Compress.zipMethodAes)).tag("AES-256")
                                            Text(l10n.t(L10n.Compress.zipMethodZipCrypto)).tag("ZipCrypto")
                                        }
                                        .pickerStyle(.segmented).controlSize(.small).tint(TTZipTheme.bambooGreen).frame(width: 220)
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    Toggle(l10n.t(L10n.Compress.filterMacJunk), isOn: $session.skipMacJunk).tint(TTZipTheme.bambooGreen)
                    Toggle(l10n.t(L10n.Compress.createSeparateArchives), isOn: $session.createSeparateArchives).tint(TTZipTheme.bambooGreen)
                    Toggle(l10n.t(L10n.Compress.deleteSource), isOn: $session.deleteSourceAfterCompress).tint(TTZipTheme.bambooGreen)
                    Toggle(l10n.t(L10n.Compress.openFinder), isOn: $session.openFinderAfterCompress).tint(TTZipTheme.bambooGreen)
                }
                .font(.system(size: 11)).padding(.top, 4)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
