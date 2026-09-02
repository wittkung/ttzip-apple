// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import CoreFoundation
import OpenGL
import OpenGL.GL3
import CMPVBridge
import os.log
import TTZipUI

/// Dynamic OpenGL function pointer resolver using macOS OpenGL framework bundle symbol lookup.
private let mpvOpenGLGetProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
    guard let name = name else { return nil }
    guard let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII) else { return nil }
    guard let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString) else { return nil }
    return CFBundleGetFunctionPointerForName(bundle, symbol)
}

/// Trampoline C function for libmpv render update callbacks.
private func mpvRenderUpdateCallback(context: UnsafeMutableRawPointer?) {
    guard let context = context else { return }
    let manager = Unmanaged<MPVRenderContextManager>.fromOpaque(context).takeUnretainedValue()
    manager.notifyRenderUpdate()
}

/// Thread-safe manager governing the lifecycle and dispatching of the native `mpv_render_context`.
public final class MPVRenderContextManager: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MPVRenderContextManager")
    private let lock = NSRecursiveLock()
    
    private var renderContext: OpaquePointer?
    private var fallbackContext: CGLContextObj?
    private var activeCGLContext: CGLContextObj?
    private var updateHandler: (@Sendable () -> Void)?
    
    /// Returns the active native `mpv_render_context` handle.
    public var rawContext: OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return renderContext
    }
    
    /// Returns the currently active `CGLContextObj` bound to the render context.
    public var activeContext: CGLContextObj? {
        lock.lock()
        defer { lock.unlock() }
        return activeCGLContext
    }
    
    public init() {}
    
    deinit {
        detachAndFree()
    }
    
    /// Registers a thread-safe callback invoked when libmpv produces a new video frame or requests a redraw.
    public func setUpdateHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        self.updateHandler = handler
    }
    
    /// Initializes and attaches the native `mpv_render_context` to the provided `mpv_handle` and OpenGL context.
    @discardableResult
    public func createRenderContext(mpvHandle: OpaquePointer, cglContext: CGLContextObj? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        if renderContext != nil {
            if let target = cglContext, target != activeCGLContext {
                detachAndFreeInternal()
            } else {
                return true
            }
        }
        
        let previousContext = CGLGetCurrentContext()
        var targetContext = cglContext ?? previousContext
        
        if targetContext == nil {
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
            if let validPix = pix {
                CGLCreateContext(validPix, nil, &self.fallbackContext)
                targetContext = self.fallbackContext
            }
        }
        
        guard let activeContext = targetContext else {
            logger.error("Failed to create mpv_render_context: No valid CGLContext available")
            return false
        }
        
        CGLSetCurrentContext(activeContext)
        defer {
            CGLSetCurrentContext(previousContext)
        }
        
        var initParams = mpv_opengl_init_params(
            get_proc_address: mpvOpenGLGetProcAddress,
            get_proc_address_ctx: nil
        )
        
        let apiType = ("opengl" as NSString).utf8String
        var advancedControl: Int32 = 1
        
        var ctx: OpaquePointer?
        let status = withUnsafeMutablePointer(to: &initParams) { initParamsPtr in
            withUnsafeMutablePointer(to: &advancedControl) { advPtr in
                var params: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initParamsPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: advPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                return mpv_render_context_create(&ctx, mpvHandle, &params)
            }
        }
        guard status >= 0, let validCtx = ctx else {
            let errStr = mpv_error_string(status).map { String(cString: $0) } ?? "Code \(status)"
            logger.error("Failed to create mpv_render_context: \(errStr, privacy: .public)")
            return false
        }
        
        self.renderContext = validCtx
        self.activeCGLContext = activeContext
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        mpv_render_context_set_update_callback(validCtx, mpvRenderUpdateCallback, selfPtr)
        
        logger.info("mpv_render_context initialized successfully with OpenGL 3.2 backend")
        return true
    }
    
    /// Queries the render context for pending flags (e.g. `MPV_RENDER_UPDATE_FRAME`).
    public func update() -> UInt64 {
        lock.lock()
        guard let ctx = renderContext else {
            lock.unlock()
            return 0
        }
        let targetCGL = self.activeCGLContext
        lock.unlock()
        
        let previousContext = CGLGetCurrentContext()
        if previousContext == nil, let target = targetCGL {
            CGLSetCurrentContext(target)
        }
        defer {
            if previousContext == nil && targetCGL != nil {
                CGLSetCurrentContext(nil)
            }
        }
        
        return mpv_render_context_update(ctx)
    }
    
    /// Rasterizes the current decoded video frame into the specified target OpenGL Framebuffer Object (FBO).
    public func render(fbo: GLint, width: Int32, height: Int32) {
        lock.lock()
        guard let ctx = renderContext else {
            lock.unlock()
            return
        }
        let targetCGL = self.activeCGLContext
        lock.unlock()
        
        guard width > 0, height > 0 else { return }
        
        let previousContext = CGLGetCurrentContext()
        if previousContext == nil, let target = targetCGL {
            CGLSetCurrentContext(target)
        }
        defer {
            if previousContext == nil && targetCGL != nil {
                CGLSetCurrentContext(nil)
            }
        }
        
        var glFbo = mpv_opengl_fbo(
            fbo: Int32(fbo),
            w: width,
            h: height,
            internal_format: 0
        )
        var flipY: Int32 = 1
        withUnsafeMutablePointer(to: &glFbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipYPtr in
                var renderParams: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipYPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                _ = mpv_render_context_render(ctx, &renderParams)
            }
        }
    }
    
    /// Informs libmpv that the backbuffer swap occurred to keep audio/video sync locked to display vsync.
    public func reportSwap() {
        lock.lock()
        guard let ctx = renderContext else {
            lock.unlock()
            return
        }
        let targetCGL = self.activeCGLContext
        lock.unlock()
        
        let previousContext = CGLGetCurrentContext()
        if previousContext == nil, let target = targetCGL {
            CGLSetCurrentContext(target)
        }
        defer {
            if previousContext == nil && targetCGL != nil {
                CGLSetCurrentContext(nil)
            }
        }
        
        mpv_render_context_report_swap(ctx)
    }
    
    /// Safely detaches update callbacks and destroys the native `mpv_render_context`.
    public func detachAndFree() {
        lock.lock()
        defer { lock.unlock() }
        detachAndFreeInternal()
    }
    
    private func detachAndFreeInternal() {
        guard let ctx = renderContext else {
            if let fallback = fallbackContext {
                CGLDestroyContext(fallback)
                fallbackContext = nil
            }
            activeCGLContext = nil
            return
        }
        renderContext = nil
        let fallback = fallbackContext
        fallbackContext = nil
        activeCGLContext = nil
        updateHandler = nil
        
        let previousContext = CGLGetCurrentContext()
        if let fallback = fallback {
            CGLSetCurrentContext(fallback)
        }
        
        mpv_render_context_set_update_callback(ctx, nil, nil)
        mpv_render_context_free(ctx)
        
        if let fallback = fallback {
            CGLDestroyContext(fallback)
            CGLSetCurrentContext(previousContext)
        }
        
        logger.info("mpv_render_context detached and released")
    }
    
    /// Internal notification trigger invoked from libmpv C update callback.
    fileprivate func notifyRenderUpdate() {
        lock.lock()
        let handler = self.updateHandler
        lock.unlock()
        handler?()
    }
}
