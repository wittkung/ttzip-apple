// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipUI

/// Floating transfer status HUD and notification banner presenting real-time transfer throughput,
/// progress, and cooperative cancellation controls for Android device I/O.
public struct TransferProgressHUD: View {
    public let job: AndroidTransferJobInfo
    public var onCancel: (() -> Void)? = nil
    
    @State private var isCollapsed: Bool = false
    
    public init(
        job: AndroidTransferJobInfo,
        onCancel: (() -> Void)? = nil
    ) {
        self.job = job
        self.onCancel = onCancel
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Direction Icon, Filename & Minimize/Cancel Buttons
            HStack(spacing: 8) {
                directionIcon
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.fileName)
                        .font(.system(size: 12, weight: .semibold, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Text(directionSubtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer(minLength: 6)
                
                // Collapse toggle
                Button(action: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isCollapsed.toggle()
                    }
                }) {
                    Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Expand HUD" : "Collapse HUD")
                
                // Cancel button
                if job.status == .transferring || job.status == .queued {
                    Button(action: {
                        onCancel?()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.secondary.opacity(0.8))
                            .frame(width: 18, height: 18)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Cancel Transfer")
                } else if job.status == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
            }
            
            if !isCollapsed {
                // Progress Bar
                ProgressView(value: job.progress, total: 1.0)
                    .progressViewStyle(ZenGradientProgressViewStyle())
                    .frame(height: 5)
                
                // Transfer Metrics: Speed & ETA
                HStack(spacing: 8) {
                    Text(formatBytes(job.transferredBytes) + " / " + formatBytes(job.totalBytes))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    
                    Spacer(minLength: 0)
                    
                    if job.status == .transferring {
                        HStack(spacing: 4) {
                            Text(String(format: "%.1f MB/s", job.speedMBs))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(TTZipTheme.bambooGreen)
                            
                            Text("·")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            
                            Text(etaString)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } else if job.status == .completed {
                        Text("Transfer Complete")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                    } else if job.status == .cancelling {
                        Text("Cancelling...")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(TTZipTheme.paperWhite.opacity(0.96))
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TTZipTheme.kintsugiGold.opacity(0.35), lineWidth: 0.8)
        )
    }
    
    // MARK: - Subviews & Formatters
    
    private var directionIcon: some View {
        Group {
            switch job.direction {
            case .macToAndroid:
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            case .androidToMac:
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TTZipTheme.archiveAmber)
            case .directPipelineExtract:
                Image(systemName: "archivebox.and.arrow.down.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
            }
        }
    }
    
    private var directionSubtitle: String {
        switch job.direction {
        case .macToAndroid:
            return "Copying to Android Storage"
        case .androidToMac:
            return "Downloading to Mac"
        case .directPipelineExtract:
            return "Direct Stream Decompression"
        }
    }
    
    private var etaString: String {
        guard let seconds = job.remainingSeconds else { return "Estimating..." }
        if seconds < 60 {
            return String(format: "%.0fs remaining", seconds)
        } else {
            let minutes = Int(seconds) / 60
            let remainder = Int(seconds) % 60
            return "\(minutes)m \(remainder)s remaining"
        }
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Zen minimalist gradient style for transfer progress tracking.
public struct ZenGradientProgressViewStyle: ProgressViewStyle {
    public init() {}
    
    public func makeBody(configuration: Configuration) -> some View {
        let fraction = configuration.fractionCompleted ?? 0.0
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [TTZipTheme.bambooGreen, TTZipTheme.kintsugiGold],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .scaleEffect(x: max(0.001, CGFloat(fraction)), y: 1.0, anchor: .leading)
            }
            .animation(.easeOut(duration: 0.15), value: fraction)
    }
}

