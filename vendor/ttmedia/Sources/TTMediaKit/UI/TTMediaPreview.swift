// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation

/// Media category detected from file format or uniform type identifier.
public enum TTMediaKind: Sendable, Equatable {
    case audio
    case video
    case spreadsheet
    case document
    case image
    case unsupported(String)
}

/// Unified, declarative media previewer. Automatically determines media kind
/// and renders the appropriate hardware-accelerated playback or document viewer.
public struct TTMediaPreview: View {
    public let url: URL
    public let customTitle: String?
    public let resourceContext: TTPreviewResourceContext

    @State private var detectedKind: TTMediaKind = .audio
    @State private var avPlayer = TTMediaAVPlayer()
    @State private var textContent: String = ""
    @State private var spreadsheetHeaders: [String] = []
    @State private var spreadsheetRows: [[String]] = []
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    @State private var leaseBox: TTMediaEphemeralLeaseBox

    public init(
        url: URL,
        title: String? = nil,
        resourceContext: TTPreviewResourceContext? = nil
    ) {
        self.url = url
        self.customTitle = title
        self.resourceContext = resourceContext ?? .unknown(
            readableURL: url,
            fileName: title ?? url.lastPathComponent
        )
        _leaseBox = State(initialValue: TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: url))
    }

    private var displayTitle: String {
        customTitle ?? url.lastPathComponent
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            headerView
            Divider()

            // Main Content Area
            Group {
                if isLoading {
                    ProgressView("Loading media...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    ContentUnavailableView {
                        Label("Preview Unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else {
                    switch detectedKind {
                    case .audio:
                        audioPreviewView
                    case .video:
                        videoPreviewView
                    case .spreadsheet:
                        TTSpreadsheetView(headers: spreadsheetHeaders, rows: spreadsheetRows)
                    case .document:
                        TTRichDocumentView(markdown: textContent)
                    case .image:
                        imagePreviewView
                    case .unsupported(let ext):
                        unsupportedView(ext: ext)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.previewResourceContext, resourceContext)
        .onAppear {
            leaseBox.bind(url: url)
        }
        .onChange(of: url) { _, newURL in
            leaseBox.bind(url: newURL)
        }
        .task(id: url) {
            await loadMedia()
        }
        .onDisappear {
            avPlayer.stop()
            leaseBox.release()
        }
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: systemIcon(for: detectedKind))
                .font(.title3)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(url.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            #if os(macOS)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Show in Finder", systemImage: "arrow.up.forward.square")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.06))
    }

    private var audioPreviewView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Big Vinyl / Disc Artwork Placeholder
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 140, height: 140)

                Image(systemName: "music.note")
                    .font(.system(size: 54))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text(displayTitle)
                    .font(.title3.bold())
                Text(formatTimestamp(avPlayer.currentTime) + " / " + formatTimestamp(avPlayer.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Waveform scrubber
            let peaks = avPlayer.waveformPeaks.isEmpty
                ? [0.2, 0.4, 0.7, 0.5, 0.8, 0.3, 0.6, 0.9, 0.4, 0.6, 0.3, 0.7, 0.5, 0.2]
                : avPlayer.waveformPeaks
            let prog = avPlayer.duration > 0 ? (avPlayer.currentTime / avPlayer.duration) : 0.0

            TTWaveformView(
                waveformPeaks: peaks,
                progress: prog,
                onSeek: { seekRatio in
                    let target = seekRatio * avPlayer.duration
                    avPlayer.seek(to: target)
                }
            )
            .frame(height: 52)
            .padding(.horizontal, 32)

            // Playback Transport Controls
            HStack(spacing: 28) {
                Button {
                    avPlayer.seek(to: max(0, avPlayer.currentTime - 10))
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }
                .buttonStyle(.plain)

                Button {
                    avPlayer.togglePlayback()
                } label: {
                    Image(systemName: avPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Button {
                    avPlayer.seek(to: min(avPlayer.duration, avPlayer.currentTime + 10))
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding()
    }

    private var videoPreviewView: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.ignoresSafeArea()
                // Video display placeholder or native player
                Image(systemName: "video.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Transport Control Strip
            HStack(spacing: 16) {
                Button {
                    avPlayer.togglePlayback()
                } label: {
                    Image(systemName: avPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                let prog = avPlayer.duration > 0 ? (avPlayer.currentTime / avPlayer.duration) : 0.0
                TTWaveformView(
                    waveformPeaks: avPlayer.waveformPeaks.isEmpty ? [0.3, 0.6, 0.4, 0.8, 0.5] : avPlayer.waveformPeaks,
                    progress: prog,
                    onSeek: { seekRatio in
                        let target = seekRatio * avPlayer.duration
                        avPlayer.seek(to: target)
                    }
                )
                .frame(height: 28)

                Text(formatTimestamp(avPlayer.currentTime) + (avPlayer.duration > 0 ? " / " + formatTimestamp(avPlayer.duration) : ""))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.08))
        }
    }

    private var imagePreviewView: some View {
        ScrollView([.horizontal, .vertical]) {
            #if os(macOS)
            if let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
            } else {
                Text("Failed to decode image data.")
            }
            #else
            if let uiImage = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
            } else {
                Text("Failed to decode image data.")
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.04))
    }

    private func unsupportedView(ext: String) -> some View {
        ContentUnavailableView {
            Label("Preview Unsupported", systemImage: "doc.questionmark")
        } description: {
            Text("File type '.\(ext)' cannot be previewed natively in TTMediaPreview.")
        }
    }

    // MARK: - Helpers

    private func loadMedia() async {
        isLoading = true
        errorMessage = nil
        let ext = url.pathExtension.lowercased()
        let kind = detectKind(extension: ext)
        self.detectedKind = kind

        switch kind {
        case .audio, .video:
            avPlayer.load(url: url)
            isLoading = false

        case .spreadsheet:
            loadSpreadsheet(ext: ext)

        case .document:
            do {
                let data = try Data(contentsOf: url)
                if let text = String(data: data, encoding: .utf8) {
                    self.textContent = text
                } else if let text = String(data: data, encoding: .ascii) {
                    self.textContent = text
                } else {
                    self.textContent = "Binary document content cannot be rendered as text."
                }
                isLoading = false
            } catch {
                errorMessage = "Failed to read document file: \(error.localizedDescription)"
                isLoading = false
            }

        case .image:
            isLoading = false

        case .unsupported:
            isLoading = false
        }
    }

    private func loadSpreadsheet(ext: String) {
        if ext == "xlsx" || ext == "xlsm" || ext == "ods" {
            if let workbook = TTMediaOfficeSpreadsheetReader.loadWorkbook(from: url, ext: ext),
               let rows = workbook.activeSheet?.rows, !rows.isEmpty {
                self.spreadsheetHeaders = rows.first ?? []
                self.spreadsheetRows = Array(rows.dropFirst())
                isLoading = false
                return
            }
            errorMessage = TTMediaOfficeSpreadsheetReader.unsupportedSpreadsheetMessage(ext: ext)
            isLoading = false
            return
        }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "TTMediaPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Encoding error"])
            }
            parseSpreadsheet(text: text, isTSV: ext == "tsv")
            isLoading = false
        } catch {
            errorMessage = "Failed to read spreadsheet file: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func parseSpreadsheet(text: String, isTSV: Bool) {
        let delimiter: Character = isTSV ? "\t" : ","
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return }

        let parsed = lines.map { line in
            line.split(separator: delimiter, omittingEmptySubsequences: false).map { String($0) }
        }

        self.spreadsheetHeaders = parsed.first ?? []
        self.spreadsheetRows = Array(parsed.dropFirst())
    }

    private func detectKind(extension ext: String) -> TTMediaKind {
        switch ext {
        case "mp3", "wav", "aac", "flac", "m4a", "ogg", "opus", "aiff":
            return .audio
        case "mp4", "mov", "mkv", "webm", "avi", "m4v":
            return .video
        case "csv", "tsv", "xlsx", "xlsm", "ods":
            return .spreadsheet
        case "md", "markdown", "txt", "rtf", "json", "yaml", "yml", "xml", "swift", "rs", "toml", "log", "c", "cpp", "h", "py", "js", "ts":
            return .document
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg":
            return .image
        default:
            return .unsupported(ext)
        }
    }

    private func systemIcon(for kind: TTMediaKind) -> String {
        switch kind {
        case .audio: return "waveform.path"
        case .video: return "film"
        case .spreadsheet: return "tablecells"
        case .document: return "doc.text"
        case .image: return "photo"
        case .unsupported: return "doc"
        }
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
