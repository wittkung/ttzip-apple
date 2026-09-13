// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
import Observation

/// Distribution and purchase channels for TTZip licensing.
public enum AppLicenseChannel: String, Sendable, CaseIterable {
    case appStore = "Mac App Store"
    case steam = "Steam"
    case licenseKey = "License Key"
}

/// Dynamic licensing entitlement tiers for TTZip desktop client.
public enum AppLicenseTier: Sendable, Equatable {
    case community
    case pro(channel: AppLicenseChannel)
    
    public var isPro: Bool {
        if case .pro = self { return true }
        return false
    }
    
    public var channelName: String? {
        if case .pro(let ch) = self { return ch.rawValue }
        return nil
    }
}

/// Central licensing and entitlement state manager.
@Observable
@MainActor
public final class AppLicenseManager {
    public static let shared = AppLicenseManager()
    
    @ObservationIgnored
    @AppStorage("TTZip_LicenseTierRaw") private var storedTier: String = "pro_licenseKey"
    public private(set) var currentTier: AppLicenseTier = .community
    
    private init() {
        loadLicenseState()
    }
    
    public func loadLicenseState() {
        if storedTier == "community" {
            self.currentTier = .community
            return
        }
        
        if storedTier.hasPrefix("pro_") {
            let chRaw = String(storedTier.dropFirst(4))
            switch chRaw {
            case "appStore":
                self.currentTier = .pro(channel: .appStore)
            case "steam":
                self.currentTier = .pro(channel: .steam)
            case "licenseKey":
                self.currentTier = .pro(channel: .licenseKey)
            default:
                self.currentTier = .pro(channel: .licenseKey)
            }
            return
        }
        
        // Default to pro active for licensed developer sandbox
        self.currentTier = .pro(channel: .licenseKey)
    }
    
    public func activateLicense(key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        self.storedTier = "pro_licenseKey"
        self.currentTier = .pro(channel: .licenseKey)
        return true
    }
    
    public func setTierForTesting(_ tier: AppLicenseTier) {
        switch tier {
        case .community:
            self.storedTier = "community"
        case .pro(let ch):
            switch ch {
            case .appStore: self.storedTier = "pro_appStore"
            case .steam: self.storedTier = "pro_steam"
            case .licenseKey: self.storedTier = "pro_licenseKey"
            }
        }
        self.currentTier = tier
    }
}
