// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

#if os(macOS)
import AppKit
import Combine

/// Viewport occlusion and display sleep coordination monitor (MacWindowOcclusionCoordinator).
/// Ensures that when the window is completely occluded, minimized, or the display is asleep,
/// the rendering pipeline drops to absolute 0Hz physical sleep with 0% GPU/CPU overhead.
@MainActor
public final class MacWindowOcclusionCoordinator: ObservableObject {
    public static let shared = MacWindowOcclusionCoordinator()

    @Published public private(set) var isOccluded: Bool = false
    @Published public private(set) var isScreenAsleep: Bool = false

    /// Determines whether the viewport is genuinely physically visible to the user.
    public var isEffectivelyVisible: Bool {
        return !isOccluded && !isScreenAsleep
    }

    private var cancellables = Set<AnyCancellable>()
    private var windowObserver: NSObjectProtocol?

    private init() {
        setupSystemObservers()
    }

    private func setupSystemObservers() {
        let ws = NSWorkspace.shared.notificationCenter

        // 1. Screens Sleep / Wake
        ws.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenAsleep = true
            }
        }

        ws.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenAsleep = false
            }
        }

        // 2. System Sleep / Wake
        ws.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenAsleep = true
            }
        }

        ws.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenAsleep = false
            }
        }
    }

    /// Binds a specific host window to observe its occlusion state.
    public func observeWindow(_ window: NSWindow) {
        updateOcclusion(for: window)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let window = window else { return }
            Task { @MainActor [weak self] in
                self?.updateOcclusion(for: window)
            }
        }
    }

    private func updateOcclusion(for window: NSWindow) {
        let isVisible = window.occlusionState.contains(.visible)
        let isMiniaturized = window.isMiniaturized
        let occluded = !isVisible || isMiniaturized

        if self.isOccluded != occluded {
            self.isOccluded = occluded
        }
    }
}
#endif
