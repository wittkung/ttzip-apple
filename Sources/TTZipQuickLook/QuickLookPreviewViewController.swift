// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Cocoa
@preconcurrency import QuickLookUI
import WebKit
import TTZipCore

/// macOS Native QuickLook Previewing View Controller for all 16 supported archive formats.
@objc(QuickLookPreviewViewController)
public final class QuickLookPreviewViewController: NSViewController, @preconcurrency QLPreviewingController, WKNavigationDelegate {
    
    private var webView: WKWebView?
    private var activityIndicator: NSProgressIndicator?
    private var pendingCompletion: ((Error?) -> Void)?
    private var currentTask: Task<Void, Never>?
    private var currentGeneration: UInt64 = 0
    private var currentNavigation: WKNavigation?
    
    deinit {
        currentTask?.cancel()
    }
    
    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.wantsLayer = true
        
        let config = WKWebViewConfiguration()
        
        let webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        container.addSubview(webView)
        self.webView = webView
        
        let activityIndicator = NSProgressIndicator()
        activityIndicator.style = .spinning
        activityIndicator.controlSize = .regular
        activityIndicator.sizeToFit()
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.isDisplayedWhenStopped = false
        container.addSubview(activityIndicator)
        self.activityIndicator = activityIndicator
        
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        
        self.view = container
    }
    
    // MARK: - QLPreviewingController
    
    public func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // Increment generation counter to invalidate previous in-flight tasks and navigations
        currentGeneration &+= 1
        let generation = currentGeneration
        
        // Cancel existing background extraction task if still running
        currentExtractionTaskCleanup()
        
        // Stop any active WebKit page loading
        webView?.stopLoading()
        currentNavigation = nil
        
        // Settle previous pending completion cleanly before assigning the new one
        if let previousCompletion = self.pendingCompletion {
            self.pendingCompletion = nil
            previousCompletion(CocoaError(.userCancelled))
        }
        
        self.pendingCompletion = handler
        activityIndicator?.startAnimation(nil)
        
        let targetLanguage = TTZipPreferencesStore.getSavedLanguage() ?? TTZipLocalizationManager.shared.currentLanguage
        
        currentTask = Task { @MainActor [weak self] in
            guard let self else {
                handler(CocoaError(.userCancelled))
                return
            }
            
            // Fast exit if another request preempted this task before starting
            guard self.currentGeneration == generation, !Task.isCancelled else {
                if self.currentGeneration == generation {
                    self.activityIndicator?.stopAnimation(nil)
                    self.pendingCompletion = nil
                    handler(CocoaError(.userCancelled))
                }
                return
            }
            
            do {
                let html = try await self.generateWindowedHTMLPreview(for: url.path, language: targetLanguage)
                
                // Confirm generation validity after async extraction completed
                guard self.currentGeneration == generation, !Task.isCancelled else {
                    if self.currentGeneration == generation {
                        self.activityIndicator?.stopAnimation(nil)
                        self.pendingCompletion = nil
                        handler(CocoaError(.userCancelled))
                    }
                    return
                }
                
                // Set baseURL to nil to prevent sandbox traversal / cross-origin resource leakage
                self.currentNavigation = self.webView?.loadHTMLString(html, baseURL: nil)
            } catch {
                guard self.currentGeneration == generation else { return }
                self.activityIndicator?.stopAnimation(nil)
                
                if Task.isCancelled {
                    if self.pendingCompletion != nil {
                        self.pendingCompletion = nil
                        handler(CocoaError(.userCancelled))
                    }
                    return
                }
                
                self.renderErrorFallback(error: error, fileURL: url, language: targetLanguage)
                if let completion = self.pendingCompletion {
                    self.pendingCompletion = nil
                    completion(nil)
                }
            }
        }
    }
    
    private func generateWindowedHTMLPreview(for archivePath: String, language: AppLanguage) async throws -> String {
        guard let session = RustVfsSession(archivePath: archivePath) else {
            return try await QuickLookPreviewEngine.generateHTMLPreview(for: archivePath, language: language)
        }
        
        let stats = session.getStats()
        let totalCount = Int(stats.totalFiles + stats.totalDirs)
        let uncompressedSize = Int64(stats.totalSize)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: archivePath)[.size] as? Int64) ?? 0
        
        let limit = 500
        let (nodes, _) = session.getChildrenPaged(subpath: nil, offset: 0, limit: limit)
        
        let manager = TTZipLocalizationManager.shared
        let locale = Locale(identifier: language.bcp47)
        let archiveName = URL(fileURLWithPath: archivePath).lastPathComponent
        let ext = (archiveName as NSString).pathExtension.uppercased()
        let formatLabel = ext.isEmpty ? "ARCHIVE" : ext
        
        let formattedUncompressed = ByteSizeFormatter.format(bytes: uncompressedSize, language: language)
        let formattedCompressed = ByteSizeFormatter.format(bytes: fileSize, language: language)
        
        let nameHeader = manager.string(for: L10n.Explorer.nameHeader, language: language)
        let sizeHeader = manager.string(for: L10n.Explorer.sizeHeader, language: language)
        let compressedTemplate = manager.string(for: L10n.QuickLook.compressedFormat, language: language)
        let compressedLabel = String(format: compressedTemplate, locale: locale, formattedCompressed)
        let itemsCountTemplate = manager.string(for: L10n.Units.itemsCount, language: language)
        let itemsCountLabel = String(format: itemsCountTemplate, locale: locale, totalCount)
        let footerText = manager.string(for: L10n.QuickLook.renderedFooter, language: language)
        
        var rowsHTML = ""
        for node in nodes {
            let icon = node.isDirectory ? "📁" : fileIconEmoji(for: node.name)
            let sizeStr = node.isDirectory ? "--" : ByteSizeFormatter.format(bytes: Int64(node.uncompressedSize), language: language)
            let encBadge = node.isEncrypted ? "<span class='badge enc'>🔒</span>" : ""
            
            rowsHTML += """
            <tr>
                <td class="name-col"><span class="icon">\(icon)</span> \(escapeHTML(node.name)) \(encBadge)</td>
                <td class="size-col">\(sizeStr)</td>
            </tr>
            """
        }
        
        if totalCount > limit {
            let omittedCount = totalCount - limit
            let omittedTemplate = manager.string(for: L10n.QuickLook.itemsOmittedFormat, language: language)
            let omittedText = String(format: omittedTemplate, locale: locale, limit, omittedCount)
            rowsHTML += """
            <tr>
                <td colspan="2" class="name-col" style="text-align: center; color: var(--secondary-text); padding: 12px;">
                    \(escapeHTML(omittedText))
                </td>
            </tr>
            """
        }
        
        return """
        <!DOCTYPE html>
        <html lang="\(language.bcp47)">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escapeHTML(archiveName)) — TTZip QuickLook</title>
            <style>
                :root {
                    --bg-color: #FFFFFF;
                    --text-color: #1D1D1F;
                    --secondary-text: #86868B;
                    --border-color: #E5E5EA;
                    --header-bg: #F5F5F7;
                    --badge-bg: #0071E3;
                    --badge-text: #FFFFFF;
                    --accent-gold: #D4AF37;
                }
                @media (prefers-color-scheme: dark) {
                    :root {
                        --bg-color: #1C1C1E;
                        --text-color: #F5F5F7;
                        --secondary-text: #98989D;
                        --border-color: #2C2C2E;
                        --header-bg: #2C2C2E;
                        --badge-bg: #0A84FF;
                        --badge-text: #FFFFFF;
                    }
                }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
                    background-color: var(--bg-color);
                    color: var(--text-color);
                    margin: 0;
                    padding: 24px;
                    font-size: 13px;
                    line-height: 1.5;
                }
                .header {
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                    border-bottom: 1px solid var(--border-color);
                    padding-bottom: 16px;
                    margin-bottom: 16px;
                }
                .title-section h1 {
                    font-size: 18px;
                    font-weight: 600;
                    margin: 0 0 4px 0;
                    letter-spacing: -0.01em;
                }
                .meta-stats {
                    font-size: 12px;
                    color: var(--secondary-text);
                    display: flex;
                    gap: 12px;
                }
                .badge {
                    display: inline-block;
                    padding: 2px 8px;
                    border-radius: 6px;
                    font-size: 11px;
                    font-weight: 600;
                    background-color: var(--badge-bg);
                    color: var(--badge-text);
                }
                .badge.enc {
                    background-color: var(--accent-gold);
                }
                table {
                    width: 100%;
                    border-collapse: collapse;
                }
                th {
                    text-align: left;
                    font-size: 11px;
                    font-weight: 600;
                    color: var(--secondary-text);
                    text-transform: uppercase;
                    border-bottom: 1px solid var(--border-color);
                    padding: 6px 12px;
                }
                td {
                    padding: 6px 12px;
                    border-bottom: 1px solid var(--border-color);
                }
                .name-col {
                    width: 75%;
                }
                .size-col {
                    width: 25%;
                    text-align: right;
                    color: var(--secondary-text);
                    font-variant-numeric: tabular-nums;
                }
                .icon {
                    margin-right: 6px;
                }
                .footer {
                    margin-top: 20px;
                    text-align: center;
                    font-size: 11px;
                    color: var(--secondary-text);
                }
            </style>
        </head>
        <body>
            <div class="header">
                <div class="title-section">
                    <h1>\(escapeHTML(archiveName))</h1>
                    <div class="meta-stats">
                        <span>\(formatLabel)</span> •
                        <span>\(itemsCountLabel)</span> •
                        <span>\(formattedUncompressed)</span>
                        \(fileSize > 0 ? "• <span>\(compressedLabel)</span>" : "")
                    </div>
                </div>
            </div>
            <table>
                <thead>
                    <tr>
                        <th>\(nameHeader)</th>
                        <th style="text-align: right;">\(sizeHeader)</th>
                    </tr>
                </thead>
                <tbody>
                    \(rowsHTML)
                </tbody>
            </table>
            <div class="footer">
                \(footerText)
            </div>
        </body>
        </html>
        """
    }

    private func fileIconEmoji(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "7z", "rar", "tar", "gz", "bz2", "xz": return "📦"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return "🖼️"
        case "mp4", "mov", "mkv", "avi": return "🎬"
        case "mp3", "wav", "flac", "aac", "m4a": return "🎵"
        case "pdf": return "📕"
        case "txt", "md", "json", "xml", "csv", "swift", "rs", "c", "h", "cpp", "py", "sh": return "📄"
        default: return "📄"
        }
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    
    private func currentExtractionTaskCleanup() {
        currentTask?.cancel()
        currentTask = nil
    }
    
    private func renderErrorFallback(error: Error, fileURL: URL, language: AppLanguage) {
        let manager = TTZipLocalizationManager.shared
        let isEncrypted: Bool
        if let archiveErr = error as? ArchiveError {
            switch archiveErr {
            case .passwordRequired, .passwordRequiredDetailed, .wrongPassword:
                isEncrypted = true
            default:
                isEncrypted = false
            }
        } else {
            isEncrypted = false
        }
        
        let title = isEncrypted
            ? manager.string(for: L10n.QuickLook.protectedWithPassword, language: language)
            : manager.string(for: L10n.QuickLook.cannotPreview, language: language)
        let subtitle = isEncrypted
            ? manager.string(for: L10n.Explorer.passwordProtectedArchive, language: language)
            : (error as? ArchiveError)?.localizedDescription(for: language) ?? error.localizedDescription
        let icon = isEncrypted ? "🔒" : "⚠️"
        
        let errorHTML = """
        <!DOCTYPE html>
        <html lang="\(language.bcp47)">
        <head>
        <meta charset="utf-8">
        <style>
            :root { color-scheme: light dark; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
                margin: 0; padding: 40px; display: flex; flex-direction: column;
                align-items: center; justify-content: center; height: 100vh;
                background: transparent; color: #1c1c1e;
            }
            @media (prefers-color-scheme: dark) { body { color: #f2f2f7; } }
            .icon { font-size: 64px; margin-bottom: 16px; }
            .title { font-size: 20px; font-weight: 600; margin-bottom: 8px; }
            .subtitle { font-size: 14px; opacity: 0.7; text-align: center; max-width: 400px; line-height: 1.5; }
            .filename { margin-top: 16px; font-family: ui-monospace, monospace; font-size: 12px; opacity: 0.5; }
        </style>
        </head>
        <body>
            <div class="icon">\(icon)</div>
            <div class="title">\(title)</div>
            <div class="subtitle">\(subtitle)</div>
            <div class="filename">\(fileURL.lastPathComponent)</div>
        </body>
        </html>
        """
        self.currentNavigation = self.webView?.loadHTMLString(errorHTML, baseURL: nil)
    }
    
    // MARK: - WKNavigationDelegate
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard navigation == nil || navigation === currentNavigation else { return }
        activityIndicator?.stopAnimation(nil)
        if let completion = pendingCompletion {
            pendingCompletion = nil
            completion(nil)
        }
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        guard navigation == nil || navigation === currentNavigation else { return }
        activityIndicator?.stopAnimation(nil)
        if let completion = pendingCompletion {
            pendingCompletion = nil
            completion(error)
        }
    }
    
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        guard navigation == nil || navigation === currentNavigation else { return }
        activityIndicator?.stopAnimation(nil)
        if let completion = pendingCompletion {
            pendingCompletion = nil
            completion(error)
        }
    }
}
