// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

public struct ArchiveIntegrityView: View {
    public let archivePath: String
    public let initialRepairOutputPath: String?
    @State private var viewModel: ArchiveIntegrityViewModel
    @Environment(\.dismiss) private var dismiss

    public var repairOutputPath: String {
        viewModel.customOutputPath
    }

    public init(
        archivePath: String,
        initialRepairOutputPath: String? = nil,
        viewModel: ArchiveIntegrityViewModel? = nil
    ) {
        self.archivePath = archivePath
        let trimmedOut = initialRepairOutputPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOut = (trimmedOut?.isEmpty == false) ? trimmedOut : nil
        self.initialRepairOutputPath = normalizedOut
        let resolvedVM = viewModel ?? ArchiveIntegrityViewModel(initialOutputPath: normalizedOut)
        if let normalizedOut, resolvedVM.customOutputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedVM.repairOutputPath = normalizedOut
        } else if resolvedVM.customOutputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !archivePath.isEmpty {
            resolvedVM.customOutputPath = ArchiveIntegrityViewModel.defaultRepairedOutputPath(for: archivePath)
        }
        self._viewModel = State(initialValue: resolvedVM)
    }

    public var body: some View {
        VStack(spacing: 16) {
            headerSection
            Divider()
            contentSection
            repairSection
            Spacer(minLength: 4)
            actionBarSection
        }
        .padding()
        .frame(minWidth: 540, minHeight: 440)
        .onAppear {
            if viewModel.report == nil && !viewModel.isVerifying {
                viewModel.startIntegrityCheck(archivePath: archivePath)
            }
        }
    }

    private var headerSection: some View {
        HStack {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 28))
                .foregroundColor(TTZipTheme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Archive Integrity Diagnostics")
                    .font(.title2.bold())
                Text((archivePath as NSString).lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var contentSection: some View {
        if viewModel.isVerifying {
            VStack(spacing: 12) {
                ProgressView(value: viewModel.progressFraction)
                    .progressViewStyle(.linear)
                    .tint(TTZipTheme.accentColor)
                HStack {
                    Text(viewModel.currentVerifyingEntry)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(Int(viewModel.progressFraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 24)
        } else if let report = viewModel.report {
            reportScrollSection(report)
        } else if let err = viewModel.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.red)
                Text("Verification Error")
                    .font(.headline)
                Text(err)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 20)
        }
    }

    private func reportScrollSection(_ report: ArchiveIntegrityReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: statusIcon(report.overallStatus))
                        .font(.title)
                        .foregroundColor(statusColor(report.overallStatus))
                    VStack(alignment: .leading) {
                        Text(statusTitle(report.overallStatus))
                            .font(.headline)
                        Text("\(report.verifiedEntriesCount)/\(report.totalEntriesCount) entries verified · \(String(format: "%.1f MB/s", report.averageThroughputMBs)) · \(String(format: "%.2fs", report.verificationDurationSeconds))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)

                if !report.corruptedEntries.isEmpty {
                    Text("Damage Breakdown")
                        .font(.headline)
                    ForEach(report.corruptedEntries) { entry in
                        corruptedEntryRow(entry)
                    }
                }
            }
        }
    }

    private func corruptedEntryRow(_ entry: CorruptedEntryDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.entryPath)
                    .font(.subheadline.monospaced())
                    .foregroundColor(.red)
                Spacer()
                Text(entry.errorType.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(4)
            }
            Text(entry.diagnosticMessage)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var repairSection: some View {
        switch viewModel.repairPhase {
        case .idle:
            if viewModel.canRepairArchive {
                outputDestinationPickerRow
            }
        case .awaitingOverwriteConfirmation(let existingPath):
            overwriteConfirmationCard(existingPath: existingPath)
        case .repairing(let targetPath):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Repairing archive into \((targetPath as NSString).lastPathComponent)...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel Repair") {
                    viewModel.cancelRepair()
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        case .completed(let outcome):
            repairOutcomeCard(outcome)
        case .cancelled:
            HStack {
                Image(systemName: "slash.circle")
                    .foregroundColor(.secondary)
                Text("Archive repair was cancelled. Original and destination files were preserved.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    private var outputDestinationPickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Repaired Output Path (isolated from damaged source)")
                .font(.caption.bold())
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextField(
                    ArchiveIntegrityViewModel.defaultRepairedOutputPath(for: archivePath),
                    text: $viewModel.customOutputPath
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                Button("Choose...") {
                    chooseRepairDestination()
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func overwriteConfirmationCard(existingPath: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Target File Already Exists")
                    .font(.subheadline.bold())
                Spacer()
            }
            Text("A file already exists at \(existingPath). Confirm overwrite to replace it atomically once repair succeeds.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.cancelRepair()
                }
                Button("Overwrite & Repair") {
                    Task {
                        _ = try? await viewModel.confirmOverwriteAndRepair()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(TTZipTheme.accentColor)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func repairOutcomeCard(_ outcome: ArchiveRepairOutcome) -> some View {
        switch outcome {
        case .fullSuccess(let outputPath, let count, let entries, let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("Full Recovery (\(count) entries)")
                        .font(.subheadline.bold())
                    Spacer()
                }
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Output: \(outputPath) · Entries: \(entries.joined(separator: ", "))")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .background(Color.green.opacity(0.12))
            .cornerRadius(8)

        case .partialRecovery(let outputPath, let count, let unrecovered, let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(.orange)
                    Text("Partial Recovery (\(count) recovered, \(unrecovered.count) unrecovered)")
                        .font(.subheadline.bold())
                    Spacer()
                }
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Output: \(outputPath) · Unrecovered: \(unrecovered.joined(separator: ", "))")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(8)

        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundColor(.red)
                    Text("Repair Failed")
                        .font(.subheadline.bold())
                    Spacer()
                }
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(Color.red.opacity(0.12))
            .cornerRadius(8)
        }
    }

    private var actionBarSection: some View {
        HStack {
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(viewModel.isVerifying ? "Verifying..." : "Verify Again") {
                viewModel.startIntegrityCheck(archivePath: archivePath)
            }
            .disabled(viewModel.isVerifying || viewModel.isRepairing)

            if viewModel.canRepairArchive {
                Button("Repair Archive...") {
                    let target = viewModel.customOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.startRepair(
                        damagedPath: archivePath,
                        outputPath: target.isEmpty ? nil : target
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(TTZipTheme.accentColor)
            }
        }
    }

    private func chooseRepairDestination() {
        let panel = NSSavePanel()
        let defaultOut = ArchiveIntegrityViewModel.defaultRepairedOutputPath(for: archivePath)
        panel.directoryURL = URL(fileURLWithPath: (defaultOut as NSString).deletingLastPathComponent)
        panel.nameFieldStringValue = (defaultOut as NSString).lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.customOutputPath = url.path
        }
    }

    private func statusIcon(_ status: IntegrityStatus) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .corrupted: return "xmark.octagon.fill"
        case .unreadable: return "slash.circle.fill"
        case .encryptedMissingKey: return "lock.circle.fill"
        }
    }

    private func statusColor(_ status: IntegrityStatus) -> Color {
        switch status {
        case .passed: return .green
        case .corrupted: return .red
        case .unreadable: return .orange
        case .encryptedMissingKey: return .yellow
        }
    }

    private func statusTitle(_ status: IntegrityStatus) -> String {
        switch status {
        case .passed: return "Archive 100% Intact"
        case .corrupted: return "Archive Contains Corrupted Data"
        case .unreadable: return "Archive Header Damaged or Unreadable"
        case .encryptedMissingKey: return "Encrypted Content Requires Password"
        }
    }
}
