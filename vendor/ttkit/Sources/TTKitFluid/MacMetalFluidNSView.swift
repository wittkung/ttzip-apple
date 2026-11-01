// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import MetalKit

#if os(macOS)
import QuartzCore
import Combine

public final class MacMetalFluidNSView: NSView {
    private let metalLayer: CAMetalLayer
    private let renderer: MetalFluidRenderer
    private var isRendering = false
    private var caDisplayLink: CADisplayLink?
    private var occlusionCancellables = Set<AnyCancellable>()

    public init?(device: MTLDevice, renderer: MetalFluidRenderer) {
        self.renderer = renderer

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = true
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false
        layer.maximumDrawableCount = 2
        self.metalLayer = layer

        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer = metalLayer
    }

    public required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        stopCADisplayLink()
        occlusionCancellables.removeAll()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            MacWindowOcclusionCoordinator.shared.observeWindow(window)
            setupOcclusionObservation()
            let scale = window.backingScaleFactor
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if size.width > 0 && size.height > 0 {
                metalLayer.drawableSize = size
                renderer.recreateOffscreenTextures(fullSize: size)
            }
            if MacWindowOcclusionCoordinator.shared.isEffectivelyVisible {
                startCADisplayLink()
                isRendering = true
            }
        } else {
            stopCADisplayLink()
            isRendering = false
            occlusionCancellables.removeAll()
        }
    }

    private func setupOcclusionObservation() {
        occlusionCancellables.removeAll()

        MacWindowOcclusionCoordinator.shared.$isOccluded
            .combineLatest(MacWindowOcclusionCoordinator.shared.$isScreenAsleep)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isOccluded, isScreenAsleep in
                guard let self = self else { return }
                let visible = !isOccluded && !isScreenAsleep
                if visible && self.window != nil {
                    if !self.isRendering {
                        self.startCADisplayLink()
                        self.isRendering = true
                    }
                } else {
                    self.stopCADisplayLink()
                    self.isRendering = false
                }
            }
            .store(in: &occlusionCancellables)
    }

    public override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0 && size.height > 0 else { return }

        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            renderer.recreateOffscreenTextures(fullSize: size)

            if let cache = renderer.frameCache, cache.needsPrerender(for: size) {
                cache.prerender(renderer: renderer, screenSize: size, blurSigma: renderer.blurSigma) {}
            }
        }

        setupPipelineIfNeeded(size: size)
    }

    public func setupPipelineIfNeeded(size: CGSize) {
        if renderer.frameCache == nil {
            let cache = FluidFrameCache.shared(device: renderer.device)
            renderer.frameCache = cache
            if cache.needsPrerender(for: size) {
                cache.prerender(
                    renderer: renderer,
                    screenSize: size,
                    blurSigma: renderer.blurSigma
                ) {}
            }
        }
    }

    private func startCADisplayLink() {
        guard caDisplayLink == nil else { return }
        let link = self.displayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        caDisplayLink = link
    }

    private func stopCADisplayLink() {
        caDisplayLink?.invalidate()
        caDisplayLink = nil
    }

    @objc private func displayLinkFired() {
        renderOneFrame()
    }

    private func renderOneFrame() {
        guard let drawable = self.metalLayer.nextDrawable() else { return }

        // Prefer cached playback path (1-pass blit, ~0.05ms) in normal wandering mode
        if self.renderer.focusMode == 0.0, let cache = self.renderer.frameCache, cache.isReady {
            self.renderer.renderCachedFrame(drawable: drawable)
            return
        }

        guard let textures = self.renderer.currentOffscreenTextures else { return }
        self.renderer.renderFrame(
            drawable: drawable,
            offscreen: textures.offscreen,
            blurOutput: textures.blurOutput,
            screenPassDescriptor: nil
        )
    }
}

public struct MetalFluidViewRepresentable: NSViewRepresentable {
    public let config: FluidBackgroundConfig

    public init(config: FluidBackgroundConfig) {
        self.config = config
    }

    public func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MetalFluidRenderer(device: device)
        else { return NSView() }

        let scaleFactor = Float(NSScreen.main?.backingScaleFactor ?? 2.0)
        renderer.blurSigma = 16.5 * scaleFactor
        context.coordinator.renderer = renderer

        guard let metalView = MacMetalFluidNSView(device: device, renderer: renderer) else {
            return NSView()
        }
        context.coordinator.metalView = metalView
        updateRenderer(renderer)
        return metalView
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let _ = context.coordinator.metalView,
              let renderer = context.coordinator.renderer
        else { return }
        updateRenderer(renderer)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }
    public class Coordinator {
        public var renderer: MetalFluidRenderer?
        public var metalView: MacMetalFluidNSView?
        public init() {}
    }

    func updateRenderer(_ renderer: MetalFluidRenderer) {
        renderer.speed = (config.isFocusPaused || config.isSystemPaused) ? 0.0 : (config.isRunning ? 0.8 : 0.2)
        #if os(macOS)
        let appearance = NSAppearance(named: config.isDarkMode ? .darkAqua : .aqua)
        var (r, g, b): (Float, Float, Float) = (Float(0.839), Float(0.365), Float(0.365))
        if let appearance = appearance {
            appearance.performAsCurrentDrawingAppearance {
                let nsColor = NSColor(config.baseColor).usingColorSpace(.sRGB) ?? NSColor(config.baseColor)
                r = Float(nsColor.redComponent)
                g = Float(nsColor.greenComponent)
                b = Float(nsColor.blueComponent)
            }
        } else {
            let nsColor = NSColor(config.baseColor).usingColorSpace(.sRGB) ?? NSColor(config.baseColor)
            r = Float(nsColor.redComponent)
            g = Float(nsColor.greenComponent)
            b = Float(nsColor.blueComponent)
        }
        #else
        let (r, g, b) = (Float(0.839), Float(0.365), Float(0.365))
        #endif
        renderer.targetColor1 = SIMD3(r, g, b)
        renderer.targetColor2 = SIMD3(r, g, b)
        renderer.targetColor3 = SIMD3(r, g, b)

        renderer.backgroundColor = config.isDarkMode ? SIMD3(0, 0, 0) : SIMD3(1, 1, 1)
        renderer.fluidOpacity = config.fluidOpacity
        renderer.focusMode = config.focusMode
        renderer.focusProgress = config.focusProgress
        renderer.breathSeed = config.breathSeed
    }
}
#endif
