// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Compression summary statistics sheet view.
public struct CompressionSummarySheetView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let l10n = AppLocalizationState.shared
    
    public let archivePath: String
    public let originalSizeBytes: Int64
    public let compressedSizeBytes: Int64
    public let elapsedSeconds: Double
    public let throughputMBs: Double
    public let format: ArchiveCompressionFormat
    public let isEncrypted: Bool
    public let cleanupWarningMessage: String?
    public let sourcePreservationNotice: String?
    public let onCloseAndExplore: () -> Void

    public var hasNotices: Bool {
        cleanupWarningMessage != nil || sourcePreservationNotice != nil
    }

    public var renderedNotices: [String] {
        [sourcePreservationNotice, cleanupWarningMessage].compactMap { $0 }
    }
    
    public init(
        archivePath: String,
        originalSizeBytes: Int64,
        compressedSizeBytes: Int64,
        elapsedSeconds: Double,
        throughputMBs: Double,
        format: ArchiveCompressionFormat,
        isEncrypted: Bool,
        cleanupWarningMessage: String? = nil,
        sourcePreservationNotice: String? = nil,
        onCloseAndExplore: @escaping () -> Void
    ) {
        self.archivePath = archivePath
        self.originalSizeBytes = originalSizeBytes
        self.compressedSizeBytes = compressedSizeBytes
        self.elapsedSeconds = elapsedSeconds
        self.throughputMBs = throughputMBs
        self.format = format
        self.isEncrypted = isEncrypted
        self.cleanupWarningMessage = cleanupWarningMessage
        self.sourcePreservationNotice = sourcePreservationNotice
        self.onCloseAndExplore = onCloseAndExplore
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            headerBar
            Divider()
            metricsGrid
            if hasNotices {
                noticesSection
            }
            Divider()
            actionButton
        }
        .padding(20)
        .frame(width: 440)
        .background(modalBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(TTZipTheme.specularHairline, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.55 : 0.18), radius: 24, y: 12)
    }
    
    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26))
                .foregroundStyle(TTZipTheme.bambooGreen)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.uiString(zh: "压缩已完成", en: "Compression Completed", zhHant: "壓縮已完成", ja: "圧縮完了", ko: "압축 완료", de: "Komprimierung abgeschlossen", fr: "Compression terminée", es: "Compresión completada"))
                    .font(.title3).fontWeight(.bold)
                Text((archivePath as NSString).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
    }
    
    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard(
                title: l10n.uiString(zh: "平均吞吐率", en: "Throughput", zhHant: "平均吞吐率", ja: "平均スループット", ko: "평균 처리량", de: "Durchsatz", fr: "Débit", es: "Rendimiento"),
                value: String(format: "%.1f MB/s", throughputMBs),
                valueColor: TTZipTheme.bambooGreen
            )
            
            let ratio = originalSizeBytes > 0 ? (1.0 - Double(compressedSizeBytes) / Double(originalSizeBytes)) * 100.0 : 0.0
            metricCard(
                title: l10n.uiString(zh: "空间节省", en: "Space Savings", zhHant: "空間節省", ja: "容量節約", ko: "공간 절약", de: "Platzersparnis", fr: "Gain d'espace", es: "Ahorro de espacio"),
                value: String(format: "-%.1f%%", max(0, ratio)),
                valueColor: .purple
            )
            
            metricCard(
                title: l10n.uiString(zh: "体积变化", en: "Size Delta", zhHant: "體積變化", ja: "サイズ変化", ko: "크기 변화", de: "Größenänderung", fr: "Variation de taille", es: "Cambio de tamaño"),
                value: "\(ByteCountFormatterFlyweight.shared.string(fromByteCount: originalSizeBytes)) ➔ \(ByteCountFormatterFlyweight.shared.string(fromByteCount: compressedSizeBytes))",
                valueColor: .primary
            )
            
            let encryptionLabel = isEncrypted
                ? l10n.uiString(zh: "已加密", en: "Encrypted", zhHant: "已加密", ja: "暗号化", ko: "암호화됨", de: "Verschlüsselt", fr: "Chiffré", es: "Cifrado")
                : l10n.uiString(zh: "未加密", en: "Standard", zhHant: "未加密", ja: "標準", ko: "표준", de: "Standard", fr: "Standard", es: "Estándar")
            metricCard(
                title: l10n.uiString(zh: "耗时 / 加密", en: "Elapsed / Encryption", zhHant: "耗時 / 加密", ja: "経過時間 / 暗号化", ko: "경과 시간 / 암호화", de: "Dauer / Verschlüsselung", fr: "Durée / Chiffrement", es: "Tiempo / Cifrado"),
                value: String(format: "%.2fs · %@", elapsedSeconds, encryptionLabel),
                valueColor: isEncrypted ? .orange : .primary
            )
        }
    }
    
    private func metricCard(title: String, value: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var noticesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sourcePreservationNotice {
                noticeRow(
                    iconName: "info.circle.fill",
                    tint: TTZipTheme.kintsugiGold,
                    message: sourcePreservationNotice
                )
            }
            if let cleanupWarningMessage {
                noticeRow(
                    iconName: "exclamationmark.triangle.fill",
                    tint: .orange,
                    message: cleanupWarningMessage
                )
            }
        }
    }

    private func noticeRow(iconName: String, tint: Color, message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(colorScheme == .dark ? 0.14 : 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    private var actionButton: some View {
        Button(action: onCloseAndExplore) {
            HStack {
                Image(systemName: "folder.badge.gearshape")
                Text(l10n.uiString(zh: "完成并在访达中查看", en: "Done and Explore Archive", zhHant: "完成並在訪達中查看", ja: "完了してFinderで表示", ko: "완료 및 Finder에서 보기", de: "Fertig und im Finder anzeigen", fr: "Terminé et afficher dans le Finder", es: "Listo y mostrar en el Finder"))
                    .fontWeight(.bold)
            }
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(TTZipTheme.bambooGreen)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [.command])
    }
    
    private var modalBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color(red: 0.11, green: 0.12, blue: 0.11).opacity(0.94)
                        : Color(red: 0.96, green: 0.97, blue: 0.96).opacity(0.96)
                )
        }
    }
}
