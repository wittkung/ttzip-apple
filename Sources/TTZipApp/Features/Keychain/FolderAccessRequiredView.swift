// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// An elegant authorization prompt view for folders requiring macOS App Sandbox permissions.
/// Conforms to the TTKit 4-layer optical model and WSJ editorial aesthetic.
public struct FolderAccessRequiredView: View {
    private var l10n = AppLocalizationState.shared
    
    public let dirURL: URL
    public let onAuthorize: () -> Void
    
    @State private var isHoveringButton: Bool = false
    @State private var isAppeared: Bool = false
    
    public init(
        dirURL: URL,
        onAuthorize: @escaping () -> Void
    ) {
        self.dirURL = dirURL
        self.onAuthorize = onAuthorize
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)
            
            VStack(spacing: 16) {
                // Subtle Shield Watermark Icon
                ZStack {
                    Circle()
                        .fill(TTZipTheme.kintsugiGold.opacity(0.08))
                        .frame(width: 58, height: 58)
                    
                    Image(systemName: "lock.shield")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(TTZipTheme.kintsugiGold.opacity(0.85))
                }
                
                // Typography Section
                VStack(spacing: 6) {
                    Text(String(localized: "Folder Authorization Required"))
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(1)
                    
                    Text(String(localized: "Under macOS App Sandbox, TTZip requires authorization to access this directory."))
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(Color.secondary.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 20)
                }
                
                // Primary Action Button
                Button(action: onAuthorize) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(String(localized: "Authorize Folder Access"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(isHoveringButton ? Color.white : TTZipTheme.bambooGreen)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isHoveringButton ? TTZipTheme.bambooGreen : TTZipTheme.bambooGreen.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(TTZipTheme.bambooGreen.opacity(isHoveringButton ? 0.6 : 0.25), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringButton = $0 }
                .help(String(localized: "Open system authorization panel"))
            }
            .opacity(isAppeared ? 1 : 0)
            .offset(y: isAppeared ? 0 : 6)
            
            Spacer(minLength: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.22)) {
                isAppeared = true
            }
        }
    }
}
