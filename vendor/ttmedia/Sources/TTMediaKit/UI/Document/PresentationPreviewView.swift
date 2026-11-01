// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

// MARK: - Presentation Slides Outline Preview

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
    
    private var filteredSlides: [TTMediaOfficeOutlineItem] {
        let all = model.outline.slides
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { slide in
            slide.title.lowercased().contains(query) ||
            slide.bulletPoints.contains { $0.lowercased().contains(query) }
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            ViewThatFits(in: .horizontal) {
                headerBar(compact: false)
                headerBar(compact: true)
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
                                Text(
                                    searchQuery.isEmpty
                                        ? TextAndDocumentPreviewLocalization.text(.slidesEmptyOutline)
                                        : TextAndDocumentPreviewLocalization.format(.slidesNoMatchFormat, searchQuery)
                                )
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            }
                            .padding(40)
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(filteredSlides) { slide in
                                slideCard(slide: slide)
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
                Text(TextAndDocumentPreviewLocalization.format(.slidesCountFormat, model.outline.slides.count))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("•")
                    .foregroundStyle(.secondary)
                Text(TextAndDocumentPreviewLocalization.text(.slidesOutlineFooter))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    @ViewBuilder
    private func headerBar(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.orange)
                Text(TextAndDocumentPreviewLocalization.text(.slidesBadge))
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .fixedSize(horizontal: true, vertical: false)

            if !compact {
                Text(model.fileName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField(TextAndDocumentPreviewLocalization.text(.slidesFilterPlaceholder), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: compact ? 84 : 120)
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
            .fixedSize(horizontal: true, vertical: false)

            Button(action: copyAllOutline) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 10))
                    if !compact {
                        Text(TextAndDocumentPreviewLocalization.text(.slidesCopyOutlineButton))
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, compact ? 7 : 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .ttButtonHelp(TextAndDocumentPreviewLocalization.text(.slidesCopyOutlineButton))
        }
    }
    
    private func slideCard(slide: TTMediaOfficeOutlineItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(TextAndDocumentPreviewLocalization.format(.slideNumberFormat, slide.slideNumber))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
                
                Spacer()
                
                Button(action: {
                    let fullText = slideFullText(slide)
                    copyToClipboard(
                        fullText,
                        message: TextAndDocumentPreviewLocalization.format(.slideCopiedSingleFormat, slide.slideNumber)
                    )
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .ttButtonHelp(TextAndDocumentPreviewLocalization.text(.slideCopySingleHelp))
            }
            
            Text(slide.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .textSelection(.enabled)
            
            if !slide.bulletPoints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(slide.bulletPoints.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(point)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
    
    private func slideFullText(_ slide: TTMediaOfficeOutlineItem) -> String {
        if slide.bulletPoints.isEmpty {
            return slide.title
        }
        return "\(slide.title)\n" + slide.bulletPoints.map { "- \($0)" }.joined(separator: "\n")
    }
    
    private func copyAllOutline() {
        let text = model.outline.slides.map { slide in
            "\(TextAndDocumentPreviewLocalization.format(.slideNumberFormat, slide.slideNumber)):\n\(slideFullText(slide))\n"
        }.joined(separator: "\n")
        copyToClipboard(
            text,
            message: TextAndDocumentPreviewLocalization.format(.slidesCopiedAllFormat, model.outline.slides.count)
        )
    }
    
    private func copyToClipboard(_ string: String, message: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        copyToastMessage = message
        withAnimation(.easeInOut(duration: 0.2)) { isToastVisible = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.0))
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
