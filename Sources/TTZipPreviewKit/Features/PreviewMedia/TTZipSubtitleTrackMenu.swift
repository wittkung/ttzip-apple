// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit

@MainActor
struct TTZipSubtitleTrackMenu: NSViewRepresentable {
    let labels = MenuLabels()
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

    struct MenuLabels: Equatable {
        let accessibilityLabel: String
        let primaryTrack: String
        let off: String
        let secondaryTrack: String
        let load: String
        let style: String
        let remove: String

        @MainActor
        init() {
            accessibilityLabel = MediaLocalization.text(.subtitles)
            primaryTrack = MediaLocalization.text(.subtitleTrack)
            off = MediaLocalization.text(.off)
            secondaryTrack = MediaLocalization.text(.secondarySubtitle)
            load = MediaLocalization.text(.loadSubtitles)
            style = MediaLocalization.text(.subtitleStyle)
            remove = MediaLocalization.text(.turnOffSubtitles)
        }
    }

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
            let labels: MenuLabels
            let options: [SubtitleMenuOption]
            let selectedID: String?
            let selectedSecondaryID: String
            let hasExternalSubtitle: Bool

            init(_ model: TTZipSubtitleTrackMenu) {
                labels = model.labels
                options = model.options
                selectedID = model.selectedID
                selectedSecondaryID = model.selectedSecondaryID
                hasExternalSubtitle = model.hasExternalSubtitle
            }
        }

        private var model: TTZipSubtitleTrackMenu?
        private weak var button: MenuButton?
        private var isTracking = false
        private var menuState: MenuState?

        func update(from model: TTZipSubtitleTrackMenu, button: MenuButton) {
            self.model = model
            self.button = button
            button.setAccessibilityLabel(model.labels.accessibilityLabel)
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

        private func makeMenu(from model: TTZipSubtitleTrackMenu) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let heading = NSMenuItem(title: model.labels.primaryTrack, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            let off = item(model.labels.off, action: #selector(removeSubtitles), state: model.selectedID == nil || model.selectedID == "off")
            menu.addItem(off)
            for option in model.options {
                let entry = item(option.title, action: #selector(selectPrimary(_:)), state: option.id == model.selectedID)
                entry.representedObject = option.id
                entry.isEnabled = option.enabled
                menu.addItem(entry)
            }
            let enabled = model.options.filter { $0.enabled && $0.supportsSecondary }
            if !enabled.isEmpty {
                let secondary = NSMenu(title: model.labels.secondaryTrack)
                secondary.autoenablesItems = false
                secondary.addItem(item(model.labels.off, action: #selector(disableSecondary), state: model.selectedSecondaryID == "off"))
                for option in enabled {
                    let entry = item(option.title, action: #selector(selectSecondary(_:)), state: option.id == model.selectedSecondaryID)
                    entry.representedObject = option.id
                    secondary.addItem(entry)
                }
                let parent = NSMenuItem(title: model.labels.secondaryTrack, action: nil, keyEquivalent: "")
                menu.setSubmenu(secondary, for: parent)
                menu.addItem(parent)
            }
            menu.addItem(.separator())
            menu.addItem(item(model.labels.load, action: #selector(loadSubtitles)))
            menu.addItem(item(model.labels.style, action: #selector(showStyle)))
            if model.hasExternalSubtitle {
                menu.addItem(.separator())
                menu.addItem(item(model.labels.remove, action: #selector(removeSubtitles)))
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
