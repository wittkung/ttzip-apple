// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTKitUI
import TTKitDesign

/// Dedicated Finder-style "Go to Folder…" modal sheet supporting POSIX absolute paths,
/// `~/` home paths, relative paths, and local `file://` URLs with asynchronous autocompletion,
/// validation error retention, and security-scoped authorization routing.
@MainActor
public struct GoToFolderSheetView: View {
    public var viewModel: AppViewState
    public let onDismiss: () -> Void

    @State private var service = GoToFolderNavigationService()
    @State private var selectedSuggestionIndex: Int = -1
    @FocusState private var isInputFocused: Bool

    private var l10n = AppLocalizationState.shared

    public init(viewModel: AppViewState, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().opacity(0.4)
            inputAndSuggestionsSection
            Divider().opacity(0.4)
            footerSection
        }
        .frame(width: 520)
        .ttOverlayGlassPlate(cornerRadius: 16)
        .onAppear {
            service.prepareForPresentation(
                initialPath: viewModel.overlayState.goToFolderInitialPath,
                baseDirectory: viewModel.effectiveDisplayDirectory
            )
            isInputFocused = true
        }
        .onDisappear {
            service.cancelActiveSubmission()
        }
        .onExitCommand {
            cancelAndClose()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text(l10n.t(MultiWindowLocaleKey.goToFolder))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text("⇧⌘G")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Input & Autocompletion

    private var inputAndSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                l10n.uiString(
                    zh: "输入文件夹或归档路径（支持绝对路径、~/ 路径及本地 file:// URL）：",
                    en: "Enter a folder or archive path (supports absolute paths, ~/ paths, and local file:// URLs):"
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField(
                    "~/Downloads",
                    text: Binding(
                        get: { service.inputText },
                        set: { service.updateInput($0, baseDirectory: viewModel.effectiveDisplayDirectory) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .focused($isInputFocused)
                .accessibilityIdentifier("GoToFolderPathInput")
                .onSubmit {
                    submitGoToFolder()
                }

                if !service.inputText.isEmpty {
                    Button {
                        service.updateInput("", baseDirectory: viewModel.effectiveDisplayDirectory)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .ttButtonHelp(l10n.uiString(zh: "清空输入", en: "Clear input"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        service.inlineErrorMessage != nil
                            ? Color.red.opacity(0.65)
                            : TTZipTheme.bambooGreen.opacity(0.55),
                        lineWidth: 1
                    )
            )

            if let err = service.inlineErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                .accessibilityIdentifier("GoToFolderErrorLabel")
            }

            suggestionsListSection
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var suggestionsListSection: some View {
        let items = service.autocompletionEngine.suggestions
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.uiString(zh: "路径补全建议", en: "Path Suggestions"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.prefix(8).enumerated()), id: \.element.id) { idx, suggestion in
                            suggestionRow(suggestion, isSelected: idx == selectedSuggestionIndex)
                        }
                    }
                }
                .frame(maxHeight: 168)
            }
        }
    }

    private func suggestionRow(_ suggestion: AddressBarSuggestionItem, isSelected: Bool) -> some View {
        Button {
            service.applySuggestion(suggestion, baseDirectory: viewModel.effectiveDisplayDirectory)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: suggestion.isDirectory ? "folder.fill" : "doc.zipper")
                    .font(.system(size: 11.5))
                    .foregroundStyle(suggestion.isDirectory ? TTZipTheme.bambooGreen : .secondary)
                    .frame(width: 16)

                Text(suggestion.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Text(suggestion.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? TTZipTheme.bambooGreen.opacity(0.16) : Color.primary.opacity(0.03))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(l10n.t(L10n.Common.cancel)) {
                cancelAndClose()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("GoToFolderCancelButton")

            Spacer()

            Button(l10n.uiString(zh: "前往", en: "Go")) {
                submitGoToFolder()
            }
            .buttonStyle(.borderedProminent)
            .tint(TTZipTheme.bambooGreen)
            .disabled(service.isResolvingAccess)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("GoToFolderConfirmButton")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func cancelAndClose() {
        service.cancelActiveSubmission()
        onDismiss()
    }

    private func submitGoToFolder() {
        service.beginSubmitAndNavigate(in: viewModel, onDismiss: onDismiss)
    }
}
