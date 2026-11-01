// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Observation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

extension CompressIntegratedConfigSectionView {
    
    // MARK: - Format Constants
    
    /// Top 3 primary golden formats representing the vast majority of user workflows.
    public static let primaryFormats: [ArchiveCompressionFormat] = [
        .sevenZip, .zip, .tarGz
    ]
    
    /// Secondary creatable container formats grouped into the dropdown tray (read-only formats like DMG, CAB, WIM, DEB, RPM are excluded).
    public static let secondaryFormats: [ArchiveCompressionFormat] = [
        .tarXz, .tarZst, .tarBz2, .tar,
        .tarLz4, .tarBrotli, .tarLzip, .tarLrzip,
        .iso, .aar, .cpio, .ar, .xar
    ]

    /// Standalone single-file compression stream formats (enabled only when compressing a single regular file).
    public static let singleStreamFormats: [ArchiveCompressionFormat] = [
        .gz, .bz2, .xz, .zst, .lz4, .brotli, .lzip, .lrzip, .snappy
    ]
    
    // MARK: - Format Selection Hierarchy
    
    /// Progressive format selection bar: 3 golden pills + active secondary pill + creatable formats dropdown menu.
    var formatSelectionSection: some View {
        HStack(alignment: .top, spacing: 10) {
            L10nText(L10n.Compress.format)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(Self.primaryFormats, id: \.rawValue) { fmt in
                        primaryFormatPill(format: fmt)
                    }
                    
                    let isSecondarySelected = Self.secondaryFormats.contains(session.selectedFormat)
                        || Self.singleStreamFormats.contains(session.selectedFormat)
                    if isSecondarySelected {
                        secondarySelectedPill(format: session.selectedFormat)
                    }
                    
                    moreFormatsMenu(isSecondarySelected: isSecondarySelected)
                    
                    Spacer()
                }
                .frame(height: 32)
                
                activeFormatBanner
            }
        }
    }
    
    /// High-frequency primary format pill with icon, display name, and capability badge.
    func primaryFormatPill(format: ArchiveCompressionFormat) -> some View {
        let isSel = session.selectedFormat == format
        return Button {
            selectFormat(format)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: format.iconName)
                    .font(.system(size: 10, weight: .semibold))
                Text(format.displayName)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                
                let subtitle = formatBadgeSubtitle(format)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(isSel ? TTZipTheme.bambooGreen.opacity(0.85) : .secondary)
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(isSel ? TTZipTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(isSel ? TTZipTheme.bambooGreen.opacity(0.14) : Color.primary.opacity(0.035))
            .foregroundStyle(isSel ? TTZipTheme.bambooGreen : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSel ? TTZipTheme.bambooGreen.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("\(format.displayName) (\(format.fileExtension)): \(format.formatDescription)")
    }
    
    /// Highlighted pill rendered when a secondary long-tail format is actively chosen.
    func secondarySelectedPill(format: ArchiveCompressionFormat) -> some View {
        HStack(spacing: 4) {
            Image(systemName: format.iconName)
                .font(.system(size: 9.5, weight: .semibold))
            Text(format.displayName)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
            Text(format.fileExtension)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(TTZipTheme.bambooGreen)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(TTZipTheme.bambooGreen.opacity(0.12))
                .clipShape(Capsule())
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(TTZipTheme.bambooGreen.opacity(0.14))
        .foregroundStyle(TTZipTheme.bambooGreen)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(TTZipTheme.bambooGreen.opacity(0.5), lineWidth: 1)
        )
        .fixedSize()
    }
    
    /// Dropdown tray encapsulating secondary container formats and single-file stream formats.
    func moreFormatsMenu(isSecondarySelected: Bool) -> some View {
        Menu {
            ForEach(Self.secondaryFormats, id: \.rawValue) { fmt in
                Button {
                    selectFormat(fmt)
                } label: {
                    HStack {
                        Text("\(fmt.displayName) (\(fmt.fileExtension))")
                        Spacer()
                        Text(fmt.shortcutBadge)
                    }
                }
            }
            Divider()
            ForEach(Self.singleStreamFormats, id: \.rawValue) { fmt in
                Button {
                    selectFormat(fmt)
                } label: {
                    HStack {
                        Text("\(fmt.displayName) (\(fmt.fileExtension))")
                        Spacer()
                        Text(fmt.shortcutBadge)
                    }
                }
                .disabled(!session.isSingleRegularFileInput)
            }
        } label: {
            HStack(spacing: 3) {
                Text(moreFormatsTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .padding(.horizontal, 7)
            .frame(height: 32)
            .background(isSecondarySelected ? Color.primary.opacity(0.02) : Color.primary.opacity(0.04))
            .foregroundStyle(isSecondarySelected ? Color.secondary : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    /// Ultra-compact status strip displaying active format capabilities and description.
    var activeFormatBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: session.selectedFormat.iconName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text(session.selectedFormat.formatDescription)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(session.selectedFormat.fileExtension)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(TTZipTheme.bambooGreen)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(TTZipTheme.bambooGreen.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    
    /// Switches archive compression format and clamps level/capabilities to supported spectrum.
    func selectFormat(_ format: ArchiveCompressionFormat) {
        guard !format.isReadOnly else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            session.selectedFormat = format
            if !format.supportedLevels.contains(session.compressionLevel) {
                session.compressionLevel = format.supportedLevels.first ?? .store
            }
            session.reconcileSelectedFormatWithInputs()
        }
    }
    
    /// Localized badge subtitle for primary format pills.
    func formatBadgeSubtitle(_ format: ArchiveCompressionFormat) -> String {
        switch format {
        case .sevenZip:
            switch l10n.currentLanguage {
            case .zhHans: return "推荐"
            case .zhHant: return "推薦"
            default: return "Best"
            }
        case .zip:
            switch l10n.currentLanguage {
            case .zhHans: return "通用"
            case .zhHant: return "通用"
            default: return "Universal"
            }
        case .tarGz:
            return "Unix"
        default:
            return ""
        }
    }
    
    /// Localized title for more formats menu.
    var moreFormatsTitle: String {
        let count = Self.secondaryFormats.count + Self.singleStreamFormats.count
        switch l10n.currentLanguage {
        case .zhHans:
            return "更多 (\(count))"
        case .zhHant:
            return "更多 (\(count))"
        default:
            return "More (\(count))"
        }
    }
    
    // MARK: - Split Volume Section (Primary Core Configuration)
    
    /// Primary split-volume preset pills and inline custom size input exposed directly on the main card.
    var splitVolumeSection: some View {
        HStack(alignment: .top, spacing: 10) {
            L10nText(L10n.Compress.splitVolume)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .padding(.top, 5)
            
            VStack(alignment: .leading, spacing: 6) {
                TTFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    volTile(size: nil, name: l10n.t(L10n.Compress.splitVolumeNone))
                    volTile(size: 700 * 1024 * 1024, name: "700 MB")
                    volTile(size: 4700 * 1024 * 1024, name: "4.7 GB")
                    volTile(size: 4000 * 1024 * 1024, name: "4 GB (FAT32)")
                    volTile(size: -1, name: l10n.t(L10n.Compress.splitVolumeCustom))
                }
                .disabled(!session.selectedFormat.supportsSplitVolume)
                
                if session.isCustomVolumeSelected && session.selectedFormat.supportsSplitVolume {
                    HStack(spacing: 6) {
                        TextField("100", text: $session.customVolumeValueString)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .customVolume)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(width: 78)
                            .background(Color.primary.opacity(0.045))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        focusedField == .customVolume
                                            ? TTZipTheme.bambooGreen.opacity(0.6)
                                            : TTZipTheme.specularHairline,
                                        lineWidth: 0.5
                                    )
                            )
                            .onChange(of: session.customVolumeValueString) { _, _ in
                                session.calculateCustomVolume()
                            }
                        
                        Picker("", selection: $session.customVolumeUnit) {
                            Text("MB").tag("MB")
                            Text("GB").tag("GB")
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .tint(TTZipTheme.bambooGreen)
                        .frame(width: 76)
                        .onChange(of: session.customVolumeUnit) { _, _ in
                            session.calculateCustomVolume()
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Encryption Section (Primary Core Configuration)
    
    /// Core password and cryptographic protection controls exposed directly on the primary viewport.
    var encryptionSection: some View {
        HStack(alignment: .top, spacing: 10) {
            L10nText(L10n.Compress.encryption)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .lineLimit(1)
                .padding(.top, 5)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("", isOn: $session.enableEncryption)
                        .labelsHidden()
                        .tint(TTZipTheme.bambooGreen)
                        .disabled(!session.selectedFormat.supportsPasswordEncryption)
                        .fixedSize()
                        .onChange(of: session.enableEncryption) { _, enabled in
                            if enabled {
                                DispatchQueue.main.async {
                                    focusedField = .password
                                }
                            }
                        }
                    
                    if session.selectedFormat.supportsPasswordEncryption {
                        TTSecureTextField(l10n.t(L10n.Vault.passwordPlaceholder), text: $session.password)
                            .focused($focusedField, equals: .password)
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.045))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        focusedField == .password
                                            ? TTZipTheme.bambooGreen.opacity(0.6)
                                            : TTZipTheme.specularHairline,
                                        lineWidth: 0.5
                                    )
                            )
                            .onChange(of: session.password) { _, newValue in
                                if !newValue.isEmpty && !session.enableEncryption {
                                    session.enableEncryption = true
                                }
                            }
                        
                        Button(action: {
                            session.enableEncryption = true
                            session.isPasswordVaultPresented = true
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "key.fill")
                                Text(l10n.t(L10n.Sidebar.vault))
                            }
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(TTZipTheme.kintsugiGold.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                    } else {
                        Text(l10n.uiString(
                            zh: "当前格式不支持密码加密",
                            en: "Selected format does not support encryption",
                            zhHant: "目前格式不支援密碼加密",
                            ja: "選択した形式は暗号化に対応していません",
                            ko: "선택한 형식은 암호화를 지원하지 않습니다",
                            de: "Format unterstützt keine Verschlüsselung",
                            fr: "Ce format ne prend pas en charge le chiffrement",
                            es: "El formato no admite cifrado"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
                
                if session.enableEncryption && session.selectedFormat.supportsPasswordEncryption {
                    HStack(spacing: 16) {
                        if session.selectedFormat == .sevenZip {
                            Toggle(l10n.t(L10n.Compress.encryptFileNames7z), isOn: $session.encryptFileNames)
                                .font(.system(size: 11))
                                .tint(TTZipTheme.bambooGreen)
                        } else if session.selectedFormat == .zip {
                            HStack(spacing: 6) {
                                Text(l10n.t(L10n.Compress.zipMethod))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $session.zipEncryptionMethod) {
                                    Text(l10n.t(L10n.Compress.zipMethodAes)).tag("AES-256")
                                    Text(l10n.t(L10n.Compress.zipMethodZipCrypto)).tag("ZipCrypto")
                                }
                                .pickerStyle(.segmented)
                                .controlSize(.small)
                                .tint(TTZipTheme.bambooGreen)
                                .frame(width: 220)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
    
    // MARK: - Advanced Archiving Drawer
    
    /// Collapsible drawer housing secondary format-specific parameters and cleanup automations.
    var advancedDisclosureDrawer: some View {
        DisclosureGroup(isExpanded: $isAdvancedExpanded.animation(.easeInOut(duration: 0.2))) {
            VStack(alignment: .leading, spacing: 12) {
                advancedOptionsContent
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.2.square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text(advancedOptionsTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if !isAdvancedExpanded {
                    Text(advancedOptionsSummary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(Capsule())
                }
            }
            .contentShape(Rectangle())
        }
    }
    
    /// Title string for advanced archiving drawer.
    var advancedOptionsTitle: String {
        let base = l10n.t(L10n.FinderSync.compressAdvancedTitle)
        let trimmed = base.replacingOccurrences(of: "...", with: "")
        if !trimmed.isEmpty { return trimmed }
        switch l10n.currentLanguage {
        case .zhHans: return "高级归档选项"
        case .zhHant: return "高級封存選項"
        default: return "Advanced Archiving Options"
        }
    }
    
    /// Compact summary badge displayed when advanced drawer is collapsed.
    var advancedOptionsSummary: String {
        var parts: [String] = []
        if session.selectedFormat == .sevenZip && session.enableSolidArchive {
            parts.append("Solid")
        }
        if session.skipMacJunk {
            parts.append("Clean Junk")
        }
        return parts.isEmpty ? "Default" : parts.joined(separator: " • ")
    }
    
    /// Content inside the advanced drawer.
    @ViewBuilder
    var advancedOptionsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Format-specific advanced algorithms and parameters
            if shouldShowFormatSpecificSection {
                formatSpecificAdvancedSection
                Divider()
            }
            
            // 4 Automation & Cleanup policies
            HStack(alignment: .top, spacing: 10) {
                Text(automationLabelTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .trailing)
                    .padding(.top, 2)
                
                TTFlowLayout(horizontalSpacing: 12, verticalSpacing: 6) {
                    Toggle(l10n.t(L10n.Compress.filterMacJunk), isOn: $session.skipMacJunk)
                        .tint(TTZipTheme.bambooGreen)
                    Toggle(l10n.t(L10n.Compress.createSeparateArchives), isOn: $session.createSeparateArchives)
                        .tint(TTZipTheme.bambooGreen)
                    Toggle(l10n.t(L10n.Compress.deleteSource), isOn: $session.deleteSourceAfterCompress)
                        .tint(TTZipTheme.bambooGreen)
                    Toggle(l10n.t(L10n.Compress.openFinder), isOn: $session.openFinderAfterCompress)
                        .tint(TTZipTheme.bambooGreen)
                }
                .font(.system(size: 11))
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    /// Localized label title for automation section.
    var automationLabelTitle: String {
        switch l10n.currentLanguage {
        case .zhHans: return "清理策略"
        case .zhHant: return "清理策略"
        default: return "Policies"
        }
    }
    
    // MARK: - Legacy / Reused Format Components
    
    var shouldShowFormatSpecificSection: Bool {
        guard session.compressionLevel != .store else { return false }
        return session.selectedFormat == .sevenZip || session.selectedFormat == .zst || session.selectedFormat == .tarZst
    }
    
    @ViewBuilder
    var formatSpecificAdvancedSection: some View {
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
            case .zst, .tarZst:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text(l10n.t(L10n.Compress.zstdLevel))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 75, alignment: .trailing)
                        Picker("", selection: $session.zstdLevel) {
                            Text("1").tag(1)
                            Text("3").tag(3)
                            Text("9").tag(9)
                            Text("19").tag(19)
                        }
                        .pickerStyle(.segmented)
                        .tint(TTZipTheme.bambooGreen)
                    }
                    Toggle(l10n.t(L10n.Compress.zstdLdm), isOn: $session.zstdEnableLDM)
                        .font(.system(size: 11))
                        .tint(TTZipTheme.bambooGreen)
                }
            default:
                EmptyView()
            }
        }
        .padding(10)
        .background(TTZipTheme.bambooGreen.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
