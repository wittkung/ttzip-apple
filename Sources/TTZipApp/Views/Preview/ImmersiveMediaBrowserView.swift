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
    @State private var isControlsVisible: Bool = true
    @State private var autoHideTimer: Timer? = nil
    
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
        GeometryReader { geometry in
            ZStack {
                // Layer 1: Frosted Scrim Dismiss Layer
                Color.black.opacity(0.92)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if !isControlsVisible {
                            showControlsAndResetTimer()
                        } else {
                            onClose()
                        }
                    }
                
                // Layer 2: Main Center Media Viewport
                MediaPreviewView(
                    fileURL: item.url,
                    fileName: item.name,
                    isImmersiveFullscreen: true
                )
                .environment(\.isImmersiveFullscreen, true)
                .id(item.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                
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
                .opacity(isControlsVisible ? 1.0 : 0.0)
                .allowsHitTesting(isControlsVisible)
                
                // Layer 4: Top Edge-to-Edge Gradient Veil Header
                VStack(spacing: 0) {
                    topGradientHeader(geometry: geometry)
                    Spacer()
                }
                .ignoresSafeArea(edges: .top)
                .opacity(isControlsVisible ? 1.0 : 0.0)
                .allowsHitTesting(isControlsVisible)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onContinuousHover { phase in
                if case .active = phase {
                    showControlsAndResetTimer()
                }
            }
            .onAppear {
                setupKeyboardMonitor()
                showControlsAndResetTimer()
            }
            .onDisappear {
                teardownKeyboardMonitor()
                autoHideTimer?.invalidate()
                autoHideTimer = nil
            }
        }
    }
    
    // MARK: - Top Gradient Veil Header
    
    private func topGradientHeader(geometry: GeometryProxy) -> some View {
        HStack(alignment: .center, spacing: 14) {
            // Leading: Format Badge + Name & Size
            HStack(spacing: 12) {
                // Zen Kintsugi Gold format badge
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
                
                // Item name and file size
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: min(720, max(80, geometry.size.width - 320)), alignment: .leading)
                    
                    if let sizeDesc = fileSizeDescription {
                        Text(sizeDesc)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
            }
            
            Spacer()
            
            // Trailing HStack (spacing 10): Actions & Close
            HStack(spacing: 10) {
                // "Finder" button with subtle translucent glass style
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                        Text("Finder")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .help("Reveal file in Finder (⌘R)")
                
                // "Copy Path" button with subtle translucent glass style
                Button(action: copyFilePath) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopiedToastShown ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isCopiedToastShown ? TTZipTheme.bambooGreen : .white.opacity(0.9))
                        Text(isCopiedToastShown ? "Copied" : "Copy Path")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isCopiedToastShown ? TTZipTheme.bambooGreen : .white.opacity(0.9))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .help("Copy full path to clipboard")
                
                // Elegant circular translucent close button
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Dismiss (Esc)")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 96, alignment: .top)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.75), Color.black.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
    
    // MARK: - Auto-Hide State Machine
    
    private func showControlsAndResetTimer() {
        if !isControlsVisible {
            withAnimation(.easeInOut(duration: 0.2)) {
                isControlsVisible = true
            }
        }
        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.35)) {
                    isControlsVisible = false
                }
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
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
