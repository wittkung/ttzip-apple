// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import WebKit

extension EPUBNativeWKWebView.Coordinator {
    func bindAnnotationCallbacks(to webView: WKWebView) {
        parent?.annotationSession?.onRequestSelection = { [weak self, weak webView] in
            guard let self, let webView else { return }
            self.captureAnnotationSelection(in: webView)
        }
        parent?.annotationSession?.onRequestHighlightRefresh = { [weak self, weak webView] _ in
            guard let self, let webView else { return }
            self.refreshAnnotationHighlights(in: webView)
        }
    }

    private func captureAnnotationSelection(in webView: WKWebView) {
        let generation = parent?.paginationController?.bookGeneration
        let chapter = parent?.chapterIndex ?? 0
        let script = """
        (function() {
            var selection = window.getSelection();
            if (!selection || !selection.rangeCount || selection.isCollapsed) return null;
            var range = selection.getRangeAt(0), quote = range.toString();
            if (!quote.trim() || quote.length > 65536) return null;
            var blocks = window.__ttPager ? window.__ttPager.getBlocks() : [];
            var block = range.startContainer.nodeType === 1 ? range.startContainer : range.startContainer.parentElement;
            while (block && blocks.indexOf(block) < 0) block = block.parentElement;
            if (!block) return null;
            var prefix = document.createRange(); prefix.selectNodeContents(block);
            prefix.setEnd(range.startContainer, range.startOffset);
            return {quote: quote, block: blocks.indexOf(block), offset: prefix.toString().length};
        })();
        """
        webView.evaluateJavaScript(script, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self] result in
            guard let self, let parent = self.parent, parent.chapterIndex == chapter,
                  parent.paginationController?.bookGeneration == generation else { return }
            guard let values = try? result.get() as? [String: Any],
                  let quote = values["quote"] as? String,
                  let block = values["block"] as? NSNumber,
                  let offset = values["offset"] as? NSNumber else {
                parent.annotationSession?.selection = nil
                return
            }
            let anchor = EPUBReaderAnchor(
                chapterIndex: UInt32(clamping: chapter), blockIndex: UInt32(clamping: block.intValue),
                characterOffset: UInt32(clamping: offset.intValue),
                chapterRatio: parent.paginationController?.normalizedProgressInChapter ?? 0
            )
            parent.annotationSession?.selection = EPUBReaderAnnotation(anchor: anchor, quote: quote)
        }
    }

    func restoreAnnotationAnchor(block: Int, character: Int, ratio: Double, in webView: WKWebView) {
        let chapter = parent?.chapterIndex ?? 0
        let generation = parent?.paginationController?.bookGeneration
        let mode = parent?.layoutMode ?? "paginated"
        let script = """
        \(EPUBReaderWebKitPagerBridge.bootstrapScript)
        window.__ttPager.relayout('anchor', \(ratio), \(block), null, \(character), '\(mode)');
        """
        webView.evaluateJavaScript(script, in: nil, in: TTWebPreviewContentPolicy.readerControlWorld) { [weak self] result in
            guard let self, let controller = self.parent?.paginationController,
                  controller.bookGeneration == generation,
                  let snapshot = EPUBReaderWebKitPagerBridge.parseSnapshot(from: try? result.get()) else { return }
            controller.didSynchronizeWebViewPagination(
                chapterIndex: chapter, pageIndex: snapshot.pageIndex, totalPages: snapshot.totalPages,
                anchorBlockIndex: snapshot.anchorBlockIndex, anchorCharOffset: snapshot.anchorCharOffset,
                readingDirectionRaw: snapshot.readingDirection, bookGeneration: generation
            )
        }
    }

    func refreshAnnotationHighlights(in webView: WKWebView) {
        let annotations = parent?.annotationSession?.annotations.filter {
            Int($0.anchor.chapterIndex) == parent?.chapterIndex
        } ?? []
        guard let data = try? JSONEncoder().encode(annotations),
              let json = String(data: data, encoding: .utf8) else { return }
        let chapter = parent?.chapterIndex ?? 0
        let generation = parent?.paginationController?.bookGeneration ?? 0
        let script = """
        if (window.__ttReaderChapterIndex === \(chapter) && window.__ttReaderBookGeneration === \(generation)) {
            \(EPUBReaderAnnotationScripts.highlight(json: json))
        }
        """
        webView.evaluateJavaScript(
            script, in: nil,
            in: TTWebPreviewContentPolicy.readerControlWorld
        ) { _ in }
    }
}

enum EPUBReaderAnnotationScripts {
    static func highlight(json: String) -> String {
        """
        (function() {
            document.querySelectorAll('mark[data-tt-reader-note]').forEach(function(mark) {
                var parent = mark.parentNode; parent.replaceChild(document.createTextNode(mark.textContent), mark); parent.normalize();
            });
            var blocks = window.__ttPager ? window.__ttPager.getBlocks() : [];
            var notes = \(json);
            notes.forEach(function(note) {
                var block = blocks[note.anchor.blockIndex]; if (!block) return;
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                var offset = note.anchor.characterOffset, remaining = note.quote.length, node;
                var pieces = [], reachedBlock = false;
                while ((node = walker.nextNode()) && remaining > 0) {
                    if (!reachedBlock) {
                        if (!block.contains(node)) continue;
                        reachedBlock = true;
                    }
                    if (offset >= node.length) { offset -= node.length; continue; }
                    var length = Math.min(remaining, node.length - offset);
                    pieces.push({node: node, start: offset, end: offset + length});
                    remaining -= length; offset = 0;
                }
                if (remaining !== 0 || pieces.map(function(piece) {
                    return piece.node.data.substring(piece.start, piece.end);
                }).join('') !== note.quote) return;
                pieces.reverse().forEach(function(piece) {
                    var range = document.createRange(); range.setStart(piece.node, piece.start); range.setEnd(piece.node, piece.end);
                    var mark = document.createElement('mark'); mark.setAttribute('data-tt-reader-note', note.id);
                    mark.style.backgroundColor = 'rgba(230,184,50,0.35)'; mark.style.color = 'inherit';
                    range.surroundContents(mark);
                });
            });
        })();
        """
    }
}
