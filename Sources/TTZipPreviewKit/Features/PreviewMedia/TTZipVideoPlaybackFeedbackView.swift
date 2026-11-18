// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit

struct TTZipVideoPlaybackFeedbackView: View {
    let feedback: VideoPlaybackFeedback?

    @State private var visibleChange: VideoPlaybackFeedback.Change?
    @State private var scale: CGFloat = 0.75
    @State private var opacity = 0.0

    var body: some View {
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if let visibleChange {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 68, height: 68)
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.40), radius: 12, y: 4)
                    Image(systemName: symbol(for: visibleChange))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .scaleEffect(scale)
                .opacity(opacity)
            }
        }
        .allowsHitTesting(false)
        .task(id: feedback?.id) {
            guard let feedback, !Task.isCancelled else { return }
            await animate(feedback.change)
        }
        .onDisappear {
            visibleChange = nil
        }
    }

    @MainActor
    private func animate(_ change: VideoPlaybackFeedback.Change) async {
        scale = 0.75
        opacity = 0.0
        visibleChange = change
        withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
            scale = 1.05
            opacity = 1.0
        }

        try? await Task.sleep(for: .milliseconds(420))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.24)) {
            opacity = 0.0
            scale = 1.20
        }
        try? await Task.sleep(for: .milliseconds(240))
        guard !Task.isCancelled else { return }
        visibleChange = nil
    }

    private func symbol(for change: VideoPlaybackFeedback.Change) -> String {
        switch change {
        case .seekForward:
            "goforward.10"
        case .seekBackward:
            "gobackward.10"
        case .volume(let level, let isMuted):
            volumeSymbol(level: level, isMuted: isMuted)
        case .muteChanged(let isMuted):
            isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .rateChanged:
            "gauge.with.needle.fill"
        }
    }

    private func volumeSymbol(level: Float, isMuted: Bool) -> String {
        if isMuted || level == 0.0 { return "speaker.slash.fill" }
        if level < 0.33 { return "speaker.wave.1.fill" }
        if level < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
