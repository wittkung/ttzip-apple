// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

extension InspectorColumnView {
    func itemIconName(for item: DiskItemInfo) -> String {
        let ext = (item.name as NSString).pathExtension.lowercased()
        if let fmt = ArchiveCompressionFormat.from(extensionOrName: ext) {
            return fmt.iconName
        }
        if item.isArchive { return "archivebox.fill" }
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"].contains(ext) { return "photo.fill" }
        if MediaPreviewFactory.videoExtensions.contains(ext) { return "film.fill" }
        if MediaPreviewFactory.audioExtensions.contains(ext) { return "music.note" }
        if ext == "pdf" { return "doc.richtext.fill" }
        if ["swift", "js", "ts", "py", "json", "html", "css", "cpp", "c", "h", "rs", "go", "sh", "xml"].contains(ext) { return "doc.text.fill" }
        return "doc.fill"
    }
    
    func itemIconGradient(for item: DiskItemInfo) -> LinearGradient {
        if item.isDirectory {
            return LinearGradient(
                colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"].contains(ext) {
            return LinearGradient(
                colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    // MARK: - Metadata Bento & Quick Action Helpers
    
    @ViewBuilder
    func metadataBentoView(for item: DiskItemInfo, metadata: [String: String], dims: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let isZh = AppLocalizationState.shared.currentLanguage == .zhHans
            let dimensions = dims ?? metadata["Dimensions (Pixels)"]
            let colorProfile = metadata["ICC Profile"] ?? metadata["Color Model"]
            let bitDepth = metadata["Bit Depth"]
            
            // Section 1: Image Specifications
            if dimensions != nil || colorProfile != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "aspectratio")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                        Text(isZh ? "图像规格" : "IMAGE SPEC")
                            .font(.system(size: 9.5, weight: .bold, design: .serif))
                            .tracking(1.2)
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                    }
                    
                    HStack(spacing: 6) {
                        if let d = dimensions {
                            bentoChip(label: isZh ? "尺寸" : "Resolution", value: d)
                        }
                        if let cp = colorProfile {
                            bentoChip(label: isZh ? "色彩" : "Color", value: cp)
                        }
                        if let bd = bitDepth {
                            bentoChip(label: isZh ? "位深" : "Depth", value: bd)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.8)
                )
            }
            
            // Section 2: Camera EXIF (if any)
            if let camera = metadata["Camera Hardware"] ?? metadata["EXIF: Lens Model"] {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "camera")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                        Text(isZh ? "摄影参数" : "EXIF")
                            .font(.system(size: 9.5, weight: .bold, design: .serif))
                            .tracking(1.2)
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                    }
                    
                    Text(camera)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    let fNum = metadata["EXIF: F-Number"]
                    let exp = metadata["EXIF: Exposure Time"]
                    let iso = metadata["EXIF: ISO Speed"]
                    let focal = metadata["EXIF: Focal Length"]
                    let params = [fNum, exp, iso, focal].compactMap { $0 }.joined(separator: " · ")
                    if !params.isEmpty {
                        Text(params)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.8)
                )
            }
            
            // Section 3: File Details
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Text(isZh ? "基本信息" : "DETAILS")
                        .font(.system(size: 9.5, weight: .bold, design: .serif))
                        .tracking(1.2)
                        .foregroundStyle(Color.secondary)
                }
                
                VStack(spacing: 4) {
                    detailRow(label: isZh ? "文件大小" : "Size", value: item.sizeText.isEmpty ? "--" : item.sizeText)
                    
                    if let modDate = item.modificationDate {
                        detailRow(label: isZh ? "修改时间" : "Modified", value: DateFormatterCache.shared.string(from: modDate, format: "yyyy/MM/dd HH:mm"))
                    }
                    
                    detailRow(label: isZh ? "所在位置" : "Where", value: (item.path as NSString).deletingLastPathComponent, isPath: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.8)
            )
        }
    }
    
    private func bentoChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(label)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    private func detailRow(label: String, value: String, isPath: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 48, idealWidth: 60, alignment: .leading)
            
            Text(value)
                .font(.system(size: 10, weight: .medium, design: isPath ? .default : .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(isPath ? 2 : 1)
                .truncationMode(isPath ? .middle : .tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    @ViewBuilder
    func quickActionButtons(
        for item: DiskItemInfo,
        onPreview: @escaping () -> Void,
        onCompress: @escaping () -> Void,
        onSelectArchive: @escaping (String) -> Void
    ) -> some View {
        let isZh = AppLocalizationState.shared.currentLanguage == .zhHans
        HStack(spacing: 8) {
            InspectorSecondaryActionButton(
                title: isZh ? "全屏预览" : "Quick Look",
                icon: "arrow.up.left.and.arrow.down.right",
                helpText: isZh ? "全屏沉浸式预览媒体 (空格键)" : "Full-screen media preview (Space)",
                shortcut: "Space",
                action: onPreview
            )
            
            InspectorSecondaryActionButton(
                title: isZh ? "访达中显示" : "Reveal",
                icon: "folder",
                helpText: isZh ? "在系统访达中定位此文件" : "Reveal file in macOS Finder",
                shortcut: nil,
                action: {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                }
            )
        }
    }
}

// MARK: - Secondary Inspector Action Button

private struct InspectorSecondaryActionButton: View {
    let title: String
    let icon: String
    let helpText: String
    let shortcut: String?
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovering ? TTZipTheme.bambooGreen : Color.white.opacity(0.85))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovering ? Color.white : Color.white.opacity(0.92))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.1) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isHovering ? Color.white.opacity(0.18) : Color.white.opacity(0.08), lineWidth: 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
        .overlay(alignment: .top) {
            if isHovering {
                HStack(spacing: 4) {
                    Text(helpText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.white)
                    
                    if let sc = shortcut {
                        Text(sc)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.black.opacity(0.85))
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 3)
                .fixedSize()
                .offset(y: -30)
                .zIndex(999)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)),
                    removal: .opacity
                ))
                .allowsHitTesting(false)
            }
        }
        .help(helpText)
        .accessibilityLabel(title)
    }
}
