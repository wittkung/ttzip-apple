// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import CryptoKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

public struct InspectorColumnView: View {
    public let item: DiskItemInfo?
    public let onSelectArchive: (String) -> Void
    public let onCompressPath: (String) -> Void
    public let onPreviewFile: (String) -> Void
    
    @State var asyncDimensions: String? = nil
    @State var localPreviewURL: URL? = nil
    @State var deepMetadataDict: [String: String] = [:]
    @State var showDetailedMetadataPopover: Bool = false
    
    public init(
        item: DiskItemInfo? = nil,
        onSelectArchive: @escaping (String) -> Void,
        onCompressPath: @escaping (String) -> Void,
        onPreviewFile: @escaping (String) -> Void
    ) {
        self.item = item
        self.onSelectArchive = onSelectArchive
        self.onCompressPath = onCompressPath
        self.onPreviewFile = onPreviewFile
    }
    
    var isVirtualItem: Bool {
        guard let item = item else { return false }
        if let u = URL(string: item.path), let q = u.query, q.contains("subpath=") {
            return true
        }
        return false
    }
    
    var effectivePreviewURL: URL? {
        if let local = localPreviewURL {
            return local
        }
        if isVirtualItem {
            return nil
        }
        guard let item = item else { return nil }
        if let url = URL(string: item.path), url.scheme != nil {
            return url
        }
        return URL(fileURLWithPath: item.path)
    }
    
    var effectiveModificationDate: Date? {
        if let d = item?.modificationDate {
            return d
        }
        guard let targetPath = effectivePreviewURL?.path else { return nil }
        if FileManager.default.fileExists(atPath: targetPath),
           let attr = try? FileManager.default.attributesOfItem(atPath: targetPath) {
            return attr[FileAttributeKey.modificationDate] as? Date
        }
        return nil
    }
    
    @ViewBuilder
    public var body: some View {
        Group {
            if let item = item {
                if item.isDirectory {
                    FolderMediaArtboardView(
                        item: item,
                        onCompressPath: onCompressPath
                    )
                    .id(item.path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        fileHeaderBar(for: item)
                        
                        Divider()
                        
                        MediaPreviewView(
                            fileURL: effectivePreviewURL,
                            fileName: item.name
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                zenPlaceholderView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item?.path) {
            guard item != nil else {
                self.deepMetadataDict = [:]
                return
            }
            if let url = effectivePreviewURL, FileManager.default.fileExists(atPath: url.path) {
                let targetURL = url
                let meta = await withTaskGroup(of: [String: String]?.self) { group in
                    group.addTask(priority: .utility) {
                        await DeepFileMetadataReader.readMetadata(for: targetURL)
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        return nil
                    }
                    
                    for await result in group {
                        if let result = result {
                            group.cancelAll()
                            return result
                        } else {
                            group.cancelAll()
                            return [:]
                        }
                    }
                    return [:]
                }
                self.deepMetadataDict = meta
            } else {
                self.deepMetadataDict = [:]
            }
        }
        .task(id: item?.path) {
            self.localPreviewURL = nil
            self.asyncDimensions = nil
            guard let item = item else { return }
            
            var realArchivePath = ""
            var subpath = ""
            var isVirtual = false
            
            if let u = URL(string: item.path),
               let comp = URLComponents(url: u, resolvingAgainstBaseURL: false),
               let qItems = comp.queryItems,
               let sub = qItems.first(where: { $0.name == "subpath" })?.value {
                isVirtual = true
                realArchivePath = u.path
                subpath = sub
            }
            
            if isVirtual {
                let filename = (subpath as NSString).lastPathComponent
                let fullId = "\(realArchivePath)::\(subpath)"
                let shaDigest = SHA256.hash(data: Data(fullId.utf8))
                let hash = shaDigest.map { String(format: "%02x", $0) }.joined()
                
                if let cached = PreviewLRUCacheManager.shared.cachedURL(forKey: hash) {
                    self.localPreviewURL = cached
                } else {
                    let targetFileURL = PreviewLRUCacheManager.shared.targetURL(forKey: hash, filename: filename)
                    let tempDir = targetFileURL.deletingLastPathComponent().path
                    let extractedPath = targetFileURL.path
                    let fm = FileManager.default
                    
                    if fm.fileExists(atPath: extractedPath),
                       let attr = try? fm.attributesOfItem(atPath: extractedPath),
                       (attr[.size] as? Int64 ?? 0) > 0 {
                        PreviewLRUCacheManager.shared.register(key: hash, fileURL: targetFileURL)
                        self.localPreviewURL = targetFileURL
                    } else if let contents = try? fm.contentsOfDirectory(atPath: tempDir),
                              let first = contents.first(where: { !$0.hasPrefix(".") }),
                              let attr = try? fm.attributesOfItem(atPath: (tempDir as NSString).appendingPathComponent(first)),
                              (attr[.size] as? Int64 ?? 0) > 0 {
                        let matchURL = URL(fileURLWithPath: (tempDir as NSString).appendingPathComponent(first))
                        PreviewLRUCacheManager.shared.register(key: hash, fileURL: matchURL)
                        self.localPreviewURL = matchURL
                    } else {
                        let pwd = ArchivePasswordStore.shared.getPassword(for: realArchivePath)
                        
                        let extractTask = Task.detached(priority: .userInitiated) {
                            try await TTZipEngineFacade.shared.extractSingleEntry(
                                archivePath: realArchivePath,
                                entryPath: subpath,
                                destinationDir: tempDir,
                                password: pwd
                            )
                        }
                        
                        _ = try? await extractTask.value
                        if fm.fileExists(atPath: extractedPath),
                           let attr = try? fm.attributesOfItem(atPath: extractedPath),
                           (attr[.size] as? Int64 ?? 0) > 0 {
                            await MainActor.run {
                                PreviewLRUCacheManager.shared.register(key: hash, fileURL: targetFileURL)
                                self.localPreviewURL = targetFileURL
                            }
                        } else if let contents = try? fm.contentsOfDirectory(atPath: tempDir),
                                  let firstFile = contents.first(where: { !$0.hasPrefix(".") }),
                                  let attr = try? fm.attributesOfItem(atPath: (tempDir as NSString).appendingPathComponent(firstFile)),
                                  (attr[.size] as? Int64 ?? 0) > 0 {
                            let matchURL = URL(fileURLWithPath: (tempDir as NSString).appendingPathComponent(firstFile))
                            await MainActor.run {
                                PreviewLRUCacheManager.shared.register(key: hash, fileURL: matchURL)
                                self.localPreviewURL = matchURL
                            }
                        }
                    }
                }
            } else {
                self.localPreviewURL = URL(fileURLWithPath: item.path)
            }
            
            let targetURL = localPreviewURL ?? URL(fileURLWithPath: item.path)
            let ext = targetURL.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp"].contains(ext) {
                if let dims = ImageMetadataCache.shared.getDimensions(for: targetURL.path) {
                    self.asyncDimensions = dims
                } else {
                    self.asyncDimensions = await ImageMetadataCache.shared.loadDimensionsAsync(path: targetURL.path, url: targetURL)
                }
            } else {
                self.asyncDimensions = nil
            }
        }
    }
    
    // MARK: - Header Bar
    
    @ViewBuilder
    private func fileHeaderBar(for targetItem: DiskItemInfo) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(itemIconGradient(for: targetItem))
                    .frame(width: 28, height: 28)
                Image(systemName: itemIconName(for: targetItem))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(targetItem.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    
                    Button(action: { showDetailedMetadataPopover.toggle() }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showDetailedMetadataPopover, arrowEdge: .bottom) {
                        detailedMetadataPopoverContent(for: targetItem)
                    }
                }
                
                HStack(spacing: 6) {
                    Text(targetItem.sizeText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    Text("•")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    
                    Text(targetItem.kindText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    if let dims = asyncDimensions {
                        Text("•")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        
                        Text(dims)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            actionButtonsGroup(for: targetItem)
                .layoutPriority(0)
                .padding(.trailing, 12)
        }
        .padding(.leading, 14)
        .padding(.vertical, 7)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Action Buttons
    
    @ViewBuilder
    private func actionButtonsGroup(for targetItem: DiskItemInfo) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Button(action: {
                    let targetPath = effectivePreviewURL?.path ?? targetItem.path
                    onPreviewFile(targetPath)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Preview")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(TTZipTheme.bambooGreen.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("全屏预览媒体 (Space / ⤢)")
                
                Button(action: {
                    let targetPath = effectivePreviewURL?.path ?? targetItem.path
                    NSWorkspace.shared.selectFile(targetPath, inFileViewerRootedAtPath: "")
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "folder").font(.system(size: 10))
                        Text("Finder")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(TTZipTheme.bambooGreen.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                
                Button(action: {
                    if targetItem.isArchive { onSelectArchive(targetItem.path) } else { onCompressPath(targetItem.path) }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: targetItem.isArchive ? "arrow.down.doc" : "archivebox")
                            .font(.system(size: 10, weight: .semibold))
                        Text(targetItem.isArchive ? "Extract" : "Compress")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(TTZipTheme.bambooGreen.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(targetItem.isArchive ? "Extract and view contents" : "New archive")
            }
            
            HStack(spacing: 6) {
                Button(action: {
                    let targetPath = effectivePreviewURL?.path ?? targetItem.path
                    onPreviewFile(targetPath)
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                        .padding(5.5)
                        .background(TTZipTheme.bambooGreen.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("全屏预览媒体 (Space / ⤢)")
                
                Button(action: {
                    let targetPath = effectivePreviewURL?.path ?? targetItem.path
                    NSWorkspace.shared.selectFile(targetPath, inFileViewerRootedAtPath: "")
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                        .padding(5.5)
                        .background(TTZipTheme.bambooGreen.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                
                Button(action: {
                    if targetItem.isArchive { onSelectArchive(targetItem.path) } else { onCompressPath(targetItem.path) }
                }) {
                    Image(systemName: targetItem.isArchive ? "arrow.down.doc" : "archivebox")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                        .padding(5.5)
                        .background(TTZipTheme.bambooGreen.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(targetItem.isArchive ? "Extract and view contents" : "New archive")
            }
        }
    }
    
    // MARK: - Zen Empty State
    
    @ViewBuilder
    private var zenPlaceholderView: some View {
        VStack(spacing: 12) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(TTZipTheme.kintsugiGold.opacity(0.06))
                    .frame(width: 56, height: 56)
                
                Image(systemName: "circle.dotted")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(TTZipTheme.kintsugiGold.opacity(0.6))
            }
            
            VStack(spacing: 4) {
                Text("Zen Workspace")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.primary.opacity(0.8))
                
                Text("Select an item in the explorer to inspect")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.015))
    }
}
