// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import QuartzCore

/// Unified hardware viewport presentation contract abstracting underlying rasterization pipelines
/// (legacy CAOpenGLLayer compatibility or modern CAMetalLayer / IOSurface direct presentation).
public protocol MPVVideoLayerProtocol: AnyObject {
    /// Thread-safe active binding status flag.
    var isBound: Bool { get }

    /// Retina display backing scale factor (e.g. 2.0 on standard Retina displays).
    var contentsScale: CGFloat { get set }

    /// Binds this viewport layer to the target player store and registers render triggers.
    func bind(store: MPVMetalPlayerStore)

    /// Unbinds this layer and detaches active render update callbacks.
    func unbind()

    /// Forces an immediate frame rasterization cycle on the viewport.
    func forceRedraw()
}
