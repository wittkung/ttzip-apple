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
        AppMemoryPressureCoordinator.installMemoryPressureHandler(
            on: source,
            readEvent: { source.data },
            deliver: { [weak self] event in
                self?.handle(event)
            }
        )
        source.resume()
    }

    /// Installs the memory pressure handler on `source`.
    ///
    /// The handler runs on the source's queue, so it must not be main-actor isolated.
    /// `setEventHandler` takes a C block, and Swift 6 emits a runtime executor check for
    /// an isolated closure handed to a C callback. GCD fires that callback on the
    /// source's background queue, the check fails, and the process traps before the body
    /// can hop to the main actor. This function is `nonisolated` so the handler closure is
    /// formed without main-actor isolation, and the `Task { @MainActor }` hop below
    /// carries the isolated work.
    ///
    /// `source` is generic over `DispatchSourceProtocol` and the event flags come from
    /// `readEvent` so a test can drive the handler from a timer source. Real kernel
    /// memory pressure events cannot be triggered on demand.
    nonisolated static func installMemoryPressureHandler<S: DispatchSourceProtocol>(
        on source: S,
        readEvent: @escaping @Sendable () -> DispatchSource.MemoryPressureEvent,
        deliver: @escaping @MainActor @Sendable (DispatchSource.MemoryPressureEvent) -> Void
    ) {
        source.setEventHandler(handler: {
            let event = readEvent()
            Task { @MainActor in
                deliver(event)
            }
        })
    }

    private func handle(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            handleCriticalPressure()
        } else if event.contains(.warning) {
            handleWarningPressure()
        } else if event.contains(.normal) {
            handleNormalPressure()
        }
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
