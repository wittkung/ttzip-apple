// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import QuartzCore
import OpenGL.GL3
import Metal
import CMPVBridge
import TTZipUI

/// Thread-safe weak proxy enabling Sendable closure invocation without retaining or capturing non-Sendable CALayers.
private final class MPVOpenGLLayerProxy: @unchecked Sendable {
    weak var layer: MPVMetalRenderLayer?
    init(layer: MPVMetalRenderLayer) { self.layer = layer }
    func trigger() {
        layer?.requestRender()
    }
}

/// High-performance native CAOpenGLLayer directly rendering libmpv frames into CoreAnimation FBOs.
///
/// Implements zero-copy hardware presentation via OpenGL 3.2 Core Profile, matching IINA's official architecture.
/// Eliminates intermediate IOSurface allocations, Metal blit command passes, and cross-API sync penalties.
public final class MPVMetalRenderLayer: CAOpenGLLayer, MPVVideoLayerProtocol, @unchecked Sendable {
    private let logger = PreviewKitLogger(category: "MPVMetalRenderLayer")
    private let stateLock = NSLock()
    private var _needsForceRedraw: Bool = false
    
    public weak var renderContextManager: MPVRenderContextManager?
    public weak var playerStore: MPVMetalPlayerStore?
    
    public private(set) var isBound: Bool = false
    private var proxy: MPVOpenGLLayerProxy?
    
    private var cglPixelFormat: CGLPixelFormatObj?
    private var cglContext: CGLContextObj?

    // Metal Layer Compatibility Interface
    public var pixelFormat: MTLPixelFormat = .bgra8Unorm
    public var allowsNextDrawableTimeout: Bool = true
    public var drawableSize: CGSize = .zero

    public override init() {
        super.init()
        setupLayer()
    }
    
    public override init(layer: Any) {
        super.init(layer: layer)
        setupLayer()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    
    private func setupLayer() {
        self.proxy = MPVOpenGLLayerProxy(layer: self)
        self.isAsynchronous = false
        self.needsDisplayOnBoundsChange = true
        self.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        self.contentsGravity = .resizeAspect
        self.backgroundColor = NSColor.black.cgColor
        self.wantsExtendedDynamicRangeContent = true
        self.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        
        createGLContext()
    }
    
    private func createGLContext() {
        let attribs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile,
            CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            kCGLPFAColorSize,
            CGLPixelFormatAttribute(24),
            kCGLPFAAlphaSize,
            CGLPixelFormatAttribute(8),
            CGLPixelFormatAttribute(0)
        ]
        var pix: CGLPixelFormatObj?
        var npix: GLint = 0
        let err = CGLChoosePixelFormat(attribs, &pix, &npix)
        guard err == kCGLNoError, let validPix = pix else {
            logger.error("Failed to create CGLPixelFormat: \(err.rawValue)")
            return
        }
        self.cglPixelFormat = validPix
        
        var ctx: CGLContextObj?
        let ctxErr = CGLCreateContext(validPix, nil, &ctx)
        guard ctxErr == kCGLNoError, let validCtx = ctx else {
            logger.error("Failed to create CGLContext: \(ctxErr.rawValue)")
            return
        }
        
        var swapInterval: GLint = 1
        CGLSetParameter(validCtx, kCGLCPSwapInterval, &swapInterval)
        CGLEnable(validCtx, kCGLCEMPEngine)
        self.cglContext = validCtx
    }
    
    deinit {
        if let ctx = cglContext {
            CGLReleaseContext(ctx)
        }
        if let pix = cglPixelFormat {
            CGLReleasePixelFormat(pix)
        }
    }
    
    public override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        if let pix = cglPixelFormat {
            CGLRetainPixelFormat(pix)
            return pix
        }
        return super.copyCGLPixelFormat(forDisplayMask: mask)
    }
    
    public override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        if let ctx = cglContext {
            CGLRetainContext(ctx)
            return ctx
        }
        return super.copyCGLContext(forPixelFormat: pf)
    }
    
    /// Configures extended dynamic range (EDR) tone curve and color space according to HDR state and screen capabilities.
    @MainActor
    public func configureEDRColorspace(isHDR: Bool, primaries: String) {
        let isEDRSupported = (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0
        if isHDR && isEDRSupported {
            self.wantsExtendedDynamicRangeContent = true
            self.contentsFormat = .RGBA16Float
            if primaries.contains("2020") {
                self.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            } else if primaries.contains("display-p3") || primaries.contains("p3") {
                self.colorspace = CGColorSpace(name: CGColorSpace.displayP3_PQ)
            } else {
                self.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            }
        } else {
            self.wantsExtendedDynamicRangeContent = false
            self.contentsFormat = .RGBA8Uint
            self.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
    }
    
    /// Binds this layer to the player store and registers its update listener.
    public func bind(store: MPVMetalPlayerStore) {
        if isBound && self.playerStore === store && self.renderContextManager?.rawContext != nil {
            return
        }
        self.playerStore = store
        self.renderContextManager = store.renderContextManager
        self.isBound = true
        store.registerRenderLayer(self)
        
        if let mpv = store.mpv {
            store.renderContextManager.createRenderContext(mpvHandle: mpv, cglContext: self.cglContext)
        }
        
        let localProxy = self.proxy ?? MPVOpenGLLayerProxy(layer: self)
        self.proxy = localProxy
        
        store.renderContextManager.setUpdateHandler(owner: self) { [weak localProxy] in
            localProxy?.trigger()
        }
        
        forceRedraw()
    }
    
    /// Unbinds this layer and detaches update callbacks.
    public func unbind() {
        self.isBound = false
        self.renderContextManager?.setUpdateHandler(owner: self, nil)
        self.renderContextManager = nil
        if let store = self.playerStore {
            store.unregisterRenderLayer(self)
        }
        self.playerStore = nil
    }
    
    /// Requests a new frame render pass.
    public func requestRender() {
        let localProxy = self.proxy
        DispatchQueue.main.async { [weak localProxy] in
            guard let layer = localProxy?.layer, layer.isBound else { return }
            layer.setNeedsDisplay()
        }
    }
    
    /// Forces an immediate frame redraw cycle.
    public func forceRedraw() {
        stateLock.lock()
        _needsForceRedraw = true
        stateLock.unlock()
        requestRender()
    }
    
    public override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        guard isBound else { return false }
        
        stateLock.lock()
        let force = _needsForceRedraw
        stateLock.unlock()
        
        if force { return true }
        
        if let manager = renderContextManager {
            let flags = manager.update()
            return (flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) != 0
        }
        return false
    }
    
    public override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        guard let manager = renderContextManager, isBound else { return }
        
        stateLock.lock()
        _needsForceRedraw = false
        stateLock.unlock()
        
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var dims: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)
        
        let width = dims[2] > 0 ? dims[2] : Int32(max(1.0, ceil(bounds.width * contentsScale)))
        let height = dims[3] > 0 ? dims[3] : Int32(max(1.0, ceil(bounds.height * contentsScale)))
        
        manager.render(fbo: fbo, width: width, height: height, internalFormat: 0)
        glFlush()
        manager.reportSwap()
    }
    
    /// Signals display swap completion to keep libmpv audio/video timing locked to VSync.
    public func displaySync() {
        guard let manager = renderContextManager else { return }
        manager.reportSwap()
    }
    
    /// Synchronizes backing scale and drawable dimensions to match the Retina HiDPI scale factor.
    public func updateDrawableSize(boundsSize: CGSize, scaleFactor: CGFloat) {
        self.contentsScale = scaleFactor
        let w = max(1.0, ceil(boundsSize.width * scaleFactor))
        let h = max(1.0, ceil(boundsSize.height * scaleFactor))
        self.drawableSize = CGSize(width: w, height: h)
        self.setNeedsDisplay()
    }
}
