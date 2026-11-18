// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import CryptoKit
import AVFoundation
import CoreMedia
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTMediaKit

public struct ExplorerItemInspectorView: View {
    public let item: DiskItemInfo?
    public let hostWindowID: UUID?
    public let onSelectArchive: (String) -> Void
    public let onCompressPath: (String) -> Void
    public let onPreviewFile: (String) -> Void
    
    @Environment(AppViewState.self) private var environmentViewModel: AppViewState?
    @State var asyncDimensions: String? = nil
    @State var orientedVideoAspectRatio: CGFloat?
    @State var localPreviewURL: URL? = nil
    @State var activePreviewLease: PreviewCacheLease? = nil
    @State var resolvedPreviewType: MediaPreviewType? = nil
    @State var deepMetadataDict: [String: String] = [:]
    @State private var virtualPreviewFailure: ArchiveEntryPreviewFailure?
    @State private var virtualPreviewRequest: ArchiveEntryPreviewRequest?
    @State private var virtualPreviewRetry: UInt64 = 0
    var l10n: AppLocalizationState { AppLocalizationState.shared }

    public static let comicArchiveExtensions: Set<String> = ["cbz", "cbr", "cb7", "cbt"]

    public static func isComicArchiveItem(_ item: DiskItemInfo) -> Bool {
        guard !item.isDirectory else { return false }
        let ext = (item.name as NSString).pathExtension.lowercased()
        return comicArchiveExtensions.contains(ext)
    }

    package var activePinnedCacheKey: String? {
        activePreviewLease?.key
    }

    package var effectiveBrowserWindowID: UUID? {
        hostWindowID ?? environmentViewModel?.windowID
    }

    @MainActor
    package static func canRetryPasswordLockedPreviewPrompt(
        failure: ArchiveEntryPreviewFailure?,
        request: ArchiveEntryPreviewRequest?,
        in viewModel: AppViewState?
    ) -> Bool {
        guard let failure, failure.isPasswordRelated,
              let request, let viewModel,
              !viewModel.showPasswordPrompt,
              viewModel.pendingPasswordContext == nil else {
            return false
        }
        return viewModel.isArchiveEntryPreviewRequestCurrent(request)
    }

    @discardableResult
    @MainActor
    package static func retryPasswordLockedPreviewPrompt(
        failure: ArchiveEntryPreviewFailure?,
        request: ArchiveEntryPreviewRequest?,
        in viewModel: AppViewState?
    ) -> Bool {
        guard canRetryPasswordLockedPreviewPrompt(failure: failure, request: request, in: viewModel),
              let failure, let request, let viewModel else {
            return false
        }
        viewModel.acceptArchiveEntryPreviewFailure(failure, request: request)
        return viewModel.showPasswordPrompt
    }
    
    public init(
        item: DiskItemInfo? = nil,
        hostWindowID: UUID? = nil,
        onSelectArchive: @escaping (String) -> Void,
        onCompressPath: @escaping (String) -> Void,
        onPreviewFile: @escaping (String) -> Void
    ) {
        self.item = item
        self.hostWindowID = hostWindowID
        self.onSelectArchive = onSelectArchive
        self.onCompressPath = onCompressPath
        self.onPreviewFile = onPreviewFile
    }
    
    package var isVirtualItem: Bool {
        guard let item = item else { return false }
        if let u = URL(string: item.path), let q = u.query, q.contains("subpath=") {
            return true
        }
        return false
    }

    package var virtualArchiveComponents: (archivePath: String, subpath: String)? {
        guard let item = item,
              let u = URL(string: item.path),
              let comp = URLComponents(url: u, resolvingAgainstBaseURL: false),
              let qItems = comp.queryItems,
              let sub = qItems.first(where: { $0.name == "subpath" })?.value else {
            return nil
        }
        return (u.path, sub)
    }
    
    package var effectivePreviewURL: URL? {
        if isVirtualItem {
            return localPreviewURL
        }
        guard let item = item else { return nil }
        if item.path.hasPrefix("ttzip://") || item.path.hasPrefix("http://") || item.path.hasPrefix("https://"),
           let url = URL(string: item.path) {
            return url
        }
        if item.path.hasPrefix("file://"),
           let parsed = URL(string: item.path),
           parsed.isFileURL {
            let fileURL = parsed.standardizedFileURL.resolvingSymlinksInPath()
            _ = RootFolderAccessManager.shared.ensureAccess(for: fileURL)
            return fileURL
        }
        let fileURL = URL(fileURLWithPath: item.path).standardizedFileURL.resolvingSymlinksInPath()
        _ = RootFolderAccessManager.shared.ensureAccess(for: fileURL)
        return fileURL
    }
    
    package var effectiveModificationDate: Date? {
        if let d = item?.modificationDate {
            return d
        }
        guard !isVirtualItem, let targetPath = effectivePreviewURL?.path else { return nil }
        if FileManager.default.fileExists(atPath: targetPath),
           let attr = try? FileManager.default.attributesOfItem(atPath: targetPath) {
            return attr[FileAttributeKey.modificationDate] as? Date
        }
        return nil
    }

    public static func usesFolderArtboard(for item: DiskItemInfo) -> Bool {
        item.isDirectory
    }

    @ViewBuilder
    public var body: some View {
        inspectorBody
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .onDisappear {
                if let lease = activePreviewLease {
                    activePreviewLease = nil
                    Task {
                        await PreviewLRUCacheManager.shared.releaseLease(lease)
                    }
                }
            }
            .task(id: item?.path) {
                self.deepMetadataDict = [:]
            }
            .task(id: PreviewReadIdentity(itemPath: item?.path, retry: virtualPreviewRetry)) {
                await runPreviewLoadTask()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipArchiveUnlockedRefresh"))) { notification in
                guard virtualPreviewFailure?.isPasswordRelated == true,
                      let request = virtualPreviewRequest,
                      environmentViewModel?.shouldRetryArchiveEntryPreview(request, notification: notification) == true else { return }
                virtualPreviewRetry &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipArchivePasswordForgotten"))) { notification in
                guard let vComponents = virtualArchiveComponents else { return }
                if let forgottenPath = notification.object as? String {
                    let lhs = ArchiveCredentialIdentity.logicalKey(for: vComponents.archivePath)
                    let rhs = ArchiveCredentialIdentity.logicalKey(for: forgottenPath)
                    guard lhs == rhs else { return }
                }
                if let lease = activePreviewLease {
                    activePreviewLease = nil
                    Task { await PreviewLRUCacheManager.shared.releaseLease(lease) }
                }
                localPreviewURL = nil
                virtualPreviewRetry &+= 1
            }
    }

    @ViewBuilder
    private var inspectorBody: some View {
        if let item = item {
            if Self.usesFolderArtboard(for: item) {
                FolderMediaArtboardView(
                    item: item,
                    onCompressPath: onCompressPath,
                    onSelectArchive: nil
                )
                .id(item.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if let failure = virtualPreviewFailure {
                        HStack(spacing: 12) {
                            Text(failure.message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if Self.canRetryPasswordLockedPreviewPrompt(
                                failure: failure,
                                request: virtualPreviewRequest,
                                in: environmentViewModel
                            ) {
                                Button(l10n.t(L10n.Extract.passwordPrompt)) {
                                    _ = Self.retryPasswordLockedPreviewPrompt(
                                        failure: failure,
                                        request: virtualPreviewRequest,
                                        in: environmentViewModel
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                        .padding(12)
                    }
                    fileInspectorContent(for: item)
                }
            }
        } else {
            zenPlaceholderView
        }
    }

    private func runPreviewLoadTask() async {
        let previousLease = self.activePreviewLease
        self.activePreviewLease = nil
        self.localPreviewURL = nil
        self.resolvedPreviewType = nil
        self.asyncDimensions = nil
        self.virtualPreviewFailure = nil
        self.virtualPreviewRequest = nil

        if let previousLease {
            await PreviewLRUCacheManager.shared.releaseLease(previousLease)
        }
        guard let item = item else { return }

        if let vComponents = virtualArchiveComponents, !item.isDirectory {
            let loaded = await loadVirtualEntryPreview(
                item: item,
                archivePath: vComponents.archivePath,
                subpath: vComponents.subpath
            )
            guard loaded, !Task.isCancelled else { return }
        }

        guard !Task.isCancelled else { return }
        guard let targetURL = effectivePreviewURL else {
            self.asyncDimensions = nil
            return
        }
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

    private func loadVirtualEntryPreview(
        item: DiskItemInfo,
        archivePath: String,
        subpath: String
    ) async -> Bool {
        let request = environmentViewModel?.captureArchiveEntryPreviewRequest(itemPath: item.path)
        self.virtualPreviewRequest = request
        let passwordRequiredWithoutCache = request.map {
            environmentViewModel?.requiresPasswordForArchiveEntryPreview($0) == true
        } ?? false
        let taskConsumerID = UUID()
        let archiveLease = RootFolderAccessManager.shared.acquireLease(for: URL(fileURLWithPath: archivePath))
        defer { archiveLease?.release() }
        let resolved = await Self.resolveAndPinVirtualPreviewURL(
            archivePath: archivePath,
            subpath: subpath,
            estimatedBytes: item.rawSizeBytes,
            consumerID: taskConsumerID,
            previousLease: nil,
            cacheManager: .shared,
            passwordRequiredWithoutCache: passwordRequiredWithoutCache
        )
        guard !Task.isCancelled else {
            if let lease = resolved.lease {
                await PreviewLRUCacheManager.shared.releaseLease(lease)
            }
            return false
        }
        if let request, environmentViewModel?.isArchiveEntryPreviewRequestCurrent(request) != true {
            if let lease = resolved.lease { await PreviewLRUCacheManager.shared.releaseLease(lease) }
            return false
        }
        self.activePreviewLease = resolved.lease
        self.localPreviewURL = resolved.url
        if let failure = resolved.failure, failure != .cancelled {
            self.virtualPreviewFailure = failure
            if let request {
                environmentViewModel?.acceptArchiveEntryPreviewFailure(failure, request: request)
            }
        }
        if let windowID = effectiveBrowserWindowID, let key = resolved.lease?.key {
            _ = await StandalonePlaybackWindowManager.shared.consumeOriginRestoredLease(
                forWindowID: windowID,
                key: key
            )
        }
        return true
    }

    private struct PreviewReadIdentity: Hashable {
        let itemPath: String?
        let retry: UInt64
    }

    @ViewBuilder
    private func fileInspectorContent(for item: DiskItemInfo) -> some View {
        GeometryReader { proxy in
            let availableHeight = proxy.size.height
            let contentWidth = max(0, proxy.size.width - 16)
            let naturalHeight = computeNaturalAdaptiveHeight(
                for: item,
                contentWidth: contentWidth,
                availableHeight: availableHeight
            )
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    inspectorHeroPreview(
                        for: item,
                        contentWidth: contentWidth,
                        naturalHeight: naturalHeight
                    )

                    quickActionButtons(
                        for: item,
                        onPreview: {
                            onPreviewFile(item.path)
                        },
                        onCompress: { onCompressPath(item.path) },
                        onSelectArchive: { archivePath in
                            environmentViewModel?.presentExtractModal(forArchiveAt: archivePath)
                            onSelectArchive(archivePath)
                        }
                    )
                    .frame(maxWidth: contentWidth)

                    metadataBentoView(
                        for: item,
                        metadata: deepMetadataDict,
                        dims: asyncDimensions
                    )
                    .frame(maxWidth: contentWidth)
                }
                .frame(width: contentWidth)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 36)
                .frame(width: proxy.size.width)
                .background(ConfigureNSScrollView())
            }
            .scrollContentBackground(.hidden)
            .background(ConfigureNSScrollView())
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func inspectorHeroPreview(
        for item: DiskItemInfo,
        contentWidth: CGFloat,
        naturalHeight: CGFloat
    ) -> some View {
        let vComponents = virtualArchiveComponents
        MediaPreviewView(
            fileURL: effectivePreviewURL,
            fileName: item.name,
            showsFloatingFullScreenButton: true,
            sourceArchivePath: vComponents?.archivePath,
            archiveSubpath: vComponents?.subpath,
            resourceCacheKey: activePinnedCacheKey,
            isEditable: !isVirtualItem,
            onPreviewTypeResolved: { resolvedType in
                self.resolvedPreviewType = resolvedType
            }
        )
        .environment(
            \.previewHostContentGeometry,
            TTPreviewHostContentGeometry(
                layoutClass: resolvedPreviewType?.hostLayoutClass ?? .structuredDocument,
                hostHeaderHeight: 0,
                contentTopSafeInset: 0,
                availableSize: CGSize(width: contentWidth, height: naturalHeight),
                isStandalonePlaybackWindow: false
            )
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                TTPreviewHorizontalKeyPolicy.releaseFileListKeyboardFocus(
                    windowNumber: NSApp.keyWindow?.windowNumber
                )
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: .ttMediaVideoGeometryChanged)) { notification in
            guard let url = notification.object as? URL,
                  url.standardizedFileURL == effectivePreviewURL?.standardizedFileURL,
                  let size = VideoPlaybackPresentation.orientedSize(for: url), size.height > 0 else { return }
            orientedVideoAspectRatio = size.width / size.height
        }
        .onChange(of: effectivePreviewURL) { _, _ in orientedVideoAspectRatio = nil }
        .id(effectivePreviewURL?.path ?? item.path)
        .frame(width: contentWidth)
        .frame(height: naturalHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(previewAccessibilityModeName(for: item))
        .accessibilityValue(previewAccessibilityModeName(for: item))
        .accessibilityIdentifier("InspectorHeroPreviewContainer")
    }
}
