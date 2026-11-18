// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
@preconcurrency import CoreMedia
import TTMediaKit

@MainActor
struct TTZipVideoGIFExportButton: View {
    let videoURL: URL?
    let currentTime: CMTime
    let duration: CMTime
    let isCompact: Bool
    @Binding var isPopoverPresented: Bool
    let onUserInteraction: () -> Void
    @ObservedObject private var exportManager: GIFExportManager = .shared

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
                if exportManager.isExporting {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                }
                Text("GIF")
                    .font(.system(size: isCompact ? 9 : 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .ttzipVideoUtilityCapsule(isCompact: isCompact)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("video_gif_export_button")
        .accessibilityLabel("Export GIF")
        .ttButtonHelp("Export GIF")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            TTZipVideoGIFExportPopover(
                videoURL: videoURL,
                currentTime: currentTime,
                duration: duration,
                onUserInteraction: onUserInteraction
            )
        }
    }
}

@MainActor
private struct TTZipVideoGIFExportPopover: View {
    let videoURL: URL?
    let currentTime: CMTime
    let duration: CMTime
    let onUserInteraction: () -> Void

    @ObservedObject private var exportManager: GIFExportManager = .shared
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
        let compatibilityIssue = exportManager.compatibilityIssue(for: videoURL)
        VStack(alignment: .leading, spacing: 10) {
            headerSection

            Divider()

            if let compatibilityIssue {
                TTZipVideoExportNotice(message: compatibilityIssue, kind: .warning)
            }

            timeRangeSection

            optionsSection

            if let errorMessage = exportManager.lastErrorMessage {
                TTZipVideoExportNotice(message: errorMessage, kind: .error)
            }

            Divider()

            actionFooter(isCompatible: compatibilityIssue == nil)
        }
        .padding(14)
        .frame(width: 310)
        .accessibilityIdentifier("video_gif_export_popover")
        .onAppear {
            seedRangeIfNeeded()
        }
    }

    private var headerSection: some View {
        HStack {
            Label("Export Animated GIF", systemImage: "photo.stack")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Button("Use Current ±3s") {
                resetRangeToCurrentWindow()
                onUserInteraction()
            }
            .buttonStyle(.link)
            .font(.system(size: 10, weight: .medium))
            .disabled(exportManager.isExporting)
        }
    }

    private var timeRangeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Time Range (seconds)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField(
                        "0.0",
                        value: Binding(
                            get: { startSeconds },
                            set: { newValue in
                                startSeconds = max(0.0, newValue)
                                exportManager.customLoopStart = startSeconds
                                onUserInteraction()
                            }
                        ),
                        format: .number.precision(.fractionLength(1))
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(exportManager.isExporting)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("End")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField(
                        "3.0",
                        value: Binding(
                            get: { endSeconds },
                            set: { newValue in
                                endSeconds = max(0.1, newValue)
                                exportManager.customLoopEnd = endSeconds
                                onUserInteraction()
                            }
                        ),
                        format: .number.precision(.fractionLength(1))
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(exportManager.isExporting)
                }
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Frame Rate")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { exportManager.selectedOptions.fps },
                        set: { newFps in
                            updateOptions(fps: newFps, width: exportManager.selectedOptions.width, dither: exportManager.selectedOptions.dither)
                        }
                    )
                ) {
                    ForEach([10, 15, 24, 30], id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
                .disabled(exportManager.isExporting)
            }

            HStack {
                Text("Width")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { exportManager.selectedOptions.width },
                        set: { newWidth in
                            updateOptions(fps: exportManager.selectedOptions.fps, width: newWidth, dither: exportManager.selectedOptions.dither)
                        }
                    )
                ) {
                    ForEach([320, 480, 640, 720], id: \.self) { width in
                        Text("\(width) px").tag(width)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
                .disabled(exportManager.isExporting)
            }

            Toggle(
                "Ordered Bayer Dithering",
                isOn: Binding(
                    get: { exportManager.selectedOptions.dither },
                    set: { newDither in
                        updateOptions(fps: exportManager.selectedOptions.fps, width: exportManager.selectedOptions.width, dither: newDither)
                    }
                )
            )
            .font(.system(size: 11, weight: .medium))
            .disabled(exportManager.isExporting)
        }
    }

    @ViewBuilder
    private func actionFooter(isCompatible: Bool) -> some View {
        if exportManager.isExporting {
            TTZipVideoExportProgress(value: exportManager.exportProgress, cancelIdentifier: "video_gif_export_cancel_button") {
                exportManager.cancelExport()
                onUserInteraction()
            }
        } else {
            HStack {
                Spacer()
                Button("Export GIF…") {
                    guard let videoURL else { return }
                    exportManager.customLoopStart = startSeconds
                    exportManager.customLoopEnd = endSeconds
                    exportManager.exportCurrentLoopAsGIF(
                        loopA: startSeconds,
                        loopB: endSeconds,
                        currentTime: currentSeconds,
                        duration: durationSeconds,
                        sourceURL: videoURL,
                        options: exportManager.selectedOptions
                    )
                    onUserInteraction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isCompatible || videoURL == nil)
                .accessibilityIdentifier("video_gif_export_confirm_button")
            }
        }
    }

    private func seedRangeIfNeeded() {
        guard !didSeedRange else { return }
        didSeedRange = true
        let resolved = exportManager.resolvedTimeRange(
            loopA: exportManager.customLoopStart,
            loopB: exportManager.customLoopEnd,
            currentTime: currentSeconds,
            duration: durationSeconds
        )
        startSeconds = resolved.lowerBound
        endSeconds = resolved.upperBound
    }

    private func resetRangeToCurrentWindow() {
        let resolved = exportManager.resolvedTimeRange(
            loopA: nil,
            loopB: nil,
            currentTime: currentSeconds,
            duration: durationSeconds
        )
        startSeconds = resolved.lowerBound
        endSeconds = resolved.upperBound
        exportManager.customLoopStart = startSeconds
        exportManager.customLoopEnd = endSeconds
    }

    private func updateOptions(fps: Int, width: Int, dither: Bool) {
        exportManager.selectedOptions = GIFExportOptions(
            fps: fps,
            width: width,
            dither: dither,
            preferNativeImageIO: exportManager.selectedOptions.preferNativeImageIO
        )
        onUserInteraction()
    }
}
