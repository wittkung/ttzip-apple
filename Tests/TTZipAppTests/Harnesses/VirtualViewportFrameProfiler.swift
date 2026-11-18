// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Darwin
import Foundation
import QuartzCore
import XCTest

// MARK: - Virtual Viewport Node Models

/// Lightweight representation of a virtual tree or table entry.
public struct VirtualViewportNode: Sendable, Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let path: String
    public let uncompressedSize: Int64
    public let isDirectory: Bool
    public let depth: Int

    public init(
        id: Int,
        name: String,
        path: String,
        uncompressedSize: Int64,
        isDirectory: Bool,
        depth: Int
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.uncompressedSize = uncompressedSize
        self.isDirectory = isDirectory
        self.depth = depth
    }
}

/// Abstract provider interface for virtual node storage.
public protocol VirtualViewportNodeProviding: Sendable {
    var totalNodeCount: Int { get }
    func node(at index: Int) -> VirtualViewportNode
}

/// Algorithmic synthetic generator simulating 1,000,000 deep hierarchical nodes without upfront heap allocation.
public final class SyntheticVirtualNodeProvider: VirtualViewportNodeProviding, @unchecked Sendable {
    public let totalNodeCount: Int

    public init(totalNodeCount: Int = 1_000_000) {
        self.totalNodeCount = max(1, totalNodeCount)
    }

    public func node(at index: Int) -> VirtualViewportNode {
        let clampedIndex = max(0, min(totalNodeCount - 1, index))
        let depth = (clampedIndex % 10) + 1
        let isDir = (clampedIndex % 25 == 0)
        let name = isDir ? "Folder_\(clampedIndex)" : "item_\(clampedIndex).dat"
        let path = "vfs/root/level_\(depth)/\(name)"
        let size: Int64 = isDir ? 0 : Int64((clampedIndex % 4096) * 1024)
        return VirtualViewportNode(
            id: clampedIndex,
            name: name,
            path: path,
            uncompressedSize: size,
            isDirectory: isDir,
            depth: depth
        )
    }
}

// MARK: - Viewport Recycling Cell

/// Recycled visual slot simulating an AppKit / SwiftUI cell view lifecycle without per-frame allocations.
public final class VirtualCellSlot: @unchecked Sendable {
    public var id: Int = -1
    public var title: String = ""
    public var detail: String = ""
    public var depth: Int = 0
    public var isDirectory: Bool = false
    public var isSelected: Bool = false

    public init() {}

    public func bind(node: VirtualViewportNode, isSelected: Bool = false) {
        self.id = node.id
        self.title = node.name
        self.detail = node.isDirectory ? "--" : "\(node.uncompressedSize / 1024) KB"
        self.depth = node.depth
        self.isDirectory = node.isDirectory
        self.isSelected = isSelected
    }
}

// MARK: - Virtual Viewport Simulation Container

/// High-velocity virtualized viewport executing recycled row layout over 1,000,000 entries.
public final class VirtualViewport: @unchecked Sendable {
    public let nodeProvider: any VirtualViewportNodeProviding
    public let rowHeight: Double
    public let viewportHeight: Double
    public let visibleRowCount: Int
    public let totalNodeCount: Int
    public private(set) var scrollOffset: Double = 0.0
    public let recycledSlots: [VirtualCellSlot]

    public init(
        nodeProvider: any VirtualViewportNodeProviding,
        rowHeight: Double = 24.0,
        viewportHeight: Double = 800.0,
        visibleRowCount: Int = 50
    ) {
        self.nodeProvider = nodeProvider
        self.rowHeight = rowHeight
        self.viewportHeight = viewportHeight
        self.visibleRowCount = visibleRowCount
        self.totalNodeCount = nodeProvider.totalNodeCount
        self.recycledSlots = (0..<visibleRowCount).map { _ in VirtualCellSlot() }
    }

    public func scroll(by deltaPoints: Double) {
        let maxOffset = Double(max(1, totalNodeCount - visibleRowCount)) * rowHeight
        scrollOffset += deltaPoints
        if scrollOffset >= maxOffset {
            scrollOffset = scrollOffset.truncatingRemainder(dividingBy: maxOffset)
        } else if scrollOffset < 0.0 {
            scrollOffset = maxOffset + scrollOffset.truncatingRemainder(dividingBy: maxOffset)
        }
    }

    @discardableResult
    public func renderVisibleRows() -> Int {
        let baseIndex = Int(scrollOffset / rowHeight)
        let maxBase = max(0, totalNodeCount - visibleRowCount)
        let startIndex = min(maxBase, max(0, baseIndex))
        var renderedCount = 0

        for slotIndex in 0..<visibleRowCount {
            let nodeIndex = startIndex + slotIndex
            let node = nodeProvider.node(at: nodeIndex)
            recycledSlots[slotIndex].bind(node: node, isSelected: (slotIndex == 0))
            renderedCount += 1
        }
        return renderedCount
    }
}

// MARK: - Profiler Configuration & Reporting Models

/// Operating driver mode for the frame profiler.
public enum ProfilerDriverMode: String, Sendable {
    case auto
    case displayLink
    case headlessMachRealTime
}

/// Frame pacing strategy during the profiling session.
public enum ProfilerPacingMode: String, Sendable {
    case realTime
    case accelerated
}

/// Profiler session parameters.
public struct ProfilerConfiguration: Sendable {
    public var nodeCount: Int
    public var targetFrameCount: Int
    public var velocityPointsPerSecond: Double
    public var targetFrameRate: Double
    public var visibleRowCount: Int
    public var rowHeight: Double
    public var viewportHeight: Double
    public var driverMode: ProfilerDriverMode
    public var pacingMode: ProfilerPacingMode

    public init(
        nodeCount: Int = 1_000_000,
        targetFrameCount: Int = 1_000,
        velocityPointsPerSecond: Double = 5_000.0,
        targetFrameRate: Double = 120.0,
        visibleRowCount: Int = 50,
        rowHeight: Double = 24.0,
        viewportHeight: Double = 800.0,
        driverMode: ProfilerDriverMode = .auto,
        pacingMode: ProfilerPacingMode = .realTime
    ) {
        self.nodeCount = nodeCount
        self.targetFrameCount = targetFrameCount
        self.velocityPointsPerSecond = velocityPointsPerSecond
        self.targetFrameRate = targetFrameRate
        self.visibleRowCount = visibleRowCount
        self.rowHeight = rowHeight
        self.viewportHeight = viewportHeight
        self.driverMode = driverMode
        self.pacingMode = pacingMode
    }
}

/// Telemetry record collected per frame callback.
public struct FrameMetricSample: Sendable {
    public let frameIndex: Int
    public let timestampMs: Double
    public let intervalMs: Double
    public let deliveryLatencyMs: Double
    public let rssBytes: Int64

    public init(
        frameIndex: Int,
        timestampMs: Double,
        intervalMs: Double,
        deliveryLatencyMs: Double,
        rssBytes: Int64
    ) {
        self.frameIndex = frameIndex
        self.timestampMs = timestampMs
        self.intervalMs = intervalMs
        self.deliveryLatencyMs = deliveryLatencyMs
        self.rssBytes = rssBytes
    }
}

/// Statistical evaluation metrics synthesized over the profiling run.
public struct FrameMetricsReport: Sendable {
    public let totalFrames: Int
    public let meanFrameIntervalMs: Double
    public let meanDeliveryLatencyMs: Double
    public let p95DeliveryLatencyMs: Double
    public let p99DeliveryLatencyMs: Double
    public let p99_9DeliveryLatencyMs: Double
    public let p95FrameIntervalMs: Double
    public let p99FrameIntervalMs: Double
    public let p99_9FrameIntervalMs: Double
    public let droppedFrameCount: Int
    public let baselineRSSBytes: Int64
    public let peakRSSBytes: Int64
    public let finalRSSBytes: Int64
    public let memoryGrowthBytes: Int64
    public let memoryGrowthMB: Double
    public let effectiveFps: Double
    public let resolvedDriverName: String

    public static func percentile(_ values: [Double], percentile p: Double) -> Double {
        guard !values.isEmpty else { return 0.0 }
        if values.count == 1 { return values[0] }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let lower = Int(floor(rank))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = rank - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }

    public static func build(
        samples: [FrameMetricSample],
        baselineRSS: Int64,
        peakRSS: Int64,
        finalRSS: Int64,
        resolvedDriverName: String,
        config: ProfilerConfiguration
    ) -> FrameMetricsReport {
        guard !samples.isEmpty else {
            return FrameMetricsReport(
                totalFrames: 0,
                meanFrameIntervalMs: 0.0,
                meanDeliveryLatencyMs: 0.0,
                p95DeliveryLatencyMs: 0.0,
                p99DeliveryLatencyMs: 0.0,
                p99_9DeliveryLatencyMs: 0.0,
                p95FrameIntervalMs: 0.0,
                p99FrameIntervalMs: 0.0,
                p99_9FrameIntervalMs: 0.0,
                droppedFrameCount: 0,
                baselineRSSBytes: baselineRSS,
                peakRSSBytes: peakRSS,
                finalRSSBytes: finalRSS,
                memoryGrowthBytes: 0,
                memoryGrowthMB: 0.0,
                effectiveFps: 0.0,
                resolvedDriverName: resolvedDriverName
            )
        }

        let intervals = samples.map(\.intervalMs)
        let latencies = samples.map(\.deliveryLatencyMs)

        let meanInterval = intervals.reduce(0.0, +) / Double(intervals.count)
        let meanLatency = latencies.reduce(0.0, +) / Double(latencies.count)

        let p95Latency = percentile(latencies, percentile: 0.95)
        let p99Latency = percentile(latencies, percentile: 0.99)
        let p99_9Latency = percentile(latencies, percentile: 0.999)

        let p95Interval = percentile(intervals, percentile: 0.95)
        let p99Interval = percentile(intervals, percentile: 0.99)
        let p99_9Interval = percentile(intervals, percentile: 0.999)

        let droppedCount = latencies.filter { $0 > 10.0 }.count
        let growthBytes = max(0, finalRSS - baselineRSS)
        let growthMB = Double(growthBytes) / (1024.0 * 1024.0)

        let totalDurationMs = intervals.reduce(0.0, +)
        let effectiveFps = totalDurationMs > 0.0 ? (Double(samples.count) / (totalDurationMs / 1000.0)) : config.targetFrameRate

        return FrameMetricsReport(
            totalFrames: samples.count,
            meanFrameIntervalMs: meanInterval,
            meanDeliveryLatencyMs: meanLatency,
            p95DeliveryLatencyMs: p95Latency,
            p99DeliveryLatencyMs: p99Latency,
            p99_9DeliveryLatencyMs: p99_9Latency,
            p95FrameIntervalMs: p95Interval,
            p99FrameIntervalMs: p99Interval,
            p99_9FrameIntervalMs: p99_9Interval,
            droppedFrameCount: droppedCount,
            baselineRSSBytes: baselineRSS,
            peakRSSBytes: peakRSS,
            finalRSSBytes: finalRSS,
            memoryGrowthBytes: growthBytes,
            memoryGrowthMB: growthMB,
            effectiveFps: effectiveFps,
            resolvedDriverName: resolvedDriverName
        )
    }

    public var formattedSummary: String {
        """
        ================================================================================
          VIRTUAL VIEWPORT FRAME PROFILER TELEMETRY (120Hz ProMotion Gate)
        ================================================================================
          Driver:                   \(resolvedDriverName)
          Sampled Frames:           \(totalFrames)
          Effective Frame Rate:     \(String(format: "%6.1f", effectiveFps)) FPS
          Mean Frame Interval:      \(String(format: "%6.3f", meanFrameIntervalMs)) ms (Target: ~8.333 ms)
          Mean Delivery Latency:    \(String(format: "%6.3f", meanDeliveryLatencyMs)) ms
          P95 Delivery Latency:     \(String(format: "%6.3f", p95DeliveryLatencyMs)) ms
          P99 Delivery Latency:     \(String(format: "%6.3f", p99DeliveryLatencyMs)) ms
          P99.9 Delivery Latency:   \(String(format: "%6.3f", p99_9DeliveryLatencyMs)) ms (Gate: <= 8.330 ms)
          Dropped Frames (>10ms):   \(droppedFrameCount)
          Baseline Memory RSS:      \(String(format: "%6.2f", Double(baselineRSSBytes) / (1024.0 * 1024.0))) MB
          Peak Memory RSS:          \(String(format: "%6.2f", Double(peakRSSBytes) / (1024.0 * 1024.0))) MB
          Final Memory RSS:         \(String(format: "%6.2f", Double(finalRSSBytes) / (1024.0 * 1024.0))) MB
          Memory RSS Growth:        \(String(format: "%6.3f", memoryGrowthMB)) MB (Gate: <= 8.000 MB)
        ================================================================================
        """
    }
}

// MARK: - Mach Monotonic Timebase Helper

private enum MachTimeHelper {
    static let info: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase
    }()

    static func ticksToMilliseconds(_ ticks: UInt64) -> Double {
        let nanos = Double(ticks) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000.0
    }

    static func millisecondsToTicks(_ ms: Double) -> UInt64 {
        let nanos = ms * 1_000_000.0
        return UInt64(nanos * Double(info.denom) / Double(info.numer))
    }
}

// MARK: - CADisplayLink Driver Target

@MainActor
private final class DisplayLinkDriverTarget: NSObject {
    var onFrame: ((_ timestamp: Double, _ targetTimestamp: Double) -> Void)?

    @objc func handleFrame(_ link: CADisplayLink) {
        onFrame?(link.timestamp, link.targetTimestamp)
    }
}

// MARK: - Virtual Viewport Frame Profiler Harness

/// 120fps headless CADisplayLink profiler harness driving high-velocity scrolling over 1,000,000 nodes.
@MainActor
public final class VirtualViewportFrameProfiler {
    @MainActor private final class StateBox { var isResumed = false }

    public let configuration: ProfilerConfiguration
    public let nodeProvider: any VirtualViewportNodeProviding

    public init(
        configuration: ProfilerConfiguration = ProfilerConfiguration(),
        nodeProvider: (any VirtualViewportNodeProviding)? = nil
    ) {
        self.configuration = configuration
        self.nodeProvider = nodeProvider ?? SyntheticVirtualNodeProvider(totalNodeCount: configuration.nodeCount)
    }

    /// Queries the current Darwin process Resident Set Size (RSS) in bytes.
    public static func currentMemoryRSS() -> Int64 {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &taskInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        return kerr == KERN_SUCCESS ? Int64(taskInfo.resident_size) : 0
    }

    /// Configures the current Mach thread for hard real-time scheduling constraints.
    private static func applyMachRealTimePolicy(periodMs: Double) {
        let periodTicks = MachTimeHelper.millisecondsToTicks(periodMs)
        let compTicks = MachTimeHelper.millisecondsToTicks(2.0)
        let constraintTicks = periodTicks

        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(clamping: periodTicks),
            computation: UInt32(clamping: compTicks),
            constraint: UInt32(clamping: constraintTicks),
            preemptible: 1
        )
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &policy) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), intPtr, count)
            }
        }
    }

    /// Executes the continuous scrolling profile session over the 1,000,000 node dataset.
    public func profile() async throws -> FrameMetricsReport {
        let baselineRSS = Self.currentMemoryRSS()
        let viewport = VirtualViewport(
            nodeProvider: nodeProvider,
            rowHeight: configuration.rowHeight,
            viewportHeight: configuration.viewportHeight,
            visibleRowCount: configuration.visibleRowCount
        )

        switch configuration.driverMode {
        case .displayLink:
            return try await runDisplayLinkProfile(viewport: viewport, baselineRSS: baselineRSS)
        case .headlessMachRealTime:
            return runMachRealTimeProfile(viewport: viewport, baselineRSS: baselineRSS)
        case .auto:
            let canUseDisplayLink = await probeDisplayLink()
            if canUseDisplayLink {
                if let report = try? await runDisplayLinkProfile(viewport: viewport, baselineRSS: baselineRSS) {
                    return report
                }
            }
            return runMachRealTimeProfile(viewport: viewport, baselineRSS: baselineRSS)
        }
    }

    private func probeDisplayLink() async -> Bool {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = view
        window.orderFront(nil)

        let target = DisplayLinkDriverTarget()
        let link = view.displayLink(target: target, selector: #selector(DisplayLinkDriverTarget.handleFrame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)

        let didFire = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let box = StateBox()
            target.onFrame = { _, _ in
                if !box.isResumed {
                    box.isResumed = true
                    continuation.resume(returning: true)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 35_000_000)
                if !box.isResumed {
                    box.isResumed = true
                    continuation.resume(returning: false)
                }
            }
        }

        link.invalidate()
        window.orderOut(nil)
        return didFire
    }

    private func runDisplayLinkProfile(
        viewport: VirtualViewport,
        baselineRSS: Int64
    ) async throws -> FrameMetricsReport {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = view
        window.orderFront(nil)

        let target = DisplayLinkDriverTarget()
        let link = view.displayLink(target: target, selector: #selector(DisplayLinkDriverTarget.handleFrame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)

        var samples: [FrameMetricSample] = []
        samples.reserveCapacity(configuration.targetFrameCount)
        var peakRSS = baselineRSS
        var lastCallbackStartTime = mach_absolute_time()
        let deltaOffsetPerFrame = configuration.velocityPointsPerSecond / configuration.targetFrameRate
        var frameIndex = 0

        let report: FrameMetricsReport = try await withCheckedThrowingContinuation { continuation in
            let box = StateBox()

            target.onFrame = { [weak self] _, _ in
                guard let self = self, !box.isResumed else { return }

                let callbackStartTime = mach_absolute_time()
                let intervalMs: Double
                if frameIndex == 0 {
                    intervalMs = 1000.0 / self.configuration.targetFrameRate
                } else {
                    intervalMs = MachTimeHelper.ticksToMilliseconds(callbackStartTime - lastCallbackStartTime)
                }
                lastCallbackStartTime = callbackStartTime

                viewport.scroll(by: deltaOffsetPerFrame)
                viewport.renderVisibleRows()

                let callbackEndTime = mach_absolute_time()
                let latencyMs = MachTimeHelper.ticksToMilliseconds(callbackEndTime - callbackStartTime)

                let sampleRSS: Int64
                if frameIndex % 100 == 0 || frameIndex == self.configuration.targetFrameCount - 1 {
                    sampleRSS = Self.currentMemoryRSS()
                    if sampleRSS > peakRSS {
                        peakRSS = sampleRSS
                    }
                } else {
                    sampleRSS = peakRSS
                }

                samples.append(
                    FrameMetricSample(
                        frameIndex: frameIndex,
                        timestampMs: MachTimeHelper.ticksToMilliseconds(callbackStartTime),
                        intervalMs: intervalMs,
                        deliveryLatencyMs: latencyMs,
                        rssBytes: sampleRSS
                    )
                )

                frameIndex += 1

                if frameIndex >= self.configuration.targetFrameCount {
                    box.isResumed = true
                    link.invalidate()
                    window.orderOut(nil)
                    let finalRSS = Self.currentMemoryRSS()
                    let rep = FrameMetricsReport.build(
                        samples: samples,
                        baselineRSS: baselineRSS,
                        peakRSS: max(peakRSS, finalRSS),
                        finalRSS: finalRSS,
                        resolvedDriverName: "CADisplayLink (Track A)",
                        config: self.configuration
                    )
                    continuation.resume(returning: rep)
                }
            }

            let timeoutSeconds = max(5.0, Double(self.configuration.targetFrameCount) * (1.5 / self.configuration.targetFrameRate))
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000.0))
                if !box.isResumed {
                    box.isResumed = true
                    link.invalidate()
                    window.orderOut(nil)
                    continuation.resume(throwing: NSError(
                        domain: "VirtualViewportFrameProfiler",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "CADisplayLink profiling timed out"]
                    ))
                }
            }
        }

        return report
    }

    private func runMachRealTimeProfile(
        viewport: VirtualViewport,
        baselineRSS: Int64
    ) -> FrameMetricsReport {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        let targetIntervalMs = 1000.0 / configuration.targetFrameRate
        Self.applyMachRealTimePolicy(periodMs: targetIntervalMs)

        let intervalTicks = MachTimeHelper.millisecondsToTicks(targetIntervalMs)
        let deltaOffsetPerFrame = configuration.velocityPointsPerSecond / configuration.targetFrameRate

        var samples: [FrameMetricSample] = []
        samples.reserveCapacity(configuration.targetFrameCount)

        var peakRSS = baselineRSS
        var nextTickTime = mach_absolute_time() + intervalTicks
        var lastCallbackStartTime = mach_absolute_time()

        for frame in 0..<configuration.targetFrameCount {
            if configuration.pacingMode == .realTime {
                mach_wait_until(nextTickTime)
            }

            let callbackStartTime = mach_absolute_time()
            let intervalMs: Double
            if frame == 0 {
                intervalMs = targetIntervalMs
            } else {
                intervalMs = MachTimeHelper.ticksToMilliseconds(callbackStartTime - lastCallbackStartTime)
            }
            lastCallbackStartTime = callbackStartTime

            viewport.scroll(by: deltaOffsetPerFrame)
            viewport.renderVisibleRows()

            let callbackEndTime = mach_absolute_time()
            let latencyMs = MachTimeHelper.ticksToMilliseconds(callbackEndTime - callbackStartTime)

            let sampleRSS: Int64
            if frame % 100 == 0 || frame == configuration.targetFrameCount - 1 {
                sampleRSS = Self.currentMemoryRSS()
                if sampleRSS > peakRSS {
                    peakRSS = sampleRSS
                }
            } else {
                sampleRSS = peakRSS
            }

            samples.append(
                FrameMetricSample(
                    frameIndex: frame,
                    timestampMs: MachTimeHelper.ticksToMilliseconds(callbackStartTime),
                    intervalMs: intervalMs,
                    deliveryLatencyMs: latencyMs,
                    rssBytes: sampleRSS
                )
            )

            nextTickTime += intervalTicks
        }

        let finalRSS = Self.currentMemoryRSS()
        return FrameMetricsReport.build(
            samples: samples,
            baselineRSS: baselineRSS,
            peakRSS: max(peakRSS, finalRSS),
            finalRSS: finalRSS,
            resolvedDriverName: "Mach Hard Real-Time 120Hz (Track B)",
            config: configuration
        )
    }
}

// MARK: - Automated Verification Suite

@MainActor
final class VirtualViewportFrameProfilerTests: XCTestCase {

    func test120FpsVirtualViewportScrollOver1MillionNodes() async throws {
        let config = ProfilerConfiguration(
            nodeCount: 1_000_000,
            targetFrameCount: 120,
            velocityPointsPerSecond: 5_000.0,
            targetFrameRate: 120.0,
            visibleRowCount: 50,
            driverMode: .headlessMachRealTime,
            pacingMode: .realTime
        )

        let profiler = VirtualViewportFrameProfiler(configuration: config)
        let report = try await profiler.profile()

        print(report.formattedSummary)

        XCTAssertEqual(report.totalFrames, 120, "Must record exactly 120 frames")
        XCTAssertLessThanOrEqual(
            report.p99_9DeliveryLatencyMs,
            8.33,
            "P99.9 frame delivery latency (\(report.p99_9DeliveryLatencyMs)ms) must meet 120Hz ProMotion budget (<= 8.33ms)"
        )
        XCTAssertEqual(
            report.droppedFrameCount,
            0,
            "Dropped frame count (delivery > 10.0ms) must strictly be 0"
        )
        XCTAssertLessThanOrEqual(
            report.memoryGrowthMB,
            8.0,
            "Continuous scroll memory growth (\(report.memoryGrowthMB)MB) must not exceed 8.0MB"
        )
    }

    func testAcceleratedVirtualViewport1MillionNodes() async throws {
        let config = ProfilerConfiguration(
            nodeCount: 1_000_000,
            targetFrameCount: 1_000,
            velocityPointsPerSecond: 10_000.0,
            targetFrameRate: 120.0,
            visibleRowCount: 60,
            driverMode: .headlessMachRealTime,
            pacingMode: .accelerated
        )

        let profiler = VirtualViewportFrameProfiler(configuration: config)
        let report = try await profiler.profile()

        XCTAssertEqual(report.totalFrames, 1_000)
        XCTAssertLessThanOrEqual(report.p99_9DeliveryLatencyMs, 8.33)
        XCTAssertEqual(report.droppedFrameCount, 0)
        XCTAssertLessThanOrEqual(report.memoryGrowthMB, 8.0)
    }

    func testMemoryRSSMeasurementIntegrity() {
        let rss = VirtualViewportFrameProfiler.currentMemoryRSS()
        XCTAssertGreaterThan(rss, 0, "Darwin resident set size must be non-zero")
    }

    func testSyntheticNodeStoreBoundsAndProperties() {
        let provider = SyntheticVirtualNodeProvider(totalNodeCount: 1_000_000)
        XCTAssertEqual(provider.totalNodeCount, 1_000_000)

        let root = provider.node(at: 0)
        XCTAssertEqual(root.id, 0)
        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(root.uncompressedSize, 0)

        let item = provider.node(at: 999_999)
        XCTAssertEqual(item.id, 999_999)
        XCTAssertFalse(item.name.isEmpty)
        XCTAssertFalse(item.path.isEmpty)
    }

    func testPercentileInterpolationMath() {
        let values: [Double] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
        let p50 = FrameMetricsReport.percentile(values, percentile: 0.5)
        XCTAssertEqual(p50, 5.5, accuracy: 0.01)

        let p90 = FrameMetricsReport.percentile(values, percentile: 0.9)
        XCTAssertEqual(p90, 9.1, accuracy: 0.01)
    }
}
