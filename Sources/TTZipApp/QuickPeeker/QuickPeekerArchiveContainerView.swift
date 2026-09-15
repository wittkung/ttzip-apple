// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit

/// Dedicated dual-column container for inspecting archive hierarchies and deep-peeking entries.
public struct QuickPeekerArchiveContainerView: View {
    public let archiveURL: URL
    
    @State private var payload: QuickLookPreviewPayload?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchQuery: String = ""
    @State private var selectedNodeId: String?
    @State private var selectedNode: PreviewTreeNode?
    
    // In-memory extracted entry state for zero disk-IO preview
    @State private var extractedData: Data?
    @State private var isExtractingEntry = false
    @State private var entryExtractionError: String?
    
    public init(archiveURL: URL) {
        self.archiveURL = archiveURL
    }
    
    public var body: some View {
        HSplitView {
            // Left Column: Hierarchical Archive Explorer
            VStack(spacing: 0) {
                archiveHeaderBar
                
                searchFilterField
                
                if isLoading {
                    VStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("Inspecting Archive...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                        Spacer()
                    }
                } else if let error = errorMessage {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(TTZipTheme.cinnabarRed)
                        Text(error)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Spacer()
                    }
                } else if let data = payload {
                    archiveEntriesList(data.rootNodes)
                }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            
            // Right Column: Zero Disk-IO Deep Peeking Content
            VStack(spacing: 0) {
                if let node = selectedNode {
                    selectedEntryPreview(node)
                } else {
                    archiveOverviewPlaceholder
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        }
        .task(id: archiveURL) {
            await loadArchiveData()
        }
    }
    
    // MARK: - Subviews
    
    private var archiveHeaderBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(TTZipTheme.archiveAmber)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(archiveURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                
                if let p = payload {
                    HStack(spacing: 6) {
                        Text(p.formatIdentifier.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(TTZipTheme.archiveAmber.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        
                        Text("\(p.totalEntriesCount) items")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        if p.isEncrypted {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(TTZipTheme.kintsugiGold)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .separatorColor).opacity(0.1))
    }
    
    private var searchFilterField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Filter files...", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.caption)
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
    
    private func archiveEntriesList(_ rootNodes: [PreviewTreeNode]) -> some View {
        let flattened = filterNodes(rootNodes, query: searchQuery)
        
        return List(flattened, id: \.id, selection: $selectedNodeId) { node in
            HStack(spacing: 6) {
                Image(systemName: node.isDirectory ? "folder.fill" : fileSystemIcon(for: node.name))
                    .foregroundStyle(node.isDirectory ? TTZipTheme.archiveAmber : .secondary)
                    .font(.caption)
                
                Text(node.name)
                    .font(.caption)
                    .lineLimit(1)
                
                Spacer()
                
                if !node.isDirectory {
                    Text(ByteSizeFormatter.format(bytes: node.uncompressedSizeBytes))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                
                if node.isEncrypted {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedNodeId = node.id
                selectedNode = node
                if !node.isDirectory {
                    Task {
                        await extractEntryData(node)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
    
    private var archiveOverviewPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            
            Text("Select an item to deep-peek inside archive")
                .font(.callout)
                .foregroundStyle(.secondary)
            
            if let p = payload {
                HStack(spacing: 16) {
                    statPill(label: "Uncompressed", value: ByteSizeFormatter.format(bytes: p.uncompressedSizeBytes))
                    statPill(label: "Compressed", value: ByteSizeFormatter.format(bytes: p.compressedSizeBytes))
                    statPill(label: "Ratio", value: String(format: "%.1f%%", p.compressionRatioPercent))
                }
                .padding(.top, 8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func statPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    private func selectedEntryPreview(_ node: PreviewTreeNode) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(node.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(ByteSizeFormatter.format(bytes: node.uncompressedSizeBytes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .separatorColor).opacity(0.08))
            
            Divider()
            
            if isExtractingEntry {
                VStack {
                    Spacer()
                    ProgressView()
                    Text("Streaming entry to memory...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
            } else if let err = entryExtractionError {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "lock.shield")
                        .font(.largeTitle)
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if let data = extractedData {
                renderExtractedData(data, fileName: node.name)
            } else {
                VStack {
                    Spacer()
                    Text("Folder: \(node.name)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }
    
    @ViewBuilder
    private func renderExtractedData(_ data: Data, fileName: String) -> some View {
        let ext = (fileName as NSString).pathExtension.lowercased()
        
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp"].contains(ext),
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .padding()
        } else if let textContent = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
            ScrollView {
                Text(textContent)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "doc.zipper")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(fileName)
                    .font(.headline)
                Text("Binary Data (\(ByteSizeFormatter.format(bytes: Int64(data.count))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadArchiveData() async {
        isLoading = true
        errorMessage = nil
        do {
            let res = try await QuickLookPreviewEngine.inspectForPreview(archivePath: archiveURL.path)
            self.payload = res
            self.isLoading = false
        } catch {
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }
    
    private func extractEntryData(_ node: PreviewTreeNode) async {
        guard !node.isDirectory else { return }
        isExtractingEntry = true
        entryExtractionError = nil
        extractedData = nil
        
        do {
            let data = try await QuickLookPreviewEngine.extractSingleFileMemoryStream(
                archivePath: archiveURL.path,
                entryPath: node.relativePath
            )
            self.extractedData = data
            self.isExtractingEntry = false
        } catch {
            self.entryExtractionError = error.localizedDescription
            self.isExtractingEntry = false
        }
    }
    
    private func filterNodes(_ nodes: [PreviewTreeNode], query: String) -> [PreviewTreeNode] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return flattenTree(nodes)
        }
        let lower = query.lowercased()
        return flattenTree(nodes).filter { $0.name.lowercased().contains(lower) }
    }
    
    private func flattenTree(_ nodes: [PreviewTreeNode]) -> [PreviewTreeNode] {
        var res: [PreviewTreeNode] = []
        for n in nodes {
            res.append(n)
            if let c = n.children, !c.isEmpty {
                res.append(contentsOf: flattenTree(c))
            }
        }
        return res
    }
    
    private func fileSystemIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg": return "photo"
        case "mp4", "mov", "mkv", "avi", "webm": return "film"
        case "mp3", "wav", "flac", "m4a", "aac": return "waveform"
        case "swift", "rs", "py", "c", "cpp", "h", "js", "ts", "json", "xml", "yaml", "yml": return "curlybraces"
        case "md", "txt", "rtf": return "doc.text"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}
