// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit

// MARK: - Metal EDR Viewport Container

public struct IINAPlayerContainerView: View {
    let url: URL
    @StateObject private var viewModel: IINAPlayerViewModel
    @State private var isControlsVisible: Bool = true
    
    public init(url: URL, demuxSummary: UniFFIMediaDemuxSummary? = nil) {
        self.url = url
        _viewModel = StateObject(wrappedValue: IINAPlayerViewModel(mediaURL: url, demuxSummary: demuxSummary))
    }
    
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // 1. CAMetalLayer 16-bit Float HDR Viewport
            IINAMetalCanvasNSViewRepresentable(isHDR: viewModel.isHDR)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isControlsVisible.toggle()
                    }
                }
            
            // 2. ASS Rich Subtitle Overlay
            if !viewModel.activeDialogues.isEmpty || viewModel.currentSubtitleText != nil {
                VStack {
                    Spacer()
                    IINARichSubtitleView(
                        dialogues: viewModel.activeDialogues,
                        fallbackText: viewModel.currentSubtitleText
                    )
                    .padding(.bottom, isControlsVisible ? 84 : 32)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: viewModel.activeDialogues)
            }
            
            // 3. Floating Interactive Multi-Track Controller Overlay
            if isControlsVisible {
                IINAPlayerControlsView(viewModel: viewModel, url: url)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: isControlsVisible)
            }
        }
    }
}
