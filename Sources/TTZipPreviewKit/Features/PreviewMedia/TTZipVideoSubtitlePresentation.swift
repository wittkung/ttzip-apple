// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit
import UniformTypeIdentifiers

@MainActor
enum TTZipVideoSubtitlePresentation {
    static let presentation = VideoSubtitlePresentation(
        pickFile: pickFile,
        attachFailureAlert: attachFailureAlert,
        renderTextOverlay: { input in AnyView(TTZipVideoTextSubtitleView(input: input)) }
    )

    private static func pickFile(
        directory: URL,
        extensions: [String],
        complete: @escaping VideoSubtitlePresentation.Selection
    ) {
        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            Task { @MainActor in complete(response == .OK ? panel.url : nil) }
        }
    }

    private static func attachFailureAlert(
        viewport: AnyView,
        message: String?,
        dismiss: @escaping VideoSubtitlePresentation.DismissFailure
    ) -> AnyView {
        AnyView(viewport.alert(
            MediaLocalization.text(.subtitleFailed),
            isPresented: Binding(get: { message != nil }, set: { if !$0 { dismiss() } })
        ) {
            Button(MediaLocalization.text(.ok), action: dismiss)
        } message: {
            Text(message ?? "")
        })
    }
}

@MainActor
private struct TTZipVideoTextSubtitleView: View {
    let input: VideoSubtitlePresentation.TextOverlay

    var body: some View {
        if !input.primaryText.isEmpty || !input.secondaryText.isEmpty {
            let metrics = input.style.resolvedMetrics(for: input.geometry)
            VStack(spacing: metrics.interTrackSpacing) {
                Spacer(minLength: 0)
                if !input.secondaryText.isEmpty {
                    styledTextBlock(
                        text: input.secondaryText,
                        size: metrics.secondaryFontSize,
                        metrics: metrics,
                        isSecondary: true
                    )
                }
                if !input.primaryText.isEmpty {
                    styledTextBlock(
                        text: input.primaryText,
                        size: metrics.primaryFontSize,
                        metrics: metrics,
                        isSecondary: false
                    )
                }
            }
            .frame(width: metrics.videoContentRect.width, alignment: .bottom)
            .padding(.bottom, metrics.viewportBottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func styledTextBlock(
        text: String,
        size: CGFloat,
        metrics: SubtitleResolvedLayoutMetrics,
        isSecondary: Bool
    ) -> some View {
        let style = input.style
        let resolvedFont = SubtitleFontResolver.resolve(style: style, size: size)
        let configuredFont = resolvedFont.swiftUIFont
        let stroke = metrics.effectiveBorderWidth

        ZStack {
            if stroke > 0.1 {
                ForEach(Self.strokeOffsets(radius: stroke), id: \.id) { offset in
                    Text(text)
                        .font(configuredFont)
                        .lineSpacing(metrics.intraTrackLineSpacing)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.black.opacity(0.92))
                        .offset(x: offset.dx, y: offset.dy)
                }
            }
            Text(text)
                .font(configuredFont)
                .lineSpacing(metrics.intraTrackLineSpacing)
                .multilineTextAlignment(.center)
                .foregroundStyle(isSecondary ? style.textColor.color.opacity(0.92) : style.textColor.color)
                .shadow(color: .black.opacity(0.85), radius: max(2.0, stroke + 1.0), y: 1.0)
        }
        .frame(maxWidth: metrics.maxTextWidth)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, size * (style.backgroundOpacity > 0.01 ? 0.4 : 0.13))
        .padding(.vertical, size * (style.backgroundOpacity > 0.01 ? 0.17 : 0.03))
        .background(
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(Color.black.opacity(style.backgroundOpacity))
        )
    }

    private struct StrokeOffset: Identifiable {
        let id: Int
        let dx: CGFloat
        let dy: CGFloat
    }

    private static func strokeOffsets(radius: CGFloat) -> [StrokeOffset] {
        let r = min(4.5, max(0.4, radius))
        let d = r * 0.72
        return [
            StrokeOffset(id: 0, dx: -r, dy: 0),
            StrokeOffset(id: 1, dx: r, dy: 0),
            StrokeOffset(id: 2, dx: 0, dy: -r),
            StrokeOffset(id: 3, dx: 0, dy: r),
            StrokeOffset(id: 4, dx: -d, dy: -d),
            StrokeOffset(id: 5, dx: d, dy: -d),
            StrokeOffset(id: 6, dx: -d, dy: d),
            StrokeOffset(id: 7, dx: d, dy: d),
        ]
    }
}
