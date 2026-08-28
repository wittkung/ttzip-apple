// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit

/// Non-destructive universal error presentation sheet with diagnostic copy and recovery actions.
public struct ErrorPresentationSheetView: View {
    public let payload: AppErrorPayload
    public let onDismiss: () -> Void

    @State private var isDetailsExpanded: Bool = false
    @State private var didCopyDiagnostic: Bool = false

    public init(payload: AppErrorPayload, onDismiss: @escaping () -> Void) {
        self.payload = payload
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.red)

                VStack(alignment: .leading, spacing: 3) {
                    Text(payload.title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("Code: \(payload.diagnosticCode)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Text(payload.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let details = payload.technicalDetails, !details.isEmpty {
                DisclosureGroup(isExpanded: $isDetailsExpanded) {
                    ScrollView {
                        Text(details)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } label: {
                    Text("Technical Diagnostics")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    let fullLog = "[\(payload.diagnosticCode)] \(payload.title)\nMessage: \(payload.message)\nDetails: \(payload.technicalDetails ?? "N/A")"
                    NSPasteboard.general.setString(fullLog, forType: .string)
                    didCopyDiagnostic = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        didCopyDiagnostic = false
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: didCopyDiagnostic ? "checkmark" : "doc.on.doc")
                        Text(didCopyDiagnostic ? "Copied" : "Copy Diagnostics")
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)

                Spacer()

                if let recoveryTitle = payload.recoveryActionTitle, let handler = payload.recoveryHandler {
                    Button(recoveryTitle) {
                        handler()
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }

                Button("Dismiss") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, maxWidth: 520)
        .background(.ultraThinMaterial)
    }
}
