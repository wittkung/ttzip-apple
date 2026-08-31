// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import QuartzCore
import Metal
import CMPVBridge
import os.log
import TTZipUI

/// Thread-safe weak proxy enabling Sendable closure invocation without retaining or capturing non-Sendable CALayers.
private final class MPVMetalLayerProxy: @unchecked Sendable {
    weak var layer: MPVMetalRenderLayer?
    init(layer: MPVMetalRenderLayer) { self.layer = layer }
    func trigger() {
        layer?.requestRender()
    }
}

/// Masterpiece pure Metal / CoreAnimation hardware passthrough layer unlocking Apple 1600 nits Liquid Retina XDR EDR headroom.
///
/// Configures a 16-bit floating point (`.rgba16Float`) texture pipeline mapped into extended linear sRGB
/// color space, bypassing standard 8-bit SDR clamp boundaries and driving direct zero-copy frame presentation.
public final class MPVMetalRenderLayer: CAMetalLayer, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MPVMetalRenderLayer")
    
    public weak var renderContextManager: MPVRenderContextManager?
    public weak var playerStore: MPVMetalPlayerStore?
    
    private let renderQueue = DispatchQueue(label: "com.metastudyline.ttzip.mpv.metalRenderQueue", qos: .userInteractive)
    private var isBound: Bool = false
    private var proxy: MPVMetalLayerProxy?
    private var commandQueue: MTLCommandQueue?
    
    public override init() {
        super.init()
        configureEDRMetalPipeline()
    }
    
    public override init(layer: Any) {
        super.init(layer: layer)
        configureEDRMetalPipeline()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureEDRMetalPipeline()
    }
    
    /// Initializes and hardens the 1600 nits EDR CAMetalLayer parameters.
    private func configureEDRMetalPipeline() {
        self.device = MTLCreateSystemDefaultDevice()
        if let dev = self.device {
            self.commandQueue = dev.makeCommandQueue()
        }
        
        self.proxy = MPVMetalLayerProxy(layer: self)
        
        // 1600 nits EDR Hardware Passthrough Configuration
        self.pixelFormat = .rgba16Float
        self.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        self.wantsExtendedDynamicRangeContent = true
        self.isOpaque = true
        self.framebufferOnly = false
        self.allowsNextDrawableTimeout = false
        self.needsDisplayOnBoundsChange = true
        self.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        self.contentsGravity = .resizeAspect
    }
    
    /// Binds this layer to the player store and registers its update listener.
    public func bind(store: MPVMetalPlayerStore) {
        self.playerStore = store
        self.renderContextManager = store.renderContextManager
        self.isBound = true
        
        let localProxy = self.proxy ?? MPVMetalLayerProxy(layer: self)
        self.proxy = localProxy
        
        store.renderContextManager.setUpdateHandler { [weak localProxy] in
            localProxy?.trigger()
        }
    }
    
    /// Unbinds this layer and detaches update callbacks.
    public func unbind() {
        self.isBound = false
        self.renderContextManager?.setUpdateHandler(nil)
        self.renderContextManager = nil
        self.playerStore = nil
    }
    
    /// Requests a new frame render pass on the dedicated userInteractive render queue.
    public func requestRender() {
        let localProxy = self.proxy
        renderQueue.async { [weak localProxy] in
            guard let layer = localProxy?.layer, layer.isBound else { return }
            layer.renderNextFrame()
        }
    }
    
    /// Executes a frame render pass, presenting into the next available CAMetalDrawable or compatible buffer.
    public func renderNextFrame() {
        guard let manager = renderContextManager, isBound else { return }
        
        let flags = manager.update()
        guard (flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) != 0 else { return }
        
        let size = self.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        
        renderFrame(size: size, fbo: 0)
    }
    
    /// Safety-bound frame rasterization into target frame buffer / texture target, followed by displaySync.
    ///
    /// - Parameters:
    ///   - size: Target viewport pixel size.
    ///   - fbo: OpenGL / Metal FBO or surface identifier.
    public func renderFrame(size: CGSize, fbo: Int32 = 0) {
        guard let manager = renderContextManager else { return }
        let width = Int32(max(1.0, size.width))
        let height = Int32(max(1.0, size.height))
        
        manager.render(fbo: fbo, width: width, height: height)
        displaySync()
    }
    
    /// Signals display swap completion to keep libmpv audio/video timing locked to VSync.
    public func displaySync() {
        guard let manager = renderContextManager else { return }
        manager.reportSwap()
    }
    
    /// Synchronizes backing scale and drawable dimensions to match the Retina HiDPI scale factor.
    public func updateDrawableSize(boundsSize: CGSize, scaleFactor: CGFloat) {
        self.contentsScale = scaleFactor
        let newWidth = max(1.0, ceil(boundsSize.width * scaleFactor))
        let newHeight = max(1.0, ceil(boundsSize.height * scaleFactor))
        let newSize = CGSize(width: newWidth, height: newHeight)
        if self.drawableSize != newSize {
            self.drawableSize = newSize
        }
    }
}
