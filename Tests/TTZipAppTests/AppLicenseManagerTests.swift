// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
@testable import TTZipApp

@MainActor
final class AppLicenseManagerTests: XCTestCase {
    
    func testCommunityTierIsNotPro() {
        let manager = AppLicenseManager.shared
        manager.setTierForTesting(.community)
        
        XCTAssertFalse(manager.currentTier.isPro)
        XCTAssertNil(manager.currentTier.channelName)
    }
    
    func testProAppStoreTierEntitlement() {
        let manager = AppLicenseManager.shared
        manager.setTierForTesting(.pro(channel: .appStore))
        
        XCTAssertTrue(manager.currentTier.isPro)
        XCTAssertEqual(manager.currentTier.channelName, "Mac App Store")
    }
    
    func testProSteamTierEntitlement() {
        let manager = AppLicenseManager.shared
        manager.setTierForTesting(.pro(channel: .steam))
        
        XCTAssertTrue(manager.currentTier.isPro)
        XCTAssertEqual(manager.currentTier.channelName, "Steam")
    }
    
    func testProLicenseKeyTierEntitlement() {
        let manager = AppLicenseManager.shared
        manager.setTierForTesting(.pro(channel: .licenseKey))
        
        XCTAssertTrue(manager.currentTier.isPro)
        XCTAssertEqual(manager.currentTier.channelName, "License Key")
    }
    
    func testActivateLicenseValidation() {
        let manager = AppLicenseManager.shared
        manager.setTierForTesting(.community)
        
        // Empty key rejection
        let failedEmpty = manager.activateLicense(key: "   ")
        XCTAssertFalse(failedEmpty)
        XCTAssertFalse(manager.currentTier.isPro)
        
        // Valid key success
        let success = manager.activateLicense(key: "TTZIP-PRO-2026-VAL")
        XCTAssertTrue(success)
        XCTAssertTrue(manager.currentTier.isPro)
        XCTAssertEqual(manager.currentTier.channelName, "License Key")
    }
}
