// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI

/// Ultra-responsive, IME-safe AppKit text field bridge for Spotlight-style omnibar input.
public struct SearchInputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommit: () -> Void
    var onCancel: () -> Void
    var onUpArrow: () -> Void
    var onDownArrow: () -> Void

    public init(
        text: Binding<String>,
        placeholder: String,
        onCommit: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {},
        onUpArrow: @escaping () -> Void = {},
        onDownArrow: @escaping () -> Void = {}
    ) {
        self._text = text
        self.placeholder = placeholder
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.onUpArrow = onUpArrow
        self.onDownArrow = onDownArrow
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSTextField {
        let field = CustomSearchNSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16, weight: .regular)
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping

        DispatchQueue.main.async {
            if let win = field.window {
                win.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
        return field
    }

    public func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
    }

    public final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchInputField

        init(_ parent: SearchInputField) {
            self.parent = parent
        }

        public func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Guard: Always let IME candidate picker process keys when composing
            if textView.hasMarkedText() {
                return false
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onUpArrow()
                return true
            } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onDownArrow()
                return true
            }
            return false
        }
    }
}

private final class CustomSearchNSTextField: NSTextField {
    override var allowsVibrancy: Bool { true }
}
