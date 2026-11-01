// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitCore
import TTKitDesign

/// Sidebar brand identity header component conforming to TTKit Architecture Spec §3.
/// Demarcated below Y=52pt golden line, supporting expanded brand lockup and collapsed icon rail mode.
public struct TTBrandIdentityView: View {
    public let title: String
    public let logoImage: Image?
    public let badgeText: String?
    public let isIconRail: Bool
    public let onOpenSettings: (() -> Void)?
    
    @State private var isSettingsHovered = false
    
    public init(
        title: String,
        logoImage: Image? = nil,
        badgeText: String? = nil,
        isIconRail: Bool = false,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.title = title
        self.logoImage = logoImage
        self.badgeText = badgeText
        self.isIconRail = isIconRail
        self.onOpenSettings = onOpenSettings
    }
    
    public var body: some View {
        if isIconRail {
            // Collapsed rail mode: 20x20 centered icon
            VStack {
                logoView
                    .frame(width: 20, height: 20)
                    .help(title)
            }
            .frame(width: 64, height: 36)
        } else {
            // Expanded sidebar mode: [Logo] Title [Badge] Spacer [Settings]
            HStack(spacing: 6) {
                logoView
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .serif))
                    .tracking(0.5)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                
                if let badge = badgeText {
                    Text(badge)
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(TTKitTheme.kintsugiGold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule(style: .continuous)
                                .strokeBorder(TTKitTheme.kintsugiGold.opacity(0.65), lineWidth: UniversalTokens.Dimensions.hairlineWidth)
                                .background(TTKitTheme.kintsugiGold.opacity(0.08))
                        )
                }
                
                Spacer()
                
                if let onSettings = onOpenSettings {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isSettingsHovered ? Color.primary : Color.secondary.opacity(0.8))
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSettingsHovered ? Color.primary.opacity(0.06) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isSettingsHovered = hovering
                    }
                    .help("Settings")
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(height: 36)
        }
    }
    
    @ViewBuilder
    private var logoView: some View {
        if let image = logoImage {
            image
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "cube.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(TTKitTheme.bambooGreen)
        }
    }
}
