// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit
import TTZipUI

// MARK: - EPUB Reader Floating Chrome Metrics

/// Geometry for the EPUB reader's floating chrome.
enum EPUBReaderFloatingChromeMetrics {
    /// Minimum edge of every clickable reader control. macOS HIG floor.
    static let hitSize: CGFloat = 28
    /// Corner radius of the glass capsules.
    static let capsuleCornerRadius: CGFloat = TTZipTheme.Radius.lg
    /// Corner radius of the controls inside a capsule.
    static let controlCornerRadius: CGFloat = TTZipTheme.Radius.sm
    /// Maximum width the chapter title may claim before it truncates.
    static let chapterTitleMaxWidth: CGFloat = 140
}

// MARK: - Keyboard Focus Targets

/// Keyboard focus targets inside the reading-control capsule.
private enum EPUBReaderFloatingControl: Hashable {
    case chapterMenu
    case layoutPaginated
    case layoutScrolling
    case typography
    case notes
}

// MARK: - EPUB Reader Floating Chrome

/// Floating chrome for the EPUB reader workspace.
///
/// TTMediaKit renders the document surface and owns the reading engine. The chrome belongs to
/// the host product, so it speaks TTZip's design language and drives the reading session
/// through TTMediaKit's public API.
///
struct EPUBReaderFloatingChromeView: View {
    @ObservedObject var session: EPUBReaderSession
    @Binding var isTypographyPresented: Bool
    @Binding var isNotesPresented: Bool

    @ObservedObject private var paginationController: EPUBPaginationController

    @State private var revealCoordinator = PreviewCornerActionRevealCoordinator()
    @State private var isPaginationHovered = false
    @State private var isMenuTracking = false
    @FocusState private var focusedControl: EPUBReaderFloatingControl?

    @Environment(\.accessibilityReduceMotion) private var envReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var envReduceTransparency
    @Environment(\.colorSchemeContrast) private var envColorSchemeContrast

    init(
        session: EPUBReaderSession,
        isTypographyPresented: Binding<Bool>,
        isNotesPresented: Binding<Bool>
    ) {
        self.session = session
        self._isTypographyPresented = isTypographyPresented
        self._isNotesPresented = isNotesPresented
        self._paginationController = ObservedObject(wrappedValue: session.paginationController)
    }

    var body: some View {
        VStack(spacing: 0) {
            EPUBReaderEngineView(session: session, appearance: TTZipEPUBAppearance.reader()) { chapter in
                chapter
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(8)
            } emptyChapter: {
                Spacer()
                Text(EBookPreviewLocalization.text(.noChapterContent))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            paginationCapsule
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, TTZipTheme.Spacing.sm)
        }
        .overlay(alignment: .topTrailing) {
            controlCapsuleZone
        }
        .onChange(of: focusedControl) { _, focus in
            updateCoordinator { $0.setButtonFocused(focus != nil) }
        }
        .onChange(of: isTypographyPresented) { _, _ in applyExternalLock() }
        .onChange(of: isNotesPresented) { _, _ in applyExternalLock() }
        .onChange(of: isMenuTracking) { _, _ in applyExternalLock() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            guard revealCoordinator.isPresented() else { return }
            isMenuTracking = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            isMenuTracking = false
        }
        .onDisappear { revealCoordinator.tearDown() }
    }

    // MARK: Reading Control Capsule

    /// The top-trailing corner zone that hosts the control capsule and its reveal sensor.
    private var controlCapsuleZone: some View {
        ZStack(alignment: .topTrailing) {
            controlCapsule
                .padding(TTZipTheme.Spacing.md)
                .background {
                    EPUBReaderRevealZoneSensor { hovering in
                        updateCoordinator { $0.setZoneHovered(hovering) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var controlCapsule: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(chapterShowsTitle: true)
            controlRow(chapterShowsTitle: false)
        }
        .padding(.horizontal, TTZipTheme.Spacing.sm)
        .padding(.vertical, TTZipTheme.Spacing.xs)
        .background { capsuleSurface }
        .overlay { capsuleStroke }
        .opacity(isControlCapsuleVisible ? 1 : 0)
        .allowsHitTesting(isControlCapsuleVisible)
        .animation(TTZipTheme.Motion.micro, value: isControlCapsuleVisible)
        .onHover { hovering in
            updateCoordinator { $0.setButtonHovered(hovering) }
        }
    }

    private func controlRow(chapterShowsTitle: Bool) -> some View {
        HStack(spacing: TTZipTheme.Spacing.xs) {
            chapterMenu(showsTitle: chapterShowsTitle)
            layoutModeControl
            typographyButton
            notesButton
        }
    }

    // MARK: Chapter Menu

    private var chapterHelpText: String {
        EBookPreviewLocalization.text(.tableOfContentsHelp)
    }

    private var currentChapterTitle: String {
        let chapters = session.chapters
        guard chapters.indices.contains(session.selectedChapterIndex) else {
            return EBookPreviewLocalization.text(.chapterFallback)
        }
        return chapters[session.selectedChapterIndex].title
    }

    private func chapterMenu(showsTitle: Bool) -> some View {
        Menu {
            ForEach(Array(session.chapters.enumerated()), id: \.offset) { index, chapter in
                Button {
                    selectChapter(at: index)
                } label: {
                    HStack {
                        Text(chapter.title)
                            .lineLimit(1)
                        if session.selectedChapterIndex == index {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "book.closed")
                    .font(.caption)
                    .foregroundStyle(TTZipTheme.bambooGreen)
                if showsTitle {
                    Text(currentChapterTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(TTZipTheme.textPhotonicPrimary)
                        .lineLimit(1)
                        .frame(
                            maxWidth: EPUBReaderFloatingChromeMetrics.chapterTitleMaxWidth,
                            alignment: .leading
                        )
                }
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, TTZipTheme.Spacing.xs)
            .frame(
                minWidth: EPUBReaderFloatingChromeMetrics.hitSize,
                minHeight: EPUBReaderFloatingChromeMetrics.hitSize
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .buttonStyle(.plain)
        .focused($focusedControl, equals: .chapterMenu)
        .ttButtonHelp(chapterHelpText)
        .accessibilityLabel(chapterHelpText)
        .accessibilityIdentifier("EPUBReaderChapterMenu")
    }

    private func selectChapter(at index: Int) {
        session.selectedChapterIndex = index
        session.paginationController.selectChapterExplicitly(index, landing: .firstPage)
        session.persistReadingProgress()
        session.requestReaderFocusRestore()
    }

    // MARK: Layout Mode

    private var layoutModeControl: some View {
        HStack(spacing: 2) {
            layoutModeSegment(systemImage: "book.pages", mode: "paginated")
            layoutModeSegment(systemImage: "scroll", mode: "scrolling")
        }
        .padding(2)
        .background {
            RoundedRectangle(
                cornerRadius: EPUBReaderFloatingChromeMetrics.controlCornerRadius,
                style: .continuous
            )
            .fill(TTZipTheme.subtleFill)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: EPUBReaderFloatingChromeMetrics.controlCornerRadius,
                style: .continuous
            )
            .strokeBorder(TTZipTheme.hairlineBorder, lineWidth: 0.5)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func layoutModeSegment(systemImage: String, mode: String) -> some View {
        let isSelected = (session.layoutMode == mode)
        let helpText = mode == "paginated"
            ? EPUBPaginationLocalization.text(.layoutModePaginated)
            : EPUBPaginationLocalization.text(.layoutModeScrolling)
        return Button {
            session.setLayoutMode(mode)
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : TTZipTheme.textPhotonicPrimary)
                .frame(
                    width: EPUBReaderFloatingChromeMetrics.hitSize,
                    height: EPUBReaderFloatingChromeMetrics.hitSize
                )
                .background {
                    RoundedRectangle(cornerRadius: TTZipTheme.Radius.xs, style: .continuous)
                        .fill(isSelected ? TTZipTheme.bambooGreen : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.xs, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: mode == "paginated" ? .layoutPaginated : .layoutScrolling)
        .ttButtonHelp(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier(
            mode == "paginated" ? "EPUBReaderLayoutModePaginatedButton" : "EPUBReaderLayoutModeScrollingButton"
        )
    }

    // MARK: Typography & Notes

    private var typographyHelpText: String {
        EBookPreviewLocalization.text(.typographyHelp)
    }

    private var typographyButton: some View {
        chromeIconButton(
            systemImage: "textformat",
            helpText: typographyHelpText,
            isActive: isTypographyPresented,
            focusTarget: .typography,
            identifier: "EPUBReaderTypographyButton"
        ) {
            session.notifyToolbarInteraction()
            isTypographyPresented.toggle()
        }
        .popover(isPresented: $isTypographyPresented, arrowEdge: .bottom) {
            EPUBReaderTypographyPanel(session: session)
        }
    }

    private var notesHelpText: String {
        EPUBReaderWorkspaceLocalization.text(.notes)
    }

    private var notesButton: some View {
        chromeIconButton(
            systemImage: "highlighter",
            helpText: notesHelpText,
            isActive: isNotesPresented,
            focusTarget: .notes,
            identifier: "EPUBReaderNotesButton"
        ) {
            session.annotationSession.errorMessage = nil
            session.annotationSession.onRequestSelection?()
            isNotesPresented = true
        }
        .popover(isPresented: $isNotesPresented, arrowEdge: .bottom) {
            EPUBReaderNotesPanel(
                session: session.annotationSession,
                save: session.saveReaderAnnotation,
                delete: session.deleteReaderAnnotation,
                locate: { annotation in
                    isNotesPresented = false
                    session.locateReaderAnnotation(annotation)
                },
                export: { format in exportAnnotations(format: format) }
            )
        }
    }

    private func chromeIconButton(
        systemImage: String,
        helpText: String,
        isActive: Bool,
        focusTarget: EPUBReaderFloatingControl,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? TTZipTheme.bambooGreen : TTZipTheme.textPhotonicPrimary)
                .frame(
                    width: EPUBReaderFloatingChromeMetrics.hitSize,
                    height: EPUBReaderFloatingChromeMetrics.hitSize
                )
                .background {
                    RoundedRectangle(
                        cornerRadius: EPUBReaderFloatingChromeMetrics.controlCornerRadius,
                        style: .continuous
                    )
                    .fill(isActive ? TTZipTheme.bambooGreen.opacity(0.14) : Color.clear)
                }
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: EPUBReaderFloatingChromeMetrics.controlCornerRadius,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: focusTarget)
        .ttButtonHelp(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Pagination Capsule

    private var paginationCapsule: some View {
        HStack(spacing: TTZipTheme.Spacing.xs) {
            paginationChevron(
                systemImage: "chevron.left",
                helpText: previousPageHelpText,
                isEnabled: canGoPrevious
            ) {
                _ = paginationController.handleHorizontalArrow(isRightArrow: false)
                session.requestReaderFocusRestore()
            }
            pageIndicator
            paginationChevron(
                systemImage: "chevron.right",
                helpText: nextPageHelpText,
                isEnabled: canGoNext
            ) {
                _ = paginationController.handleHorizontalArrow(isRightArrow: true)
                session.requestReaderFocusRestore()
            }
        }
        .padding(.horizontal, TTZipTheme.Spacing.sm)
        .padding(.vertical, TTZipTheme.Spacing.xs)
        .background { capsuleSurface }
        .overlay { capsuleStroke }
        .opacity(isPaginationHovered ? 1 : 0.75)
        .animation(TTZipTheme.Motion.micro, value: isPaginationHovered)
        .onHover { hovering in isPaginationHovered = hovering }
    }

    private var previousPageHelpText: String {
        EPUBPaginationLocalization.text(.previousPageHelp)
    }

    private var nextPageHelpText: String {
        EPUBPaginationLocalization.text(.nextPageHelp)
    }

    private var currentPageIndex: Int {
        paginationController.currentPageIndex
    }

    private var totalPages: Int {
        max(paginationController.totalPagesInChapter, 1)
    }

    private var canGoPrevious: Bool {
        session.selectedChapterIndex > 0 || currentPageIndex > 0
    }

    private var canGoNext: Bool {
        session.selectedChapterIndex < max(session.chapters.count - 1, 0)
            || (currentPageIndex + 1 < paginationController.totalPagesInChapter)
    }

    private var pageIndicator: some View {
        Text("\(currentPageIndex + 1)/\(totalPages)")
            .font(.caption.monospaced())
            .foregroundStyle(TTZipTheme.textPhotonicPrimary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: EPUBReaderFloatingChromeMetrics.hitSize)
            .accessibilityIdentifier("EPUBReaderPageIndicator")
    }

    private func paginationChevron(
        systemImage: String,
        helpText: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(TTZipTheme.textPhotonicPrimary)
                .frame(
                    width: EPUBReaderFloatingChromeMetrics.hitSize,
                    height: EPUBReaderFloatingChromeMetrics.hitSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.4)
        .ttButtonHelp(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier(
            systemImage == "chevron.left" ? "EPUBReaderPreviousPageButton" : "EPUBReaderNextPageButton"
        )
    }

    // MARK: Capsule Surfaces

    @ViewBuilder
    private var capsuleSurface: some View {
        let shape = RoundedRectangle(
            cornerRadius: EPUBReaderFloatingChromeMetrics.capsuleCornerRadius,
            style: .continuous
        )
        if usesHighContrastOrReducedTransparency {
            shape.fill(TTZipTheme.plateSurfaceL3)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    private var capsuleStroke: some View {
        RoundedRectangle(
            cornerRadius: EPUBReaderFloatingChromeMetrics.capsuleCornerRadius,
            style: .continuous
        )
        .strokeBorder(TTZipTheme.hairlineBorder, lineWidth: 0.5)
    }

    // MARK: Reveal Policy

    private var isControlCapsuleVisible: Bool {
        revealCoordinator.isPresented()
    }

    private var usesReducedMotion: Bool {
        envReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var usesHighContrastOrReducedTransparency: Bool {
        envReduceTransparency
            || envColorSchemeContrast == .increased
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Keeps the capsule alive while a panel or a menu owns the interaction.
    private func applyExternalLock() {
        let locked = isTypographyPresented || isNotesPresented || isMenuTracking
        updateCoordinator { $0.setExternallyLocked(locked) }
    }

    private func updateCoordinator(_ mutation: (PreviewCornerActionRevealCoordinator) -> Void) {
        if usesReducedMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { mutation(revealCoordinator) }
        } else {
            withAnimation(TTZipTheme.Motion.micro) { mutation(revealCoordinator) }
        }
    }

    // MARK: Annotation Export

    /// Exports the reading notes and hands the payload to the product-owned writer.
    private func exportAnnotations(format: String) {
        guard let contents = try? session.exportReaderAnnotations(format: format) else { return }
        do {
            try EPUBReaderNoteExporter.save(contents: contents, format: format)
        } catch {
            session.annotationSession.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Reveal Zone Sensor

/// Passive AppKit sensor that reveals the reading-control capsule when the pointer enters its
/// corner zone. Reuses `PreviewCornerHoverSensorNSView`, whose `hitTest(_:)` returns `nil`, so
/// hidden chrome never intercepts clicks, drags, or text selection in the document.
private struct EPUBReaderRevealZoneSensor: NSViewRepresentable {
    let onHoverChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> PreviewCornerHoverSensorNSView {
        let view = PreviewCornerHoverSensorNSView(frame: .zero)
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: PreviewCornerHoverSensorNSView, context: Context) {
        nsView.onHoverChange = onHoverChange
    }

    static func dismantleNSView(_ nsView: PreviewCornerHoverSensorNSView, coordinator: ()) {
        nsView.tearDown()
    }
}
