// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit

/// Immersive full-viewport media browser presenting media files and documents.
/// Separates `.canvasMedia` (full-bleed with auto-hiding HUD) from `.structuredDocument` (stacked dedicated top bar)
/// so document toolbars and scrollbars are never occluded and background clicks never accidentally dismiss the window.
public struct ImmersiveMediaBrowserView: View {
    public let item: ImmersiveMediaItem
    public let onClose: @MainActor @Sendable () -> Void
    public let onNavigatePrevious: (@MainActor @Sendable () -> Void)?
    public let onNavigateNext: (@MainActor @Sendable () -> Void)?
    public let isStandalonePlaybackWindow: Bool
    public let onReturnToOriginPreview: (@MainActor @Sendable () -> Void)?
    public let returnToOriginLabel: String?
    public let returnToOriginHelp: String?
    
    @State private var eventMonitor: Any? = nil
    @State private var isCopiedToastShown: Bool = false
    @State private var controls = MediaControlsVisibility()
    @State private var leaseBox: TTMediaEphemeralLeaseBox
    @State private var layoutClass: PreviewHostLayoutClass
    @State private var resolvedPreviewType: MediaPreviewType? = nil
    @State private var hostWindowNumber: Int? = nil
    private var isControlsVisible: Bool { controls.isVisible }
    
    public init(
        item: ImmersiveMediaItem,
        onClose: @escaping @MainActor @Sendable () -> Void,
        onNavigatePrevious: (@MainActor @Sendable () -> Void)? = nil,
        onNavigateNext: (@MainActor @Sendable () -> Void)? = nil,
        isStandalonePlaybackWindow: Bool = false,
        onReturnToOriginPreview: (@MainActor @Sendable () -> Void)? = nil,
        returnToOriginLabel: String? = nil,
        returnToOriginHelp: String? = nil
    ) {
        self.item = item
        self.onClose = onClose
        self.onNavigatePrevious = onNavigatePrevious
        self.onNavigateNext = onNavigateNext
        self.isStandalonePlaybackWindow = isStandalonePlaybackWindow
        self.onReturnToOriginPreview = onReturnToOriginPreview
        self.returnToOriginLabel = returnToOriginLabel
        self.returnToOriginHelp = returnToOriginHelp
        _leaseBox = State(initialValue: TTMediaEphemeralLeaseBox(adoptingUnclaimedFor: item.url))
        let initialLayout = TTMediaDetector.inferHostLayoutClass(url: item.url, fileName: item.name)
        _layoutClass = State(initialValue: initialLayout)
    }
    
    private var formatExtension: String {
        let nameExt = (item.name as NSString).pathExtension.uppercased()
        if !nameExt.isEmpty { return nameExt }
        let ext = item.url.pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : ext
    }
    
    private var fileSizeDescription: String? {
        if let size = item.fileSizeBytes {
            return ByteCountFormatterFlyweight.shared.string(fromByteCount: size)
        }
        if let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            return ByteCountFormatterFlyweight.shared.string(fromByteCount: Int64(size))
        }
        return nil
    }

    private func computeHostGeometry(for geometry: GeometryProxy) -> TTPreviewHostContentGeometry {
        let headerHeight: CGFloat = (layoutClass == .structuredDocument) ? 52.0 : 0.0
        let contentHeight = max(0.0, geometry.size.height - headerHeight)
        return TTPreviewHostContentGeometry(
            layoutClass: layoutClass,
            hostHeaderHeight: headerHeight,
            contentTopSafeInset: 0.0,
            availableSize: CGSize(width: geometry.size.width, height: contentHeight),
            isStandalonePlaybackWindow: isStandalonePlaybackWindow
        )
    }
    
    public var body: some View {
        GeometryReader { geometry in
            Group {
                if layoutClass == .structuredDocument {
                    structuredDocumentLayout(geometry: geometry)
                } else {
                    canvasMediaLayout(geometry: geometry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TTPreviewHostWindowNumberReader(windowNumber: $hostWindowNumber))
            .environment(\.mediaControlsVisibility, controls)
            .environment(\.previewResourceContext, item.resolvedResourceContext)
            .environment(\.previewHostContentGeometry, computeHostGeometry(for: geometry))
            .animation(.spring(response: 0.16, dampingFraction: 1), value: isControlsVisible)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    controls.recordMouseMove(at: location)
                case .ended:
                    controls.setHovered(false)
                }
            }
            .onAppear {
                leaseBox.bind(url: item.url, consumeFullscreenHandoff: true)
                layoutClass = TTMediaDetector.inferHostLayoutClass(url: item.url, fileName: item.name)
                setupKeyboardMonitor()
                if !isVideoCanvas {
                    showControlsAndResetTimer()
                }
            }
            .onChange(of: item.url) { _, newURL in
                controls.resetForNewItem()
                leaseBox.bind(url: newURL, consumeFullscreenHandoff: true)
                resolvedPreviewType = nil
                layoutClass = TTMediaDetector.inferHostLayoutClass(url: newURL, fileName: item.name)
                setupKeyboardMonitor()
            }
            .onDisappear {
                teardownKeyboardMonitor()
                controls.tearDown()
                TTMediaDetector.endFullscreenEphemeralHandoff(for: item.url)
                leaseBox.release()
            }
        }
    }

    // MARK: - Dual-Mode Host Layouts

    private func structuredDocumentLayout(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            documentHostHeaderBar(geometry: geometry)
            Divider()
                .overlay(Color.white.opacity(0.14))
            mediaPreviewViewport
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            Color.black.opacity(0.94)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
        )
    }

    private var isVideoCanvas: Bool {
        if let resolvedPreviewType {
            return resolvedPreviewType.isVideoPreview
        }
        let rawExt = (item.name as NSString).pathExtension.isEmpty
            ? item.url.pathExtension
            : (item.name as NSString).pathExtension
        let ext = TTMediaCapabilityMatrix.cleanExtension(from: rawExt)
        return TTMediaCapabilityMatrix.videoExtensions.contains(ext) && layoutClass == .canvasMedia
    }

    private func canvasMediaLayout(geometry: GeometryProxy) -> some View {
        ZStack {
            Color.black.opacity(0.92)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture {
                    if !isControlsVisible && !isVideoCanvas {
                        showControlsAndResetTimer()
                    }
                }

            mediaPreviewViewport
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            if isVideoCanvas {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        Spacer(minLength: 0)
                        videoCanvasTopRightCluster
                    }
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(edges: .top)
            } else {
                VStack(spacing: 0) {
                    topGradientHeader(geometry: geometry)
                    Spacer()
                }
                .ignoresSafeArea(edges: .top)
                .opacity(isControlsVisible ? 1.0 : 0.0)
                .allowsHitTesting(isControlsVisible)
            }
        }
    }

    private var videoCanvasTopRightCluster: some View {
        var items: [VideoWindowCornerControlItem] = []
        if onNavigatePrevious != nil || onNavigateNext != nil {
            items.append(
                VideoWindowCornerControlItem(
                    id: "ImmersiveMediaPreviousButton",
                    symbolName: "chevron.left",
                    accessibilityLabel: MediaLocalization.text(.previous),
                    accessibilityHint: MediaLocalization.text(.previousHint),
                    helpText: MediaLocalization.text(.previousHelp),
                    shapeStyle: .roundedPill,
                    isEnabled: onNavigatePrevious != nil,
                    action: { onNavigatePrevious?() }
                )
            )
            items.append(
                VideoWindowCornerControlItem(
                    id: "ImmersiveMediaNextButton",
                    symbolName: "chevron.right",
                    accessibilityLabel: MediaLocalization.text(.next),
                    accessibilityHint: MediaLocalization.text(.nextHint),
                    helpText: MediaLocalization.text(.nextHelp),
                    shapeStyle: .roundedPill,
                    isEnabled: onNavigateNext != nil,
                    action: { onNavigateNext?() }
                )
            )
        }
        if let onReturnToOriginPreview {
            let labelText = returnToOriginLabel ?? "Return to Preview"
            let helpText = returnToOriginHelp ?? labelText
            items.append(
                VideoWindowCornerControlItem(
                    id: "StandalonePlaybackReturnToPreviewButton",
                    symbolName: "arrow.down.right.and.arrow.up.left",
                    title: labelText,
                    accessibilityLabel: labelText,
                    helpText: helpText,
                    shapeStyle: .roundedPill,
                    action: onReturnToOriginPreview
                )
            )
        }
        items.append(
            VideoWindowCornerControlItem(
                id: "ImmersiveMediaFinderButton",
                symbolName: "folder",
                title: MediaLocalization.text(.finder),
                accessibilityLabel: MediaLocalization.text(.finder),
                helpText: MediaLocalization.text(.finderHelp),
                shapeStyle: .roundedPill,
                action: revealInFinder
            )
        )
        items.append(
            VideoWindowCornerControlItem(
                id: "ImmersiveMediaCopyPathButton",
                symbolName: isCopiedToastShown ? "checkmark" : "doc.on.doc",
                title: isCopiedToastShown ? MediaLocalization.text(.copied) : MediaLocalization.text(.copyPath),
                accessibilityLabel: MediaLocalization.text(.copyPathLabel),
                helpText: MediaLocalization.text(.copyPathHelp),
                shapeStyle: .roundedPill,
                customTint: isCopiedToastShown ? NSColor(TTZipTheme.bambooGreen) : nil,
                action: copyFilePath
            )
        )
        items.append(
            VideoWindowCornerControlItem(
                id: "ImmersiveMediaCloseButton",
                symbolName: "xmark",
                accessibilityLabel: MediaLocalization.text(.close),
                accessibilityHint: MediaLocalization.text(.escapeHint),
                helpText: MediaLocalization.text(.dismissHelp),
                shapeStyle: .circle,
                action: onClose
            )
        )
        return VideoWindowCornerControlClusterView(
            sensorID: "ImmersiveVideoTopRightControls.HoverSensor",
            items: items
        )
    }

    private var mediaPreviewViewport: some View {
        MediaPreviewView(
            fileURL: item.url,
            fileName: item.name,
            isImmersiveFullscreen: true,
            showsFloatingFullScreenButton: false,
            sourceArchivePath: item.sourceArchivePath,
            archiveSubpath: item.archiveSubpath,
            resourceCacheKey: item.resourceCacheKey,
            isEditable: item.isEditable,
            resourceContext: item.resolvedResourceContext,
            onPreviewTypeResolved: { resolvedType in
                resolvedPreviewType = resolvedType
                layoutClass = resolvedType.hostLayoutClass
            }
        )
        .environment(\.isImmersiveFullscreen, true)
        .environment(\.previewResourceContext, item.resolvedResourceContext)
        .id(item.url)
    }
    
    // MARK: - Host Header Bars
    
    private func documentHostHeaderBar(geometry: GeometryProxy) -> some View {
        headerBarContent(geometry: geometry)
            .padding(.leading, 84)
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.black.opacity(0.82))
    }

    private func topGradientHeader(geometry: GeometryProxy) -> some View {
        headerBarContent(geometry: geometry)
            .padding(.leading, 84)
            .padding(.trailing, 24)
            .padding(.top, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 96, alignment: .top)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.75), Color.black.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private func headerBarContent(geometry: GeometryProxy) -> some View {
        HStack(alignment: .center, spacing: 14) {
            leadingBadgeAndTitle(geometry: geometry)
            Spacer()
            trailingHeaderControls
        }
    }

    private func leadingBadgeAndTitle(geometry: GeometryProxy) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: MediaPreviewFactory.iconName(for: item.name))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                
                Text(formatExtension)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(TTZipTheme.kintsugiGold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(TTZipTheme.kintsugiGold.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(TTZipTheme.kintsugiGold.opacity(0.4), lineWidth: 0.5)
            )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: min(640, max(80, geometry.size.width - 420)), alignment: .leading)
                
                if let sizeDesc = fileSizeDescription {
                    Text(sizeDesc)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
        }
    }

    private var trailingHeaderControls: some View {
        HStack(spacing: 10) {
            if onNavigatePrevious != nil || onNavigateNext != nil {
                headerNavigationCluster
            }

            if let onReturnToOriginPreview {
                returnToOriginPreviewButton(action: onReturnToOriginPreview)
            }

            Button(action: revealInFinder) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                    Text(MediaLocalization.text(.finder))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help(MediaLocalization.text(.finderHelp))
            .accessibilityLabel(MediaLocalization.text(.finder))
            
            Button(action: copyFilePath) {
                HStack(spacing: 4) {
                    Image(systemName: isCopiedToastShown ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isCopiedToastShown ? TTZipTheme.bambooGreen : .white.opacity(0.9))
                    Text(isCopiedToastShown ? MediaLocalization.text(.copied) : MediaLocalization.text(.copyPath))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isCopiedToastShown ? TTZipTheme.bambooGreen : .white.opacity(0.9))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help(MediaLocalization.text(.copyPathHelp))
            .accessibilityLabel(MediaLocalization.text(.copyPathLabel))
            
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(MediaLocalization.text(.dismissHelp))
            .accessibilityLabel(MediaLocalization.text(.close))
            .accessibilityHint(MediaLocalization.text(.escapeHint))
            .accessibilityIdentifier("ImmersiveMediaCloseButton")
        }
    }

    private func returnToOriginPreviewButton(action: @escaping () -> Void) -> some View {
        let labelText = returnToOriginLabel ?? "Return to Preview"
        let helpText = returnToOriginHelp ?? labelText
        return Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11, weight: .medium))
                Text(labelText)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(labelText)
        .accessibilityIdentifier("StandalonePlaybackReturnToPreviewButton")
    }

    private var headerNavigationCluster: some View {
        HStack(spacing: 4) {
            Button(action: { onNavigatePrevious?() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(onNavigatePrevious != nil ? .white.opacity(0.92) : .white.opacity(0.3))
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(onNavigatePrevious == nil)
            .help(MediaLocalization.text(.previousHelp))
            .accessibilityLabel(MediaLocalization.text(.previous))
            .accessibilityHint(MediaLocalization.text(.previousHint))
            .accessibilityIdentifier("ImmersiveMediaPreviousButton")

            Button(action: { onNavigateNext?() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(onNavigateNext != nil ? .white.opacity(0.92) : .white.opacity(0.3))
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(onNavigateNext == nil)
            .help(MediaLocalization.text(.nextHelp))
            .accessibilityLabel(MediaLocalization.text(.next))
            .accessibilityHint(MediaLocalization.text(.nextHint))
            .accessibilityIdentifier("ImmersiveMediaNextButton")
        }
    }
    
    // MARK: - Auto-Hide State Machine
    
    private func showControlsAndResetTimer() {
        controls.interact()
    }

    // MARK: - Actions & Keyboard
    
    private func revealInFinder() {
        if let archivePath = item.sourceArchivePath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: archivePath)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
    }

    private func copyFilePath() {
        NSPasteboard.general.clearContents()
        let copiedPath: String
        if let archivePath = item.sourceArchivePath {
            if let subpath = item.archiveSubpath, !subpath.isEmpty {
                copiedPath = "\(archivePath)::\(subpath)"
            } else {
                copiedPath = archivePath
            }
        } else {
            copiedPath = item.url.path
        }
        NSPasteboard.general.setString(copiedPath, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            isCopiedToastShown = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(.easeInOut(duration: 0.2)) {
                isCopiedToastShown = false
            }
        }
    }
    
    private func setupKeyboardMonitor() {
        teardownKeyboardMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let eventWinNum = event.window?.windowNumber ?? NSApp?.keyWindow?.windowNumber
            if let hostWindowNumber, let eventWinNum, eventWinNum != hostWindowNumber {
                return event
            }
            let targetWindow = event.window ?? NSApp?.keyWindow
            let isInputActive = TTPreviewHorizontalKeyPolicy.isWindowTextInputActive(targetWindow)
            if event.keyCode == 53 {
                guard !isInputActive else { return event }
                if isStandalonePlaybackWindow, let targetWindow, targetWindow.styleMask.contains(.fullScreen) {
                    targetWindow.toggleFullScreen(nil)
                    return nil
                }
                onClose()
                return nil
            }
            if event.keyCode == 123 || event.keyCode == 124 {
                let disposition = TTPreviewKeyboardOwnershipCoordinator.shared.handleOrBlockOuterHorizontalArrow(event: event)
                if disposition == .consumedByPreviewOwner {
                    return nil
                }
                if disposition == .yieldToTextInput {
                    return event
                }
                guard TTPreviewHorizontalKeyPolicy.shouldOuterBrowserInterceptHorizontalArrow(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags,
                    eventWindowNumber: eventWinNum,
                    hostWindowNumber: hostWindowNumber,
                    isAppKitTextInputActive: isInputActive,
                    previewType: resolvedPreviewType,
                    url: item.url,
                    fileName: item.name
                ) else {
                    return event
                }
                if event.keyCode == 123, let prev = onNavigatePrevious {
                    prev()
                    return nil
                }
                if event.keyCode == 124, let next = onNavigateNext {
                    next()
                    return nil
                }
            }
            return event
        }
    }
    
    private func teardownKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

@MainActor
extension TTPreviewHorizontalKeyPolicy {
    private static let defaultFileListSessionID = UUID(uuidString: "00000000-0000-0000-0000-0000F11E1157")!
    private static var windowFileListSessionIDs: [Int: UUID] = [:]

    public static func fileListSessionID(forWindowNumber windowNumber: Int?) -> UUID {
        guard let windowNumber else { return defaultFileListSessionID }
        if let existing = windowFileListSessionIDs[windowNumber] {
            return existing
        }
        let created = UUID()
        windowFileListSessionIDs[windowNumber] = created
        return created
    }

    /// Marks the outer file list as the active keyboard target in `windowNumber`,
    /// setting the reader session's `focusSource` to `.none` so Left/Right arrow keys return to Miller column file navigation.
    public static func returnKeyboardFocusToFileList(windowNumber: Int?) {
        let sessionID = fileListSessionID(forWindowNumber: windowNumber)
        TTPreviewKeyboardOwnershipCoordinator.shared.unregisterSession(instanceID: sessionID)
        let ownership = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(windowNumber: windowNumber)
        if let ownerID = ownership.ownerInstanceID {
            TTPreviewKeyboardOwnershipCoordinator.shared.setReaderFocusState(
                instanceID: ownerID,
                isFocused: false,
                source: .none
            )
        }
    }

    /// Releases the outer file list's keyboard override in `windowNumber` so the active reader session regains horizontal arrow ownership.
    public static func releaseFileListKeyboardFocus(windowNumber: Int?) {
        let sessionID = fileListSessionID(forWindowNumber: windowNumber)
        TTPreviewKeyboardOwnershipCoordinator.shared.unregisterSession(instanceID: sessionID)
        let ownership = TTPreviewKeyboardOwnershipCoordinator.shared.queryOwnership(windowNumber: windowNumber)
        if let ownerID = ownership.ownerInstanceID {
            TTPreviewKeyboardOwnershipCoordinator.shared.setReaderFocusState(
                instanceID: ownerID,
                isFocused: true,
                source: .readingArea
            )
        }
    }
}

