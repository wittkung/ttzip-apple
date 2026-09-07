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

/// Immersive full-viewport media browser presenting media files over a frosted dark scrim.
/// Features a floating Glassmorphic HUD with Zen Kintsugi Gold badge, keyboard shortcuts,
/// and smooth file navigation across the active directory.
public struct ImmersiveMediaBrowserView: View {
    public let item: ImmersiveMediaItem
    public let onClose: () -> Void
    public let onNavigatePrevious: (() -> Void)?
    public let onNavigateNext: (() -> Void)?
    
    @State private var eventMonitor: Any? = nil
    @State private var isCopiedToastShown: Bool = false
    
    public init(
        item: ImmersiveMediaItem,
        onClose: @escaping () -> Void,
        onNavigatePrevious: (() -> Void)? = nil,
        onNavigateNext: (() -> Void)? = nil
    ) {
        self.item = item
        self.onClose = onClose
        self.onNavigatePrevious = onNavigatePrevious
        self.onNavigateNext = onNavigateNext
    }
    
    private var formatExtension: String {
        let ext = item.url.pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : ext
    }
    
    private var fileSizeDescription: String? {
        if let size = item.fileSizeBytes {
            return ByteCountFormatterFlyweight.shared.string(fromByteCount: size)
        }
        if let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            return ByteCountFormatterFlyweight.shared.string(fromByteCount: Int64(size))
        }
        return nil
    }
    
    public var body: some View {
        ZStack {
            // Layer 1: Frosted Scrim Dismiss Layer
            Color.black.opacity(0.92)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }
            
            // Layer 2: Main Center Media Viewport
            VStack(spacing: 0) {
                MediaPreviewView(
                    fileURL: item.url,
                    fileName: item.name
                )
                .id(item.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
            }
            .padding(.horizontal, (onNavigatePrevious != nil || onNavigateNext != nil) ? 80 : 32)
            .padding(.top, 82)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Layer 3: Left & Right Navigation Chevrons
            HStack(spacing: 0) {
                if let prev = onNavigatePrevious {
                    Button(action: prev) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(.ultraThinMaterial)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.8))
                            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 18)
                    .help("Previous media (Left arrow)")
                } else {
                    Spacer().frame(width: 46)
                        .padding(.leading, 18)
                }
                
                Spacer()
                
                if let next = onNavigateNext {
                    Button(action: next) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(.ultraThinMaterial)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.8))
                            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 18)
                    .help("Next media (Right arrow)")
                } else {
                    Spacer().frame(width: 46)
                        .padding(.trailing, 18)
                }
            }
            .allowsHitTesting(true)
            
            // Layer 4: Top Floating Glassmorphic HUD
            VStack(spacing: 0) {
                topHUDBar
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            setupKeyboardMonitor()
        }
        .onDisappear {
            teardownKeyboardMonitor()
        }
    }
    
    // MARK: - Top Floating Glassmorphic HUD
    
    private var topHUDBar: some View {
        HStack(spacing: 12) {
            // Zen Kintsugi Gold badge icon with format name
            HStack(spacing: 5) {
                Image(systemName: MediaPreviewFactory.iconName(for: item.name))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                
                Text(formatExtension)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(TTZipTheme.kintsugiGold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(TTZipTheme.kintsugiGold.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(TTZipTheme.kintsugiGold.opacity(0.4), lineWidth: 0.8)
            )
            
            // File Name (Headline, Bold Serif) + File Size (Monospaced)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 13, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                if let sizeDesc = fileSizeDescription {
                    Text(sizeDesc)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Action Buttons
            HStack(spacing: 8) {
                // Reveal in Finder
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10.5, weight: .medium))
                        Text("Finder")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Reveal file in Finder (⌘R)")
                
                // Copy Path
                Button(action: copyFilePath) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopiedToastShown ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(isCopiedToastShown ? TTZipTheme.bambooGreen : .white.opacity(0.9))
                        Text(isCopiedToastShown ? "Copied" : "Copy Path")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isCopiedToastShown ? TTZipTheme.bambooGreen : .white.opacity(0.9))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Copy full path to clipboard")
                
                // Exit Fullscreen Button
                Button(action: onClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("退出全屏 (Esc)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4.5)
                    .background(TTZipTheme.cinnabarRed.opacity(0.88))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Dismiss fullscreen browser (Esc)")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 7)
    }
    
    // MARK: - Actions & Keyboard
    
    private func copyFilePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            isCopiedToastShown = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                isCopiedToastShown = false
            }
        }
    }
    
    private func setupKeyboardMonitor() {
        teardownKeyboardMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc Key
            if event.keyCode == 53 {
                onClose()
                return nil
            }
            // Left Arrow
            if event.keyCode == 123 {
                if let prev = onNavigatePrevious {
                    prev()
                    return nil
                }
            }
            // Right Arrow
            if event.keyCode == 124 {
                if let next = onNavigateNext {
                    next()
                    return nil
                }
            }
            return event
        }
    }
    
    private func teardownKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
