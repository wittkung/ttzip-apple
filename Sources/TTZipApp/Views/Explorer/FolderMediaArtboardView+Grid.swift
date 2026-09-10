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
                .foregroundStyle(TTZipTheme.kintsugiGold)
            
            let itemsValue: String = {
                if isCalculating {
                    return l10n.t(L10n.Common.calculating)
                }
                return l10n.formatFilesAndDirectories(files: fileCount, directories: subfolderCount)
            }()
            
            let fsValue = (l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant)
                ? "APFS (Apple 文件系统)"
                : "APFS (Apple File System)"
            
            VStack(spacing: 10) {
                detailRow(label: l10n.t(L10n.Inspector.size), value: formattedFolderSize, isHighlight: true)
                detailRow(label: l10n.t(L10n.Inspector.items), value: itemsValue)
                detailRow(label: l10n.t(L10n.Inspector.modified), value: formattedDate)
                detailRow(label: l10n.t(L10n.Inspector.fileSystem), value: fsValue)
                detailRow(label: l10n.t(L10n.Inspector.permissions), value: "0755 (drwxr-xr-x)")
                detailRow(label: l10n.t(L10n.Inspector.ownerGroup), value: ownerGroupString)
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
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                
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
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            
                            Spacer(minLength: 4)
                            
                            // Fixed-width right-aligned item count
                            Text(l10n.plural(key: L10n.Units.itemsCount, count: item.count))
                                .font(.system(size: 11, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
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
    
    func detailRow(label: String, value: String, isHighlight: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            // Wide layout: single line
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                
                Spacer(minLength: 4)
                
                Text(value)
                    .font(.system(size: isHighlight ? 13 : 11, weight: isHighlight ? .bold : .regular, design: isHighlight ? .default : .monospaced))
                    .foregroundStyle(isHighlight ? TTZipTheme.bambooGreen : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            
            // Narrow layout: double line stacked
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                Text(value)
                    .font(.system(size: isHighlight ? 12 : 11, weight: isHighlight ? .bold : .regular, design: isHighlight ? .default : .monospaced))
                    .foregroundStyle(isHighlight ? TTZipTheme.bambooGreen : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
    
    private var ownerGroupString: String {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: item.path) {
            let owner = attrs[.ownerAccountName] as? String ?? NSUserName()
            let ownerID = (attrs[.ownerAccountID] as? NSNumber)?.stringValue ?? "\(getuid())"
            let group = attrs[.groupOwnerAccountName] as? String ?? "staff"
            let groupID = (attrs[.groupOwnerAccountID] as? NSNumber)?.stringValue ?? "\(getgid())"
            return "\(owner) (\(ownerID)) / \(group) (\(groupID))"
        }
        return "\(NSUserName()) (\(getuid())) / staff (\(getgid()))"
    }
    
    func categoryColor(_ cat: String) -> Color {
        TTZipTheme.fileCategoryColor(for: cat)
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
