// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Carbon.HIToolbox
import Foundation

public struct GlobalKeyCombo: Equatable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let display: String
    public let spec: String

    private static let keyMap: [String: (code: Int, name: String)] = {
        var map: [String: (Int, String)] = [
            "space": (kVK_Space, "Space"),
            "return": (kVK_Return, "↩"),
            "tab": (kVK_Tab, "⇥"),
            "escape": (kVK_Escape, "⎋"),
            "esc": (kVK_Escape, "⎋"),
            "slash": (kVK_ANSI_Slash, "/"),
            "period": (kVK_ANSI_Period, "."),
            "comma": (kVK_ANSI_Comma, ","),
            "semicolon": (kVK_ANSI_Semicolon, ";"),
            "minus": (kVK_ANSI_Minus, "-"),
            "equal": (kVK_ANSI_Equal, "="),
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
            ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
            ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
            ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1),
            ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4), ("5", kVK_ANSI_5),
            ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ]
        for (char, code) in letters {
            map[char] = (code, char.uppercased())
        }
        return map
    }()

    public init?(_ text: String) {
        var modifiers: UInt32 = 0
        var key: (code: Int, name: String)?
        for part in text.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " }) {
            switch part {
            case "cmd", "command", "⌘":
                modifiers |= UInt32(cmdKey)
            case "shift", "⇧":
                modifiers |= UInt32(shiftKey)
            case "opt", "option", "alt", "⌥":
                modifiers |= UInt32(optionKey)
            case "ctrl", "control", "⌃":
                modifiers |= UInt32(controlKey)
            default:
                guard key == nil, let found = Self.keyMap[String(part)] else { return nil }
                key = found
            }
        }
        guard let key else { return nil }
        self.init(code: key.code, modifiers: modifiers, name: key.name, specPart: String(text))
    }

    public init?(code: Int, modifiers: UInt32, name: String? = nil, specPart: String? = nil) {
        guard modifiers & UInt32(cmdKey | optionKey | controlKey | shiftKey) != 0 else { return nil }
        let resolvedName = name ?? Self.keyMap.first(where: { $0.value.code == code })?.value.name ?? "Key"
        self.keyCode = UInt32(code)
        self.carbonModifiers = modifiers
        var symbols = ""
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃"; parts.append("ctrl") }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥"; parts.append("opt") }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧"; parts.append("shift") }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘"; parts.append("cmd") }
        self.display = symbols + resolvedName
        self.spec = (parts + [resolvedName.lowercased()]).joined(separator: "+")
    }

    public static let defaultGlobalSearch = GlobalKeyCombo("cmd+shift+space")!
}

@MainActor
public final class CarbonHotkeyCenter {
    public static let shared = CarbonHotkeyCenter()
    private var hotkey: GlobalCarbonHotkey?
    public private(set) var activeCombo: GlobalKeyCombo?
    public var onTrigger: (@MainActor () -> Void)?

    private init() {}

    @discardableResult
    public func register(combo: GlobalKeyCombo, action: @escaping @MainActor () -> Void) -> Bool {
        if combo == activeCombo, hotkey != nil {
            self.onTrigger = action
            return true
        }
        let previous = hotkey
        hotkey = nil
        guard let newHotkey = GlobalCarbonHotkey(combo, action: { [weak self] in
            Task { @MainActor in
                self?.onTrigger?()
            }
        }) else {
            hotkey = previous
            return false
        }
        self.hotkey = newHotkey
        self.activeCombo = combo
        self.onTrigger = action
        return true
    }

    public func unregister() {
        hotkey = nil
        activeCombo = nil
        onTrigger = nil
    }
}

private final class GlobalCarbonHotkey {
    let combo: GlobalKeyCombo
    private let action: () -> Void
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?

    init?(_ combo: GlobalKeyCombo, action: @escaping () -> Void) {
        self.combo = combo
        self.action = action
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyCallback,
            1,
            &eventSpec,
            context,
            &handlerRef
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x54545A50), id: 1) // 'TTZP'
        let registerStatus = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let handler = handlerRef { RemoveEventHandler(handler) }
            handlerRef = nil
            return nil
        }
    }

    deinit {
        if let key = hotKeyRef { UnregisterEventHotKey(key) }
        if let handler = handlerRef { RemoveEventHandler(handler) }
    }

    fileprivate func fire() {
        action()
    }
}

private nonisolated func carbonHotKeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let rawAddress = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: rawAddress) else { return }
        let hotkey = Unmanaged<GlobalCarbonHotkey>.fromOpaque(pointer).takeUnretainedValue()
        hotkey.fire()
    }
    return noErr
}
