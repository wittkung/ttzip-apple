// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit
import TTZipUI

struct TTZipMarkdownDocumentView: View {
    let markdown: String
    let documentIdentity: String

    var body: some View {
        let blocks = TTMarkdownParser.parseDocumentBlocks(markdown)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(blocks) { block in
                    blockView(block)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .id(documentIdentity)
        .background(Color.clear)
    }

    @ViewBuilder
    private func inlineMarkdownText(_ rawText: String) -> some View {
        Text(TTMarkdownParser.parseInlineAttributedString(rawText))
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: DocumentBlock) -> some View {
        switch block {
        case .title:
            EmptyView()
        case .heading(let level, let text, _):
            headingBlockView(level: level, text: text)
        case .paragraph(let text, _):
            inlineMarkdownText(text)
                .font(.body)
                .lineSpacing(5)
                .foregroundStyle(.primary)
        case .quote(let text, _):
            quoteBlockView(text: text)
        case .code(let language, let code, _):
            TTZipMarkdownCodeBlock(language: language, code: code)
        case .callout(let type, let text, _):
            calloutBlockView(type: type, text: text)
        case .bullet(let text, _):
            bulletBlockView(text: text)
        case .table(let headers, let rows, _):
            TTZipMarkdownTable(headers: headers, rows: rows)
        case .divider:
            Divider().padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func headingBlockView(level: Int, text: String) -> some View {
        let clamped = min(max(level, 1), 6)
        VStack(alignment: .leading, spacing: 6) {
            inlineMarkdownText(text)
                .font(headingFont(for: clamped))
                .foregroundStyle(clamped >= 5 ? .secondary : .primary)
            if clamped <= 2 {
                Divider().opacity(0.45)
            }
        }
        .padding(.top, clamped <= 2 ? 12 : 6)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .system(size: 24, weight: .bold)
        case 2: return .system(size: 20, weight: .bold)
        case 3: return .system(size: 17, weight: .semibold)
        case 4: return .system(size: 15, weight: .semibold)
        case 5: return .system(size: 13.5, weight: .semibold)
        default: return .system(size: 12.5, weight: .semibold)
        }
    }

    private func quoteBlockView(text: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(TTZipTheme.accentColor)
                .frame(width: 4)
            inlineMarkdownText(text)
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .padding(.vertical, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func calloutBlockView(type: DocumentCalloutType, text: String) -> some View {
        let style = calloutStyle(for: type)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
                .font(.title3)
            inlineMarkdownText(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(style.color.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func calloutStyle(for type: DocumentCalloutType) -> (icon: String, color: Color) {
        switch type {
        case .info: return ("info.circle.fill", .blue)
        case .tip: return ("lightbulb.fill", .green)
        case .warning: return ("exclamationmark.triangle.fill", .orange)
        case .note: return ("bookmark.fill", .purple)
        }
    }

    private func bulletBlockView(text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.secondary)
                .frame(width: 5, height: 5)
                .padding(.top, 8)
            inlineMarkdownText(text)
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(4)
        }
    }
}

private struct TTZipMarkdownTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { idx, header in
                        Text(TTMarkdownParser.parseInlineAttributedString(header))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        if idx < headers.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(Color.primary.opacity(0.06))

                Divider()

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                            Text(TTMarkdownParser.parseInlineAttributedString(cell))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                            if colIdx < row.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .background(rowIdx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                    if rowIdx < rows.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
    }
}

private struct TTZipMarkdownCodeBlock: View {
    let language: String?
    let code: String

    @State private var isCopied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    copyToClipboard(code)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCopied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        withAnimation { isCopied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                        Text(TTZipMarkdownHexPreviewLocalization.text(isCopied ? .copiedCodeButton : .copyCodeButton))
                            .font(.caption2)
                    }
                    .foregroundStyle(isCopied ? Color.green : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider().opacity(0.3)

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
