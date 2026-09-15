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
import Darwin

extension FolderMediaArtboardView {
    @ViewBuilder
    var overviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.t(L10n.Inspector.overviewFs))
                .font(.system(size: 9, weight: .bold, design: .serif))
                .tracking(2)
                .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)
            
            let itemsValue: String = {
                if isCalculating {
                    return l10n.t(L10n.Common.calculating)
                }
                return l10n.formatFilesAndDirectories(files: fileCount, directories: subfolderCount)
            }()
            
            let isZh = l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
            let fsTooltip = isZh ? "Apple 文件系统 (APFS)" : "Apple File System (APFS)"
            let ownerLabel = isZh ? "所有者" : "Owner"
            let permTooltip = "0755 (drwxr-xr-x)"
            
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                detailGridRow(label: l10n.t(L10n.Inspector.size), value: formattedFolderSize, isHighlight: true)
                detailGridRow(label: l10n.t(L10n.Inspector.items), value: itemsValue)
                detailGridRow(label: l10n.t(L10n.Inspector.modified), value: formattedDate)
                detailGridRow(label: l10n.t(L10n.Inspector.fileSystem), value: "APFS", tooltip: fsTooltip)
                detailGridRow(label: l10n.t(L10n.Inspector.permissions), value: "0755", tooltip: permTooltip)
                detailGridRow(label: ownerLabel, value: ownerNameString, tooltip: ownerGroupTooltipString)
            }
        }
    }
    
    @ViewBuilder
    var contentBreakdownSection: some View {
        if !fileTypeDistribution.isEmpty {
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n.t(L10n.Inspector.contentBreakdown))
                    .font(.system(size: 9, weight: .bold, design: .serif))
                    .tracking(2)
                    .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)
                
                GeometryReader { barGeo in
                    let total = fileTypeDistribution.reduce(0) { $0 + $1.count }
                    HStack(spacing: 1.5) {
                        ForEach(fileTypeDistribution, id: \.category) { item in
                            let ratio = total > 0 ? CGFloat(item.count) / CGFloat(total) : 0
                            Rectangle()
                                .fill(categoryColor(item.category))
                                .frame(width: max(2.5, barGeo.size.width * ratio))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 9)
                .background(Color.primary.opacity(0.04))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8))
                
                let total = fileTypeDistribution.reduce(0) { $0 + $1.count }
                VStack(spacing: 7) {
                    ForEach(fileTypeDistribution, id: \.category) { item in
                        let pct = total > 0 ? Int(round(Double(item.count) / Double(total) * 100)) : 0
                        HStack(spacing: 8) {
                            // Category dot and name
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(categoryColor(item.category))
                                    .frame(width: 7.5, height: 7.5)
                                    .shadow(color: categoryColor(item.category).opacity(0.4), radius: 2, x: 0, y: 1)
                                
                                Text(item.category)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)
                            }
                            
                            Spacer(minLength: 4)
                            
                            // Fixed-width right-aligned item count
                            Text(l10n.plural(key: L10n.Units.itemsCount, count: item.count))
                                .font(.system(size: 11, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                                .frame(width: 80, alignment: .trailing)
                            
                            // Fixed-width right-aligned percentage badge
                            Text("\(pct)%")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(TTZipTheme.kintsugiGold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(TTZipTheme.kintsugiGold.opacity(0.12))
                                .clipShape(Capsule())
                                .frame(width: 45, alignment: .trailing)
                        }
                    }
                }
            }
        } else if isCalculating {
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n.t(L10n.Inspector.contentBreakdown))
                    .font(.system(size: 9, weight: .bold, design: .serif))
                    .tracking(2)
                    .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)
                
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.04),
                                Color.primary.opacity(0.08),
                                Color.primary.opacity(0.04)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 9)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8))
            }
        } else if !isCalculating && fileCount == 0 && subfolderCount == 0 {
            Divider()
            
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(TTZipTheme.kintsugiGold.opacity(0.6))
                    Text(l10n.t(L10n.Inspector.emptyDirectory))
                        .font(.system(size: 11, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.primary.opacity(0.75))
                }
                
                Text(l10n.t(L10n.Inspector.emptyDirectoryDesc))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.015))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(TTZipTheme.hairlineBorder, lineWidth: 0.8)
            )
        }
    }
    
    @ViewBuilder
    func detailGridRow(label: String, value: String, isHighlight: Bool = false, tooltip: String? = nil) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 54, idealWidth: 62, maxWidth: 72, alignment: .leading)
            
            Text(value)
                .font(.system(size: isHighlight ? 12 : 11, weight: isHighlight ? .semibold : .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(tooltip ?? value)
        }
    }
    
    private var ownerNameString: String {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: item.path) {
            return attrs[.ownerAccountName] as? String ?? NSUserName()
        }
        return NSUserName()
    }
    
    private var ownerGroupTooltipString: String {
        let isZh = l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
        if let attrs = try? FileManager.default.attributesOfItem(atPath: item.path) {
            let owner = attrs[.ownerAccountName] as? String ?? NSUserName()
            let group = attrs[.groupOwnerAccountName] as? String ?? "staff"
            return isZh ? "所有者: \(owner) · 用户组: \(group)" : "Owner: \(owner) · Group: \(group)"
        }
        return isZh ? "所有者: \(NSUserName()) · 用户组: staff" : "Owner: \(NSUserName()) · Group: staff"
    }
    
    func categoryColor(_ cat: String) -> Color {
        let key = cat.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        // 1. Visual & Images -> Mineral Gold
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "svg", "bmp", "raw", "psd", "ai", "image", "图片":
            return TTZipUniversalTokens.Mineral.gold
            
        // 2. Documents & Code -> Mineral Bamboo
        case "pdf", "txt", "doc", "docx", "pages", "rtf", "md", "markdown", "swift", "rs", "c", "cpp", "h", "py", "js", "ts", "json", "yaml", "yml", "toml", "xml", "html", "css", "sh", "document", "code", "文档", "代码":
            return TTZipUniversalTokens.Mineral.bamboo
            
        // 3. Video & Motion -> Mineral Cinnabar
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "video", "视频":
            return TTZipUniversalTokens.Mineral.cinnabar
            
        // 4. Audio & Speech -> Mineral Amethyst
        case "mp3", "m4a", "aac", "wav", "flac", "alac", "ogg", "opus", "audio", "音频":
            return TTZipUniversalTokens.Mineral.amethyst
            
        // 5. Archives & Disk Packages -> Mineral Amber
        case "zip", "7z", "tar", "gz", "bz2", "xz", "zst", "rar", "dmg", "iso", "pkg", "deb", "rpm", "ttzip", "archive", "压缩包", "归档包":
            return TTZipUniversalTokens.Mineral.amber
            
        default:
            // Deterministic cyclic fallback across the 5 harmonious mineral tokens
            let palette: [Color] = [
                TTZipUniversalTokens.Mineral.gold,
                TTZipUniversalTokens.Mineral.bamboo,
                TTZipUniversalTokens.Mineral.cinnabar,
                TTZipUniversalTokens.Mineral.amethyst,
                TTZipUniversalTokens.Mineral.amber
            ]
            let hash = abs(key.hashValue)
            return palette[hash % palette.count]
        }
    }
    
    func createNewFolder() {
        let parentDir = URL(fileURLWithPath: item.path)
        let trimmed = newSubfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Untitled Folder" : trimmed
        var targetURL = parentDir.appendingPathComponent(baseName)
        var counter = 2
        while FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = parentDir.appendingPathComponent("\(baseName) \(counter)")
            counter += 1
        }
        try? FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
        newSubfolderName = "Untitled Folder"
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
    }
    
    func createNewFile() {
        let parentDir = URL(fileURLWithPath: item.path)
        let trimmed = newSubfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Untitled.txt" : trimmed
        let pathExtension = (baseName as NSString).pathExtension
        let nameWithoutExt = (baseName as NSString).deletingPathExtension
        var targetURL = parentDir.appendingPathComponent(baseName)
        var counter = 2
        while FileManager.default.fileExists(atPath: targetURL.path) {
            let nextName = pathExtension.isEmpty ? "\(baseName) \(counter)" : "\(nameWithoutExt) \(counter).\(pathExtension)"
            targetURL = parentDir.appendingPathComponent(nextName)
            counter += 1
        }
        FileManager.default.createFile(atPath: targetURL.path, contents: Data(), attributes: nil)
        newSubfileName = "Untitled.txt"
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: nil)
    }
    
    static func calculateFolderStats(at targetPath: String) async -> (totalSize: Int64, folderCount: Int, fileCount: Int, distribution: [(category: String, count: Int)]) {
        await Task.detached {
            var totalSize: Int64 = 0
            var folderCount = 0
            var fileCount = 0
            var typeDist: [String: Int] = [:]
            
            let fm = FileManager.default
            if let enumerator = fm.enumerator(at: URL(fileURLWithPath: targetPath), includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) {
                        if resourceValues.isDirectory == true {
                            folderCount += 1
                        } else {
                            fileCount += 1
                            let s = Int64(resourceValues.fileSize ?? 0)
                            totalSize += s
                            let ext = fileURL.pathExtension.lowercased()
                            typeDist[ext.isEmpty ? "other" : ext, default: 0] += 1
                        }
                    }
                }
            }
            let distArray: [(category: String, count: Int)] = typeDist.map { (category: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
            return (totalSize, folderCount, fileCount, distArray)
        }.value
    }
    
    func calculateStats() async {
        isCalculating = true
        let (size, subfolders, files, dist) = await Self.calculateFolderStats(at: item.path)
        await MainActor.run {
            self.totalSizeBytes = size
            self.subfolderCount = subfolders
            self.fileCount = files
            self.fileTypeDistribution = dist
            self.isCalculating = false
        }
    }
}
