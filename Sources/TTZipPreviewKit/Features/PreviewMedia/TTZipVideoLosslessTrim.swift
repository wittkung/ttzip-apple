// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
@preconcurrency import CoreMedia
import TTMediaKit

@MainActor
struct TTZipVideoLosslessTrimButton: View {
    let videoURL: URL?
    let currentTime: CMTime
    let duration: CMTime
    let isCompact: Bool
    @Binding var isPopoverPresented: Bool
    let onUserInteraction: () -> Void
    @ObservedObject private var trimManager: VideoLosslessTrimManager = .shared

    init(
        videoURL: URL?,
        currentTime: CMTime,
        duration: CMTime,
        isCompact: Bool,
        isPopoverPresented: Binding<Bool>,
        onUserInteraction: @escaping () -> Void
    ) {
        self.videoURL = videoURL
        self.currentTime = currentTime
        self.duration = duration
        self.isCompact = isCompact
        self._isPopoverPresented = isPopoverPresented
        self.onUserInteraction = onUserInteraction
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
            onUserInteraction()
        } label: {
            HStack(spacing: 3) {
                if trimManager.isTrimming {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                } else {
                    Image(systemName: "scissors")
                        .font(.system(size: isCompact ? 8 : 9, weight: .semibold))
                }
                Text("Trim")
                    .font(.system(size: isCompact ? 9 : 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .ttzipVideoUtilityCapsule(isCompact: isCompact)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("video_lossless_trim_button")
        .accessibilityLabel("Lossless Trim")
        .ttButtonHelp("Lossless Trim")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            TTZipVideoLosslessTrimPopover(
                videoURL: videoURL,
                currentTime: currentTime,
                duration: duration,
                onUserInteraction: onUserInteraction
            )
        }
    }
}

@MainActor
private struct TTZipVideoLosslessTrimPopover: View {
    let videoURL: URL?
    let currentTime: CMTime
    let duration: CMTime
    let onUserInteraction: () -> Void

    @ObservedObject private var trimManager: VideoLosslessTrimManager = .shared
    @State private var startSeconds: Double = 0.0
    @State private var endSeconds: Double = 3.0
    @State private var didSeedRange: Bool = false

    init(
        videoURL: URL?,
        currentTime: CMTime,
        duration: CMTime,
        onUserInteraction: @escaping () -> Void
    ) {
        self.videoURL = videoURL
        self.currentTime = currentTime
        self.duration = duration
        self.onUserInteraction = onUserInteraction
    }

    private var currentSeconds: Double {
        let raw = CMTimeGetSeconds(currentTime)
        return raw.isFinite ? max(0.0, raw) : 0.0
    }

    private var durationSeconds: Double {
        let raw = CMTimeGetSeconds(duration)
        return raw.isFinite && raw > 0 ? raw : 0.0
    }

    var body: some View {
        let compatibilityIssue = trimManager.compatibilityIssue(for: videoURL)
        VStack(alignment: .leading, spacing: 10) {
            headerSection

            Divider()

            if let compatibilityIssue {
                TTZipVideoExportNotice(message: compatibilityIssue, kind: .warning)
            }

            timeRangeSection

            metadataSummarySection

            if let errorMessage = trimManager.lastErrorMessage {
                TTZipVideoExportNotice(message: errorMessage, kind: .error)
            }

            Divider()

            actionFooter(isCompatible: compatibilityIssue == nil)
        }
        .padding(14)
        .frame(width: 316)
        .accessibilityIdentifier("video_lossless_trim_popover")
        .onAppear {
            seedRangeIfNeeded()
        }
    }

    private var headerSection: some View {
        HStack {
            Label("Lossless Video Trim", systemImage: "scissors")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Button("Use Current ±3s") {
                resetRangeToCurrentWindow()
                onUserInteraction()
            }
            .buttonStyle(.link)
            .font(.system(size: 10, weight: .medium))
            .disabled(trimManager.isTrimming)
        }
    }

    private var timeRangeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trim Window (seconds)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Start")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Set In") {
                            startSeconds = currentSeconds
                            trimManager.customTrimStart = startSeconds
                            onUserInteraction()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 9))
                        .disabled(trimManager.isTrimming)
                    }
                    TextField(
                        "0.0",
                        value: Binding(
                            get: { startSeconds },
                            set: { newValue in
                                startSeconds = max(0.0, newValue)
                                trimManager.customTrimStart = startSeconds
                                onUserInteraction()
                            }
                        ),
                        format: .number.precision(.fractionLength(2))
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(trimManager.isTrimming)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("End")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Set Out") {
                            endSeconds = max(startSeconds + 0.1, currentSeconds)
                            trimManager.customTrimEnd = endSeconds
                            onUserInteraction()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 9))
                        .disabled(trimManager.isTrimming)
                    }
                    TextField(
                        "3.0",
                        value: Binding(
                            get: { endSeconds },
                            set: { newValue in
                                endSeconds = max(0.1, newValue)
                                trimManager.customTrimEnd = endSeconds
                                onUserInteraction()
                            }
                        ),
                        format: .number.precision(.fractionLength(2))
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(trimManager.isTrimming)
                }
            }
        }
    }

    private var metadataSummarySection: some View {
        let branch = trimManager.plannedBranch(startSeconds: startSeconds)
        let modeText = branch == .tailOnlyZeroCopy
            ? "Tail-Only APFS Passthrough"
            : "Edit-List (elst) Keyframe A/V Sync"
        let defaultName = videoURL.map { trimManager.defaultOutputURL(for: $0).lastPathComponent } ?? "trimmed.mp4"

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Mode")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(modeText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            HStack {
                Text("Default Output")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(defaultName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func actionFooter(isCompatible: Bool) -> some View {
        if trimManager.isTrimming {
            TTZipVideoExportProgress(value: trimManager.trimProgress, cancelIdentifier: "video_lossless_trim_cancel_button") {
                trimManager.cancelTrim()
                onUserInteraction()
            }
        } else {
            HStack {
                Spacer()
                Button("Trim Losslessly…") {
                    guard let videoURL else { return }
                    trimManager.customTrimStart = startSeconds
                    trimManager.customTrimEnd = endSeconds
                    trimManager.trimCurrentRange(
                        trimStart: startSeconds,
                        trimEnd: endSeconds,
                        currentTime: currentSeconds,
                        duration: durationSeconds,
                        sourceURL: videoURL
                    )
                    onUserInteraction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isCompatible || videoURL == nil)
                .accessibilityIdentifier("video_lossless_trim_confirm_button")
            }
        }
    }

    private func seedRangeIfNeeded() {
        guard !didSeedRange else { return }
        didSeedRange = true
        let resolved = trimManager.resolvedTimeRange(
            trimStart: trimManager.customTrimStart,
            trimEnd: trimManager.customTrimEnd,
            currentTime: currentSeconds,
            duration: durationSeconds
        )
        startSeconds = resolved.lowerBound
        endSeconds = resolved.upperBound
    }

    private func resetRangeToCurrentWindow() {
        let resolved = trimManager.resolvedTimeRange(
            trimStart: nil,
            trimEnd: nil,
            currentTime: currentSeconds,
            duration: durationSeconds
        )
        startSeconds = resolved.lowerBound
        endSeconds = resolved.upperBound
        trimManager.customTrimStart = startSeconds
        trimManager.customTrimEnd = endSeconds
    }
}
