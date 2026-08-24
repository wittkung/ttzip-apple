// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import TTZipCore
@testable import TTZipApp

final class ChannelDistributionTests: XCTestCase {
    
    func testChannelStateEvaluation() {
        let manager = Ed25519LicenseManager.shared
        manager.deactivate()
        
        #if MAS_BUILD
        XCTAssertEqual(manager.currentState, .masPro)
        XCTAssertTrue(manager.isPro)
        XCTAssertEqual(manager.currentState.badgeTitle, "Pro Lifetime (App Store)")
        #elseif STEAM_BUILD
        XCTAssertEqual(manager.currentState, .steamPro)
        XCTAssertTrue(manager.isPro)
        XCTAssertEqual(manager.currentState.badgeTitle, "Pro Lifetime (Steam)")
        #else
        XCTAssertEqual(manager.currentState, .community)
        XCTAssertFalse(manager.isPro)
        XCTAssertEqual(manager.currentState.badgeTitle, "Community Edition")
        #endif
    }
    
    func testAllCoreFeaturesAlwaysAllowed() {
        let manager = LicenseManager.shared
        XCTAssertTrue(manager.canUseFeature(.basicExtract))
        XCTAssertTrue(manager.canUseFeature(.quickLookPreview))
        XCTAssertTrue(manager.canUseFeature(.zipCompression))
        XCTAssertTrue(manager.canUseFeature(.ultraCompression))
        XCTAssertTrue(manager.canUseFeature(.volumeSplit))
        XCTAssertTrue(manager.canUseFeature(.batchProcessing))
        XCTAssertTrue(manager.canUseFeature(.commercialUse))
    }
}
