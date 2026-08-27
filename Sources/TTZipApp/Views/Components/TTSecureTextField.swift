// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI

/// Non-blocking password text field compatible with macOS Text Service Manager (TSM).
/// Avoids native `SecureField` IME deadlock in Popovers/Sheets.
public struct TTSecureTextField: View {
    public let title: String
    @Binding public var text: String
    @State private var isRevealed: Bool = false
    
    public init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }
    
    public var body: some View {
        HStack(spacing: 6) {
            if isRevealed {
                TextField(title, text: $text)
                    .textFieldStyle(.plain)
            } else {
                SecureField(title, text: $text)
                    .textFieldStyle(.plain)
            }
            
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(isRevealed ? "Hide password" : "Show password")
        }
    }
}
