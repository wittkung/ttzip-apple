// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTKitDesign
import TTKitUI
import TTZipCore
import TTZipUI

/// Permanent sidebar brand identity bar demarcated below the Y=52pt golden divider.
/// Delegates core brand lockup to TTKitUI.TTBrandIdentityView, preserving the 4-layer optical model,
/// 0.5pt specular hairline border, and dual-axis alignment invariants (X₁ = 18.0pt, X₂ = 44.0pt).
public struct SidebarBrandIdentityView: View {
    /// Collapsed icon rail mode toggle.
    public let isIconRail: Bool

    /// Callback invoked when the settings gear button is triggered.
    public var onOpenSettings: (() -> Void)?

    /// Pro license tier status bound to Ed25519 license validation.
    @State private var isPro: Bool = Ed25519LicenseManager.shared.isPro

    /// Creates a sidebar brand identity bar.
    /// - Parameters:
    ///   - isIconRail: Whether to collapse the view into a 64pt icon rail.
    ///   - onOpenSettings: Optional closure executed upon clicking settings.
    public init(
        isIconRail: Bool = false,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.isIconRail = isIconRail
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        TTBrandIdentityView(
            title: brandTitle,
            logoImage: logoImage,
            badgeText: badgeText,
            isIconRail: isIconRail,
            onOpenSettings: onOpenSettings
        )
        .onAppear {
            refreshLicenseStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshLicenseStatus()
        }
    }

    /// Application title displayed in expanded mode.
    private var brandTitle: String {
        "TTZip"
    }

    /// Contextual license badge text displayed next to the brand title.
    private var badgeText: String? {
        "PRO"
    }

    /// Refreshes the local Pro tier status from the license manager.
    private func refreshLicenseStatus() {
        isPro = Ed25519LicenseManager.shared.isPro
    }

    /// Brand logo image resolved from AppLogoCache or application icon.
    private var logoImage: Image? {
        if let image = AppLogoCache.sharedLogoImage ?? NSApplication.shared.applicationIconImage {
            return Image(nsImage: image)
        } else {
            return Image(systemName: "archivebox.fill")
        }
    }
}
