// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore

/// Dedicated fallback view for non-native video containers (MKV, AVI, WebM, FLV, WMV)
/// and AVFoundation decoding failures, offering 1-click external player dispatch,
/// QuickLook preview, and detailed file diagnostics.
public struct VideoPlaybackFallbackView: View {
    @ObservedObject private var l10n = AppLocalizationState.shared
    
    public let url: URL
    public let fileName: String
    public let containerName: String
    public let errorMessage: String?
    
    public init(
        url: URL,
        fileName: String = "",
        containerName: String = "",
        errorMessage: String? = nil
    ) {
        self.url = url
        self.fileName = fileName.isEmpty ? url.lastPathComponent : fileName
        self.containerName = containerName.isEmpty ? url.pathExtension.uppercased() : containerName
        self.errorMessage = errorMessage
    }
    
    private var isChinese: Bool {
        l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
    }
    
    private var fileSizeString: String {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attr[.size] as? Int64 else {
            return "--"
        }
        return l10n.formatBytes(size)
    }
    
    private var detectedMediaBadges: [String] {
        var badges: [String] = []
        let upper = fileName.uppercased()
        
        if upper.contains("2160P") || upper.contains("4K") || upper.contains("UHD") {
            badges.append("4K UHD (2160p)")
        } else if upper.contains("1080P") || upper.contains("FHD") {
            badges.append("1080p FHD")
        } else if upper.contains("720P") {
            badges.append("720p HD")
        }
        
        if upper.contains("DV") || upper.contains("DOLBY VISION") {
            badges.append("Dolby Vision")
        }
        if upper.contains("HDR") || upper.contains("HDR10") {
            badges.append("HDR")
        }
        
        if upper.contains("DDP5.1") || upper.contains("DDP") || upper.contains("E-AC-3") {
            badges.append("Dolby Digital+ 5.1")
        } else if upper.contains("DTS") {
            badges.append("DTS Surround")
        } else if upper.contains("TRUEHD") || upper.contains("ATMOS") {
            badges.append("Dolby Atmos")
        }
        
        if upper.contains("H.265") || upper.contains("HEVC") || upper.contains("X265") {
            badges.append("HEVC (H.265)")
        } else if upper.contains("H.264") || upper.contains("AVC") || upper.contains("X264") {
            badges.append("AVC (H.264)")
        } else if upper.contains("AV1") {
            badges.append("AV1")
        }
        
        return badges
    }
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 20) {
                // MARK: - 1. Animated Hero Icon with Ambient Halo
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    TTZipTheme.kintsugiGold.opacity(0.22),
                                    TTZipTheme.bambooGreen.opacity(0.10),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 18,
                                endRadius: 90
                            )
                        )
                        .frame(width: 170, height: 170)
                        .blur(radius: 10)
                    
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.12), Color(white: 0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 110, height: 110)
                        .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 6)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [TTZipTheme.kintsugiGold.opacity(0.5), Color.white.opacity(0.1)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.2
                                )
                        )
                    
                    Image(systemName: "film.stack")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [TTZipTheme.kintsugiGold, Color.white],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: TTZipTheme.kintsugiGold.opacity(0.4), radius: 8)
                }
                .padding(.top, 14)
                
                // MARK: - 2. Title & Container Notice
                VStack(spacing: 8) {
                    Text(fileName)
                        .font(.system(size: 14, weight: .bold, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    
                    // Container and Quality Badges
                    HStack(spacing: 6) {
                        Text(containerName.isEmpty ? "MKV" : containerName)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(TTZipTheme.kintsugiGold.opacity(0.15))
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(TTZipTheme.kintsugiGold.opacity(0.35), lineWidth: 0.8))
                        
                        Text(fileSizeString)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(TTZipTheme.bambooGreen.opacity(0.15))
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(TTZipTheme.bambooGreen.opacity(0.35), lineWidth: 0.8))
                    }
                    
                    if !detectedMediaBadges.isEmpty {
                        FlowTagLayout(spacing: 5) {
                            ForEach(detectedMediaBadges, id: \.self) { badge in
                                Text(badge)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.04))
                                    .clipShape(Capsule())
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
                
                // MARK: - 3. Explanatory Callout Card
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                        Text(isChinese ? "\(containerName) 封装容器说明" : "\(containerName) Container Format")
                            .font(.system(size: 11.5, weight: .bold, design: .serif))
                            .foregroundStyle(.primary)
                    }
                    
                    Text(
                        isChinese
                            ? "macOS 原生 AVFoundation 框架不支持直接硬件解包 \(containerName) 容器格式。建议使用关联的专业播放器（如 IINA、VLC、Infuse 等）直接打开播放，即可完美呈现 4K HDR、杜比视界及多声道音频。"
                            : "macOS AVFoundation does not natively demux \(containerName) container formats. Open with your external media player (IINA, VLC, Infuse) for complete HDR, Dolby Vision, and surround audio decoding."
                    )
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(TTZipTheme.kintsugiGold.opacity(0.2), lineWidth: 0.8)
                )
                .padding(.horizontal, 20)
                
                // MARK: - 4. Primary & Secondary Action Dispatchers
                VStack(spacing: 10) {
                    // Primary Action: Open in External Player
                    Button(action: {
                        NSWorkspace.shared.open(url)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text(isChinese ? "使用系统默认播放器打开" : "Open in Default Player")
                                .font(.system(size: 12.5, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [TTZipTheme.bambooGreen, Color(red: 0.15, green: 0.65, blue: 0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: TTZipTheme.bambooGreen.opacity(0.35), radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    
                    // Secondary Actions: Reveal in Finder & QuickLook
                    HStack(spacing: 10) {
                        Button(action: {
                            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 11))
                                Text(isChinese ? "在访达中显示" : "Reveal in Finder")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            QuickLookPreviewCoordinator.shared.previewDiskFile(url: url)
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "eye.fill")
                                    .font(.system(size: 11))
                                Text(isChinese ? "快速查看 (空格)" : "Quick Look (Space)")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                
                // MARK: - 5. File System Metadata Grid
                VStack(alignment: .leading, spacing: 10) {
                    Label(isChinese ? "媒体详细规格" : "Media Specifications", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .bold, design: .serif))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                    
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            metaRowItem(title: isChinese ? "容器格式" : "Container", value: "\(containerName) (Matroska)")
                            metaRowItem(title: isChinese ? "文件大小" : "File Size", value: fileSizeString)
                        }
                        GridRow {
                            metaRowItem(title: isChinese ? "原生硬解" : "Native Support", value: isChinese ? "需要外部播放器" : "Requires External App")
                            metaRowItem(title: isChinese ? "扩展名" : "Extension", value: ".\(url.pathExtension)")
                        }
                    }
                }
                .padding(14)
                .background(Color.primary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                )
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
    }
    
    private func metaRowItem(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Dynamic Tag Flow Layout helper.
fileprivate struct FlowTagLayout: Layout {
    var spacing: CGFloat = 6
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var height: CGFloat = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height = y + rowHeight
        return CGSize(width: width, height: height)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
