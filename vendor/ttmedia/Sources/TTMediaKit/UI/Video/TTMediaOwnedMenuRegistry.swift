// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit

@MainActor
public enum TTMediaOwnedMenuRegistry {
    private struct OwnedMenuEntry {
        let menuID: ObjectIdentifier
        let rootMenuID: ObjectIdentifier
        weak var menu: NSMenu?
        let windowNumber: Int
        weak var window: NSWindow?
        weak var controlsVisibility: MediaControlsVisibility?
        let lifecycleGeneration: UInt64
        var isTracking: Bool
    }

    private static var activeMenuWindowNumbers: Set<Int> = []
    private static var ownedMenus: [ObjectIdentifier: OwnedMenuEntry] = [:]

    public static func registerOwnedMenu(
        _ menu: NSMenu,
        for window: NSWindow?,
        controlsVisibility: MediaControlsVisibility? = nil
    ) {
        purgeStaleOwnedMenus()
        guard let window, window.windowNumber > 0 else { return }
        let rootID = ObjectIdentifier(menu)
        let generation = controlsVisibility?.lifecycleGeneration ?? 0
        registerMenuTree(
            menu,
            rootMenuID: rootID,
            window: window,
            controlsVisibility: controlsVisibility,
            lifecycleGeneration: generation
        )
    }

    private static func registerMenuTree(
        _ menu: NSMenu,
        rootMenuID: ObjectIdentifier,
        window: NSWindow,
        controlsVisibility: MediaControlsVisibility?,
        lifecycleGeneration: UInt64
    ) {
        let id = ObjectIdentifier(menu)
        let existingTracking = ownedMenus[id]?.isTracking ?? false
        ownedMenus[id] = OwnedMenuEntry(
            menuID: id,
            rootMenuID: rootMenuID,
            menu: menu,
            windowNumber: window.windowNumber,
            window: window,
            controlsVisibility: controlsVisibility,
            lifecycleGeneration: lifecycleGeneration,
            isTracking: existingTracking
        )
        for item in menu.items {
            if let submenu = item.submenu {
                registerMenuTree(
                    submenu,
                    rootMenuID: rootMenuID,
                    window: window,
                    controlsVisibility: controlsVisibility,
                    lifecycleGeneration: lifecycleGeneration
                )
            }
        }
    }

    private static func purgeStaleOwnedMenus() {
        for (id, entry) in ownedMenus {
            let menuDeallocated = (entry.menu == nil)
            let windowDeallocated = (entry.window == nil) || (entry.window?.windowNumber != entry.windowNumber)
            let generationChanged: Bool = {
                guard let cv = entry.controlsVisibility else { return false }
                return cv.lifecycleGeneration != entry.lifecycleGeneration
            }()
            if menuDeallocated || windowDeallocated || generationChanged {
                ownedMenus.removeValue(forKey: id)
            }
        }
    }

    @discardableResult
    public static func beginTrackedMenu(menuID: ObjectIdentifier?, for window: NSWindow?) -> Bool {
        purgeStaleOwnedMenus()
        guard let menuID, let window, doesMenuBelongToWindow(menuID: menuID, window: window) else {
            return false
        }
        if var entry = ownedMenus[menuID] {
            entry.isTracking = true
            ownedMenus[menuID] = entry
            if var rootEntry = ownedMenus[entry.rootMenuID] {
                rootEntry.isTracking = true
                ownedMenus[entry.rootMenuID] = rootEntry
            }
            if let cv = entry.controlsVisibility,
               cv.lifecycleGeneration == entry.lifecycleGeneration,
               cv.isVisible {
                cv.acquireInteractionLock(id: entry.rootMenuID)
            }
        }
        return true
    }

    @discardableResult
    public static func endTrackedMenu(menuID: ObjectIdentifier?, for window: NSWindow?) -> Bool {
        purgeStaleOwnedMenus()
        guard let menuID, let window, window.windowNumber > 0 else { return false }
        if let entry = ownedMenus[menuID] {
            guard entry.window === window, entry.windowNumber == window.windowNumber else {
                return false
            }
            let affectedIDs = relatedMenuIDs(forEndOf: menuID)
            var wasAnyTracking = false
            for id in affectedIDs {
                if var item = ownedMenus[id] {
                    if item.isTracking { wasAnyTracking = true }
                    item.isTracking = false
                    ownedMenus[id] = item
                }
            }
            let anySiblingStillTracking = ownedMenus.values.contains {
                $0.rootMenuID == entry.rootMenuID && $0.isTracking
            }
            if !anySiblingStillTracking,
               let cv = entry.controlsVisibility,
               cv.lifecycleGeneration == entry.lifecycleGeneration {
                cv.releaseInteractionLock(id: entry.rootMenuID)
            }
            return wasAnyTracking
        }
        return doesMenuBelongToWindow(menuID: menuID, window: window)
    }

    public static func relatedMenuIDs(forEndOf menuID: ObjectIdentifier) -> Set<ObjectIdentifier> {
        guard let entry = ownedMenus[menuID] else { return [menuID] }
        if entry.menuID == entry.rootMenuID {
            var ids: Set<ObjectIdentifier> = [menuID]
            for (id, candidate) in ownedMenus where candidate.rootMenuID == entry.rootMenuID {
                ids.insert(id)
            }
            return ids
        }
        return [menuID]
    }

    public static func invalidateOwnedMenus(for window: NSWindow?) {
        guard let window else { return }
        let winNum = window.windowNumber
        for (id, entry) in ownedMenus where entry.window === window || (winNum > 0 && entry.windowNumber == winNum) {
            if let cv = entry.controlsVisibility, cv.lifecycleGeneration == entry.lifecycleGeneration {
                cv.releaseInteractionLock(id: entry.rootMenuID)
            }
            ownedMenus.removeValue(forKey: id)
        }
        if winNum > 0 {
            activeMenuWindowNumbers.remove(winNum)
        }
    }

    public static func invalidateOwnedMenus(for controlsVisibility: MediaControlsVisibility) {
        for (id, entry) in ownedMenus where entry.controlsVisibility === controlsVisibility {
            ownedMenus.removeValue(forKey: id)
        }
    }

    public static func doesMenuBelongToControls(
        menuID: ObjectIdentifier?,
        controlsVisibility: MediaControlsVisibility?
    ) -> Bool {
        purgeStaleOwnedMenus()
        guard let menuID, let controlsVisibility, let entry = ownedMenus[menuID] else {
            return false
        }
        return entry.controlsVisibility === controlsVisibility
            && entry.lifecycleGeneration == controlsVisibility.lifecycleGeneration
    }

    public static func isMenuTrackingActive(for controlsVisibility: MediaControlsVisibility?) -> Bool {
        purgeStaleOwnedMenus()
        guard let controlsVisibility else { return false }
        return ownedMenus.values.contains {
            $0.controlsVisibility === controlsVisibility
                && $0.lifecycleGeneration == controlsVisibility.lifecycleGeneration
                && $0.isTracking
        }
    }

    public static func setMenuTrackingActive(_ active: Bool, for window: NSWindow?) {
        guard let window, window.windowNumber > 0 else { return }
        if active {
            activeMenuWindowNumbers.insert(window.windowNumber)
        } else {
            activeMenuWindowNumbers.remove(window.windowNumber)
            invalidateOwnedMenus(for: window)
        }
    }

    public static func doesMenuBelongToWindow(_ menu: NSMenu?, window: NSWindow?) -> Bool {
        doesMenuBelongToWindow(menuID: menu.map { ObjectIdentifier($0) }, window: window)
    }

    public static func doesMenuBelongToWindow(menuID: ObjectIdentifier?, window: NSWindow?) -> Bool {
        purgeStaleOwnedMenus()
        guard let menuID, let window, window.windowNumber > 0 else { return false }
        if let mainMenu = NSApplication.shared.mainMenu, ObjectIdentifier(mainMenu) == menuID {
            return false
        }
        if let entry = ownedMenus[menuID] {
            return entry.window === window && entry.windowNumber == window.windowNumber
        }
        if let winMenu = window.menu, menuTreeContains(menuID: menuID, in: winMenu) {
            return true
        }
        let rootView = window.contentView?.superview ?? window.contentView
        return viewHierarchyContainsMenu(menuID: menuID, in: rootView)
    }

    private static func menuTreeContains(menuID: ObjectIdentifier, in menu: NSMenu) -> Bool {
        if ObjectIdentifier(menu) == menuID {
            return true
        }
        for item in menu.items {
            if let sub = item.submenu, menuTreeContains(menuID: menuID, in: sub) {
                return true
            }
        }
        return false
    }

    private static func viewHierarchyContainsMenu(menuID: ObjectIdentifier, in view: NSView?) -> Bool {
        guard let view else { return false }
        if let viewMenu = view.menu, menuTreeContains(menuID: menuID, in: viewMenu) {
            return true
        }
        for subview in view.subviews {
            if viewHierarchyContainsMenu(menuID: menuID, in: subview) {
                return true
            }
        }
        return false
    }

    public static func isMenuTrackingActive(for window: NSWindow?) -> Bool {
        purgeStaleOwnedMenus()
        guard let window, window.windowNumber > 0 else { return false }
        if activeMenuWindowNumbers.contains(window.windowNumber) {
            return true
        }
        if ownedMenus.values.contains(where: {
            $0.window === window && $0.windowNumber == window.windowNumber && $0.isTracking
        }) {
            return true
        }
        return (window.childWindows ?? []).contains {
            $0.isVisible && ($0.level == .popUpMenu || $0.level == .statusBar)
        }
    }
}
