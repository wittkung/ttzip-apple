// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
@preconcurrency import PDFKit
import TTZipCore
import TTZipUI

public enum PDFLayoutMode: String, CaseIterable, Identifiable {
    case singleFullWidth = "Single Page"
    case twoPages = "Two Pages"
    case threePages = "Three Pages"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .singleFullWidth: return "doc.text.fill"
        case .twoPages: return "book.fill"
        case .threePages: return "square.grid.3x1.fill"
        }
    }
}

public struct InteractivePDFPreviewContainerView: View {
    public let url: URL
    @State private var layoutMode: PDFLayoutMode = .singleFullWidth
    
    public init(url: URL) {
        self.url = url
    }
    
    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                switch layoutMode {
                case .singleFullWidth, .twoPages:
                    PDFKitView(url: url, layoutMode: layoutMode)
                case .threePages:
                    PDFThreePageTileGridView(url: url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            HStack(spacing: 6) {
                ForEach(PDFLayoutMode.allCases) { mode in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            layoutMode = mode
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 10))
                            Text(mode.rawValue)
                                .font(.system(size: 10, weight: layoutMode == mode ? .bold : .regular))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(layoutMode == mode ? TTZipTheme.bambooGreen : Color.primary.opacity(0.08))
                        .foregroundStyle(layoutMode == mode ? Color.white : Color.primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
            .padding(12)
        }
    }
}

public struct PDFThreePageTileGridView: View {
    public let url: URL
    @State private var document: PDFDocument?
    @State private var passwordInput: String = ""
    @State private var isUnlocking: Bool = false
    @State private var unlockError: String? = nil
    
    public init(url: URL) {
        self.url = url
    }
    
    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if let doc = document {
                if doc.isLocked {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                        
                        Text("Encrypted PDF Document")
                            .font(.system(size: 14, weight: .bold))
                        
                        Text("This document is password protected. Enter password to view contents.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                        
                        HStack(spacing: 8) {
                            SecureField("Enter Password", text: $passwordInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                                .onSubmit { unlockDocument(doc: doc) }
                            
                            Button(action: { unlockDocument(doc: doc) }) {
                                Text("Unlock")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(TTZipTheme.bambooGreen)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                        
                        if let err = unlockError {
                            Text(err)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(TTZipTheme.cinnabarRed)
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else if doc.pageCount > 0 {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(0..<doc.pageCount, id: \.self) { pageIndex in
                            if let page = doc.page(at: pageIndex) {
                                PDFPageThumbnailCard(page: page, pageIndex: pageIndex + 1)
                            }
                        }
                    }
                    .padding(6)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("PDF Document has no pages or is empty.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            } else {
                VStack {
                    Spacer()
                    ProgressView("Loading PDF...")
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: url) {
            self.document = PDFDocument(url: url)
        }
    }
    
    private func unlockDocument(doc: PDFDocument) {
        guard !passwordInput.isEmpty else { return }
        if doc.unlock(withPassword: passwordInput) {
            self.unlockError = nil
            // Trigger SwiftUI re-render
            self.document = doc
        } else {
            self.unlockError = "Incorrect password. Please try again."
        }
    }
}

public struct PDFPageThumbnailCard: View {
    public let page: PDFPage
    public let pageIndex: Int
    
    @State private var thumbnail: NSImage?
    
    public init(page: PDFPage, pageIndex: Int) {
        self.page = page
        self.pageIndex = pageIndex
    }
    
    public var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color.white
                
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .aspectRatio(0.75, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            
            Text("Page \(pageIndex)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .task(id: pageIndex) {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        let bounds = page.bounds(for: .cropBox)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let targetSize = CGSize(width: max(bounds.width * scale * 1.5, 600), height: max(bounds.height * scale * 1.5, 800))
        self.thumbnail = page.thumbnail(of: targetSize, for: .cropBox)
    }
}

public final class InteractivePDFView: PDFView {
    public override func magnify(with event: NSEvent) {
        if self.autoScales {
            self.autoScales = false
        }
        let currentScale = self.scaleFactor
        let newScale = currentScale * (1.0 + event.magnification)
        self.scaleFactor = min(max(newScale, minScaleFactor), maxScaleFactor)
    }
    
    public override func smartMagnify(with event: NSEvent) {
        if self.autoScales || abs(self.scaleFactor - 1.0) < 0.2 {
            self.autoScales = false
            self.scaleFactor = 2.5
        } else {
            self.autoScales = true
        }
    }
}

public struct PDFKitView: NSViewRepresentable {
    public let url: URL
    public let layoutMode: PDFLayoutMode
    
    public init(url: URL, layoutMode: PDFLayoutMode) {
        self.url = url
        self.layoutMode = layoutMode
    }
    
    public func makeNSView(context: Context) -> PDFView {
        let pdfView = InteractivePDFView()
        pdfView.document = PDFDocument(url: url)
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 10.0
        pdfView.interpolationQuality = .high
        pdfView.displaysPageBreaks = true
        pdfView.displayBox = .cropBox
        pdfView.wantsLayer = true
        pdfView.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        applyLayoutMode(layoutMode, to: pdfView)
        configurePDFScrollView(pdfView)
        return pdfView
    }
    
    public func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
        configurePDFScrollView(nsView)
        nsView.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        applyLayoutMode(layoutMode, to: nsView)
    }
    
    private func configurePDFScrollView(_ pdfView: PDFView) {
        DispatchQueue.main.async {
            if let scrollView = pdfView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView {
                scrollView.allowsMagnification = true
                scrollView.minMagnification = 0.25
                scrollView.maxMagnification = 10.0
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
                scrollView.hasVerticalScroller = true
                scrollView.hasHorizontalScroller = true
                scrollView.verticalScroller?.scrollerStyle = .overlay
                scrollView.horizontalScroller?.scrollerStyle = .overlay
                scrollView.verticalScroller?.alphaValue = 0
                scrollView.horizontalScroller?.alphaValue = 0
            }
        }
    }
    
    private func applyLayoutMode(_ mode: PDFLayoutMode, to pdfView: PDFView) {
        switch mode {
        case .singleFullWidth:
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
            pdfView.autoScales = true
            
        case .twoPages:
            pdfView.displayMode = .twoUpContinuous
            pdfView.displayDirection = .vertical
            pdfView.displaysAsBook = false
            pdfView.autoScales = true
            
        case .threePages:
            pdfView.displayMode = .twoUpContinuous
            pdfView.displayDirection = .vertical
            pdfView.displaysAsBook = true
            pdfView.autoScales = true
        }
        
        pdfView.layoutDocumentView()
        
        DispatchQueue.main.async {
            pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
        }
    }
}

public typealias PDFKitRepresentedView = PDFKitView
