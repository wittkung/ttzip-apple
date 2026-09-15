// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Cocoa
import Carbon

/// Low-overhead global hotkey monitor utilizing Carbon EventHotKey API.
/// Operates without requiring accessibility keystroke eavesdropping permissions.
@MainActor
public final class GlobalHotKeyManager {
    
    public static let shared = GlobalHotKeyManager()
    
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var onTrigger: (() -> Void)?
    
    private init() {}
    
    deinit {
        unregister()
    }
    
    /// Registers the global hotkey. Defaults to Shift + Space (keyCode 49, shiftKey modifier).
    public func register(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(shiftKey),
        onTrigger: @escaping () -> Void
    ) {
        unregister()
        self.onTrigger = onTrigger
        
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, inEvent, inUserData -> OSStatus in
                guard let inUserData = inUserData, let inEvent = inEvent else { return noErr }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(inUserData).takeUnretainedValue()
                
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    inEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                
                if status == noErr && hotKeyID.signature == OSType(0x54545A50) { // 'TTZP'
                    Task { @MainActor in
                        manager.onTrigger?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
        
        guard installStatus == noErr else {
            return
        }
        
        let hotKeyID = EventHotKeyID(signature: OSType(0x54545A50), id: 1)
        var newHotKeyRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &newHotKeyRef
        )
        
        if registerStatus == noErr {
            self.hotKeyRef = newHotKeyRef
        }
    }
    
    /// Unregisters the active hotkey and cleans up event handlers.
    nonisolated public func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        onTrigger = nil
    }
}
