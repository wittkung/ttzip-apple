// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import MediaPlayer
import os.log

/// Hardware and system-level remote command coordinator managing macOS media keys (F7, F8, F9),
/// AirPods gestures (single click, double click, press-and-hold), and Control Center playback controls.
@MainActor
public final class TTRemoteCommandCoordinator {
    public static let shared = TTRemoteCommandCoordinator()
    
    private let logger = Logger(subsystem: "dev.metastudyline.ttmedia", category: "TTRemoteCommandCoordinator")
    private let commandCenter = MPRemoteCommandCenter.shared()
    
    public var playHandler: (@MainActor () -> Void)?
    public var pauseHandler: (@MainActor () -> Void)?
    public var toggleHandler: (@MainActor () -> Void)?
    public var nextTrackHandler: (@MainActor () -> Void)?
    public var previousTrackHandler: (@MainActor () -> Void)?
    public var seekHandler: (@MainActor (Double) -> Void)?
    public var skipForwardHandler: (@MainActor (Double) -> Void)?
    public var skipBackwardHandler: (@MainActor (Double) -> Void)?
    
    private var registeredTargets: [(MPRemoteCommand, Any)] = []
    
    private init() {}
    
    /// Configures remote command handlers and enables all supported system playback controls.
    ///
    /// - Parameters:
    ///   - playHandler: Callback when system play is triggered.
    ///   - pauseHandler: Callback when system pause is triggered.
    ///   - toggleHandler: Callback when play/pause toggle is triggered (F8, AirPods click).
    ///   - nextTrackHandler: Callback when next track is triggered (F9, AirPods double click).
    ///   - previousTrackHandler: Callback when previous track is triggered (F7, AirPods triple click).
    ///   - seekHandler: Callback when timeline scrub position changes.
    ///   - skipForwardHandler: Callback when 15s forward skip is triggered.
    ///   - skipBackwardHandler: Callback when 15s backward skip is triggered.
    public func setupRemoteCommands(
        playHandler: (@MainActor () -> Void)? = nil,
        pauseHandler: (@MainActor () -> Void)? = nil,
        toggleHandler: (@MainActor () -> Void)? = nil,
        nextTrackHandler: (@MainActor () -> Void)? = nil,
        previousTrackHandler: (@MainActor () -> Void)? = nil,
        seekHandler: (@MainActor (Double) -> Void)? = nil,
        skipForwardHandler: (@MainActor (Double) -> Void)? = nil,
        skipBackwardHandler: (@MainActor (Double) -> Void)? = nil
    ) {
        self.playHandler = playHandler
        self.pauseHandler = pauseHandler
        self.toggleHandler = toggleHandler
        self.nextTrackHandler = nextTrackHandler
        self.previousTrackHandler = previousTrackHandler
        self.seekHandler = seekHandler
        self.skipForwardHandler = skipForwardHandler
        self.skipBackwardHandler = skipBackwardHandler
        
        enableCommands()
    }
    
    /// Enables all remote commands and registers event targets with `MPRemoteCommandCenter`.
    public func enableCommands() {
        disableCommands()
        
        // Play / Pause / Toggle commands (F8 / AirPods single tap)
        registerCommand(commandCenter.playCommand) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playHandler?()
            }
            return .success
        }
        
        registerCommand(commandCenter.pauseCommand) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pauseHandler?()
            }
            return .success
        }
        
        registerCommand(commandCenter.togglePlayPauseCommand) { [weak self] _ in
            Task { @MainActor [weak self] in
                if let toggleHandler = self?.toggleHandler {
                    toggleHandler()
                } else {
                    self?.playHandler?()
                }
            }
            return .success
        }
        
        // Track Navigation commands (F7 / F9 / AirPods double tap)
        registerCommand(commandCenter.nextTrackCommand) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.nextTrackHandler?()
            }
            return .success
        }
        
        registerCommand(commandCenter.previousTrackCommand) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.previousTrackHandler?()
            }
            return .success
        }
        
        // Timeline Scrubbing / Seek command (Control Center timeline scrub)
        registerCommand(commandCenter.changePlaybackPositionCommand) { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let targetPosition = positionEvent.positionTime
            Task { @MainActor [weak self] in
                self?.seekHandler?(targetPosition)
            }
            return .success
        }
        
        // Skip Interval commands (15 seconds forward/backward)
        commandCenter.skipForwardCommand.preferredIntervals = [15.0]
        registerCommand(commandCenter.skipForwardCommand) { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15.0
            Task { @MainActor [weak self] in
                self?.skipForwardHandler?(interval)
            }
            return .success
        }
        
        commandCenter.skipBackwardCommand.preferredIntervals = [15.0]
        registerCommand(commandCenter.skipBackwardCommand) { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15.0
            Task { @MainActor [weak self] in
                self?.skipBackwardHandler?(interval)
            }
            return .success
        }
        
        logger.info("Configured and enabled all MPRemoteCommandCenter controls")
    }
    
    /// Unregisters all active targets and disables remote commands.
    public func disableCommands() {
        for (command, target) in registeredTargets {
            command.removeTarget(target)
        }
        registeredTargets.removeAll()
        
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
    }
    
    private func registerCommand(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        let target = command.addTarget(handler: handler)
        registeredTargets.append((command, target))
    }
}
