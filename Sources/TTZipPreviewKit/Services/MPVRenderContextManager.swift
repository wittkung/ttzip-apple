// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import CoreFoundation
import AppKit
import SwiftUI
import OpenGL
import OpenGL.GL3
import CMPVBridge
import os.log
import TTZipUI

import CoreVideo
import IOSurface

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
    private let contextLock = NSRecursiveLock()
    private let surfaceLock = NSLock()
    private let handlerLock = NSLock()
    
    private var renderContext: OpaquePointer?
    private var activeCGLContext: CGLContextObj?
    private var updateHandlerOwner: ObjectIdentifier?
    private var updateHandler: (@Sendable () -> Void)?
    
    // Dedicated IOSurface and OpenGL FBO backing resources for zero-copy Metal presentation
    private var currentSurface: IOSurface?
    private var currentTexture: GLuint = 0
    private var currentFBO: GLuint = 0
    private var surfaceWidth: Int32 = 0
    private var surfaceHeight: Int32 = 0
    
    /// Returns the active IOSurface backing buffer if available.
    public var activeIOSurface: IOSurface? {
        surfaceLock.lock()
        defer { surfaceLock.unlock() }
        return currentSurface
    }
    
    /// Returns the owner of the currently registered update handler.
    public var activeUpdateHandlerOwner: ObjectIdentifier? {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        return updateHandlerOwner
    }
    
    /// Returns the active native `mpv_render_context` handle.
    public var rawContext: OpaquePointer? {
        contextLock.lock()
        defer { contextLock.unlock() }
        return renderContext
    }
    
    /// Returns the currently active `CGLContextObj` bound to the render context.
    public var activeContext: CGLContextObj? {
        contextLock.lock()
        defer { contextLock.unlock() }
        return activeCGLContext
    }
    
    public init() {}
    
    deinit {
        detachAndFreeInternal()
    }
    
    /// Registers a thread-safe callback invoked when libmpv produces a new video frame or requests a redraw.
    /// When an `owner` is provided, clearing (`handler == nil`) will only succeed if the caller is the current registered owner.
    public func setUpdateHandler(
        owner: AnyObject? = nil,
        isFullScreenOwner: Bool? = nil,
        _ handler: (@Sendable () -> Void)?
    ) {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        if let owner = owner {
            let ownerId = ObjectIdentifier(owner)
            if handler == nil {
                if updateHandlerOwner == ownerId {
                    self.updateHandler = nil
                    self.updateHandlerOwner = nil
                }
            } else {
                self.updateHandlerOwner = ownerId
                self.updateHandler = handler
            }
        } else {
            self.updateHandler = handler
            self.updateHandlerOwner = nil
        }
    }
    
    /// Initializes and attaches the native `mpv_render_context` to the provided `mpv_handle` and OpenGL context.
    /// If no CGLContext is provided, creates a dedicated immortal off-screen CGLContext.
    @discardableResult
    public func createRenderContext(mpvHandle: OpaquePointer, cglContext: CGLContextObj? = nil) -> Bool {
        contextLock.lock()
        defer { contextLock.unlock() }
        
        if renderContext != nil {
            return true
        }
        
        var targetContext = cglContext ?? CGLGetCurrentContext()
        if targetContext == nil {
            let attribs: [CGLPixelFormatAttribute] = [
                kCGLPFAOpenGLProfile,
                CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
                kCGLPFAAccelerated,
                kCGLPFAAllowOfflineRenderers,
                CGLPixelFormatAttribute(0)
            ]
            var pix: CGLPixelFormatObj?
            var npix: GLint = 0
            CGLChoosePixelFormat(attribs, &pix, &npix)
            if let validPix = pix {
                defer { CGLReleasePixelFormat(validPix) }
                var dedicatedContext: CGLContextObj?
                CGLCreateContext(validPix, nil, &dedicatedContext)
                if let ctx = dedicatedContext {
                    targetContext = ctx
                }
            }
        }
        
        guard let activeContext = targetContext else {
            logger.error("Deferred mpv_render_context creation: No active CGLContext available")
            return false
        }
        
        _ = CGLLockContext(activeContext)
        defer { _ = CGLUnlockContext(activeContext) }
        
        let previousContext = CGLGetCurrentContext()
        if previousContext != activeContext {
            CGLSetCurrentContext(activeContext)
        }
        defer {
            if previousContext != activeContext {
                CGLSetCurrentContext(previousContext)
            }
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
        
        logger.info("mpv_render_context initialized successfully with dedicated OpenGL 3.2 backend")
        return true
    }

    /// Queries the render context for pending flags (e.g. `MPV_RENDER_UPDATE_FRAME`).
    public func update() -> UInt64 {
        contextLock.lock()
        guard let ctx = renderContext else {
            contextLock.unlock()
            return 0
        }
        let targetCGL = self.activeCGLContext
        contextLock.unlock()
        
        guard let target = targetCGL else {
            return mpv_render_context_update(ctx)
        }
        
        _ = CGLLockContext(target)
        defer { _ = CGLUnlockContext(target) }
        
        let previousContext = CGLGetCurrentContext()
        if previousContext != target {
            CGLSetCurrentContext(target)
        }
        defer {
            if previousContext != target {
                CGLSetCurrentContext(previousContext)
            }
        }
        
        return mpv_render_context_update(ctx)
    }

    /// Rasterizes the current decoded video frame into the specified target OpenGL Framebuffer Object (FBO).
    @discardableResult
    public func render(fbo: GLint, width: Int32, height: Int32, internalFormat: GLint = GLint(GL_RGBA8)) -> Int32 {
        guard width > 0, height > 0 else { return 0 }
        
        contextLock.lock()
        guard let ctx = renderContext else {
            contextLock.unlock()
            return 0
        }
        let targetCGL = self.activeCGLContext
        contextLock.unlock()
        
        guard let target = targetCGL else { return 0 }
        
        _ = CGLLockContext(target)
        defer { _ = CGLUnlockContext(target) }
        
        let previousContext = CGLGetCurrentContext()
        if previousContext != target {
            CGLSetCurrentContext(target)
        }
        defer {
            if previousContext != target {
                CGLSetCurrentContext(previousContext)
            }
        }
        
        var glFbo = mpv_opengl_fbo(
            fbo: Int32(fbo),
            w: width,
            h: height,
            internal_format: internalFormat
        )
        var flipY: Int32 = 1
        let err: Int32 = withUnsafeMutablePointer(to: &glFbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipYPtr in
                var renderParams: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipYPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                return mpv_render_context_render(ctx, &renderParams)
            }
        }
        if err < 0 {
            logger.warning("mpv_render_context_render returned error: \(err)")
        }
        return err
    }

    /// Informs libmpv that the backbuffer swap occurred to keep audio/video sync locked to display vsync.
    public func reportSwap() {
        contextLock.lock()
        guard let ctx = renderContext else {
            contextLock.unlock()
            return
        }
        let targetCGL = self.activeCGLContext
        contextLock.unlock()
        
        guard let target = targetCGL else {
            mpv_render_context_report_swap(ctx)
            return
        }
        
        _ = CGLLockContext(target)
        defer { _ = CGLUnlockContext(target) }
        
        let previousContext = CGLGetCurrentContext()
        if previousContext != target {
            CGLSetCurrentContext(target)
        }
        defer {
            if previousContext != target {
                CGLSetCurrentContext(previousContext)
            }
        }
        
        mpv_render_context_report_swap(ctx)
    }
        
    /// Renders the decoded video frame directly into an off-screen IOSurface FBO for zero-copy Metal presentation.
    public func renderToSurface(width: Int32, height: Int32) -> IOSurface? {
        guard width > 0, height > 0 else { return nil }
        
        contextLock.lock()
        guard let ctx = renderContext, let cglCtx = self.activeCGLContext else {
            contextLock.unlock()
            return nil
        }
        contextLock.unlock()
        
        _ = CGLLockContext(cglCtx)
        defer { _ = CGLUnlockContext(cglCtx) }
        
        let previousContext = CGLGetCurrentContext()
        if previousContext != cglCtx {
            CGLSetCurrentContext(cglCtx)
        }
        defer {
            if previousContext != cglCtx {
                CGLSetCurrentContext(previousContext)
            }
        }
        
        surfaceLock.lock()
        guard let (surface, fbo) = ensureSurface(width: width, height: height, cglContext: cglCtx) else {
            surfaceLock.unlock()
            return nil
        }
        surfaceLock.unlock()
        
        var glFbo = mpv_opengl_fbo(
            fbo: Int32(fbo),
            w: width,
            h: height,
            internal_format: GLint(GL_RGBA8)
        )
        var flipY: Int32 = 0
        let err: Int32 = withUnsafeMutablePointer(to: &glFbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipYPtr in
                var renderParams: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipYPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                return mpv_render_context_render(ctx, &renderParams)
            }
        }
        if err < 0 {
            logger.warning("mpv_render_context_render to surface returned code: \(err)")
        }
        
        glFlush()
        return surface
    }
    
    /// Allocates or resizes the backing IOSurface and OpenGL FBO matching the target viewport dimensions.
    private func ensureSurface(width: Int32, height: Int32, cglContext: CGLContextObj) -> (IOSurface, GLuint)? {
        if let surface = currentSurface,
           currentFBO != 0,
           surfaceWidth == width,
           surfaceHeight == height {
            return (surface, currentFBO)
        }
        
        cleanupSurface()
        
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: Int(width),
            kIOSurfaceHeight: Int(height),
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: Int(kCVPixelFormatType_32BGRA)
        ]
        
        guard let surfaceRef = IOSurfaceCreate(properties as CFDictionary) else {
            logger.error("Failed to allocate IOSurface of size \(width)x\(height)")
            return nil
        }
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
        
        var tex: GLuint = 0
        glGenTextures(1, &tex)
        glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), tex)
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        
        let err = CGLTexImageIOSurface2D(
            cglContext,
            GLenum(GL_TEXTURE_RECTANGLE),
            GLenum(GL_RGBA),
            GLsizei(width),
            GLsizei(height),
            GLenum(GL_BGRA),
            GLenum(GL_UNSIGNED_INT_8_8_8_8_REV),
            surfaceRef,
            0
        )
        guard err == kCGLNoError else {
            logger.error("CGLTexImageIOSurface2D failed with error: \(err.rawValue)")
            glDeleteTextures(1, &tex)
            return nil
        }
        
        var fbo: GLuint = 0
        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferTexture2D(
            GLenum(GL_FRAMEBUFFER),
            GLenum(GL_COLOR_ATTACHMENT0),
            GLenum(GL_TEXTURE_RECTANGLE),
            tex,
            0
        )
        
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            logger.error("OpenGL Framebuffer is incomplete: \(status)")
            glDeleteFramebuffers(1, &fbo)
            glDeleteTextures(1, &tex)
            return nil
        }
        
        self.currentSurface = surface
        self.currentTexture = tex
        self.currentFBO = fbo
        self.surfaceWidth = width
        self.surfaceHeight = height
        
        return (surface, fbo)
    }
    
    private func cleanupSurface() {
        contextLock.lock()
        let targetCGL = self.activeCGLContext
        contextLock.unlock()
        
        if let targetCGL = targetCGL {
            _ = CGLLockContext(targetCGL)
            defer { _ = CGLUnlockContext(targetCGL) }
            
            let prev = CGLGetCurrentContext()
            if prev != targetCGL {
                CGLSetCurrentContext(targetCGL)
            }
            if currentFBO != 0 {
                var f = currentFBO
                glDeleteFramebuffers(1, &f)
                currentFBO = 0
            }
            if currentTexture != 0 {
                var t = currentTexture
                glDeleteTextures(1, &t)
                currentTexture = 0
            }
            if prev != targetCGL {
                CGLSetCurrentContext(prev)
            }
        }
        currentSurface = nil
        surfaceWidth = 0
        surfaceHeight = 0
    }

    /// Safely detaches update callbacks and destroys the native `mpv_render_context`.
    public func detachAndFree() {
        contextLock.lock()
        defer { contextLock.unlock() }
        detachAndFreeInternal()
    }
    
    private func detachAndFreeInternal() {
        surfaceLock.lock()
        cleanupSurface()
        surfaceLock.unlock()
        
        guard let ctx = renderContext else {
            activeCGLContext = nil
            return
        }
        
        let previousContext = CGLGetCurrentContext()
        let active = self.activeCGLContext
        if let active = active {
            _ = CGLLockContext(active)
            if previousContext != active {
                CGLSetCurrentContext(active)
            }
        }
        
        mpv_render_context_set_update_callback(ctx, nil, nil)
        mpv_render_context_free(ctx)
        self.renderContext = nil
        self.activeCGLContext = nil
        
        handlerLock.lock()
        self.updateHandler = nil
        self.updateHandlerOwner = nil
        handlerLock.unlock()
        
        if let active = active {
            if previousContext != active {
                CGLSetCurrentContext(previousContext)
            }
            _ = CGLUnlockContext(active)
        } else {
            CGLSetCurrentContext(previousContext)
        }
        
        logger.info("mpv_render_context detached and released")
    }
    
    /// Internal notification trigger invoked from libmpv C update callback.
    fileprivate func notifyRenderUpdate() {
        handlerLock.lock()
        let handler = self.updateHandler
        handlerLock.unlock()
        handler?()
    }
}

