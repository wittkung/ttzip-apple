// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit

/// Geometry contract between the code preview's line-number ruler and its text layout.
///
/// The preview scroll view uses overlay scrollers, so the vertical ruler is painted on top of the
/// clip view instead of owning a dedicated column. AppKit compensates by resting the clip view's
/// horizontal origin at `-ruleThickness`, which places the document's left edge exactly at the
/// ruler's right edge.
///
/// Layout has to honour that reservation:
/// - the usable text width is `contentSize.width - ruleThickness`;
/// - the resting horizontal origin is `-ruleThickness`.
///
/// Ignoring the reservation makes the ruler cover the leading characters of every line, because the
/// document's `x = 0` would land inside the ruler's painted band.
enum CodeRulerGeometry {
    /// Width the visible vertical ruler occupies inside the clip view.
    static func reservedWidth(in scrollView: NSScrollView?) -> CGFloat {
        guard let scrollView,
              scrollView.rulersVisible,
              let ruler = scrollView.verticalRulerView else {
            return 0
        }
        return max(0, ruler.ruleThickness)
    }

    /// Horizontal clip origin that keeps the document's left edge flush against the ruler's right edge.
    static func restingOriginX(in scrollView: NSScrollView?) -> CGFloat {
        -reservedWidth(in: scrollView)
    }

    /// Viewport width that remains usable for text once the ruler reservation is removed.
    static func usableWidth(forViewportWidth width: CGFloat, in scrollView: NSScrollView?) -> CGFloat {
        max(1.0, width - reservedWidth(in: scrollView))
    }
}
