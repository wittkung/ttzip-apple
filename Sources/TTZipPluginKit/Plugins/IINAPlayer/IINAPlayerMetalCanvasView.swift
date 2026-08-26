// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import MetalKit
import AppKit

// MARK: - CAMetalLayer 16-bit Float HDR AppKit Viewport

public struct IINAMetalCanvasNSViewRepresentable: NSViewRepresentable {
    public let isHDR: Bool
    
    public init(isHDR: Bool) {
        self.isHDR = isHDR
    }
    
    public func makeNSView(context: Context) -> IINAMetalCanvasNSView {
        IINAMetalCanvasNSView(isHDR: isHDR)
    }
    
    public func updateNSView(_ nsView: IINAMetalCanvasNSView, context: Context) {
        nsView.updateHDRState(isHDR: isHDR)
    }
}

public final class IINAMetalCanvasNSView: NSView {
    private var metalLayer: CAMetalLayer?
    private var isHDR: Bool
    
    public init(isHDR: Bool) {
        self.isHDR = isHDR
        super.init(frame: .zero)
        self.wantsLayer = true
        setupMetalLayer()
    }
    
    required init?(coder: NSCoder) {
        self.isHDR = true
        super.init(coder: coder)
        self.wantsLayer = true
        setupMetalLayer()
    }
    
    private func setupMetalLayer() {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = isHDR
        if isHDR, let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
            layer.colorspace = cs
        }
        self.layer = layer
        self.metalLayer = layer
    }
    
    public func updateHDRState(isHDR: Bool) {
        self.isHDR = isHDR
        metalLayer?.wantsExtendedDynamicRangeContent = isHDR
        if isHDR, let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
            metalLayer?.colorspace = cs
        }
    }
}
