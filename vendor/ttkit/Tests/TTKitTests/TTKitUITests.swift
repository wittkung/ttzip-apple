// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
@testable import TTKitCore
@testable import TTKitDesign
@testable import TTKitFluid
@testable import TTKitUI
@testable import TTKit

final class TTKitUITests: XCTestCase {

    // MARK: - ProMotion Dynamics Tests

    func testProMotionSpringCriticalDampingSettling() {
        let config = ProMotionSpringConfiguration.critical120Hz
        XCTAssertEqual(config.dampingRatio, 1.0)
        XCTAssertGreaterThan(config.naturalFrequency, 0.0)

        // Evaluate state after 0.5 seconds
        let state = ProMotionDynamicsSolver.evaluate(
            initialDisplacement: 100.0,
            initialVelocity: 0.0,
            elapsedTime: 0.5,
            configuration: config
        )

        // Monotonic decay without negative overshoot
        XCTAssertGreaterThanOrEqual(state.displacement, -0.001)
        XCTAssertLessThan(state.displacement, 10.0)
        XCTAssertLessThan(state.totalEnergy, 0.5 * config.stiffness * 100.0 * 100.0)
    }

    func testProMotionSpringElastic120HzSimulation() {
        let config = ProMotionSpringConfiguration.elastic120Hz
        XCTAssertEqual(config.dampingRatio, 0.82)

        var displacement = 50.0
        var velocity = 0.0

        // Step through 60 frames of 120Hz (0.5 seconds)
        for _ in 0..<60 {
            let nextState = ProMotionDynamicsSolver.step(
                currentDisplacement: displacement,
                currentVelocity: velocity,
                deltaTime: ProMotionDynamicsSolver.proMotion120HzDeltaTime,
                configuration: config
            )
            displacement = nextState.displacement
            velocity = nextState.velocity
        }

        // Energy must decay towards equilibrium
        XCTAssertLessThan(abs(displacement), 2.0)
    }

    func testProMotionDynamicsHighFrequencyGate() {
        XCTAssertTrue(ProMotionDynamicsSolver.respectsHighFrequencyGate(responseDuration: 0.16))
        XCTAssertFalse(ProMotionDynamicsSolver.respectsHighFrequencyGate(responseDuration: 0.35))
    }

    func testMomentumProjectionAndRubberBand() {
        let projected = ProMotionDynamicsSolver.projectMomentum(initialVelocity: 1000.0, decelerationRate: 0.998)
        XCTAssertGreaterThan(projected, 0.0)

        let resistance = ProMotionDynamicsSolver.rubberBandResistance(offset: 100.0, dimension: 300.0, coefficient: 0.55)
        XCTAssertGreaterThan(resistance, 0.0)
        XCTAssertLessThan(resistance, 100.0)
    }

    // MARK: - Bulk Drag Representation Tests

    func testBulkDragTiers() {
        XCTAssertEqual(BulkDragTier.tier(forCount: 1), .direct)
        XCTAssertEqual(BulkDragTier.tier(forCount: 100), .direct)
        XCTAssertEqual(BulkDragTier.tier(forCount: 101), .aggregated)
        XCTAssertEqual(BulkDragTier.tier(forCount: 2000), .aggregated)
        XCTAssertEqual(BulkDragTier.tier(forCount: 2001), .spillGuarded)
    }

    func testBulkDragPayloadFormatting() {
        let items = [
            BulkDragItem(name: "video.mov", byteSize: 1024 * 1024 * 50),
            BulkDragItem(name: "archive.7z", byteSize: 1024 * 1024 * 100)
        ]
        let payload = BulkDragPayload(items: items, totalItemCount: 1420)
        XCTAssertEqual(payload.tier, .aggregated)
        XCTAssertTrue(payload.formattedCount.contains("1,420"))
    }

    // MARK: - Forensic Collision Panel Tests

    func testConflictResolutionActionPrimitives() {
        let actions = ConflictResolutionAction.allCases
        XCTAssertEqual(actions.count, 4)
        XCTAssertEqual(ConflictResolutionAction.replace.rawValue, "REPLACE")
        XCTAssertEqual(ConflictResolutionAction.keepBoth.rawValue, "KEEP_BOTH")
        XCTAssertEqual(ConflictResolutionAction.skip.rawValue, "SKIP")
        XCTAssertEqual(ConflictResolutionAction.stop.rawValue, "STOP")

        XCTAssertEqual(ConflictResolutionAction.replace.title, "Replace")
        XCTAssertEqual(ConflictResolutionAction.keepBoth.title, "Keep Both")
        XCTAssertEqual(ConflictResolutionAction.skip.title, "Skip")
        XCTAssertEqual(ConflictResolutionAction.stop.title, "Stop")
    }

    func testConflictFileDescriptorFormatting() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let descriptor = ConflictFileDescriptor(
            fileName: "archive.tar",
            relativePath: "nested/archive.tar",
            filePath: "/tmp/nested/archive.tar",
            byteSize: 2048,
            modificationDate: date,
            conflictKind: .sameType
        )
        XCTAssertEqual(descriptor.relativePath, "nested/archive.tar")
        XCTAssertEqual(descriptor.conflictKind, .sameType)
        XCTAssertTrue(descriptor.formattedSize.contains("2,048 B"))
        XCTAssertFalse(descriptor.formattedTimestamp.isEmpty)

        let dirDescriptor = ConflictFileDescriptor(
            fileName: "docs",
            relativePath: "docs",
            filePath: "/tmp/docs",
            byteSize: 0,
            modificationDate: date,
            isDirectory: true,
            conflictKind: .typeMismatch
        )
        XCTAssertEqual(dirDescriptor.conflictKind, .typeMismatch)
        XCTAssertEqual(dirDescriptor.formattedSize, "Directory")
    }

    // MARK: - Fuzzy Matcher Tests

    func testFuzzyMatcherRanking() {
        let query = "trans"
        let resExact = FuzzyMatcher.match(candidate: "trans", pattern: query)
        let resPrefix = FuzzyMatcher.match(candidate: "transcribe audio", pattern: query)
        let resMismatch = FuzzyMatcher.match(candidate: "compress", pattern: query)

        XCTAssertTrue(resExact.isMatch)
        XCTAssertTrue(resPrefix.isMatch)
        XCTAssertFalse(resMismatch.isMatch)
        XCTAssertGreaterThan(resExact.score, resPrefix.score)
    }

    // MARK: - SwiftUI View Instantiations

    @MainActor
    func testOmnibarViewInstantiation() {
        let omnibar = OmnibarView()
        _ = omnibar
    }

    @MainActor
    func testBulkDragViewsInstantiation() {
        let payload = BulkDragPayload(
            items: [BulkDragItem(name: "file.txt", byteSize: 100)],
            totalItemCount: 1420
        )
        let view = BulkDragRepresentationView(payload: payload)
        _ = view
    }

    @MainActor
    func testForensicPanelInstantiation() {
        let now = Date()
        let src = ConflictFileDescriptor(
            fileName: "model.bin",
            relativePath: "models/model.bin",
            filePath: "/src/models/model.bin",
            byteSize: 1000,
            modificationDate: now,
            conflictKind: .typeMismatch
        )
        let target = ConflictFileDescriptor(
            fileName: "model.bin",
            relativePath: "models/model.bin",
            filePath: "/dest/models/model.bin",
            byteSize: 1000,
            modificationDate: now.addingTimeInterval(-3600),
            isDirectory: true,
            conflictKind: .typeMismatch
        )
        var applyAll = false
        let binding = Binding(get: { applyAll }, set: { applyAll = $0 })
        let panel = ForensicCollisionPanel(
            sourceFile: src,
            targetFile: target,
            conflictIndex: 2,
            totalConflicts: 8,
            applyToAllRemaining: binding,
            onResolve: { _, _ in }
        )
        _ = panel
    }
}
