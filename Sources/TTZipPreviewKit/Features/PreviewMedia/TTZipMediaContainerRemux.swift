// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit

@MainActor
struct TTZipMediaContainerRemuxButton: View {
    let videoURL: URL?
    let isCompact: Bool
    @Binding var isPopoverPresented: Bool
    let onUserInteraction: () -> Void
    @ObservedObject private var remuxManager: MediaContainerRemuxManager = .shared

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
            onUserInteraction()
        } label: {
            HStack(spacing: 3) {
                if remuxManager.isRemuxing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath.video")
                        .font(.system(size: isCompact ? 8 : 9, weight: .semibold))
                }
                Text("Remux")
                    .font(.system(size: isCompact ? 9 : 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .ttzipVideoUtilityCapsule(isCompact: isCompact)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("media_container_remux_button")
        .accessibilityLabel("Container Remux")
        .ttButtonHelp("Container Remux")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            TTZipMediaContainerRemuxPopover(
                videoURL: videoURL,
                onUserInteraction: onUserInteraction
            )
        }
    }
}

@MainActor
private struct TTZipMediaContainerRemuxPopover: View {
    let videoURL: URL?
    let onUserInteraction: () -> Void

    @ObservedObject private var remuxManager: MediaContainerRemuxManager = .shared

    init(
        videoURL: URL?,
        onUserInteraction: @escaping () -> Void
    ) {
        self.videoURL = videoURL
        self.onUserInteraction = onUserInteraction
    }

    var body: some View {
        let compatibilityIssue = remuxManager.compatibilityIssue(for: videoURL)
        let executionPath = remuxManager.executionPath(for: videoURL)
        VStack(alignment: .leading, spacing: 10) {
            headerSection

            Divider()

            if let compatibilityIssue {
                TTZipVideoExportNotice(message: compatibilityIssue, kind: .warning)
            }

            optionsSection(executionPath: executionPath)

            metadataSummarySection(executionPath: executionPath)

            if let errorMessage = remuxManager.lastErrorMessage {
                TTZipVideoExportNotice(message: errorMessage, kind: .error)
            }

            Divider()

            actionFooter(isCompatible: compatibilityIssue == nil)
        }
        .padding(14)
        .frame(width: 316)
        .accessibilityIdentifier("media_container_remux_popover")
    }

    private var headerSection: some View {
        HStack {
            Label("Container Remux (Lossless)", systemImage: "arrow.triangle.2.circlepath.video")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private func optionsSection(executionPath: MediaRemuxExecutionPath?) -> some View {
        let forcesVideoOnly = executionPath == .rustBitstreamRemux
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target Container")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { remuxManager.targetContainer },
                        set: { newValue in
                            remuxManager.targetContainer = newValue
                            onUserInteraction()
                        }
                    )
                ) {
                    ForEach(MediaRemuxTargetContainer.allCases) { container in
                        Text(container.fileExtension.uppercased()).tag(container)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 128)
                .disabled(remuxManager.isRemuxing)
            }

            Toggle(
                isOn: Binding(
                    get: { remuxManager.fastStart },
                    set: { newValue in
                        remuxManager.fastStart = newValue
                        onUserInteraction()
                    }
                )
            ) {
                Text("FastStart (place moov atom before mdat)")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .disabled(remuxManager.isRemuxing)

            Toggle(
                isOn: Binding(
                    get: { forcesVideoOnly ? true : remuxManager.stripAudio },
                    set: { newValue in
                        remuxManager.stripAudio = newValue
                        onUserInteraction()
                    }
                )
            ) {
                Text(forcesVideoOnly ? "Video-only bitstream reparenting" : "Strip audio tracks")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .disabled(remuxManager.isRemuxing || forcesVideoOnly)
        }
    }

    private func metadataSummarySection(executionPath: MediaRemuxExecutionPath?) -> some View {
        let engineLabel: String = {
            switch executionPath {
            case .isoBMFFPassthrough:
                return "ISO-BMFF Passthrough"
            case .rustBitstreamRemux:
                return "Rust Bitstream Remux (<= 256 MiB)"
            case nil:
                return "Unavailable"
            }
        }()
        let defaultName = videoURL.map {
            remuxManager.defaultOutputURL(for: $0, targetContainer: remuxManager.targetContainer).lastPathComponent
        } ?? "remuxed.\(remuxManager.targetContainer.fileExtension)"

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
        if remuxManager.isRemuxing {
            TTZipVideoExportProgress(value: remuxManager.remuxProgress, cancelIdentifier: "media_container_remux_cancel_button") {
                remuxManager.cancelRemux()
                onUserInteraction()
            }
        } else {
            HStack {
                Spacer()
                Button("Remux Container…") {
                    guard let videoURL else { return }
                    remuxManager.remuxCurrentMedia(
                        sourceURL: videoURL,
                        options: remuxManager.selectedOptions
                    )
                    onUserInteraction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isCompatible || videoURL == nil)
                .accessibilityIdentifier("media_container_remux_confirm_button")
            }
        }
    }
}
