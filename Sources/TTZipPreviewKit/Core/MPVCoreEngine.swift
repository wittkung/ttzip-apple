// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import os.log
import CMPVBridge

/// C-Safe wakeup trampoline preventing Use-After-Free (UAF) across actor and thread boundaries.
private final class MPVWakeupTrampoline: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive: Bool = true
    private var onWakeup: (@Sendable () -> Void)?

    init(onWakeup: (@Sendable () -> Void)?) {
        self.onWakeup = onWakeup
    }

    func trigger() {
        lock.lock()
        let active = isActive
        let handler = onWakeup
        lock.unlock()
        if active {
            handler?()
        }
    }

    func deactivate() {
        lock.lock()
        isActive = false
        onWakeup = nil
        lock.unlock()
    }
}

/// Global C function pointer invoked by libmpv on event availability.
private func mpvCoreWakeupCallback(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let trampoline = Unmanaged<MPVWakeupTrampoline>.fromOpaque(context).takeUnretainedValue()
    trampoline.trigger()
}

/// Thread-safe wrapper for destroying handle pointers asynchronously without blocking actors.
private struct UncheckedHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// Thread-safe holder managing the resident libmpv client handle lifecycle.
private final class MPVHandleHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var rawPointer: OpaquePointer?
    private var trampoline: MPVWakeupTrampoline?

    init(rawPointer: OpaquePointer? = nil) {
        self.rawPointer = rawPointer
    }

    var pointer: OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return rawPointer
    }

    func setPointer(_ ptr: OpaquePointer?) {
        lock.lock()
        rawPointer = ptr
        lock.unlock()
    }

    func lockAndInitialize(
        mode: MPVOutputMode,
        isTesting: Bool,
        onWakeup: @escaping @Sendable () -> Void
    ) throws -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }

        if let existing = rawPointer { return existing }

        guard let newHandle = mpv_create() else {
            throw MPVError.initializationFailed("Failed to allocate libmpv client handle")
        }

        mpv_request_log_messages(newHandle, "warn")
        mpv_set_option_string(newHandle, "force-window", "no")
        mpv_set_option_string(newHandle, "fullscreen", "no")
        mpv_set_option_string(newHandle, "ontop", "no")
        mpv_set_option_string(newHandle, "border", "no")
        mpv_set_option_string(newHandle, "window-dragging", "no")
        mpv_set_option_string(newHandle, "focus-on-open", "no")
        mpv_set_option_string(newHandle, "keepaspect-window", "no")
        mpv_set_option_string(newHandle, "input-cursor", "no")
        mpv_set_option_string(newHandle, "osc", "no")
        mpv_set_option_string(newHandle, "osd-level", "0")
        mpv_set_option_string(newHandle, "osd-bar", "no")
        mpv_set_option_string(newHandle, "config", "no")
        mpv_set_option_string(newHandle, "load-scripts", "no")
        mpv_set_option_string(newHandle, "load-osd-console", "no")
        mpv_set_option_string(newHandle, "load-auto-profiles", "no")
        mpv_set_option_string(newHandle, "load-stats-overlay", "no")
        mpv_set_option_string(newHandle, "ytdl", "no")
        mpv_set_option_string(newHandle, "input-default-bindings", "no")
        mpv_set_option_string(newHandle, "input-vo-keyboard", "no")
        mpv_set_option_string(newHandle, "input-app-events", "no")

        if mode.isAudioOnly {
            mpv_set_option_string(newHandle, "vo", "null")
            mpv_set_option_string(newHandle, "vid", "no")
            mpv_set_option_string(newHandle, "hwdec", "no")
            mpv_set_option_string(newHandle, "ao", isTesting ? "null" : "auto")
        } else {
            mpv_set_option_string(newHandle, "vo", isTesting ? "null" : "libmpv")
            mpv_set_option_string(newHandle, "hwdec", isTesting ? "no" : "videotoolbox-copy")
            mpv_set_option_string(newHandle, "hwdec-codecs", "all")
            mpv_set_option_string(newHandle, "ao", isTesting ? "null" : "auto")
        }

        mpv_set_option_string(newHandle, "target-colorspace-hint", "no")
        mpv_set_option_string(newHandle, "target-trc", "auto")
        mpv_set_option_string(newHandle, "tone-mapping", "bt.2446a")
        mpv_set_option_string(newHandle, "gamut-mapping-mode", "perceptual")
        mpv_set_option_string(newHandle, "hdr-compute-peak", "no")
        mpv_set_option_string(newHandle, "sub-auto", "fuzzy")
        mpv_set_option_string(newHandle, "sub-codepage", "auto")
        mpv_set_option_string(newHandle, "sub-font-size", "52")
        mpv_set_option_string(newHandle, "sub-border-size", "3")
        mpv_set_option_string(newHandle, "keep-open", "yes")
        mpv_set_option_string(newHandle, "idle", "yes")

        let initStatus = mpv_initialize(newHandle)
        guard initStatus >= 0 else {
            let reason = mpv_error_string(initStatus).map { String(cString: $0) } ?? "Code \(initStatus)"
            mpv_destroy(newHandle)
            throw MPVError.initializationFailed(reason)
        }

        let tramp = MPVWakeupTrampoline(onWakeup: onWakeup)
        self.trampoline = tramp
        let rawContext = Unmanaged.passUnretained(tramp).toOpaque()
        mpv_set_wakeup_callback(newHandle, mpvCoreWakeupCallback, rawContext)

        let properties: [(UInt64, String, mpv_format)] = [
            (1, "time-pos", MPV_FORMAT_DOUBLE),
            (2, "duration", MPV_FORMAT_DOUBLE),
            (3, "pause", MPV_FORMAT_FLAG),
            (4, "mute", MPV_FORMAT_FLAG),
            (5, "volume", MPV_FORMAT_DOUBLE),
            (6, "cache-buffering-state", MPV_FORMAT_INT64),
            (7, "eof-reached", MPV_FORMAT_FLAG),
            (8, "core-idle", MPV_FORMAT_FLAG),
            (9, "sub-text", MPV_FORMAT_STRING),
            (10, "audio-codec-name", MPV_FORMAT_STRING),
            (11, "audio-params/samplerate", MPV_FORMAT_DOUBLE),
            (12, "audio-params/channels", MPV_FORMAT_STRING),
            (13, "audio-bitrate", MPV_FORMAT_DOUBLE),
            (14, "video-params/w", MPV_FORMAT_DOUBLE),
            (15, "video-params/h", MPV_FORMAT_DOUBLE)
        ]
        for (replyId, name, format) in properties {
            mpv_observe_property(newHandle, replyId, name, format)
        }

        self.rawPointer = newHandle
        return newHandle
    }

    func terminateAndClear() {
        lock.lock()
        guard let handle = rawPointer else {
            lock.unlock()
            return
        }
        rawPointer = nil
        trampoline?.deactivate()
        trampoline = nil
        lock.unlock()

        mpv_set_wakeup_callback(handle, nil, nil)
        mpv_terminate_destroy(handle)
    }
}

/// Swift 6 Actor-isolated core engine driver managing the resident libmpv instance.
public actor MPVCoreEngine {
    /// Shared singleton instance for unified application-wide playback orchestration.
    public static let shared = MPVCoreEngine()

    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MPVCoreEngine")
    private let handleHolder = MPVHandleHolder()
    private var handle: OpaquePointer? { handleHolder.pointer }
    private var securityScopedURL: URL? = nil
    private var currentOutputMode: MPVOutputMode = .video(renderBackend: "libmpv")
    private var legacyWakeupHandler: (@Sendable () -> Void)? = nil
    private var wakeupListeners: [UUID: @Sendable () -> Void] = [:]

    /// Native libmpv client handle pointer accessible across concurrency boundaries.
    public nonisolated var rawHandle: OpaquePointer? { handleHolder.pointer }

    private static var isTestEnvironment: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        if Bundle.main.bundlePath.hasSuffix(".xctest") { return true }
        let proc = ProcessInfo.processInfo.processName.lowercased()
        if proc.contains("test") || proc.contains("xctest") { return true }
        return false
    }

    public init() {}

    deinit {
        handleHolder.terminateAndClear()
    }

    /// Registers an asynchronous wakeup listener triggered when libmpv queues new events.
    ///
    /// - Parameter listener: Asynchronous callback closure invoked upon event arrival.
    /// - Returns: Unique identifier used to unregister the listener.
    @discardableResult
    public func addWakeupListener(_ listener: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        wakeupListeners[id] = listener
        return id
    }

    /// Unregisters a previously registered wakeup listener by its identifier.
    ///
    /// - Parameter id: Unique listener identifier returned from `addWakeupListener`.
    public func removeWakeupListener(id: UUID) {
        wakeupListeners.removeValue(forKey: id)
    }

    /// Attaches a legacy asynchronous wakeup handler triggered when libmpv queues new events.
    ///
    /// - Parameter handler: Optional callback closure. Passing nil unsets the legacy handler.
    public func setWakeupHandler(_ handler: (@Sendable () -> Void)?) {
        self.legacyWakeupHandler = handler
    }

    /// Synchronously ensures the native libmpv instance is allocated and initialized once.
    @discardableResult
    public nonisolated func ensureInitialized(mode: MPVOutputMode = .video(renderBackend: "libmpv")) throws -> OpaquePointer {
        try handleHolder.lockAndInitialize(mode: mode, isTesting: Self.isTestEnvironment, onWakeup: { [weak self] in
            guard let self else { return }
            Task {
                await self.handleWakeupNotification()
            }
        })
    }

    /// Initializes and configures the native libmpv instance with defensive settings.
    public func initialize(mode: MPVOutputMode = .video(renderBackend: "libmpv")) throws {
        _ = try ensureInitialized(mode: mode)
        self.currentOutputMode = mode
        logger.info("libmpv Core Engine initialized successfully in mode: \(String(describing: mode), privacy: .public)")
    }

    /// Loads a local or remote media file with optional security-scoped bookmark support.
    public func loadFile(url: URL, replace: Bool = true, isAudioOnly: Bool = false) async throws {
        if handle == nil {
            try initialize(mode: isAudioOnly ? .audioOnly : .video(renderBackend: "libmpv"))
        }

        if let prevURL = securityScopedURL {
            prevURL.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }

        if url.startAccessingSecurityScopedResource() {
            self.securityScopedURL = url
        }

        if isAudioOnly != currentOutputMode.isAudioOnly {
            setOutputMode(isAudioOnly ? .audioOnly : .video(renderBackend: "libmpv"))
        }

        try sendCommand(["loadfile", url.path, replace ? "replace" : "append"])
    }

    /// Executes a low-level synchronous libmpv command.
    public func sendCommand(_ args: [String]) throws {
        guard let handle else { throw MPVError.handleDeallocated }
        var cPointers: [UnsafePointer<CChar>?] = args.map { arg in
            UnsafePointer(strdup(arg))
        }
        cPointers.append(nil)
        defer {
            for ptr in cPointers where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr))
            }
        }
        let status = cPointers.withUnsafeMutableBufferPointer { buf in
            mpv_command(handle, buf.baseAddress)
        }
        if status < 0 {
            let reason = mpv_error_string(status).map { String(cString: $0) } ?? "Code \(status)"
            throw MPVError.commandFailed(command: args.joined(separator: " "), status: status, reason: reason)
        }
    }

    /// Sets a string property value in libmpv.
    public func setProperty(name: String, value: String) throws {
        guard let handle else { throw MPVError.handleDeallocated }
        let status = mpv_set_property_string(handle, name, value)
        if status < 0 {
            let reason = mpv_error_string(status).map { String(cString: $0) } ?? "Code \(status)"
            throw MPVError.setPropertyFailed(property: name, status: status, reason: reason)
        }
    }

    /// Sets a double-precision floating point property value in libmpv.
    public func setProperty(name: String, value: Double) throws {
        guard let handle else { throw MPVError.handleDeallocated }
        var v = value
        let status = mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
        if status < 0 {
            let reason = mpv_error_string(status).map { String(cString: $0) } ?? "Code \(status)"
            throw MPVError.setPropertyFailed(property: name, status: status, reason: reason)
        }
    }

    /// Sets a boolean flag property value in libmpv.
    public func setProperty(name: String, value: Bool) throws {
        guard let handle else { throw MPVError.handleDeallocated }
        var flag: Int32 = value ? 1 : 0
        let status = mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
        if status < 0 {
            let reason = mpv_error_string(status).map { String(cString: $0) } ?? "Code \(status)"
            throw MPVError.setPropertyFailed(property: name, status: status, reason: reason)
        }
    }

    /// Reads a string property from the core engine.
    public func getPropertyString(name: String) -> String? {
        guard let handle, let ptr = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(ptr) }
        return String(cString: ptr)
    }

    /// Reads a double property from the core engine.
    public func getPropertyDouble(name: String) -> Double? {
        guard let handle else { return nil }
        var val: Double = 0.0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &val) >= 0 else { return nil }
        return val.isFinite ? val : nil
    }

    /// Reads a boolean flag property from the core engine.
    public func getPropertyBool(name: String) -> Bool? {
        guard let handle else { return nil }
        var flag: Int32 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &flag) >= 0 else { return nil }
        return flag != 0
    }

    /// Dynamically switches the engine output mode between audio-only and video rendering.
    public func setOutputMode(_ mode: MPVOutputMode) {
        self.currentOutputMode = mode
        guard let handle else { return }
        let isTesting = Self.isTestEnvironment
        if mode.isAudioOnly {
            mpv_set_option_string(handle, "vo", "null")
            mpv_set_option_string(handle, "vid", "no")
            mpv_set_option_string(handle, "hwdec", "no")
            mpv_set_option_string(handle, "ao", isTesting ? "null" : "auto")
        } else {
            mpv_set_option_string(handle, "vo", isTesting ? "null" : "libmpv")
            mpv_set_option_string(handle, "vid", "auto")
            mpv_set_option_string(handle, "hwdec", isTesting ? "no" : "videotoolbox-copy")
            mpv_set_option_string(handle, "hwdec-codecs", "all")
            mpv_set_option_string(handle, "ao", isTesting ? "null" : "auto")
        }
    }

    /// Stops playback and resets active timeline position.
    public func stop() {
        try? sendCommand(["stop"])
    }

    /// Completely terminates and tears down the libmpv instance and associated C-trampolines.
    public func terminate() {
        if let prevURL = securityScopedURL {
            prevURL.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }

        legacyWakeupHandler = nil
        wakeupListeners.removeAll()
        handleHolder.terminateAndClear()
        logger.info("libmpv Core Engine terminated successfully")
    }

    /// Drains all pending events from the libmpv client event queue into Sendable structures.
    public func drainEvents() -> [MPVEvent] {
        guard let handle else { return [] }
        var events: [MPVEvent] = []
        while true {
            guard let eventPtr = mpv_wait_event(handle, 0) else { break }
            let event = eventPtr.pointee
            if event.event_id == MPV_EVENT_NONE {
                break
            }
            if let parsed = parseMpvEvent(event) {
                events.append(parsed)
            }
        }
        return events
    }

    private func handleWakeupNotification() {
        legacyWakeupHandler?()
        for listener in wakeupListeners.values {
            listener()
        }
    }

    private func parseMpvEvent(_ event: mpv_event) -> MPVEvent? {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_PLAYBACK_RESTART:
            return .playbackRestart
        case MPV_EVENT_SEEK:
            let pos = getPropertyDouble(name: "time-pos") ?? 0.0
            return .seek(position: pos)
        case MPV_EVENT_END_FILE:
            if let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self) {
                let endFile = data.pointee
                if endFile.error != 0 {
                    let errStr = mpv_error_string(endFile.error).map { String(cString: $0) } ?? "Code \(endFile.error)"
                    return .error(errStr)
                }
            }
            return .eof
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data?.assumingMemoryBound(to: mpv_event_property.self),
                  let nameCStr = data.pointee.name else { return nil }
            let name = String(cString: nameCStr)
            let value = parsePropertyValue(data.pointee)
            return .propertyChange(name: name, value: value)
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data?.assumingMemoryBound(to: mpv_event_log_message.self),
                  let levelCStr = data.pointee.level,
                  let textCStr = data.pointee.text else { return nil }
            let level = String(cString: levelCStr)
            let text = String(cString: textCStr).trimmingCharacters(in: .whitespacesAndNewlines)
            return .logMessage(level: level, text: text)
        default:
            return nil
        }
    }

    private func parsePropertyValue(_ prop: mpv_event_property) -> MPVPropertyValue {
        guard let data = prop.data else { return .none }
        switch prop.format {
        case MPV_FORMAT_STRING:
            let ptr = data.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee
            return .string(String(cString: ptr))
        case MPV_FORMAT_DOUBLE:
            let val = data.assumingMemoryBound(to: Double.self).pointee
            return .double(val)
        case MPV_FORMAT_FLAG:
            let val = data.assumingMemoryBound(to: Int32.self).pointee
            return .flag(val != 0)
        case MPV_FORMAT_INT64:
            let val = data.assumingMemoryBound(to: Int64.self).pointee
            return .int64(val)
        default:
            return .none
        }
    }
}
