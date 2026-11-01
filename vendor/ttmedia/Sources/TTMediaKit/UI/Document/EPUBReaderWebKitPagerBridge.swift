// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import WebKit

// MARK: - WebKit Multi-Column Pager & Input/IME Lifecycle Bridge (readerControlWorld)

@MainActor
public final class EPUBReaderInputStateScriptMessageHandler: NSObject, WKScriptMessageHandler {
    public var onInputStateChanged: (@MainActor (EPUBReaderWebKitPagerBridge.InputStateMessage) -> Void)?

    public override init() {
        super.init()
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == EPUBReaderWebKitPagerBridge.inputStateHandlerName,
              let parsed = EPUBReaderWebKitPagerBridge.parseInputStateMessage(from: message.body) else {
            return
        }
        onInputStateChanged?(parsed)
    }
}

@MainActor
public enum EPUBReaderWebKitPagerBridge {
    public static let inputStateHandlerName = "ttReaderInputState"

    public struct PagerSnapshot: Sendable, Equatable {
        public let pageIndex: Int
        public let totalPages: Int
        public let anchorBlockIndex: Int?
        public let anchorCharOffset: Int
        public let readingDirection: String
        public let isInputActive: Bool
        public let isIMEComposing: Bool
        public let layoutMode: String
        public let isLayoutReady: Bool

        public init(
            pageIndex: Int,
            totalPages: Int,
            anchorBlockIndex: Int?,
            anchorCharOffset: Int = 0,
            readingDirection: String,
            isInputActive: Bool,
            isIMEComposing: Bool = false,
            layoutMode: String = "paginated",
            isLayoutReady: Bool = true
        ) {
            self.pageIndex = pageIndex
            self.totalPages = totalPages
            self.anchorBlockIndex = anchorBlockIndex
            self.anchorCharOffset = anchorCharOffset
            self.readingDirection = readingDirection
            self.isInputActive = isInputActive
            self.isIMEComposing = isIMEComposing
            self.layoutMode = layoutMode
            self.isLayoutReady = isLayoutReady
        }
    }

    public struct InputStateMessage: Sendable, Equatable {
        public let isInputActive: Bool
        public let isIMEComposing: Bool
        public let eventType: String

        public init(isInputActive: Bool, isIMEComposing: Bool, eventType: String) {
            self.isInputActive = isInputActive
            self.isIMEComposing = isIMEComposing
            self.eventType = eventType
        }
    }

    public static let bootstrapScript: String = """
    (function() {
        if (!window.__ttPager) {
            window.__ttPager = {
                pageIndex: 0,
                totalPages: 1,
                anchorIdx: 0,
                anchorCharOffset: 0,
                layoutMode: 'paginated',
                isIMEComposing: false,
                _listenersInstalled: false,
                getBlocks: function() {
                    if (!document.body) return [];
                    var all = document.body.querySelectorAll('p, h1, h2, h3, h4, h5, h6, li, blockquote, pre, div, section, article');
                    var leaves = [];
                    for (var i = 0; i < all.length; i++) {
                        var el = all[i];
                        var tag = (el.tagName || '').toUpperCase();
                        if (tag === 'DIV' || tag === 'SECTION' || tag === 'ARTICLE') {
                            if (el.querySelector('p, h1, h2, h3, h4, h5, h6, li, blockquote, pre')) {
                                continue;
                            }
                        }
                        leaves.push(el);
                    }
                    return leaves.length > 0 ? leaves : (all.length > 0 ? all : document.body.children);
                },
                detectDirection: function() {
                    var rootDir = (document.documentElement.getAttribute('dir') || (document.body && document.body.getAttribute('dir')) || '').toLowerCase();
                    var style = document.body ? window.getComputedStyle(document.body) : null;
                    var wm = style ? (style.writingMode || '').toLowerCase() : '';
                    if (wm.indexOf('vertical-rl') === 0) return 'vertical-rl';
                    var dir = rootDir || (style ? (style.direction || 'ltr').toLowerCase() : 'ltr');
                    return dir === 'rtl' ? 'rtl' : 'ltr';
                },
                isEditableElement: function(el) {
                    if (!el) return false;
                    var tag = (el.tagName || '').toUpperCase();
                    if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
                    if (tag === 'INPUT') {
                        var type = (el.getAttribute('type') || 'text').toLowerCase();
                        return type !== 'button' && type !== 'submit' && type !== 'reset' && type !== 'checkbox' && type !== 'radio';
                    }
                    return !!el.isContentEditable || (el.getAttribute && el.getAttribute('contenteditable') === 'true');
                },
                isInputFocused: function() {
                    return this.isEditableElement(document.activeElement);
                },
                parseColorChannels: function(color) {
                    if (!color) return null;
                    var m = color.match(/rgba?\\(([^)]+)\\)/i);
                    if (!m) return null;
                    var parts = m[1].split(',');
                    if (parts.length < 3) return null;
                    var r = parseFloat(parts[0]), g = parseFloat(parts[1]), b = parseFloat(parts[2]);
                    if (isNaN(r) || isNaN(g) || isNaN(b)) return null;
                    return [r, g, b];
                },
                relativeLuminance: function(rgb) {
                    var lin = [0, 0, 0];
                    for (var i = 0; i < 3; i++) {
                        var c = rgb[i] / 255;
                        lin[i] = c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
                    }
                    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
                },
                needsDarkThemeLift: function(rgb) {
                    var maxC = Math.max(rgb[0], rgb[1], rgb[2]);
                    var minC = Math.min(rgb[0], rgb[1], rgb[2]);
                    if ((maxC - minC) > 24) return false;
                    return this.relativeLuminance(rgb) < 0.12;
                },
                applyDarkThemeContrast: function(enabled) {
                    if (!document.body) return 0;
                    if (!enabled) {
                        var liftedNodes = document.querySelectorAll('[data-ttmedia-contrast-lifted="1"]');
                        for (var j = 0; j < liftedNodes.length; j++) {
                            var node = liftedNodes[j];
                            var original = node.getAttribute('data-ttmedia-contrast-original') || '';
                            var priority = node.getAttribute('data-ttmedia-contrast-priority') || '';
                            if (original) { node.style.setProperty('color', original, priority); } else { node.style.removeProperty('color'); }
                            node.removeAttribute('data-ttmedia-contrast-original');
                            node.removeAttribute('data-ttmedia-contrast-priority');
                            node.removeAttribute('data-ttmedia-contrast-lifted');
                        }
                        return 0;
                    }
                    var selector = 'p, li, td, th, dd, dt, h1, h2, h3, h4, h5, h6, blockquote, figcaption, caption, span, div, em, strong, b, i, small, label';
                    var nodes = document.body.querySelectorAll(selector);
                    var lifted = 0;
                    for (var i = 0; i < nodes.length; i++) {
                        var el = nodes[i];
                        if (el.closest && el.closest('svg, img, canvas, video, pre, code, a')) continue;
                        var text = el.textContent || '';
                        if (text.replace(/\\s+/g, '').length === 0) continue;
                        var rgb = this.parseColorChannels(window.getComputedStyle(el).color);
                        if (!rgb || !this.needsDarkThemeLift(rgb)) continue;
                        if (!el.hasAttribute('data-ttmedia-contrast-original')) {
                            el.setAttribute('data-ttmedia-contrast-original', el.style.getPropertyValue('color') || '');
                            el.setAttribute('data-ttmedia-contrast-priority', el.style.getPropertyPriority('color') || '');
                        }
                        el.style.setProperty('color', '#e5e5e7', 'important');
                        el.setAttribute('data-ttmedia-contrast-lifted', '1');
                        lifted++;
                    }
                    return lifted;
                },
                postInputState: function(eventType, explicitInputActive) {
                    var active = (typeof explicitInputActive === 'boolean')
                        ? explicitInputActive
                        : this.isEditableElement(document.activeElement);
                    var composing = !!this.isIMEComposing;
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ttReaderInputState) {
                        window.webkit.messageHandlers.ttReaderInputState.postMessage({
                            isInputActive: active,
                            isIMEComposing: composing,
                            eventType: eventType || 'sync'
                        });
                    }
                },
                installInputLifecycleListeners: function() {
                    if (this._listenersInstalled) return;
                    this._listenersInstalled = true;
                    var self = this;
                    document.addEventListener('focusin', function() { self.postInputState('focusin'); }, true);
                    document.addEventListener('focusout', function(e) {
                        var nextEditable = self.isEditableElement(e.relatedTarget);
                        if (!nextEditable) { self.isIMEComposing = false; }
                        self.postInputState('focusout', nextEditable);
                    }, true);
                    document.addEventListener('compositionstart', function() {
                        self.isIMEComposing = true; self.postInputState('compositionstart');
                    }, true);
                    document.addEventListener('compositionupdate', function() {
                        self.isIMEComposing = true; self.postInputState('compositionupdate');
                    }, true);
                    document.addEventListener('compositionend', function() {
                        self.isIMEComposing = false; self.postInputState('compositionend');
                    }, true);
                    document.addEventListener('input', function(e) {
                        var t = (e && e.inputType) ? e.inputType : '';
                        if (t === 'insertCompositionText') {
                            self.isIMEComposing = !!(e.data && e.data.length > 0);
                            self.postInputState('input-composing');
                        } else if (t === 'deleteCompositionText' || t === 'insertFromComposition') {
                            self.isIMEComposing = false;
                            self.postInputState('input-composition-done');
                        }
                    }, true);
                    document.addEventListener('keydown', function(e) {
                        if (e.isComposing || e.keyCode === 229) {
                            self.isIMEComposing = true; self.postInputState('keydown-composing');
                        } else if (e.key === 'Escape' && self.isIMEComposing) {
                            self.isIMEComposing = false; self.postInputState('compositioncancel');
                        } else if (self.isIMEComposing && !e.isComposing) {
                            self.isIMEComposing = false; self.postInputState('keydown-clear-composing');
                        }
                    }, true);
                },
                blockNativeWheel: function() {
                    if (this._wheelGuardInstalled) return;
                    this._wheelGuardInstalled = true;
                    var self = this;
                    document.addEventListener('wheel', function(event) {
                        if (self.layoutMode !== 'scrolling') event.preventDefault();
                    }, {passive: false, capture: true});
                    window.addEventListener('scroll', function() {
                        if (self.layoutMode === 'scrolling') return;
                        var width = Math.max(window.innerWidth || 600, 120);
                        var expected = self.pageIndex * width;
                        if (Math.abs(window.scrollX - expected) > 1 || window.scrollY !== 0) {
                            window.scrollTo(expected, 0);
                        }
                    }, {passive: true});
                },
                getCharOffsetRect: function(block, charOffset) {
                    if (!block || charOffset <= 0) return block ? block.getBoundingClientRect() : null;
                    var walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT, null, false);
                    var remaining = charOffset, node = walker.nextNode(), lastNode = null;
                    while (node) {
                        var len = (node.nodeValue || '').length;
                        if (len > 0) {
                            lastNode = node;
                            if (remaining < len) {
                                var range = document.createRange();
                                range.setStart(node, remaining);
                                range.setEnd(node, Math.min(len, remaining + 1));
                                var rects = range.getClientRects();
                                return rects.length > 0 ? rects[0] : range.getBoundingClientRect();
                            }
                            remaining -= len;
                        }
                        node = walker.nextNode();
                    }
                    if (lastNode) {
                        var lLen = (lastNode.nodeValue || '').length;
                        var fRange = document.createRange();
                        fRange.setStart(lastNode, Math.max(0, lLen - 1)); fRange.setEnd(lastNode, lLen);
                        var fRects = fRange.getClientRects();
                        return fRects.length > 0 ? fRects[0] : fRange.getBoundingClientRect();
                    }
                    return block.getBoundingClientRect();
                },
                findFirstVisibleCharOffset: function(block) {
                    if (!block) return 0;
                    var text = block.textContent || '';
                    if (text.length <= 1) return 0;
                    var low = 0, high = text.length - 1, best = 0;
                    while (low <= high) {
                        var mid = (low + high) >> 1;
                        var rect = this.getCharOffsetRect(block, mid);
                        if (!rect) break;
                        var leading = this.layoutMode === 'scrolling' ? rect.top : rect.left;
                        if (leading >= -4) { best = mid; high = mid - 1; } else { low = mid + 1; }
                    }
                    return best;
                },
                captureAnchor: function() {
                    var isScroll = (this.layoutMode === 'scrolling');
                    var vw = Math.max(window.innerWidth || 600, 120);
                    var vh = Math.max(window.innerHeight || 400, 120);
                    var blocks = this.getBlocks();
                    for (var i = 0; i < blocks.length; i++) {
                        var r = blocks[i].getBoundingClientRect();
                        if (isScroll) {
                            if (r.width > 0 && r.height > 0 && r.bottom > 4 && r.top < vh - 4) {
                                this.anchorIdx = i;
                                this.anchorCharOffset = r.top < -4 ? this.findFirstVisibleCharOffset(blocks[i]) : 0;
                                return i;
                            }
                        } else {
                            if (r.width > 0 && r.height > 0 && r.right > 4 && r.left < vw - 4) {
                                this.anchorIdx = i;
                                this.anchorCharOffset = r.left < -4 ? this.findFirstVisibleCharOffset(blocks[i]) : 0;
                                return i;
                            }
                        }
                    }
                    return this.anchorIdx || 0;
                },
                applyLayout: function(mode) {
                    if (mode) this.layoutMode = mode;
                    var isScroll = (this.layoutMode === 'scrolling');
                    if (!document.body) return 600;
                    var vw = Math.max(window.innerWidth || 600, 120);
                    var vh = Math.max(window.innerHeight || 400, 120);
                    var padX = vw < 420 ? 18 : 28;
                    var padY = vh < 360 ? 16 : 28;
                    var bs = document.body.style;
                    var hs = document.documentElement ? document.documentElement.style : null;
                    if (isScroll) {
                        bs.removeProperty('column-width');
                        bs.removeProperty('column-count');
                        bs.removeProperty('column-gap');
                        bs.removeProperty('column-fill');
                        bs.removeProperty('height');
                        bs.setProperty('box-sizing', 'border-box', 'important');
                        bs.setProperty('margin', '0 auto', 'important');
                        bs.setProperty('max-width', '720px', 'important');
                        bs.setProperty('width', '100%', 'important');
                        bs.setProperty('padding', padY + 'px ' + padX + 'px', 'important');
                        bs.setProperty('overflow-y', 'auto', 'important');
                        bs.setProperty('overflow-x', 'hidden', 'important');
                        if (hs) {
                            hs.removeProperty('height');
                            hs.removeProperty('box-sizing');
                            hs.removeProperty('margin');
                            hs.removeProperty('padding');
                            hs.setProperty('overflow-y', 'auto', 'important');
                            hs.setProperty('overflow-x', 'hidden', 'important');
                        }
                        return vh;
                    }
                    var columns = vw >= 1000 ? 2 : 1;
                    var colW = Math.max(80, vw / columns - 2 * padX);
                    bs.setProperty('column-count', String(columns), 'important');
                    bs.removeProperty('overflow-y');
                    bs.setProperty('box-sizing', 'border-box', 'important');
                    bs.setProperty('margin', '0', 'important');
                    bs.setProperty('max-width', 'none', 'important');
                    bs.setProperty('width', '100%', 'important');
                    bs.setProperty('height', vh + 'px', 'important');
                    bs.setProperty('padding', padY + 'px ' + padX + 'px', 'important');
                    bs.setProperty('column-width', colW + 'px', 'important');
                    bs.setProperty('column-gap', (2 * padX) + 'px', 'important');
                    bs.setProperty('column-fill', 'auto', 'important');
                    if (hs) {
                        hs.setProperty('box-sizing', 'border-box', 'important');
                        hs.setProperty('margin', '0', 'important');
                        hs.setProperty('padding', '0', 'important');
                        hs.setProperty('height', vh + 'px', 'important');
                        hs.setProperty('overflow-x', 'hidden', 'important');
                        hs.setProperty('scroll-behavior', 'auto', 'important');
                        hs.setProperty('overscroll-behavior', 'none', 'important');
                        hs.setProperty('overflow-y', 'hidden', 'important');
                    }
                    return vw;
                },
                relayout: function(mode, progress, anchorHint, fragmentId, anchorCharOffsetHint, explicitLayoutMode) {
                    this.installInputLifecycleListeners();
                    this.applyLayout(explicitLayoutMode);
                    var isScroll = (this.layoutMode === 'scrolling');
                    var vw = Math.max(window.innerWidth || 600, 120);
                    var vh = Math.max(window.innerHeight || 400, 120);
                    if (isScroll) {
                        var scrollH = Math.max(document.documentElement ? document.documentElement.scrollHeight : vh, document.body ? document.body.scrollHeight : vh, vh);
                        this.totalPages = Math.max(1, Math.ceil((scrollH - 4) / vh));
                    } else {
                        var scrollW = Math.max(document.documentElement ? document.documentElement.scrollWidth : vw, document.body ? document.body.scrollWidth : vw, vw);
                        this.totalPages = Math.max(1, Math.ceil((scrollW - 4) / vw));
                    }
                    var target = 0, preservedAnchor = -1, preservedCharOffset = 0;
                    if (mode === 'last') {
                        target = this.totalPages - 1;
                    } else if (mode === 'fragment' && fragmentId) {
                        var el = document.getElementById(fragmentId) || document.getElementsByName(fragmentId)[0];
                        if (el) {
                            var fr = el.getBoundingClientRect();
                            target = isScroll ? Math.floor((fr.top + window.scrollY) / vh) : Math.floor((fr.left + window.scrollX) / vw);
                            window.location.hash = '#' + fragmentId;
                        }
                    } else if (mode === 'anchor') {
                        var blocks = this.getBlocks();
                        var idx = (typeof anchorHint === 'number' && anchorHint >= 0) ? anchorHint : this.anchorIdx;
                        var charOff = (typeof anchorCharOffsetHint === 'number' && anchorCharOffsetHint >= 0) ? anchorCharOffsetHint : (this.anchorCharOffset || 0);
                        if (idx >= 0 && idx < blocks.length) {
                            var targetRect = charOff > 0 ? this.getCharOffsetRect(blocks[idx], charOff) : blocks[idx].getBoundingClientRect();
                            if (targetRect) {
                                target = isScroll ? Math.floor((targetRect.top + window.scrollY) / vh) : Math.floor((targetRect.left + window.scrollX) / vw);
                            }
                            preservedAnchor = idx; preservedCharOffset = charOff;
                        } else if (typeof progress === 'number') {
                            target = Math.round(progress * Math.max(this.totalPages - 1, 0));
                        }
                    }
                    var res = this.goToPage(target);
                    if (preservedAnchor >= 0) {
                        this.anchorIdx = preservedAnchor; this.anchorCharOffset = preservedCharOffset;
                        res.anchorBlockIndex = preservedAnchor; res.anchorCharOffset = preservedCharOffset;
                    }
                    return res;
                },
                goToPage: function(idx) {
                    this.installInputLifecycleListeners();
                    var isScroll = (this.layoutMode === 'scrolling');
                    var vw = Math.max(window.innerWidth || 600, 120);
                    var vh = Math.max(window.innerHeight || 400, 120);
                    var clamped = Math.max(0, Math.min(idx, this.totalPages - 1));
                    this.pageIndex = clamped;
                    if (isScroll) {
                        window.scrollTo(0, clamped * vh);
                    } else {
                        window.scrollTo(clamped * vw, 0);
                    }
                    var anchor = this.captureAnchor();
                    return {
                        pageIndex: this.pageIndex,
                        totalPages: this.totalPages,
                        anchorBlockIndex: anchor,
                        anchorCharOffset: this.anchorCharOffset || 0,
                        readingDirection: this.detectDirection(),
                        isInputActive: this.isInputFocused(),
                        isIMEComposing: !!this.isIMEComposing,
                        layoutMode: this.layoutMode || 'paginated',
                        layoutReady: !!document.body
                    };
                },
                scrollVertical: function(isDown) {
                    this.installInputLifecycleListeners();
                    var vh = Math.max(window.innerHeight || 400, 120);
                    var delta = Math.round(vh * 0.45) * (isDown ? 1 : -1);
                    var scrollH = Math.max(document.documentElement ? document.documentElement.scrollHeight : vh, document.body ? document.body.scrollHeight : vh, vh);
                    var curY = window.scrollY || window.pageYOffset || 0;
                    var maxY = Math.max(0, scrollH - vh);
                    if (isDown && curY >= maxY - 4) {
                        return { atBoundary: 'bottom', pageIndex: this.totalPages - 1, totalPages: this.totalPages, layoutMode: 'scrolling' };
                    }
                    if (!isDown && curY <= 4) {
                        return { atBoundary: 'top', pageIndex: 0, totalPages: this.totalPages, layoutMode: 'scrolling' };
                    }
                    window.scrollBy(0, delta);
                    var anchor = this.captureAnchor();
                    var newY = window.scrollY || window.pageYOffset || 0;
                    this.pageIndex = Math.min(this.totalPages - 1, Math.max(0, Math.floor((newY + vh / 2) / vh)));
                    return {
                        atBoundary: 'none',
                        pageIndex: this.pageIndex,
                        totalPages: this.totalPages,
                        anchorBlockIndex: anchor,
                        anchorCharOffset: this.anchorCharOffset || 0,
                        readingDirection: this.detectDirection(),
                        isInputActive: this.isInputFocused(),
                        isIMEComposing: !!this.isIMEComposing,
                        layoutMode: 'scrolling'
                    };
                }
            };
        }
        window.__ttPager.installInputLifecycleListeners();
        window.__ttPager.blockNativeWheel();
    })();
    """

    public static func parseSnapshot(from rawResult: Any?) -> PagerSnapshot? {
        guard let dict = rawResult as? [String: Any] else { return nil }
        let pageIndex = (dict["pageIndex"] as? NSNumber)?.intValue ?? 0
        let totalPages = max(1, (dict["totalPages"] as? NSNumber)?.intValue ?? 1)
        let anchor = (dict["anchorBlockIndex"] as? NSNumber)?.intValue
        let charOffset = max(0, (dict["anchorCharOffset"] as? NSNumber)?.intValue ?? 0)
        let direction = (dict["readingDirection"] as? String) ?? "ltr"
        let isInput = (dict["isInputActive"] as? NSNumber)?.boolValue ?? false
        let isComposing = (dict["isIMEComposing"] as? NSNumber)?.boolValue ?? false
        let layoutMode = (dict["layoutMode"] as? String) ?? "paginated"
        let isLayoutReady = (dict["layoutReady"] as? NSNumber)?.boolValue ?? true
        return PagerSnapshot(
            pageIndex: min(max(0, pageIndex), totalPages - 1),
            totalPages: totalPages,
            anchorBlockIndex: anchor,
            anchorCharOffset: charOffset,
            readingDirection: direction,
            isInputActive: isInput,
            isIMEComposing: isComposing,
            layoutMode: layoutMode,
            isLayoutReady: isLayoutReady
        )
    }

    public static func parseInputStateMessage(from rawBody: Any) -> InputStateMessage? {
        guard let dict = rawBody as? [String: Any] else { return nil }
        let isInput = (dict["isInputActive"] as? NSNumber)?.boolValue ?? false
        let isComposing = (dict["isIMEComposing"] as? NSNumber)?.boolValue ?? false
        let eventType = (dict["eventType"] as? String) ?? "sync"
        return InputStateMessage(
            isInputActive: isInput,
            isIMEComposing: isComposing,
            eventType: eventType
        )
    }
}
