// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

public struct CompressionProgressModalView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let l10n = AppLocalizationState.shared
    
    let outputFileName: String
    let progress: ArchiveProgress
    public let isCancellationRequested: Bool
    let onCancel: () -> Void
    let onMinimize: () -> Void
    
    public init(
        outputFileName: String,
        progress: ArchiveProgress,
        isCancellationRequested: Bool = false,
        onCancel: @escaping () -> Void,
        onMinimize: @escaping () -> Void
    ) {
        self.outputFileName = outputFileName
        self.progress = progress
        self.isCancellationRequested = isCancellationRequested
        self.onCancel = onCancel
        self.onMinimize = onMinimize
    }
    
    private var formattedBytesProcessed: String {
        ByteCountFormatterFlyweight.shared.string(fromByteCount: progress.bytesProcessed)
    }
    
    private var formattedTotalBytes: String {
        ByteCountFormatterFlyweight.shared.string(fromByteCount: max(progress.totalBytes, progress.bytesProcessed))
    }
    
    private var estimatedRemainingSeconds: String {
        if progress.totalBytes > 0 && progress.bytesProcessed >= progress.totalBytes {
            return l10n.uiString(zh: "即将完成", en: "Almost done", zhHant: "即將完成", ja: "まもなく完了", ko: "거의 완료됨", de: "Fast fertig", fr: "Presque terminé", es: "Casi listo")
        }
        guard progress.throughputMBs > 0, progress.totalBytes > progress.bytesProcessed else {
            return l10n.t(L10n.Common.calculating)
        }
        let remainingBytes = Double(progress.totalBytes - progress.bytesProcessed)
        let remainingMB = remainingBytes / (1024 * 1024)
        let seconds = remainingMB / progress.throughputMBs
        if seconds < 1 {
            return l10n.uiString(zh: "即将完成", en: "Almost done", zhHant: "即將完成", ja: "まもなく完了", ko: "거의 완료됨", de: "Fast fertig", fr: "Presque terminé", es: "Casi listo")
        }
        if seconds < 60 {
            return String(format: l10n.uiString(zh: "约 %d 秒", en: "About %ds", zhHant: "約 %d 秒", ja: "約 %d 秒", ko: "약 %d초", de: "Etwa %d Sek.", fr: "Environ %d s", es: "Unos %d s"), Int(seconds))
        }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: l10n.uiString(zh: "约 %d 分 %d 秒", en: "About %dm %ds", zhHant: "約 %d 分 %d 秒", ja: "約 %d 分 %d 秒", ko: "약 %d분 %d초", de: "Etwa %d Min. %d Sek.", fr: "Environ %d min %d s", es: "Unos %d min %d s"), mins, secs)
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: TTZipTheme.Layout.hairlineBorderWidth)
            
            VStack(alignment: .leading, spacing: 20) {
                progressSection
                statsBox
                actionButtons
            }
            .padding(20)
        }
        .frame(width: 520)
        .background(modalBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(TTZipTheme.specularHairline, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.55 : 0.18), radius: 28, x: 0, y: 14)
    }
    
    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                Text(
                    isCancellationRequested
                        ? l10n.uiString(zh: "正在停止压缩...", en: "Stopping compression...", zhHant: "正在停止壓縮...", ja: "圧縮を停止しています...", ko: "압축 중지 중...", de: "Komprimierung wird gestoppt...", fr: "Arrêt de la compression...", es: "Deteniendo la compresión...")
                        : l10n.uiString(zh: "正在压缩...", en: "Compressing...", zhHant: "正在壓縮...", ja: "圧縮中...", ko: "압축 중...", de: "Komprimieren...", fr: "Compression...", es: "Comprimiendo...")
                )
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text(outputFileName)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(TTZipTheme.bambooGreen.opacity(0.12))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }
    
    private var progressSection: some View {
        VStack(spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                Text(l10n.uiString(zh: "总进度", en: "Progress", zhHant: "總進度", ja: "進行状況", ko: "진행률", de: "Fortschritt", fr: "Progression", es: "Progreso"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", progress.fractionCompleted * 100))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .contentTransition(.numericText(value: progress.fractionCompleted * 100))
                    .animation(.snappy, value: progress.fractionCompleted)
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            
            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(.linear)
                .tint(TTZipTheme.bambooGreen)
                .frame(height: 6)
        }
    }
    
    private var statsBox: some View {
        VStack(spacing: 12) {
            HStack {
                Label(
                    l10n.uiString(zh: "当前文件：", en: "Current File:", zhHant: "目前檔案：", ja: "現在のファイル:", ko: "현재 파일:", de: "Aktuelle Datei:", fr: "Fichier actuel :", es: "Archivo actual:"),
                    systemImage: "doc.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Text(progress.currentFileName.isEmpty ? outputFileName : progress.currentFileName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.identity)
                Spacer()
            }
            
            Divider()
            
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.uiString(zh: "已处理", en: "Processed", zhHant: "已處理", ja: "処理済み", ko: "처리됨", de: "Verarbeitet", fr: "Traité", es: "Procesado"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("\(formattedBytesProcessed) / \(formattedTotalBytes)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .contentTransition(.numericText())
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.uiString(zh: "吞吐速率", en: "Speed", zhHant: "吞吐速率", ja: "速度", ko: "속도", de: "Geschwindigkeit", fr: "Vitesse", es: "Velocidad"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f MB/s", progress.throughputMBs))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .contentTransition(.numericText())
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 3) {
                    Text(l10n.uiString(zh: "预计剩余", en: "Remaining", zhHant: "預計剩餘", ja: "残り時間", ko: "남은 시간", de: "Verbleibend", fr: "Temps restant", es: "Restante"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(estimatedRemainingSeconds)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: onMinimize) {
                Text(l10n.uiString(zh: "后台运行", en: "Run in Background", zhHant: "背景執行", ja: "バックグラウンドで実行", ko: "백그라운드에서 실행", de: "Im Hintergrund ausführen", fr: "Exécuter en arrière-plan", es: "Ejecutar en segundo plano"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.04))
            .clipShape(Capsule())
            
            Button(role: .destructive, action: onCancel) {
                Text(l10n.t(L10n.Queue.cancelTask))
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .background(TTZipTheme.cinnabarRed.opacity(0.15))
            .foregroundStyle(TTZipTheme.cinnabarRed)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(TTZipTheme.cinnabarRed.opacity(0.3), lineWidth: 0.5)
            )
            .keyboardShortcut(.escape, modifiers: [])
        }
    }
    
    private var modalBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color(red: 0.11, green: 0.12, blue: 0.11).opacity(0.94)
                        : Color(red: 0.96, green: 0.97, blue: 0.96).opacity(0.96)
                )
        }
    }
}
