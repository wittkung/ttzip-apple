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

/// Root host view for QuickPeeker managing active selection list and polymorph preview routing.
public struct QuickPeekerHostView: View {
    public let urls: [URL]
    public let onClose: () -> Void
    
    @State private var currentIndex: Int = 0
    
    public init(urls: [URL], onClose: @escaping () -> Void) {
        self.urls = urls
        self.onClose = onClose
    }
    
    private var currentURL: URL? {
        guard !urls.isEmpty, currentIndex >= 0, currentIndex < urls.count else {
            return nil
        }
        return urls[currentIndex]
    }
    
    private var isArchive: Bool {
        guard let url = currentURL else { return false }
        let ext = url.pathExtension.lowercased()
        return ArchiveCompressionFormat.from(extensionOrName: ext) != nil
    }
    
    public var body: some View {
        ZStack(alignment: .bottom) {
            // Main Content Area with Modern Glassmorphism Background
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            if let url = currentURL {
                Group {
                    if isArchive {
                        QuickPeekerArchiveContainerView(archiveURL: url)
                    } else {
                        MediaPreviewView(fileURL: url, fileName: url.lastPathComponent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                emptySelectionPlaceholder
            }
            
            // Header Top Bar: Filename and Close Button
            VStack {
                HStack(spacing: 8) {
                    if let url = currentURL {
                        Text(url.lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
                
                Spacer()
            }
            
            // Bottom Floating Pagination Capsule (when multiple files selected)
            if urls.count > 1 {
                multipleFilesPaginationBar
                    .padding(.bottom, 16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
        )
        .onReceive(NotificationCenter.default.publisher(for: .ttzipQuickPeekerNextFile)) { _ in
            navigateNext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttzipQuickPeekerPreviousFile)) { _ in
            navigatePrevious()
        }
    }
    
    // MARK: - Subviews
    
    private var emptySelectionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.tap")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No item selected in Finder")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var multipleFilesPaginationBar: some View {
        HStack(spacing: 12) {
            Button(action: navigatePrevious) {
                Image(systemName: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex == 0)
            
            Text("\(currentIndex + 1) / \(urls.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            
            Button(action: navigateNext) {
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex >= urls.count - 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
    
    // MARK: - Navigation
    
    private func navigateNext() {
        if currentIndex < urls.count - 1 {
            withAnimation(.easeInOut(duration: 0.15)) {
                currentIndex += 1
            }
        }
    }
    
    private func navigatePrevious() {
        if currentIndex > 0 {
            withAnimation(.easeInOut(duration: 0.15)) {
                currentIndex -= 1
            }
        }
    }
}
