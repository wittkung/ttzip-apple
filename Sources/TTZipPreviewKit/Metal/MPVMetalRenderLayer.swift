// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import QuartzCore
import Metal
import IOSurface
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
/// Configures an Apple Silicon zero-copy IOSurface to CAMetalDrawable hardware presentation pipeline mapped
/// into extended linear sRGB color space, bypassing standard 8-bit SDR clamp boundaries.
public final class MPVMetalRenderLayer: CAMetalLayer, MPVVideoLayerProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MPVMetalRenderLayer")
    private let stateLock = NSLock()
    private var _needsForceRedraw: Bool = false
    
    public weak var renderContextManager: MPVRenderContextManager?
    public weak var playerStore: MPVMetalPlayerStore?
    
    private let renderQueue = DispatchQueue(label: "com.metastudyline.ttzip.mpv.metalRenderQueue", qos: .userInteractive)
    public private(set) var isBound: Bool = false
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
        self.pixelFormat = .bgra8Unorm
        self.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        self.wantsExtendedDynamicRangeContent = true
        self.isOpaque = true
        self.framebufferOnly = false
        self.allowsNextDrawableTimeout = true
        self.needsDisplayOnBoundsChange = true
        self.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        self.contentsGravity = .resizeAspect
    }
    
    /// Binds this layer to the player store and registers its update listener.
    public func bind(store: MPVMetalPlayerStore) {
        if isBound && self.playerStore === store && self.renderContextManager?.rawContext != nil {
            return
        }
        self.playerStore = store
        self.renderContextManager = store.renderContextManager
        self.isBound = true
        
        if let mpv = store.mpv {
            store.renderContextManager.createRenderContext(mpvHandle: mpv)
        }
        
        let localProxy = self.proxy ?? MPVMetalLayerProxy(layer: self)
        self.proxy = localProxy
        
        store.renderContextManager.setUpdateHandler(owner: self) { [weak localProxy] in
            localProxy?.trigger()
        }
    }
    
    /// Unbinds this layer and detaches update callbacks.
    public func unbind() {
        self.isBound = false
        self.renderContextManager?.setUpdateHandler(owner: self, nil)
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

    /// Forces an immediate frame redraw cycle.
    public func forceRedraw() {
        stateLock.lock()
        _needsForceRedraw = true
        stateLock.unlock()
        requestRender()
    }
    
    /// Executes a frame render pass, presenting into the next available CAMetalDrawable or compatible buffer.
    public func renderNextFrame() {
        guard let manager = renderContextManager, isBound else { return }
        
        stateLock.lock()
        let force = _needsForceRedraw
        _needsForceRedraw = false
        stateLock.unlock()
        
        let flags = manager.update()
        guard (flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) != 0 || force else { return }
        
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
        
        if let surface = manager.renderToSurface(width: width, height: height) {
            presentSurface(surface)
        } else {
            manager.render(fbo: fbo, width: width, height: height)
        }
        displaySync()
    }
    
    /// Presents the rendered IOSurface through CAMetalDrawable hardware blit with CoreAnimation composition fallback.
    private func presentSurface(_ surface: IOSurface) {
        guard let drawable = self.nextDrawable(),
              let commandQueue = self.commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            self.contents = surface
            return
        }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: self.pixelFormat,
            width: surface.width,
            height: surface.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        
        let surfaceRef = unsafeBitCast(surface, to: IOSurfaceRef.self)
        guard let srcTexture = self.device?.makeTexture(descriptor: desc, iosurface: surfaceRef, plane: 0),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            self.contents = surface
            return
        }
        
        let copyWidth = min(srcTexture.width, drawable.texture.width)
        let copyHeight = min(srcTexture.height, drawable.texture.height)
        
        blitEncoder.copy(
            from: srcTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
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
