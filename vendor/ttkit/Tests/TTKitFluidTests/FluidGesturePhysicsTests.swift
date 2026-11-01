// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
@testable import TTKitFluid

final class FluidGesturePhysicsTests: XCTestCase {

    func testRubberBandClampWithinBounds() {
        let range = 0.0...100.0
        let dimension = 400.0

        // In-bound values remain unmodified
        XCTAssertEqual(FluidGesturePhysics.rubberBandClamp(offset: 0.0, range: range, dimension: dimension), 0.0)
        XCTAssertEqual(FluidGesturePhysics.rubberBandClamp(offset: 50.0, range: range, dimension: dimension), 50.0)
        XCTAssertEqual(FluidGesturePhysics.rubberBandClamp(offset: 100.0, range: range, dimension: dimension), 100.0)
    }

    func testRubberBandClampBeyondBoundsResistance() {
        let range = 0.0...100.0
        let dimension = 400.0

        // Beyond upper bound: damped offset is damped and strictly monotonic
        let out1 = FluidGesturePhysics.rubberBandClamp(offset: 150.0, range: range, dimension: dimension)
        let out2 = FluidGesturePhysics.rubberBandClamp(offset: 200.0, range: range, dimension: dimension)

        XCTAssertGreaterThan(out1, 100.0)
        XCTAssertLessThan(out1, 150.0, "Damped value must be smaller than raw overscroll.")
        XCTAssertGreaterThan(out2, out1, "Damped function must be strictly monotonic.")
        XCTAssertLessThan(out2, 100.0 + dimension, "Overshoot cannot exceed viewport dimension asymptote.")

        // Beyond lower bound: damped offset
        let lower1 = FluidGesturePhysics.rubberBandClamp(offset: -50.0, range: range, dimension: dimension)
        let lower2 = FluidGesturePhysics.rubberBandClamp(offset: -100.0, range: range, dimension: dimension)

        XCTAssertLessThan(lower1, 0.0)
        XCTAssertGreaterThan(lower1, -50.0, "Damped lower bound must be less negative than raw overscroll.")
        XCTAssertLessThan(lower2, lower1, "Damped lower bound must remain strictly monotonic.")
        XCTAssertGreaterThan(lower2, -dimension, "Negative overshoot cannot exceed dimension asymptote.")
    }

    func testMomentumProjection() {
        let initialOffset = 100.0
        let velocity = 1000.0 // 1000 pt/s
        let decelerationRate = 0.998

        // Expected: 100.0 + (1000.0 / 1000.0) * (0.998 / 0.002) = 100.0 + 499.0 = 599.0
        let projected = FluidGesturePhysics.projectMomentum(
            initialOffset: initialOffset,
            velocity: velocity,
            decelerationRate: decelerationRate
        )

        XCTAssertEqual(projected, 599.0, accuracy: 1e-4)

        // Zero velocity leaves offset intact
        let staticProjected = FluidGesturePhysics.projectMomentum(
            initialOffset: initialOffset,
            velocity: 0.0,
            decelerationRate: decelerationRate
        )
        XCTAssertEqual(staticProjected, initialOffset)
    }

    func testRelativeVelocitySpringInjection() {
        let rel = FluidGesturePhysics.relativeVelocity(
            gestureVelocity: 500.0,
            currentOffset: 100.0,
            targetOffset: 200.0
        )
        // Expected: 500.0 / (200.0 - 100.0) = 5.0
        XCTAssertEqual(rel, 5.0, accuracy: 1e-5)

        // Safe division by zero handling
        let zeroRel = FluidGesturePhysics.relativeVelocity(
            gestureVelocity: 500.0,
            currentOffset: 100.0,
            targetOffset: 100.0
        )
        XCTAssertEqual(zeroRel, 0.0)
    }
}
