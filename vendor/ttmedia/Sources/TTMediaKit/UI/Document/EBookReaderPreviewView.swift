// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import WebKit
import CryptoKit
import TTI18nCore
import TTI18nUI

// MARK: - E-Book Information & Metadata Viewer

public struct EBookReaderPreviewView: View {
    public static var inspectionOnlyBannerTitle: String {
        EBookPreviewLocaleKey.inspectionModeBadge.fallbackTranslation(for: .en)
    }
    public static var inspectionOnlyDescription: String {
        EBookPreviewLocaleKey.inspectionModeSummary.fallbackTranslation(for: .en)
    }
    public static let legacyPlaceholderExcerpt = "E-Book publication ready for viewing."

    public let metadata: EBookMetadata
    @State private var sha256Checksum: String? = nil
    @State private var hashedURL: URL? = nil
    @State private var hashGeneration = UUID()
    @State private var isCalculatingHash: Bool = false
    @State private var copiedHash: Bool = false

    public init(metadata: EBookMetadata) {
        self.metadata = metadata
    }

    @MainActor
    public var inspectionBanner: EBookInspectionBannerModel {
        EBookInspectionBannerModel.resolve(for: metadata)
    }

    @MainActor
    public var effectiveInspectionNotice: String {
        inspectionBanner.summaryText
    }

    public var body: some View {
        let banner = inspectionBanner
        VStack(spacing: 12) {
            heroBannerCard(banner: banner)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    filePropertiesCard
                    integrityVerificationCard
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: metadata.url) {
            await computeSHA256()
        }
    }

    @ViewBuilder
    private func heroBannerCard(banner: EBookInspectionBannerModel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                coverThumbnail(width: 80, height: 110)
                heroTextAndActions(banner: banner, isCompact: false)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    coverThumbnail(width: 56, height: 78)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metadata.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        compactMetadataBadges(banner: banner)
                    }
                    Spacer(minLength: 0)
                }
                Text(banner.summaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                heroActionButtons(isCompact: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func coverThumbnail(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.9),
                            Color.accentColor.opacity(0.5)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 2, y: 4)

            if let cover = metadata.coverImage {
                Image(nsImage: cover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: width > 64 ? 28 : 20))
                        .foregroundStyle(.white)

                    Text(metadata.formatName.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.28))
                        .clipShape(Capsule())
                }
            }
        }
        .frame(width: width, height: height)
    }

    private func heroTextAndActions(banner: EBookInspectionBannerModel, isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(metadata.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Label(metadata.formatName.uppercased(), systemImage: "doc.text.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(metadata.fileSizeDescription)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Label(banner.badgeTitle, systemImage: "magnifyingglass.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                }
                compactMetadataBadges(banner: banner)
            }

            Text(banner.summaryText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            heroActionButtons(isCompact: isCompact)
                .padding(.top, 4)
        }
    }

    private func compactMetadataBadges(banner: EBookInspectionBannerModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Label(metadata.formatName.uppercased(), systemImage: "doc.text.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text("•")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(metadata.fileSizeDescription)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Label(banner.badgeTitle, systemImage: "magnifyingglass.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.orange)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func heroActionButtons(isCompact: Bool) -> some View {
        let openTitle = EBookPreviewLocalization.text(.openInExternalReader)
        let revealTitle = EBookPreviewLocalization.text(.revealInFinder)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                externalReaderButton(title: openTitle, expandWidth: false)
                revealInFinderButton(title: revealTitle, expandWidth: false)
            }
            VStack(alignment: .leading, spacing: 6) {
                externalReaderButton(title: openTitle, expandWidth: isCompact)
                revealInFinderButton(title: revealTitle, expandWidth: isCompact)
            }
        }
    }

    private func externalReaderButton(title: String, expandWidth: Bool) -> some View {
        Button(action: { NSWorkspace.shared.open(metadata.url) }) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.forward.app.fill")
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: expandWidth ? .infinity : nil)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .ttButtonHelp(title)
    }

    private func revealInFinderButton(title: String, expandWidth: Bool) -> some View {
        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([metadata.url]) }) {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: expandWidth ? .infinity : nil)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .ttButtonHelp(title)
    }

    private var filePropertiesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text(EBookPreviewLocalization.text(.fileProperties))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            Divider().opacity(0.5)

            infoRow(title: EBookPreviewLocalization.text(.fileName), value: metadata.url.lastPathComponent, isMonospaced: true)
            infoRow(title: EBookPreviewLocalization.text(.format), value: metadata.formatName.uppercased(), isMonospaced: true)
            infoRow(title: EBookPreviewLocalization.text(.fileSize), value: metadata.fileSizeDescription, isMonospaced: true)
            infoRow(title: EBookPreviewLocalization.text(.location), value: metadata.url.deletingLastPathComponent().path, isMonospaced: false)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var integrityVerificationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "shield.checkerboard")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.orange)
                Text(EBookPreviewLocalization.text(.verifyIntegrity))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()

                if let hash = sha256Checksum {
                    copyHashButton(hash: hash)
                }
            }

            Divider().opacity(0.5)

            if isCalculatingHash {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(EBookPreviewLocalization.text(.computingSHA256))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if let hash = sha256Checksum {
                VStack(alignment: .leading, spacing: 4) {
                    Text(EBookPreviewLocalization.text(.integrityVerifiedSHA256))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(hash)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            } else {
                Text(EBookPreviewLocalization.text(.checksumUnavailable))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }

    private func copyHashButton(hash: String) -> some View {
        let labelText = EBookPreviewLocalization.text(copiedHash ? .copied : .copySHA256)
        return Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hash, forType: .string)
            copiedHash = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.0))
                copiedHash = false
            }
        }) {
            HStack(spacing: 3) {
                Image(systemName: copiedHash ? "checkmark.circle.fill" : "doc.on.doc.fill")
                Text(labelText)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(copiedHash ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .ttButtonHelp(labelText)
    }

    private func infoRow(title: String, value: String, isMonospaced: Bool) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(isMonospaced ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)

            Spacer()
        }
    }

    nonisolated public static func computeSHA256Hex(for url: URL) async -> String? {
        guard !Task.isCancelled else { return nil }
        let computeTask = Task.detached(priority: .utility) { () -> String? in
            guard !Task.isCancelled else { return nil }
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                guard !Task.isCancelled else { return nil }
                let digest = SHA256.hash(data: data)
                guard !Task.isCancelled else { return nil }
                return digest.map { String(format: "%02x", $0) }.joined()
            }
            guard !Task.isCancelled else { return nil }
            if let provider = EPUBChapterContentLoaderActor.customDataProvider,
               let data = await provider(url) {
                guard !Task.isCancelled else { return nil }
                let digest = SHA256.hash(data: data)
                guard !Task.isCancelled else { return nil }
                return digest.map { String(format: "%02x", $0) }.joined()
            }
            return nil
        }
        return await withTaskCancellationHandler {
            await computeTask.value
        } onCancel: {
            computeTask.cancel()
        }
    }

    @MainActor
    private func computeSHA256() async {
        let targetURL = metadata.url
        if hashedURL == targetURL, sha256Checksum != nil {
            return
        }
        sha256Checksum = nil
        copiedHash = false
        hashedURL = targetURL
        isCalculatingHash = true
        let gen = UUID()
        hashGeneration = gen

        let hashStr = await Self.computeSHA256Hex(for: targetURL)
        guard !Task.isCancelled, hashGeneration == gen, metadata.url == targetURL else { return }
        self.sha256Checksum = hashStr
        self.isCalculatingHash = false
    }
}
