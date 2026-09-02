// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// Structured presentation outline reader view for PPTX and ODP documents.
public struct PresentationPreviewView: View {
    public let model: OfficePresentationModel
    
    @State private var selectedSlideIndex: Int = 0
    @State private var searchQuery: String = ""
    @State private var copyToastMessage: String? = nil
    @State private var isToastVisible: Bool = false
    
    public init(model: OfficePresentationModel) {
        self.model = model
    }
    
    private var filteredSlides: [(index: Int, title: String)] {
        let all: [(index: Int, title: String)] = model.outline.slides.enumerated().map { (index: $0.offset + 1, title: $0.element) }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(query) }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.orange)
                    Text("SLIDES")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                
                Text(model.fileName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
                
                // Search Bar
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField("Filter slides...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 120)
                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                
                Button(action: copyAllOutline) {
                    Label("Copy Outline", systemImage: "doc.on.doc.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(TTZipTheme.bambooGreen.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Slide Cards List
            ZStack {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 12) {
                        if filteredSlides.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "rectangle.slash")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary)
                                Text(searchQuery.isEmpty ? "No slides found in presentation outline." : "No slides match '\(searchQuery)'.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(40)
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(filteredSlides, id: \.index) { slide in
                                slideCard(index: slide.index, content: slide.title)
                            }
                        }
                    }
                    .padding(14)
                }
                
                if isToastVisible, let msg = copyToastMessage {
                    toastOverlay(msg)
                }
            }
            
            Divider()
            
            // Status Bar
            HStack(spacing: 8) {
                Text("\(model.outline.slides.count) slides")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("•")
                    .foregroundStyle(.secondary)
                Text(model.outline.documentType)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
    
    private func slideCard(index: Int, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Slide \(index)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
                
                Spacer()
                
                Button(action: {
                    copyToClipboard(content, message: "Copied Slide \(index) text")
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy slide text")
            }
            
            Text(content)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }
    
    private func copyAllOutline() {
        let text = model.outline.slides.enumerated().map { "Slide \($0.offset + 1):\n\($0.element)\n" }.joined(separator: "\n")
        copyToClipboard(text, message: "Copied all \(model.outline.slides.count) slide outlines")
    }
    
    private func copyToClipboard(_ string: String, message: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        copyToastMessage = message
        withAnimation(.easeInOut(duration: 0.2)) { isToastVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.25)) { isToastVisible = false }
        }
    }
    
    private func toastOverlay(_ msg: String) -> some View {
        VStack {
            Spacer()
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.85)))
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 16)
        }
    }
}
