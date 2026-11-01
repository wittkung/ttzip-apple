// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import WebKit

// MARK: - HTML Preview Modes

public enum HTMLPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case rendered = "Rendered"
    case source = "Source Code"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .rendered: return "globe"
        case .source: return "curlybraces"
        }
    }

    @MainActor
    public var localizedTitle: String {
        switch self {
        case .rendered: return HTMLWebPreviewLocalization.text(.modeRendered)
        case .source: return HTMLWebPreviewLocalization.text(.modeSourceCode)
        }
    }
}

// MARK: - Dual-Mode Web Rich Preview View

/// Dual-mode HTML & SVG viewer supporting offline WKWebView rendering, vector zoom, and source inspection.
public struct HTMLWebRichPreviewView: View {
    public let content: String
    public let fileURL: URL?
    public let fileName: String
    public let onSave: ((String) -> Void)?
    
    @Environment(\.previewResourceContext) private var envResourceContext
    @State private var previewMode: HTMLPreviewMode = .rendered
    @State private var reloadToken: Int = 0
    @State private var pageZoom: Double = 1.0
    @State private var isCopiedToastPresented: Bool = false
    
    public init(
        content: String,
        fileURL: URL? = nil,
        fileName: String = "",
        onSave: ((String) -> Void)? = nil
    ) {
        self.content = content
        self.fileURL = fileURL
        if !fileName.isEmpty {
            self.fileName = fileName
        } else if let last = fileURL?.lastPathComponent, !last.isEmpty {
            self.fileName = last
        } else {
            self.fileName = HTMLWebPreviewLocalization.text(.webDocumentFallback)
        }
        self.onSave = onSave
    }

    private var effectiveFileName: String { fileName }
    
    private var lineCount: Int {
        content.reduce(into: 1) { count, char in
            if char == "\n" { count += 1 }
        }
    }
    
    private var characterCount: Int { content.count }
    
    public var body: some View {
        VStack(spacing: 0) {
            topControlBar
            
            Divider()
            
            ZStack {
                if previewMode == .rendered {
                    HTMLWKWebViewRepresentable(
                        content: content,
                        fileURL: fileURL,
                        reloadToken: reloadToken,
                        pageZoom: pageZoom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    makeSourceCodeEditorView(ambientContext: envResourceContext)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: fileURL) { _, _ in
            pageZoom = 1.0
        }
    }

    internal func makeSourceCodeEditorView(
        ambientContext: TTPreviewResourceContext = .unknown()
    ) -> CodeTextEditorContainerView {
        let baseContext: TTPreviewResourceContext =
            ambientContext.origin != .unknown(readableURL: nil) ? ambientContext : envResourceContext
        let isSVGZ = detectedExtension == "SVGZ"
            || fileURL?.pathExtension.lowercased() == "svgz"
            || (effectiveFileName as NSString).pathExtension.lowercased() == "svgz"
            || baseContext.readableURL?.pathExtension.lowercased() == "svgz"
            || (baseContext.displayFileName as NSString).pathExtension.lowercased() == "svgz"
        if isSVGZ {
            let decompressedContext = baseContext
                .withDerivedRepresentation(true, description: "SVGZDecompressedSource")
                .withReadableURL(nil)
            return CodeTextEditorContainerView(
                initialText: content,
                fileURL: nil,
                fileName: effectiveFileName,
                initialByteCount: Int64(content.utf8.count),
                isReadOnly: true,
                resourceContext: decompressedContext
            )
        }
        let forwardedContext: TTPreviewResourceContext? =
            baseContext.origin == .unknown(readableURL: nil) ? nil : baseContext
        return CodeTextEditorContainerView(
            initialText: content,
            fileURL: fileURL,
            fileName: effectiveFileName,
            resourceContext: forwardedContext
        )
    }
    
    // MARK: - Responsive Top Control Bar (220pt / 320pt / 400pt / 520pt)
    
    private var topControlBar: some View {
        ViewThatFits(in: .horizontal) {
            // Tier 1: Full width (>= 520pt)
            HStack(spacing: 10) {
                documentTypeBadge
                fileNameText
                Spacer(minLength: 8)
                documentStatsView
                if previewMode == .rendered {
                    zoomControlCluster
                }
                modeSegmentedSwitcher(isCompact: false, iconOnly: false)
                actionButtonsGroup
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Tier 2: Medium width (360pt ..< 520pt) — deduplicate fileName, move secondary actions to menu
            HStack(spacing: 8) {
                documentTypeBadge
                Spacer(minLength: 6)
                if previewMode == .rendered {
                    zoomControlCluster
                }
                modeSegmentedSwitcher(isCompact: false, iconOnly: false)
                overflowActionsMenu
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // Tier 3: Compact width (260pt ..< 360pt) — compact mode switcher + overflow menu
            HStack(spacing: 6) {
                documentTypeBadge
                Spacer(minLength: 4)
                modeSegmentedSwitcher(isCompact: true, iconOnly: false)
                overflowActionsMenu
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            // Tier 4: Minimal width (< 260pt, down to 220pt sidebar) — icon-only mode switcher + overflow menu
            HStack(spacing: 6) {
                documentTypeBadge
                Spacer(minLength: 4)
                modeSegmentedSwitcher(isCompact: true, iconOnly: true)
                overflowActionsMenu
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var detectedExtension: String {
        if let url = fileURL, !url.pathExtension.isEmpty {
            return url.pathExtension.uppercased()
        }
        if effectiveFileName.contains(".") {
            let ext = (effectiveFileName as NSString).pathExtension
            if !ext.isEmpty { return ext.uppercased() }
        }
        if HTMLWKWebViewRepresentable.isStandaloneSVG(content: content, fileURL: fileURL) {
            return "SVG"
        }
        return "HTML"
    }
    
    private var documentTypeBadge: some View {
        let ext = detectedExtension
        let isVector = (ext == "SVG" || ext == "SVGZ")
        let icon = isVector ? "beziercurve" : "globe"
        let helpLabel = isVector
            ? HTMLWebPreviewLocalization.text(.formatVectorSVG)
            : HTMLWebPreviewLocalization.text(.formatWebRich)
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentColor)
            Text(ext)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .ttButtonHelp(helpLabel)
    }
    
    private var fileNameText: some View {
        Text(effectiveFileName)
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var formattedStatsText: String {
        let linesLabel = HTMLWebPreviewLocalization.text(.linesUnit)
        let charsLabel = HTMLWebPreviewLocalization.text(.charsUnit)
        return "\(lineCount) \(linesLabel) • \(characterCount) \(charsLabel)"
    }
    
    private var documentStatsView: some View {
        Text(formattedStatsText)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var zoomControlCluster: some View {
        let zoomOutHelp = HTMLWebPreviewLocalization.text(.zoomOutHelp)
        let zoomInHelp = HTMLWebPreviewLocalization.text(.zoomInHelp)
        let zoomResetHelp = HTMLWebPreviewLocalization.text(.zoomResetHelp)
        return HStack(spacing: 2) {
            Button(action: { pageZoom = max(0.5, pageZoom - 0.25) }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(pageZoom <= 0.5)
            .ttButtonHelp(zoomOutHelp)
            .accessibilityLabel(zoomOutHelp)

            Button(action: { pageZoom = 1.0 }) {
                Text("\(Int(round(pageZoom * 100)))%")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(abs(pageZoom - 1.0) < 0.01 ? .secondary : Color.accentColor)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            .ttButtonHelp(zoomResetHelp)
            .accessibilityLabel(zoomResetHelp)

            Button(action: { pageZoom = min(3.0, pageZoom + 0.25) }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(pageZoom >= 3.0)
            .ttButtonHelp(zoomInHelp)
            .accessibilityLabel(zoomInHelp)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    private func modeSegmentedSwitcher(isCompact: Bool, iconOnly: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(HTMLPreviewMode.allCases) { mode in
                let title = mode.localizedTitle
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        previewMode = mode
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 10, weight: .bold))
                        if !iconOnly {
                            Text(title)
                                .font(.system(size: 10.5, weight: previewMode == mode ? .bold : .medium))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, isCompact ? 6 : 8)
                    .padding(.vertical, 4)
                    .background(previewMode == mode ? Color.accentColor : Color.clear)
                    .foregroundStyle(previewMode == mode ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .ttButtonHelp(title)
                .accessibilityLabel(title)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    
    private var actionButtonsGroup: some View {
        let refreshHelp = HTMLWebPreviewLocalization.text(.refreshHelp)
        let browserHelp = HTMLWebPreviewLocalization.text(.openInBrowserHelp)
        let copyHelp = HTMLWebPreviewLocalization.text(isCopiedToastPresented ? .copiedToClipboard : .copySourceHelp)
        return HStack(spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    reloadToken += 1
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .ttButtonHelp(refreshHelp)
            .accessibilityLabel(refreshHelp)
            
            Button(action: { openInDefaultBrowser() }) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .ttButtonHelp(browserHelp)
            .accessibilityLabel(browserHelp)
            
            Button(action: { copyContentToClipboard() }) {
                Image(systemName: isCopiedToastPresented ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(isCopiedToastPresented ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(isCopiedToastPresented ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .ttButtonHelp(copyHelp)
            .accessibilityLabel(copyHelp)
        }
    }

    private var overflowActionsMenu: some View {
        let moreHelp = HTMLWebPreviewLocalization.text(.moreActionsHelp)
        return Menu {
            if previewMode == .rendered {
                Button(action: { pageZoom = min(3.0, pageZoom + 0.25) }) {
                    Label(HTMLWebPreviewLocalization.text(.zoomInHelp), systemImage: "plus.magnifyingglass")
                }
                .disabled(pageZoom >= 3.0)

                Button(action: { pageZoom = max(0.5, pageZoom - 0.25) }) {
                    Label(HTMLWebPreviewLocalization.text(.zoomOutHelp), systemImage: "minus.magnifyingglass")
                }
                .disabled(pageZoom <= 0.5)

                Button(action: { pageZoom = 1.0 }) {
                    Label(HTMLWebPreviewLocalization.text(.zoomResetHelp), systemImage: "1.magnifyingglass")
                }
                .disabled(abs(pageZoom - 1.0) < 0.01)

                Divider()
            }

            Button(action: { copyContentToClipboard() }) {
                Label(
                    HTMLWebPreviewLocalization.text(isCopiedToastPresented ? .copiedToClipboard : .copySourceHelp),
                    systemImage: isCopiedToastPresented ? "checkmark" : "doc.on.doc"
                )
            }

            Button(action: { reloadToken += 1 }) {
                Label(HTMLWebPreviewLocalization.text(.refreshHelp), systemImage: "arrow.clockwise")
            }

            Button(action: { openInDefaultBrowser() }) {
                Label(HTMLWebPreviewLocalization.text(.openInBrowserHelp), systemImage: "arrow.up.right.square")
            }

            Divider()

            Text(formattedStatsText)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .ttButtonHelp(moreHelp)
        .accessibilityLabel(moreHelp)
    }
    
    // MARK: - Actions
    
    private func copyContentToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(content, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            isCopiedToastPresented = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeInOut(duration: 0.2)) {
                isCopiedToastPresented = false
            }
        }
    }
    
    private func openInDefaultBrowser() {
        if let url = fileURL, url.isFileURL {
            NSWorkspace.shared.open(url)
        } else {
            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory
                .appendingPathComponent("TTMediaWebPreview", isDirectory: true)
            try? fm.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
            let fileExtension = MHTMLMimeBoundaryGuard.isMultipartMHTML(text: content) ? "mhtml" : "html"
            let tempHTML = tempDir.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
            if (try? content.write(to: tempHTML, atomically: true, encoding: .utf8)) != nil {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempHTML.path)
                NSWorkspace.shared.open(tempHTML)
            }
        }
    }
}
