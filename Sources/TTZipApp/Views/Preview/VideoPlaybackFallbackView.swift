// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore

/// Secondary companion diagnostics and external player launcher view.
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
    
    private var containerDescription: String {
        switch containerName.uppercased() {
        case "MKV": return "MKV (Matroska Video)"
        case "AVI": return "AVI (Audio Video Interleave)"
        case "WEBM": return "WebM (Open Web Video)"
        case "WMV": return "WMV (Windows Media Video)"
        case "FLV": return "FLV (Flash Video)"
        case "TS", "M2TS": return "MPEG Transport Stream"
        case "OGV": return "Ogg Theora Video"
        case "3GP": return "3GPP Multimedia"
        default: return "\(containerName.uppercased()) Video"
        }
    }
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 18) {
                // Animated Hero Icon
                ZStack {
                    Circle()
                        .fill(TTZipTheme.kintsugiGold.opacity(0.15))
                        .frame(width: 90, height: 90)
                        .blur(radius: 8)
                    
                    Circle()
                        .fill(Color(white: 0.12))
                        .frame(width: 72, height: 72)
                        .overlay(Circle().strokeBorder(TTZipTheme.kintsugiGold.opacity(0.4), lineWidth: 1))
                    
                    Image(systemName: "film.stack")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                }
                .padding(.top, 16)
                
                // Title and Badges
                VStack(spacing: 6) {
                    Text(fileName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    
                    HStack(spacing: 6) {
                        Text(containerName.isEmpty ? "MKV" : containerName)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(TTZipTheme.kintsugiGold.opacity(0.15))
                            .clipShape(Capsule())
                        
                        Text(fileSizeString)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(TTZipTheme.bambooGreen.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                
                // Action Buttons
                VStack(spacing: 8) {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text(isChinese ? "使用系统默认播放器打开" : "Open in Default Player")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(TTZipTheme.bambooGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    
                    HStack(spacing: 8) {
                        Button(action: { NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "") }) {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 11))
                                Text(isChinese ? "在访达中显示" : "Reveal in Finder")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { QuickLookPreviewCoordinator.shared.previewDiskFile(url: url) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "eye.fill")
                                    .font(.system(size: 11))
                                Text(isChinese ? "快速查看" : "Quick Look")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                
                // Media Specifications
                VStack(alignment: .leading, spacing: 8) {
                    Label(isChinese ? "媒体规格" : "Specifications", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                    
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        GridRow {
                            metaRow(title: isChinese ? "容器格式" : "Container", value: containerDescription)
                            metaRow(title: isChinese ? "文件大小" : "Size", value: fileSizeString)
                        }
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
    }
    
    private func metaRow(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
