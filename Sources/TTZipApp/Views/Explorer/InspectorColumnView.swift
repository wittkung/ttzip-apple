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

public struct InspectorColumnView: View {
    public let item: DiskItemInfo?
    public let onSelectArchive: (String) -> Void
    public let onCompressPath: (String) -> Void
    public let onPreviewFile: (String) -> Void
    
    @State var asyncDimensions: String? = nil
    @State var localPreviewURL: URL? = nil
    @State var deepMetadataDict: [String: String] = [:]
    
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
                } else if isInteractiveDocumentOrMedia(for: item) {
                    GeometryReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            MediaPreviewView(
                                fileURL: effectivePreviewURL,
                                fileName: item.name
                            )
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: max(480, proxy.size.height))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    fileInspectorContent(for: item)
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
                
                if let cached = await PreviewLRUCacheManager.shared.cachedURL(forKey: hash) {
                    self.localPreviewURL = cached
                } else {
                    let targetFileURL = PreviewLRUCacheManager.shared.targetURL(forKey: hash, filename: filename)
                    let tempDir = targetFileURL.deletingLastPathComponent().path
                    let extractedPath = targetFileURL.path
                    let fm = FileManager.default
                    
                    if fm.fileExists(atPath: extractedPath),
                       let attr = try? fm.attributesOfItem(atPath: extractedPath),
                       (attr[.size] as? Int64 ?? 0) > 0 {
                        await PreviewLRUCacheManager.shared.register(key: hash, fileURL: targetFileURL)
                        self.localPreviewURL = targetFileURL
                    } else if let contents = try? fm.contentsOfDirectory(atPath: tempDir),
                              let first = contents.first(where: { !$0.hasPrefix(".") }),
                              let attr = try? fm.attributesOfItem(atPath: (tempDir as NSString).appendingPathComponent(first)),
                              (attr[.size] as? Int64 ?? 0) > 0 {
                        let matchURL = URL(fileURLWithPath: (tempDir as NSString).appendingPathComponent(first))
                        await PreviewLRUCacheManager.shared.register(key: hash, fileURL: matchURL)
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
                            await PreviewLRUCacheManager.shared.register(key: hash, fileURL: targetFileURL)
                            await MainActor.run {
                                self.localPreviewURL = targetFileURL
                            }
                        } else if let contents = try? fm.contentsOfDirectory(atPath: tempDir),
                                  let firstFile = contents.first(where: { !$0.hasPrefix(".") }),
                                  let attr = try? fm.attributesOfItem(atPath: (tempDir as NSString).appendingPathComponent(firstFile)),
                                  (attr[.size] as? Int64 ?? 0) > 0 {
                            let matchURL = URL(fileURLWithPath: (tempDir as NSString).appendingPathComponent(firstFile))
                            await PreviewLRUCacheManager.shared.register(key: hash, fileURL: matchURL)
                            await MainActor.run {
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
    
    private func isInteractiveDocumentOrMedia(for item: DiskItemInfo) -> Bool {
        let ext = (item.name as NSString).pathExtension.lowercased()
        if ["swift", "js", "ts", "py", "json", "html", "css", "cpp", "c", "h", "rs", "go", "sh", "xml", "txt", "md", "pdf", "docx", "rtf"].contains(ext) {
            return true
        }
        if ext == "epub" || MediaPreviewFactory.ebookExtensions.contains(ext) {
            return true
        }
        if MediaPreviewFactory.spreadsheetExtensions.contains(ext) {
            return true
        }
        if MediaPreviewFactory.presentationExtensions.contains(ext) {
            return true
        }
        if MediaPreviewFactory.audioExtensions.contains(ext) {
            return true
        }
        return false
    }
    
    @ViewBuilder
    private func fileInspectorContent(for item: DiskItemInfo) -> some View {
        GeometryReader { proxy in
            let availableHeight = proxy.size.height
            let isImage = ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"]
                .contains((item.name as NSString).pathExtension.lowercased())
            let reservedHeight: CGFloat = isImage ? 230.0 : 250.0
            let dynamicCardHeight = max(280.0, availableHeight - reservedHeight)
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    // 1. Centered Hero Preview Card (Adaptive Height)
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.025))
                        
                        MediaPreviewView(
                            fileURL: effectivePreviewURL,
                            fileName: item.name
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: dynamicCardHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                    )
                    
                    // 2. Quick Action Buttons
                    quickActionButtons(
                        for: item,
                        onPreview: { onPreviewFile(item.path) },
                        onCompress: { onCompressPath(item.path) },
                        onSelectArchive: onSelectArchive
                    )
                    
                    // 3. Structured Metadata Bento Card
                    metadataBentoView(
                        for: item,
                        metadata: deepMetadataDict,
                        dims: asyncDimensions
                    )
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
