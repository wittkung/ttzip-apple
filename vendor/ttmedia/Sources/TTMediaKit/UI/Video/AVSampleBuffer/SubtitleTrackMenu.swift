// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI

@MainActor
struct SubtitleTrackMenu: NSViewRepresentable {
    let languageCode: String
    let options: [SubtitleMenuOption]
    let selectedID: String?
    let selectedSecondaryID: String
    let hasExternalSubtitle: Bool
    let controlsVisibility: MediaControlsVisibility?
    let onSelect: (String) -> Void
    let onSelectSecondary: (String) -> Void
    let onRemove: () -> Void
    let onLoad: () -> Void
    let onShowStyle: () -> Void
    let onUserInteraction: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MenuButton {
        let button = MenuButton(frame: .zero)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        context.coordinator.update(from: self, button: button)
        return button
    }

    func updateNSView(_ button: MenuButton, context: Context) {
        context.coordinator.update(from: self, button: button)
    }

    final class MenuButton: NSButton {
        var trackMenu: NSMenu?
    }

    @MainActor
    final class Coordinator: NSObject {
        private struct MenuState: Equatable {
            let languageCode: String
            let options: [SubtitleMenuOption]
            let selectedID: String?
            let selectedSecondaryID: String
            let hasExternalSubtitle: Bool

            init(_ model: SubtitleTrackMenu) {
                languageCode = model.languageCode
                options = model.options
                selectedID = model.selectedID
                selectedSecondaryID = model.selectedSecondaryID
                hasExternalSubtitle = model.hasExternalSubtitle
            }
        }

        private var model: SubtitleTrackMenu?
        private weak var button: MenuButton?
        private var isTracking = false
        private var menuState: MenuState?

        func update(from model: SubtitleTrackMenu, button: MenuButton) {
            self.model = model
            self.button = button
            button.setAccessibilityLabel(MediaLocalization.text(.subtitles))
            button.image = NSImage(
                systemSymbolName: model.hasExternalSubtitle ? "captions.bubble.fill" : "captions.bubble",
                accessibilityDescription: nil
            )
            let nextState = MenuState(model)
            if !isTracking && nextState != menuState {
                button.trackMenu = makeMenu(from: model)
                menuState = nextState
            }
        }

        @objc func openMenu(_ sender: NSButton) {
            guard let button, let model, let menu = button.trackMenu else { return }
            isTracking = true
            let lockID = ObjectIdentifier(button)
            // Menu tracking owns the cursor lock until AppKit returns from its modal event loop.
            model.controlsVisibility?.acquireInteractionLock(id: lockID)
            defer {
                model.controlsVisibility?.releaseInteractionLock(id: lockID)
                isTracking = false
                if let latest = self.model {
                    button.trackMenu = makeMenu(from: latest)
                    menuState = MenuState(latest)
                }
            }
            model.onUserInteraction()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
        }

        private func makeMenu(from model: SubtitleTrackMenu) -> NSMenu {
            let menu = NSMenu()
            let heading = NSMenuItem(title: MediaLocalization.text(.subtitleTrack), action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            let off = item(MediaLocalization.text(.off), action: #selector(removeSubtitles), state: model.selectedID == nil || model.selectedID == "off")
            menu.addItem(off)
            for option in model.options {
                let entry = item(option.title, action: #selector(selectPrimary(_:)), state: option.id == model.selectedID)
                entry.representedObject = option.id
                entry.isEnabled = option.enabled
                menu.addItem(entry)
            }
            let enabled = model.options.filter { $0.enabled && $0.supportsSecondary }
            if !enabled.isEmpty {
                let secondary = NSMenu(title: MediaLocalization.text(.secondarySubtitle))
                secondary.addItem(item(MediaLocalization.text(.off), action: #selector(disableSecondary), state: model.selectedSecondaryID == "off"))
                for option in enabled {
                    let entry = item(option.title, action: #selector(selectSecondary(_:)), state: option.id == model.selectedSecondaryID)
                    entry.representedObject = option.id
                    secondary.addItem(entry)
                }
                let parent = NSMenuItem(title: MediaLocalization.text(.secondarySubtitle), action: nil, keyEquivalent: "")
                menu.setSubmenu(secondary, for: parent)
                menu.addItem(parent)
            }
            menu.addItem(.separator())
            menu.addItem(item(MediaLocalization.text(.loadSubtitles), action: #selector(loadSubtitles)))
            menu.addItem(item(MediaLocalization.text(.subtitleStyle), action: #selector(showStyle)))
            if model.hasExternalSubtitle {
                menu.addItem(.separator())
                menu.addItem(item(MediaLocalization.text(.turnOffSubtitles), action: #selector(removeSubtitles)))
            }
            return menu
        }

        private func item(_ title: String, action: Selector, state: Bool = false) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.state = state ? .on : .off
            return entry
        }

        @objc private func selectPrimary(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            model?.onSelect(id)
            model?.onUserInteraction()
        }

        @objc private func selectSecondary(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            model?.onSelectSecondary(id)
            model?.onUserInteraction()
        }

        @objc private func disableSecondary() {
            model?.onSelectSecondary("off")
            model?.onUserInteraction()
        }

        @objc private func removeSubtitles() {
            model?.onRemove()
            model?.onUserInteraction()
        }

        @objc private func loadSubtitles() {
            model?.onLoad()
            model?.onUserInteraction()
        }

        @objc private func showStyle() {
            model?.onShowStyle()
            model?.onUserInteraction()
        }
    }
}
