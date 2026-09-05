// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import QuartzCore
import OpenGL
import OpenGL.GL3
import CMPVBridge
import os.log
import TTZipUI

/// Thread-safe weak proxy enabling Sendable closure invocation without retaining or capturing non-Sendable CALayers.
private final class MPVLayerProxy: @unchecked Sendable {
    weak var layer: MPVOpenGLLayer?
    init(layer: MPVOpenGLLayer) { self.layer = layer }
    func trigger() {
        layer?.requestRender()
    }
}

/// High-performance OpenGL 3.2 Core rasterization layer driving libmpv frame rendering directly into CoreAnimation.
public final class MPVOpenGLLayer: CAOpenGLLayer {
    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MPVOpenGLLayer")
    public weak var renderContextManager: MPVRenderContextManager?
    public weak var playerStore: MPVMetalPlayerStore?
    
    private let renderQueue = DispatchQueue(label: "com.metastudyline.ttzip.mpv.renderQueue", qos: .userInteractive)
    private let stateLock = NSRecursiveLock()
    private var _needsForceRedraw: Bool = false
    private var _isBound: Bool = false
    
    
    /// Thread-safe binding flag ensuring render loops do not dispatch against detached layers.
    public var isBound: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isBound
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _isBound = newValue
        }
    }
    private var proxy: MPVLayerProxy?
    
    public override init() {
        super.init()
        configureLayerProperties()
    }
    
    public override init(layer: Any) {
        super.init(layer: layer)
        configureLayerProperties()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayerProperties()
    }
    
    private func configureLayerProperties() {
        self.proxy = MPVLayerProxy(layer: self)
        self.isAsynchronous = true
        self.needsDisplayOnBoundsChange = true
        self.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        self.contentsGravity = .resizeAspect
    }
    
    /// Forces an immediate redraw on the next render cycle, useful for viewport resizing and scrubbing while paused.
    public func forceRedraw() {
        stateLock.lock()
        _needsForceRedraw = true
        stateLock.unlock()
        requestRender()
    }
    
    /// Binds this layer to the player store and registers its update listener.
    public func bind(store: MPVMetalPlayerStore) {
        self.playerStore = store
        self.renderContextManager = store.renderContextManager
        self.isBound = true
        
        let localProxy = self.proxy ?? MPVLayerProxy(layer: self)
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
        self.playerStore = nil
    }
    
    fileprivate func requestRender() {
        let localProxy = self.proxy
        renderQueue.async { [weak localProxy] in
            guard let layer = localProxy?.layer, layer.isBound else { return }
            layer.setNeedsDisplay()
        }
    }
    
    // MARK: - CAOpenGLLayer Virtual Overrides
    
    public override func releaseCGLContext(_ glContext: CGLContextObj) {
        if let manager = renderContextManager, manager.activeContext == glContext {
            manager.detachAndFree()
        }
        super.releaseCGLContext(glContext)
    }
    
    public override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attribs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile,
            CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFADoubleBuffer,
            kCGLPFAAccelerated,
            kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0)
        ]
        var pix: CGLPixelFormatObj?
        var npix: GLint = 0
        CGLChoosePixelFormat(attribs, &pix, &npix)
        guard let validPix = pix else {
            fatalError("Failed to allocate OpenGL 3.2 Core CGLPixelFormat")
        }
        return validPix
    }
    
    public override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        var ctx: CGLContextObj?
        CGLCreateContext(pf, nil, &ctx)
        guard let validCtx = ctx else {
            fatalError("Failed to allocate CGLContextObj")
        }
        
        // Enable Apple Multi-threaded OpenGL Engine for maximum throughput
        CGLEnable(validCtx, kCGLCEMPEngine)
        
        // Synchronize with display VSync (swapInterval = 1)
        var swapInterval: GLint = 1
        CGLSetParameter(validCtx, kCGLCPSwapInterval, &swapInterval)
        
        // If the player handle is ready, pre-initialize
        if let store = playerStore, let mpvHandle = store.mpv, let manager = renderContextManager {
            manager.createRenderContext(mpvHandle: mpvHandle, cglContext: validCtx)
        }
        
        return validCtx
    }
    
    public override func canDraw(
        inCGLContext glContext: CGLContextObj,
        pixelFormat: CGLPixelFormatObj,
        forLayerTime time: CFTimeInterval,
        displayTime: UnsafePointer<CVTimeStamp>?
    ) -> Bool {
        guard isBound else { return false }
        
        guard let manager = renderContextManager else { return false }
        guard let store = playerStore, let mpvHandle = store.mpv else { return false }
        
        if manager.rawContext == nil || manager.activeContext != glContext {
            manager.createRenderContext(mpvHandle: mpvHandle, cglContext: glContext)
        }
        
        // Ensure the active layer has its update handler registered with the manager
        if manager.activeUpdateHandlerOwner != ObjectIdentifier(self) {
            let localProxy = self.proxy ?? MPVLayerProxy(layer: self)
            self.proxy = localProxy
            manager.setUpdateHandler(owner: self) { [weak localProxy] in
                localProxy?.trigger()
            }
        }
        
        let previousContext = CGLGetCurrentContext()
        if previousContext != glContext {
            CGLSetCurrentContext(glContext)
        }
        defer {
            if previousContext != glContext {
                CGLSetCurrentContext(previousContext)
            }
        }
        
        let flags = manager.update()
        stateLock.lock()
        let force = _needsForceRedraw
        stateLock.unlock()
        
        let hasFrame = (flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) != 0
        return hasFrame || force
    }
    
    public override func draw(
        inCGLContext glContext: CGLContextObj,
        pixelFormat: CGLPixelFormatObj,
        forLayerTime time: CFTimeInterval,
        displayTime: UnsafePointer<CVTimeStamp>?
    ) {
        stateLock.lock()
        _needsForceRedraw = false
        stateLock.unlock()
        guard isBound else { return }
        
        guard let manager = renderContextManager else { return }
        
        CGLSetCurrentContext(glContext)
        
        var currentFBO: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &currentFBO)
        
        let scale = self.contentsScale > 0 ? self.contentsScale : (NSScreen.main?.backingScaleFactor ?? 2.0)
        let width = Int32(max(1.0, ceil(bounds.width * scale)))
        let height = Int32(max(1.0, ceil(bounds.height * scale)))
        
        manager.render(fbo: currentFBO, width: width, height: height)
        manager.reportSwap()
        CGLFlushDrawable(glContext)
        glFlush()
    }
}
