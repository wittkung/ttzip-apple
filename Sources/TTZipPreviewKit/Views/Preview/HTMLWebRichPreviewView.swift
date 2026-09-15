// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import WebKit
import TTZipCore
import TTZipUI

/// Preview mode for HTML web document viewing.
public enum HTMLPreviewMode: String, CaseIterable, Identifiable {
    case rendered = "网页渲染"
    case source = "源代码"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .rendered: return "globe"
        case .source: return "curlybraces"
        }
    }
}

/// Dual-mode HTML Web viewer supporting high-fidelity WKWebView rendering and syntax source viewing.
public struct HTMLWebRichPreviewView: View {
    public let content: String
    public let fileURL: URL?
    public let fileName: String
    public let onSave: ((String) -> Void)?
    
    @State private var previewMode: HTMLPreviewMode = .rendered
    @State private var reloadToken: Int = 0
    @State private var isCopiedToastPresented: Bool = false
    
    public init(
        content: String,
        fileURL: URL? = nil,
        fileName: String = "",
        onSave: ((String) -> Void)? = nil
    ) {
        self.content = content
        self.fileURL = fileURL
        self.fileName = fileName.isEmpty ? (fileURL?.lastPathComponent ?? "Web Document") : fileName
        self.onSave = onSave
    }
    
    private var lineCount: Int {
        content.reduce(into: 1) { count, char in
            if char == "\n" { count += 1 }
        }
    }
    
    private var characterCount: Int { content.count }
    
    public var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width <= 480
            VStack(spacing: 0) {
                // Top Control & Mode Switcher Bar
                topControlBar(isCompact: isCompact)
                
                Divider()
                
                // Main Content Canvas (Rendered Web vs Source Editor)
                ZStack {
                    if previewMode == .rendered {
                        HTMLWKWebViewRepresentable(
                            content: content,
                            fileURL: fileURL,
                            reloadToken: reloadToken
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        CodeTextEditorContainerView(
                            initialText: content,
                            fileURL: fileURL,
                            fileName: fileName
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
    
    // MARK: - Top Control Bar & Subviews
    
    @ViewBuilder
    private func topControlBar(isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 6 : 10) {
            if isCompact {
                modeSegmentedSwitcher(isCompact: true)
                
                Spacer()
                
                actionButtonsGroup
                
                fullscreenButton
            } else {
                documentTypeBadge
                
                fileNameText
                
                Spacer()
                
                documentStatsView
                
                modeSegmentedSwitcher(isCompact: false)
                
                actionButtonsGroup
                
                fullscreenButton
            }
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var detectedExtension: String {
        if let url = fileURL, !url.pathExtension.isEmpty {
            return url.pathExtension.uppercased()
        }
        if fileName.contains(".") {
            let ext = (fileName as NSString).pathExtension
            if !ext.isEmpty { return ext.uppercased() }
        }
        return "WEB"
    }
    
    private var documentTypeBadge: some View {
        let ext = detectedExtension
        let icon = (ext == "SVG" || ext == "SVGZ") ? "photo.fill" : "globe"
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text(ext)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(TTZipTheme.bambooGreen.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    private var fileNameText: some View {
        Text(fileName)
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
    }
    
    private var documentStatsView: some View {
        HStack(spacing: 8) {
            Text("\(lineCount) lines")
            Text("•")
            Text("\(characterCount) chars")
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    
    private func modeSegmentedSwitcher(isCompact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(HTMLPreviewMode.allCases) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        previewMode = mode
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 10, weight: .bold))
                        Text(mode.rawValue)
                            .font(.system(size: 10.5, weight: previewMode == mode ? .bold : .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, isCompact ? 6 : 8)
                    .padding(.vertical, 4)
                    .background(previewMode == mode ? TTZipTheme.bambooGreen : Color.clear)
                    .foregroundStyle(previewMode == mode ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    
    private var actionButtonsGroup: some View {
        HStack(spacing: 6) {
            // 1. Refresh Webpage Button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
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
            .help("Refresh Webpage (↻)")
            
            // 2. Open in Default Browser Button
            Button(action: {
                openInDefaultBrowser()
            }) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open in Default Browser (Safari / Chrome)")
            
            // 3. Copy HTML Content / Path Button
            Button(action: {
                copyContentToClipboard()
            }) {
                Image(systemName: isCopiedToastPresented ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(isCopiedToastPresented ? TTZipTheme.bambooGreen : Color.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(isCopiedToastPresented ? TTZipTheme.bambooGreen.opacity(0.12) : Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(isCopiedToastPresented ? "Copied to clipboard" : "Copy HTML Content")
        }
    }
    
    private var fullscreenButton: some View {
        Button(action: {
            if let url = fileURL {
                let userInfo: [String: Any] = [
                    "url": url,
                    "name": fileName
                ]
                NotificationCenter.default.post(
                    name: NSNotification.Name("TTZipToggleMediaFocusNotification"),
                    object: url,
                    userInfo: userInfo
                )
            } else {
                NotificationCenter.default.post(
                    name: NSNotification.Name("TTZipToggleMediaFocusNotification"),
                    object: nil
                )
            }
        }) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Toggle Fullscreen Preview")
    }
    
    // MARK: - Actions
    
    private func copyContentToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(content, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            isCopiedToastPresented = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                isCopiedToastPresented = false
            }
        }
    }
    
    private func openInDefaultBrowser() {
        if let url = fileURL, url.isFileURL {
            NSWorkspace.shared.open(url)
        } else {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("TTZipWebPreview", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempHTML = tempDir.appendingPathComponent("\(UUID().uuidString).html")
            if (try? content.write(to: tempHTML, atomically: true, encoding: .utf8)) != nil {
                NSWorkspace.shared.open(tempHTML)
            }
        }
    }
}

// MARK: - WKWebView NSViewRepresentable Wrapper

public struct HTMLWKWebViewRepresentable: NSViewRepresentable {
    public let content: String
    public let fileURL: URL?
    public let reloadToken: Int
    
    public init(content: String, fileURL: URL?, reloadToken: Int = 0) {
        self.content = content
        self.fileURL = fileURL
        self.reloadToken = reloadToken
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.lastLoadedURL = fileURL
        loadHTML(in: webView)
        return webView
    }
    
    public func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            loadHTML(in: webView)
        } else if context.coordinator.lastLoadedURL != fileURL {
            context.coordinator.lastLoadedURL = fileURL
            loadHTML(in: webView)
        }
    }
    
    private func loadHTML(in webView: WKWebView) {
        let rawContent: String = {
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return content
            }
            if let url = fileURL, url.isFileURL, let diskStr = try? String(contentsOf: url, encoding: .utf8) {
                return diskStr
            }
            return ""
        }()
        
        let pathExt = fileURL?.pathExtension.lowercased() ?? ""
        let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isSVG = pathExt == "svg" || pathExt == "svgz" || trimmed.hasPrefix("<svg") || trimmed.contains("<svg")
        
        if isSVG {
            var processedSVG = rawContent
            let lowerSVG = processedSVG.lowercased()
            if !lowerSVG.contains("viewbox") {
                let widthPattern = #"(?i)(?<![\w-])width\s*=\s*["']([^"'%]+)["']"#
                let heightPattern = #"(?i)(?<![\w-])height\s*=\s*["']([^"'%]+)["']"#
                if let widthRegex = try? NSRegularExpression(pattern: widthPattern),
                   let heightRegex = try? NSRegularExpression(pattern: heightPattern) {
                    let nsStr = processedSVG as NSString
                    let fullRange = NSRange(location: 0, length: nsStr.length)
                    if let widthMatch = widthRegex.firstMatch(in: processedSVG, options: [], range: fullRange),
                       let heightMatch = heightRegex.firstMatch(in: processedSVG, options: [], range: fullRange),
                       widthMatch.numberOfRanges > 1,
                       heightMatch.numberOfRanges > 1 {
                        let wRaw = nsStr.substring(with: widthMatch.range(at: 1))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "px", with: "")
                            .replacingOccurrences(of: "pt", with: "")
                        let hRaw = nsStr.substring(with: heightMatch.range(at: 1))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "px", with: "")
                            .replacingOccurrences(of: "pt", with: "")
                        if let w = Double(wRaw), let h = Double(hRaw), w > 0, h > 0 {
                            let wStr = (w.truncatingRemainder(dividingBy: 1) == 0) ? String(Int(w)) : String(w)
                            let hStr = (h.truncatingRemainder(dividingBy: 1) == 0) ? String(Int(h)) : String(h)
                            if let svgTagRange = lowerSVG.range(of: "<svg") {
                                let insertIdx = processedSVG.index(svgTagRange.lowerBound, offsetBy: 4)
                                processedSVG.insert(contentsOf: " viewBox=\"0 0 \(wStr) \(hStr)\"", at: insertIdx)
                            }
                        }
                    }
                }
            }
            
            let htmlEnvelope = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
              html, body {
                margin: 0;
                padding: 16px;
                width: 100%;
                height: 100%;
                box-sizing: border-box;
                display: flex;
                align-items: center;
                justify-content: center;
                background: transparent;
                overflow: hidden;
              }
              svg {
                width: 100% !important;
                height: 100% !important;
                max-width: 100%;
                max-height: 100%;
                object-fit: contain;
              }
            </style>
            </head>
            <body>
            \(processedSVG)
            </body>
            </html>
            """
            webView.loadHTMLString(htmlEnvelope, baseURL: fileURL?.deletingLastPathComponent())
        } else if let url = fileURL, url.isFileURL {
            let directory = url.deletingLastPathComponent()
            webView.loadFileURL(url, allowingReadAccessTo: directory)
        } else {
            webView.loadHTMLString(content, baseURL: nil)
        }
    }
    
    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLWKWebViewRepresentable
        var lastReloadToken: Int = 0
        var lastLoadedURL: URL? = nil
        
        init(_ parent: HTMLWKWebViewRepresentable) {
            self.parent = parent
            super.init()
        }
        
        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if url.isFileURL && url.path == webView.url?.path {
                    // Internal in-page anchor navigation (e.g. #heading)
                    decisionHandler(.allow)
                } else {
                    // External link or different document, open in system default browser
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                }
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

