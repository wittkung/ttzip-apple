// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore

extension SettingsView {
    @ViewBuilder
    var generalSection: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.md) {
            Label(l10n.t(L10n.Settings.smartStoreBypass), systemImage: "bolt.badge.automatic.fill")
                .font(TTZipTheme.Typography.sectionHeader)
                .foregroundStyle(TTZipTheme.bambooGreen)
            
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: 0.5)
            
            Toggle(isOn: $isSmartStoreBypassEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t(L10n.Compress.smartStoreBypassTitle))
                        .font(TTZipTheme.Typography.bodyMedium)
                    Text(l10n.t(L10n.Settings.bypassHighEntropyDesc))
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }
    
    @ViewBuilder
    var localizationSection: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.md) {
            Label(l10n.t(L10n.Settings.localization), systemImage: "globe")
                .font(TTZipTheme.Typography.sectionHeader)
                .foregroundStyle(TTZipTheme.bambooGreen)
            
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: 0.5)
            
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(l10n.t(L10n.Settings.language) + ":")
                        .font(TTZipTheme.Typography.bodyMedium)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { l10n.currentLanguage },
                        set: { l10n.setLanguage($0) }
                    )) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .frame(width: 180)
                }
                
                HStack {
                    Text(l10n.t(L10n.Settings.byteUnits) + ":")
                        .font(TTZipTheme.Typography.bodyMedium)
                    Spacer()
                    Picker("", selection: $l10n.byteUnitStandard) {
                        Text(l10n.t(L10n.Settings.unitSI)).tag(ByteSizeStandard.metricSI)
                        Text(l10n.t(L10n.Settings.unitIEC)).tag(ByteSizeStandard.binaryIEC)
                    }
                    .frame(width: 240)
                }
                
                Text(l10n.t(L10n.Settings.instantSwitchNote))
                    .font(TTZipTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    @ViewBuilder
    var presetsSection: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.md) {
            Label(l10n.t(L10n.Presets.title), systemImage: "slider.horizontal.3")
                .font(TTZipTheme.Typography.sectionHeader)
                .foregroundStyle(TTZipTheme.bambooGreen)
            
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: 0.5)
            
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    Text(l10n.t(L10n.Settings.defaultFormat) + ":")
                        .font(TTZipTheme.Typography.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $defaultFormat) {
                        Text("ZIP (PKWARE)").tag(ArchiveCompressionFormat.zip)
                        Text("7Z (LZMA2)").tag(ArchiveCompressionFormat.sevenZip)
                        Text("TAR.ZST (Direct)").tag(ArchiveCompressionFormat.tarZst)
                    }
                    .frame(width: 180)
                }
                
                GridRow {
                    Text(l10n.t(L10n.Compress.level) + ":")
                        .font(TTZipTheme.Typography.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $defaultLevel) {
                        Text(l10n.t(L10n.Compress.levelStore)).tag(ArchiveCompressionLevel.store)
                        Text(l10n.t(L10n.Compress.levelFastest)).tag(ArchiveCompressionLevel.fastest)
                        Text(l10n.t(L10n.Compress.levelNormal)).tag(ArchiveCompressionLevel.normal)
                        Text(l10n.t(L10n.Compress.levelMaximum)).tag(ArchiveCompressionLevel.maximum)
                        Text(l10n.t(L10n.Compress.levelUltra)).tag(ArchiveCompressionLevel.ultra)
                    }
                    .frame(width: 180)
                }
            }
        }
    }
    
    @ViewBuilder
    var vaultSection: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.md) {
            Label(l10n.t(L10n.Vault.vaultSecurityHeader), systemImage: "lock.shield.fill")
                .font(TTZipTheme.Typography.sectionHeader)
                .foregroundStyle(TTZipTheme.bambooGreen)
            
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: 0.5)
            
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.t(L10n.Vault.pbkdf2Desc))
                    .font(TTZipTheme.Typography.caption)
                Text(l10n.t(L10n.Vault.volatileZeroingDesc))
                    .font(TTZipTheme.Typography.caption)
                Text(l10n.t(L10n.Vault.aesGcmStorageDesc))
                    .font(TTZipTheme.Typography.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    var licenseAndHardwareSection: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.md) {
            HStack {
                Label(l10n.t(L10n.Settings.licenseStatus), systemImage: "checkmark.seal.fill")
                    .font(TTZipTheme.Typography.sectionHeader)
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(TTZipTheme.bambooGreen)
                        .frame(width: 8, height: 8)
                    Text(isPro ? l10n.t(L10n.Settings.proLicenseActive) : l10n.t(L10n.Settings.freeEdition))
                        .font(TTZipTheme.Typography.caption)
                        .bold()
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
                .padding(.horizontal, TTZipTheme.Spacing.xs)
                .padding(.vertical, 4)
                .background(TTZipTheme.bambooGreen.opacity(0.12))
                .clipShape(Capsule())
            }
            
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: 0.5)
            
            #if MAS_BUILD
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t(L10n.Settings.macAppStoreLicenseActive))
                        .font(TTZipTheme.Typography.bodyMedium)
                    Text("Pro Lifetime License · Apple Sandbox Protection Active")
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            #elseif STEAM_BUILD
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Steam Store Edition")
                        .font(TTZipTheme.Typography.bodyMedium)
                    Text("Pro Lifetime License · Steam Verified & DRM-Free")
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            #else
            let state = Ed25519LicenseManager.shared.currentState
            switch state {
            case .directPro(let payload):
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.t(L10n.Settings.licenseStatusActive))
                            .font(TTZipTheme.Typography.bodyMedium)
                        Text("Registered to \(payload.email) · Order \(payload.order_id)")
                            .font(TTZipTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(l10n.t(L10n.Settings.deactivateButton)) {
                        Ed25519LicenseManager.shared.deactivate()
                        isPro = false
                        activationStatus = "Deactivated. Reverted to Community Edition."
                    }
                    .buttonStyle(.plain)
                    .font(TTZipTheme.Typography.caption)
                    .padding(.horizontal, TTZipTheme.Spacing.sm)
                    .padding(.vertical, TTZipTheme.Spacing.xxs)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
                }
            default:
                VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Community Edition")
                                .font(TTZipTheme.Typography.bodyMedium)
                            Text("All core archiving and compression capabilities are 100% unrestricted.")
                                .font(TTZipTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Free & Open Source")
                            .font(TTZipTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(Capsule())
                    }
                    
                    Text("Enter Ed25519 License Key (TTZIP1-...) to unlock Pro badge & priority support:")
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    
                    HStack(spacing: TTZipTheme.Spacing.xs) {
                        TextField("TTZIP1-<Payload>.<Signature>", text: $licenseKeyInput)
                            .font(TTZipTheme.Typography.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        
                        Button(action: activateLicense) {
                            Text(l10n.t(L10n.Settings.activateProButton))
                                .font(TTZipTheme.Typography.callout)
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, TTZipTheme.Spacing.sm)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .background(TTZipTheme.bambooGradient)
                        .clipShape(Capsule())
                    }
                }
            }
            
            if !activationStatus.isEmpty {
                Text(activationStatus)
                    .font(TTZipTheme.Typography.caption)
                    .foregroundStyle(isPro ? TTZipTheme.bambooGreen : TTZipTheme.cinnabarRed)
            }
            #endif
            
            Spacer().frame(height: 12)
            
            Label(l10n.t(L10n.Settings.hardwareTopology), systemImage: "cpu.fill")
                .font(TTZipTheme.Typography.sectionHeader)
                .foregroundStyle(TTZipTheme.bambooGreen)
            
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: 0.5)
            
            let tuner = AppleSiliconTuner.shared
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    Text(l10n.t(L10n.Settings.chipModel) + ":")
                        .font(TTZipTheme.Typography.subheadline)
                        .foregroundStyle(.secondary)
                    Text(tuner.topology.chipName)
                        .font(TTZipTheme.Typography.bodyMedium)
                }
                
                GridRow {
                    Text(l10n.t(L10n.Settings.cpuCores) + ":")
                        .font(TTZipTheme.Typography.subheadline)
                        .foregroundStyle(.secondary)
                    Text(l10n.format(L10n.Benchmark.hardwareCoresFormat, tuner.topology.totalCores, tuner.topology.performanceCores, tuner.topology.efficiencyCores))
                        .font(TTZipTheme.Typography.body)
                }
                
                GridRow {
                    Text(l10n.t(L10n.Settings.unifiedMemory) + ":")
                        .font(TTZipTheme.Typography.subheadline)
                        .foregroundStyle(.secondary)
                    Text(l10n.format(L10n.Benchmark.hardwareMemoryFormat, tuner.topology.unifiedMemoryGB))
                        .font(TTZipTheme.Typography.body)
                }
            }
        }
    }
}
