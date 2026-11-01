// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Dispatch
import Foundation
import os.log

/// Memory pressure severity level mapped from Darwin memorystatus events.
public enum MemoryPressureLevel: Sendable {
    case normal
    case warning
    case critical
}

/// Central coordinator monitoring Darwin kernel memory pressure via Grand Central Dispatch.
/// Dynamically orchestrates cache eviction, capacity throttling, and staircase warm-up.
@MainActor
public final class AppMemoryPressureCoordinator {
    public static let shared = AppMemoryPressureCoordinator()

    public private(set) var currentLevel: MemoryPressureLevel = .normal
    private var memorySource: (any DispatchSourceMemoryPressure)?
    private var warmupTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MemoryPressure")

    private init() {
        setupSource()
    }

    private func setupSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        self.memorySource = source

        source.setEventHandler { [weak self] in
            let event = source.data
            Task { @MainActor [weak self] in
                guard let self else { return }
                if event.contains(.critical) {
                    self.handleCriticalPressure()
                } else if event.contains(.warning) {
                    self.handleWarningPressure()
                } else if event.contains(.normal) {
                    self.handleNormalPressure()
                }
            }
        }
        source.resume()
    }

    private func handleCriticalPressure() {
        currentLevel = .critical
        warmupTask?.cancel()
        warmupTask = nil
        logger.fault("System memory pressure CRITICAL! Forcing cache eviction and capacity collapse.")

        SidebarIconCache.shared.emergencyPurge(targetCapacity: 16)
        SidebarMetadataCache.shared.emergencyPurge(targetCapacity: 16)
    }

    private func handleWarningPressure() {
        currentLevel = .warning
        warmupTask?.cancel()
        warmupTask = nil
        logger.warning("System memory pressure WARNING. Halving cache bounds.")

        SidebarIconCache.shared.throttleCapacity(targetCapacity: 64)
        SidebarMetadataCache.shared.throttleCapacity(targetCapacity: 64)
    }

    private func handleNormalPressure() {
        guard currentLevel != .normal else { return }
        logger.info("System memory pressure returned to NORMAL. Arming hysteresis debounce timer.")

        warmupTask?.cancel()
        warmupTask = Task { @MainActor [weak self] in
            // 3-second debounce window to prevent flapping
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }

            self.currentLevel = .normal
            self.logger.info("Pressure stable. Initiating staircase cache warm-up.")

            // Stage 1: Expand to 64
            SidebarIconCache.shared.setCapacity(64)
            SidebarMetadataCache.shared.setCapacity(64)

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            // Stage 2: Expand to 128
            SidebarIconCache.shared.setCapacity(128)
            SidebarMetadataCache.shared.setCapacity(128)

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }

            // Stage 3: Restore to baseline 256
            SidebarIconCache.shared.setCapacity(256)
            SidebarMetadataCache.shared.setCapacity(256)
        }
    }
}
