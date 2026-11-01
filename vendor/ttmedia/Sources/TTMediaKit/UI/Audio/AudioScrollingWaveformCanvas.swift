// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Draws resolved samples without owning playback, seeking, or tile requests.
struct AudioScrollingWaveformCanvas: View {
    let ticks: [AudioScrollingWaveformTick]
    let tickWidth: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let midY = canvasSize.height * 0.5
            let centerPlayheadX = canvasSize.width * 0.5

            // Subtle baseline axis
            let axisRect = CGRect(x: 0, y: midY - 0.25, width: canvasSize.width, height: 0.5)
            context.fill(Path(axisRect), with: .color(TTAudioTheme.waveformInactiveBar.opacity(0.28)))

            let radius = tickWidth * 0.5
            for tick in ticks {
                let tickH = TTWaveformView.resolveVoiceMemosTickHeight(
                    amplitude: tick.amplitude,
                    canvasHeight: canvasSize.height
                )
                let rect = CGRect(
                    x: tick.xPosition - radius,
                    y: midY - tickH * 0.5,
                    width: tickWidth,
                    height: tickH
                )
                let isSilenceDot = abs(tick.amplitude) <= TTWaveformView.silenceAmplitudeThreshold
                let baseColor = tick.isPlayed ? TTAudioTheme.bambooGreen : TTAudioTheme.waveformInactiveBar
                let finalColor = isSilenceDot ? baseColor.opacity(0.62) : baseColor
                context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(finalColor))
            }

            // Fixed center playhead needle (Voice Memos style)
            let needleRect = CGRect(x: centerPlayheadX - 0.9, y: 0, width: 1.8, height: canvasSize.height)
            context.fill(Path(roundedRect: needleRect, cornerRadius: 0.9), with: .color(TTAudioTheme.kintsugiGold))
            let topCap = CGRect(x: centerPlayheadX - 2.2, y: 0, width: 4.4, height: 2.2)
            context.fill(Path(roundedRect: topCap, cornerRadius: 1.1), with: .color(TTAudioTheme.kintsugiGold))
        }
    }
}
