// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit

@MainActor
struct TTZipMediaAudioExtractButton: View {
    let videoURL: URL?
    let isCompact: Bool
    @Binding var isPopoverPresented: Bool
    let onUserInteraction: () -> Void
    private var extractManager: MediaAudioExtractManager = .shared

    init(
        videoURL: URL?,
        isCompact: Bool,
        isPopoverPresented: Binding<Bool>,
        onUserInteraction: @escaping () -> Void
    ) {
        self.videoURL = videoURL
        self.isCompact = isCompact
        self._isPopoverPresented = isPopoverPresented
        self.onUserInteraction = onUserInteraction
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
            extractManager.isAudioExtractPopoverPresented = isPopoverPresented
            onUserInteraction()
        } label: {
            HStack(spacing: 3) {
                if extractManager.isExtracting {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                } else {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: isCompact ? 8 : 9, weight: .semibold))
                }
                Text("Audio")
                    .font(.system(size: isCompact ? 9 : 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .ttzipVideoUtilityCapsule(isCompact: isCompact)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("media_audio_extract_button")
        .accessibilityLabel("Extract Audio")
        .ttButtonHelp("Extract Audio Track")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            TTZipMediaAudioExtractPopover(
                videoURL: videoURL,
                onUserInteraction: onUserInteraction
            )
        }
    }
}

@MainActor
private struct TTZipMediaAudioExtractPopover: View {
    let videoURL: URL?
    let onUserInteraction: () -> Void

    private var extractManager: MediaAudioExtractManager = .shared

    init(
        videoURL: URL?,
        onUserInteraction: @escaping () -> Void
    ) {
        self.videoURL = videoURL
        self.onUserInteraction = onUserInteraction
    }

    var body: some View {
        let compatibilityIssue = extractManager.compatibilityIssue(for: videoURL)
        let executionPath = extractManager.executionPath(for: videoURL)
        VStack(alignment: .leading, spacing: 10) {
            headerSection

            Divider()

            if let compatibilityIssue {
                TTZipVideoExportNotice(message: compatibilityIssue, kind: .warning)
            }

            optionsSection

            metadataSummarySection(executionPath: executionPath)

            if let errorMessage = extractManager.errorMessage {
                TTZipVideoExportNotice(message: errorMessage, kind: .error)
            }

            Divider()

            actionFooter(isCompatible: compatibilityIssue == nil)
        }
        .padding(14)
        .frame(width: 324)
        .accessibilityIdentifier("media_audio_extract_popover")
        .task(id: videoURL) {
            await extractManager.refreshAvailableTracks(for: videoURL)
        }
    }

    private var headerSection: some View {
        HStack {
            Label("Extract Audio Track (Lossless)", systemImage: "waveform.and.mic")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio Track")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { extractManager.selectedTrackIndex },
                        set: { newValue in
                            extractManager.selectedTrackIndex = newValue
                            onUserInteraction()
                        }
                    )
                ) {
                    if extractManager.availableTracks.isEmpty {
                        Text("Track 1 (Default)").tag(0)
                    } else {
                        ForEach(extractManager.availableTracks) { track in
                            Text(track.displayName).tag(track.index)
                        }
                    }
                }
                .frame(maxWidth: 200)
                .disabled(extractManager.isExtracting)
            }

            HStack {
                Text("Export Mode")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { extractManager.selectedMode },
                        set: { newValue in
                            extractManager.selectedMode = newValue
                            onUserInteraction()
                        }
                    )
                ) {
                    ForEach(MediaAudioExtractionMode.allCases) { mode in
                        Text(mode.shortLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 148)
                .disabled(extractManager.isExtracting)
            }
        }
    }

    private func metadataSummarySection(executionPath: MediaAudioExtractExecutionPath?) -> some View {
        let engineLabel: String = {
            switch executionPath {
            case .avFoundationM4A:
                return "AVFoundation M4A Passthrough"
            case .rustBitstreamExtract:
                return "Rust Bitstream Demux (<= 256 MiB)"
            case nil:
                return "Unavailable"
            }
        }()
        let defaultName = videoURL.map {
            extractManager.defaultOutputURL(for: $0).lastPathComponent
        } ?? "audio.m4a"

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pipeline")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(engineLabel)
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
        if extractManager.isExtracting {
            TTZipVideoExportProgress(value: extractManager.extractProgress, cancelIdentifier: "media_audio_extract_cancel_button") {
                extractManager.cancelExtraction()
                onUserInteraction()
            }
        } else {
            HStack {
                Spacer()
                Button("Extract Audio…") {
                    guard let videoURL else { return }
                    extractManager.extractCurrentAudio(
                        sourceURL: videoURL,
                        options: extractManager.selectedOptions
                    )
                    onUserInteraction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isCompatible || videoURL == nil)
                .accessibilityIdentifier("media_audio_extract_confirm_button")
            }
        }
    }
}
