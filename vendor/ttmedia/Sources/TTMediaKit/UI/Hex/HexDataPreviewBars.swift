// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

/// Three-column aligned header bar for the hex editor canvas.
public struct HexColumnHeaderBar: View {
    public init() {}
    
    public var body: some View {
        HStack(spacing: 0) {
            Text(TextAndDocumentPreviewLocalization.text(.hexColumnOffset))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: HexMetrics.offsetColumnWidth, alignment: .leading)
            Text("00 01 02 03 04 05 06 07   08 09 0A 0B 0C 0D 0E 0F")
                .font(.system(size: HexMetrics.fontSize, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Divider()
                .frame(height: 14)
                .padding(.leading, 22)
                .padding(.trailing, 8)
            Text(TextAndDocumentPreviewLocalization.text(.hexColumnDecodedText))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HexMetrics.horizontalPadding)
        .padding(.vertical, 4.5)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

/// Dropdown menu for selecting hex dump page size.
public struct HexPageSizeMenu: View {
    @Binding public var pageSizeOption: HexPageSizeOption
    public let compact: Bool
    
    public init(pageSizeOption: Binding<HexPageSizeOption>, compact: Bool) {
        self._pageSizeOption = pageSizeOption
        self.compact = compact
    }
    
    public var body: some View {
        Menu {
            ForEach(HexPageSizeOption.allCases) { option in
                Button(action: { pageSizeOption = option }) {
                    HStack {
                        Text(
                            TextAndDocumentPreviewLocalization.format(
                                .hexPageSizeLinesFormat,
                                option.rawValue / 1024,
                                option.rawValue / 16
                            )
                        )
                        if pageSizeOption == option { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 9.5))
                Text(
                    compact
                        ? TextAndDocumentPreviewLocalization.format(.hexPageSizeCompactFormat, pageSizeOption.rawValue / 1024)
                        : TextAndDocumentPreviewLocalization.format(.hexPageSizeMenuFormat, pageSizeOption.rawValue / 1024)
                )
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            }
            .padding(.horizontal, compact ? 5 : 8).padding(.vertical, 3.5)
            .background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
        .ttButtonHelp(TextAndDocumentPreviewLocalization.format(.hexPageSizeMenuFormat, pageSizeOption.rawValue / 1024))
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Action menu providing multi-format clipboard export options.
public struct HexCopyActionMenu: View {
    public let compact: Bool
    public let onCopyHexBytes: () -> Void
    public let onCopyContinuousHex: () -> Void
    public let onCopyASCII: () -> Void
    public let onCopyCArray: () -> Void
    public let onCopyFullDump: () -> Void
    
    public init(
        compact: Bool,
        onCopyHexBytes: @escaping () -> Void,
        onCopyContinuousHex: @escaping () -> Void,
        onCopyASCII: @escaping () -> Void,
        onCopyCArray: @escaping () -> Void,
        onCopyFullDump: @escaping () -> Void
    ) {
        self.compact = compact
        self.onCopyHexBytes = onCopyHexBytes
        self.onCopyContinuousHex = onCopyContinuousHex
        self.onCopyASCII = onCopyASCII
        self.onCopyCArray = onCopyCArray
        self.onCopyFullDump = onCopyFullDump
    }
    
    public var body: some View {
        Menu {
            Button(action: onCopyHexBytes) {
                Label(TextAndDocumentPreviewLocalization.text(.hexCopyHexBytesMenu), systemImage: "doc.on.doc")
            }
            Button(action: onCopyContinuousHex) {
                Label(TextAndDocumentPreviewLocalization.text(.hexCopyContinuousHexMenu), systemImage: "number")
            }
            Button(action: onCopyASCII) {
                Label(TextAndDocumentPreviewLocalization.text(.hexCopyASCIIMenu), systemImage: "text.alignleft")
            }
            Button(action: onCopyCArray) {
                Label(TextAndDocumentPreviewLocalization.text(.hexCopyCArrayMenu), systemImage: "curlybraces")
            }
            Divider()
            Button(action: onCopyFullDump) {
                Label(TextAndDocumentPreviewLocalization.text(.hexCopyFullDumpMenu), systemImage: "tablecells")
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "doc.on.doc.fill").font(.system(size: 10)).foregroundStyle(TTMediaTheme.bambooGreen)
                if !compact {
                    Text(TextAndDocumentPreviewLocalization.text(.copyCodeButton))
                        .font(.system(size: 10.5, weight: .bold))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, compact ? 6 : 9).padding(.vertical, 3.5)
            .background(TTMediaTheme.bambooGreen.opacity(0.12)).clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .ttButtonHelp(TextAndDocumentPreviewLocalization.text(.copyCodeButton))
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Responsive top header bar displaying binary title, badge, file size, page size picker, and copy menu.
public struct HexTopControlBar: View {
    public let fileName: String
    public let totalFileSize: Int64
    @Binding public var pageSizeOption: HexPageSizeOption
    public let onCopyHexBytes: () -> Void
    public let onCopyContinuousHex: () -> Void
    public let onCopyASCII: () -> Void
    public let onCopyCArray: () -> Void
    public let onCopyFullDump: () -> Void
    
    public init(
        fileName: String,
        totalFileSize: Int64,
        pageSizeOption: Binding<HexPageSizeOption>,
        onCopyHexBytes: @escaping () -> Void,
        onCopyContinuousHex: @escaping () -> Void,
        onCopyASCII: @escaping () -> Void,
        onCopyCArray: @escaping () -> Void,
        onCopyFullDump: @escaping () -> Void
    ) {
        self.fileName = fileName
        self.totalFileSize = totalFileSize
        self._pageSizeOption = pageSizeOption
        self.onCopyHexBytes = onCopyHexBytes
        self.onCopyContinuousHex = onCopyContinuousHex
        self.onCopyASCII = onCopyASCII
        self.onCopyCArray = onCopyCArray
        self.onCopyFullDump = onCopyFullDump
    }
    
    public var body: some View {
        ViewThatFits(in: .horizontal) {
            barContent(compact: false, minimal: false, showFileName: true)
            barContent(compact: true, minimal: false, showFileName: false)
            barContent(compact: true, minimal: true, showFileName: false)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    @ViewBuilder
    private func barContent(compact: Bool, minimal: Bool, showFileName: Bool) -> some View {
        HStack(spacing: compact ? (minimal ? 6 : 8) : 10) {
            if minimal {
                Image(systemName: "memorychip.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(TTMediaTheme.bambooGreen)
                    .padding(4).background(TTMediaTheme.bambooGreen.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "memorychip.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(TTMediaTheme.bambooGreen)
                    Text(
                        compact
                            ? TextAndDocumentPreviewLocalization.text(.hexViewerCompactBadge)
                            : TextAndDocumentPreviewLocalization.text(.hexViewerBadge)
                    )
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                }
                .padding(.horizontal, compact ? 6 : 8).padding(.vertical, 3.5)
                .background(TTMediaTheme.bambooGreen.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize(horizontal: true, vertical: false)
            }
            if showFileName {
                Text(fileName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(ByteCountFormatterFlyweight.shared.string(fromByteCount: totalFileSize))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 4))
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: minimal ? 2 : 4)
            HexPageSizeMenu(pageSizeOption: $pageSizeOption, compact: compact)
            HexCopyActionMenu(
                compact: compact || minimal,
                onCopyHexBytes: onCopyHexBytes,
                onCopyContinuousHex: onCopyContinuousHex,
                onCopyASCII: onCopyASCII,
                onCopyCArray: onCopyCArray,
                onCopyFullDump: onCopyFullDump
            )
        }
    }
}

/// Popover allowing users to input and jump to an arbitrary byte offset.
public struct HexJumpPopoverView: View {
    @Binding public var jumpOffsetInput: String
    public let onJump: () -> Void
    
    public init(jumpOffsetInput: Binding<String>, onJump: @escaping () -> Void) {
        self._jumpOffsetInput = jumpOffsetInput
        self.onJump = onJump
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TextAndDocumentPreviewLocalization.text(.hexJumpToOffsetTitle))
                .font(.system(size: 12, weight: .bold))
            Text(TextAndDocumentPreviewLocalization.text(.hexJumpToOffsetPrompt))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("0x00000000", text: $jumpOffsetInput)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced)).frame(width: 140)
                    .onSubmit(onJump)
                Button(action: onJump) {
                    Text(TextAndDocumentPreviewLocalization.text(.hexJumpConfirmButton))
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(TTMediaTheme.bambooGreen).clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14).frame(width: 260)
    }
}

/// Jump address trigger button with attached popover sheet.
public struct HexAddressNavigatorBar: View {
    @Binding public var isJumpPopoverPresented: Bool
    @Binding public var jumpOffsetInput: String
    public let compact: Bool
    public let onJump: () -> Void
    
    public init(
        isJumpPopoverPresented: Binding<Bool>,
        jumpOffsetInput: Binding<String>,
        compact: Bool,
        onJump: @escaping () -> Void
    ) {
        self._isJumpPopoverPresented = isJumpPopoverPresented
        self._jumpOffsetInput = jumpOffsetInput
        self.compact = compact
        self.onJump = onJump
    }
    
    public var body: some View {
        Button(action: { isJumpPopoverPresented.toggle() }) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.right.to.line.compact").font(.system(size: 10))
                if !compact {
                    Text(TextAndDocumentPreviewLocalization.text(.hexJumpTriggerButton))
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, compact ? 5 : 6).padding(.vertical, 3)
            .background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .ttButtonHelp(TextAndDocumentPreviewLocalization.text(.hexJumpToOffsetTitle))
        .popover(isPresented: $isJumpPopoverPresented, arrowEdge: .bottom) {
            HexJumpPopoverView(jumpOffsetInput: $jumpOffsetInput, onJump: onJump)
        }
    }
}

/// Stepper and quick-jump pagination controls for navigating hex pages.
public struct HexPaginationControls: View {
    @Binding public var currentPageIndex: Int
    public let totalPages: Int
    public let compact: Bool
    
    public init(currentPageIndex: Binding<Int>, totalPages: Int, compact: Bool) {
        self._currentPageIndex = currentPageIndex
        self.totalPages = totalPages
        self.compact = compact
    }
    
    public var body: some View {
        HStack(spacing: compact ? 2 : 4) {
            if !compact {
                Button(action: { currentPageIndex = 0 }) {
                    Image(systemName: "backward.end.fill").font(.system(size: 9))
                }
                .disabled(currentPageIndex <= 0).buttonStyle(.plain).padding(4)
                .ttButtonHelp(SpreadsheetPreviewLocalization.text(.firstPageHelp))
            }
            Button(action: { if currentPageIndex > 0 { currentPageIndex -= 1 } }) {
                Image(systemName: "chevron.left").font(.system(size: compact ? 9.5 : 10, weight: .bold))
            }
            .disabled(currentPageIndex <= 0).buttonStyle(.plain).padding(compact ? 3 : 4)
            .ttButtonHelp(SpreadsheetPreviewLocalization.text(.previousPageHelp))
            Text(
                compact
                    ? "\(currentPageIndex + 1)/\(totalPages)"
                    : TextAndDocumentPreviewLocalization.format(.hexPageOfTotalFormat, currentPageIndex + 1, totalPages)
            )
            .font(.system(size: compact ? 10 : 10.5, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, compact ? 4 : 6)
            Button(action: { if currentPageIndex < totalPages - 1 { currentPageIndex += 1 } }) {
                Image(systemName: "chevron.right").font(.system(size: compact ? 9.5 : 10, weight: .bold))
            }
            .disabled(currentPageIndex >= totalPages - 1).buttonStyle(.plain).padding(compact ? 3 : 4)
            .ttButtonHelp(SpreadsheetPreviewLocalization.text(.nextPageHelp))
            if !compact {
                Button(action: { currentPageIndex = max(0, totalPages - 1) }) {
                    Image(systemName: "forward.end.fill").font(.system(size: 9))
                }
                .disabled(currentPageIndex >= totalPages - 1).buttonStyle(.plain).padding(4)
                .ttButtonHelp(SpreadsheetPreviewLocalization.text(.lastPageHelp))
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, compact ? 3 : 4).padding(.vertical, 2)
        .background(Color.primary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: compact ? 4 : 5))
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Status summary badge and offset indicator for inspection metrics.
public struct HexStatusStatsBar: View {
    public let startOffset: Int64
    public let endOffset: Int64
    public let compact: Bool
    
    public init(startOffset: Int64, endOffset: Int64, compact: Bool = false) {
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.compact = compact
    }
    
    public var body: some View {
        HStack(spacing: 4) {
            if !compact {
                Text(TextAndDocumentPreviewLocalization.text(.hexRangeLabel))
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(HexDataFormattingHelper.formatOffsetRange(start: startOffset, end: endOffset, compact: compact))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(TTMediaTheme.bambooGreen)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Responsive bottom status bar displaying offset range, jump button, and pagination controls.
public struct HexBottomStatusBar: View {
    public let startOffset: Int64
    public let endOffset: Int64
    @Binding public var isJumpPopoverPresented: Bool
    @Binding public var jumpOffsetInput: String
    @Binding public var currentPageIndex: Int
    public let totalPages: Int
    public let onJump: () -> Void
    
    public init(
        startOffset: Int64,
        endOffset: Int64,
        isJumpPopoverPresented: Binding<Bool>,
        jumpOffsetInput: Binding<String>,
        currentPageIndex: Binding<Int>,
        totalPages: Int,
        onJump: @escaping () -> Void
    ) {
        self.startOffset = startOffset
        self.endOffset = endOffset
        self._isJumpPopoverPresented = isJumpPopoverPresented
        self._jumpOffsetInput = jumpOffsetInput
        self._currentPageIndex = currentPageIndex
        self.totalPages = totalPages
        self.onJump = onJump
    }
    
    public var body: some View {
        ViewThatFits(in: .horizontal) {
            statusBarContent(showRange: true, compactRange: false, compactNav: false)
            statusBarContent(showRange: true, compactRange: true, compactNav: true)
            statusBarContent(showRange: false, compactRange: true, compactNav: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func statusBarContent(showRange: Bool, compactRange: Bool, compactNav: Bool) -> some View {
        HStack(spacing: compactNav ? (showRange ? 8 : 6) : 12) {
            if showRange {
                HexStatusStatsBar(startOffset: startOffset, endOffset: endOffset, compact: compactRange)
            }
            Spacer(minLength: compactNav ? 4 : 6)
            HexAddressNavigatorBar(
                isJumpPopoverPresented: $isJumpPopoverPresented,
                jumpOffsetInput: $jumpOffsetInput,
                compact: compactNav,
                onJump: onJump
            )
            HexPaginationControls(currentPageIndex: $currentPageIndex, totalPages: totalPages, compact: compactNav)
        }
    }
}

/// Floating capsule toast overlay confirming clipboard operations.
public struct HexToastOverlay: View {
    public let message: String
    
    public init(message: String) {
        self.message = message
    }
    
    public var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(TTMediaTheme.bambooGreen)
                Text(message).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.85)))
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .padding(.bottom, 20)
        }
    }
}
