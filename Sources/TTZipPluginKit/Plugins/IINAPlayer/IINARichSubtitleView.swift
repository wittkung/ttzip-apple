// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore

/// Rich text subtitle renderer interpreting Rust UniFFI ASS subtitle AST and style spans.
public struct IINARichSubtitleView: View {
    public let dialogues: [UniFFISubtitleDialogue]
    public let fallbackText: String?
    
    public init(dialogues: [UniFFISubtitleDialogue], fallbackText: String? = nil) {
        self.dialogues = dialogues
        self.fallbackText = fallbackText
    }
    
    public init(dialogue: UniFFISubtitleDialogue) {
        self.dialogues = [dialogue]
        self.fallbackText = nil
    }
    
    public var body: some View {
        VStack(spacing: 4) {
            if !dialogues.isEmpty {
                ForEach(Array(dialogues.enumerated()), id: \.offset) { _, dialogue in
                    dialogueRow(for: dialogue)
                }
            } else if let text = fallbackText, !text.isEmpty {
                IINASubtitleVectorTextView(rawText: text)
            }
        }
        .padding(.horizontal, 24)
        .transition(.opacity)
    }
    
    @ViewBuilder
    private func dialogueRow(for dialogue: UniFFISubtitleDialogue) -> some View {
        let attrString = Self.renderAttributedString(spans: dialogue.spans, plainText: dialogue.plainText)
        let alignment = dialogue.spans.first?.alignment ?? .bottomCenter
        
        Text(attrString)
            .multilineTextAlignment(alignment.swiftUITextAlignment)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
            )
            .frame(maxWidth: .infinity, alignment: alignment.swiftUIAlignment)
    }
    
    /// Converts a sequence of UniFFISubtitleSpan elements into a formatted Swift AttributedString.
    public static func renderAttributedString(spans: [UniFFISubtitleSpan], plainText: String) -> AttributedString {
        guard !spans.isEmpty else {
            var defaultAttr = AttributedString(plainText)
            defaultAttr.foregroundColor = .yellow
            defaultAttr.font = .system(size: 20, weight: .bold, design: .rounded)
            return defaultAttr
        }
        
        var combined = AttributedString()
        for span in spans {
            guard !span.text.isEmpty else { continue }
            var spanAttr = AttributedString(span.text)
            
            // 1. Color mapping
            if let color = span.primaryColor {
                spanAttr.foregroundColor = color.swiftUIColor
            } else {
                spanAttr.foregroundColor = .white
            }
            
            // 2. Font & Size
            let baseSize: CGFloat = span.fontSize.map { CGFloat($0) } ?? 20.0
            var font = Font.system(size: baseSize, weight: (span.bold == true) ? .bold : .medium, design: .rounded)
            if span.italic == true {
                font = font.italic()
            }
            spanAttr.font = font
            
            // 3. Decorations (Underline / Strikethrough)
            if span.underline == true {
                spanAttr.underlineStyle = .single
            }
            if span.strikeout == true {
                spanAttr.strikethroughStyle = .single
            }
            
            combined.append(spanAttr)
        }
        return combined
    }
}

// MARK: - Legacy / Plain Text Subtitle Vector View

public struct IINASubtitleVectorTextView: View {
    public let rawText: String
    
    public init(rawText: String) {
        self.rawText = rawText
    }
    
    public var cleanText: String {
        rawText.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
    }
    
    public var body: some View {
        Text(cleanText)
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(.yellow)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black, radius: 4, x: 0, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8)
            )
    }
}
