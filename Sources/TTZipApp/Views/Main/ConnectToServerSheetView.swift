// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTKitUI
import TTKitDesign

/// Modal sheet for user-initiated network share connections (`smb://`, `afp://`, `nfs://`).
///
/// Explicitly scopes supported protocols, delegates authentication to the macOS NetFS / Keychain UI,
/// scrubs any passwords from recents/logs, and navigates TTZip's browser upon mount success.
@MainActor
public struct ConnectToServerSheetView: View {
    public var viewModel: AppViewState
    public let onDismiss: () -> Void

    @State private var selectedScheme: SupportedNetworkShareScheme = .smb
    @State private var addressInput: String = "smb://"
    @State private var validationErrorMessage: String? = nil

    private var service = ServerConnectionService.shared
    private var l10n = AppLocalizationState.shared

    public init(viewModel: AppViewState, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    private var isConnecting: Bool {
        service.state.isConnecting
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().opacity(0.4)
            contentSection
            Divider().opacity(0.4)
            footerSection
        }
        .frame(width: 540)
        .ttOverlayGlassPlate(cornerRadius: 16)
        .onAppear {
            service.resetState()
            if let initial = viewModel.overlayState.connectToServerInitialAddress, !initial.isEmpty {
                addressInput = initial
            } else if let firstRecent = service.recentServerAddresses.first {
                addressInput = firstRecent
            } else {
                addressInput = selectedScheme.defaultPrefix
            }
        }
        .onExitCommand {
            handleCancelOrClose()
        }
        .onDisappear {
            service.cancelActiveConnection(resetToIdle: true)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text(l10n.t(MultiWindowLocaleKey.connectToServer))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text("⌥⌘K")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            protocolPickerRow
            serverAddressInputRow
            statusAndErrorRow
            recentServersSection
            channelCapabilityFootnote
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var protocolPickerRow: some View {
        HStack(spacing: 10) {
            Text(l10n.uiString(zh: "共享协议：", en: "Share Protocol:"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Picker("", selection: $selectedScheme) {
                ForEach(SupportedNetworkShareScheme.allCases, id: \.self) { scheme in
                    Text("\(scheme.displayBadge) (\(scheme.defaultPrefix))").tag(scheme)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: selectedScheme) { _, newScheme in
                applySchemePrefixIfAppropriate(newScheme)
            }
        }
    }

    private var serverAddressInputRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(
                l10n.uiString(
                    zh: "服务器地址（例如 smb://nas.local/share）：",
                    en: "Server Address (e.g. smb://nas.local/share):"
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField("smb://server.local/share", text: $addressInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .disabled(isConnecting)
                    .accessibilityIdentifier("ConnectToServerAddressField")
                    .onSubmit {
                        submitConnection()
                    }
                    .onChange(of: addressInput) { _, _ in
                        validationErrorMessage = nil
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
                        validationErrorMessage != nil
                            ? Color.red.opacity(0.65)
                            : TTZipTheme.bambooGreen.opacity(0.55),
                        lineWidth: 1
                    )
            )
        }
    }

    @ViewBuilder
    private var statusAndErrorRow: some View {
        if let err = validationErrorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }
            .accessibilityIdentifier("ConnectToServerErrorLabel")
        } else {
            switch service.state {
            case .idle:
                EmptyView()
            case .connecting(let endpoint):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(
                        l10n.uiString(
                            zh: "正在连接 \(endpoint.sanitizedAddressString)…",
                            en: "Connecting to \(endpoint.sanitizedAddressString)…"
                        )
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
            case .connected(let mountURL, let reused):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                    Text(
                        reused
                            ? l10n.uiString(
                                zh: "已复用挂载卷：\(mountURL.path)",
                                en: "Reused mounted share: \(mountURL.path)"
                            )
                            : l10n.uiString(
                                zh: "已挂载：\(mountURL.path)",
                                en: "Mounted at: \(mountURL.path)"
                            )
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                }
            case .cancelled:
                Text(l10n.uiString(zh: "已取消连接。", en: "Connection cancelled."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                    Text(reason.errorDescription ?? reason.localizedDescription)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier("ConnectToServerFailureLabel")
            }
        }
    }

    @ViewBuilder
    private var recentServersSection: some View {
        if !service.recentServerAddresses.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(l10n.uiString(zh: "最近使用的服务器（不含密码）", en: "Recent Servers (Credential-Free)"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(l10n.t(MultiWindowLocaleKey.clearRecentItems)) {
                        service.clearRecentServers()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(service.recentServerAddresses, id: \.self) { addr in
                            Button {
                                addressInput = addr
                                validationErrorMessage = nil
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                    Text(addr)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.03)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
    }

    private var channelCapabilityFootnote: some View {
        Text(ServerConnectionService.channelCapabilitySummary.description)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .lineLimit(2)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(isConnecting ? l10n.uiString(zh: "停止连接", en: "Stop") : l10n.t(L10n.Common.cancel)) {
                handleCancelOrClose()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("ConnectToServerCancelButton")

            Spacer()

            Button(l10n.uiString(zh: "连接", en: "Connect")) {
                submitConnection()
            }
            .buttonStyle(.borderedProminent)
            .tint(TTZipTheme.bambooGreen)
            .disabled(isConnecting)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("ConnectToServerConfirmButton")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func applySchemePrefixIfAppropriate(_ newScheme: SupportedNetworkShareScheme) {
        let trimmed = addressInput.trimmingCharacters(in: .whitespacesAndNewlines)
        for known in SupportedNetworkShareScheme.allCases where trimmed.lowercased().hasPrefix(known.defaultPrefix) {
            let suffix = String(trimmed.dropFirst(known.defaultPrefix.count))
            addressInput = newScheme.defaultPrefix + suffix
            return
        }
        if trimmed.isEmpty {
            addressInput = newScheme.defaultPrefix
        }
    }

    private func handleCancelOrClose() {
        if isConnecting {
            service.cancelActiveConnection()
        } else {
            service.resetState()
            onDismiss()
        }
    }

    private func submitConnection() {
        validationErrorMessage = nil
        switch ServerConnectionService.validateServerInput(addressInput, defaultScheme: selectedScheme) {
        case .failure(let err):
            validationErrorMessage = err.errorDescription
            return
        case .success(let endpoint):
            selectedScheme = endpoint.scheme
            addressInput = endpoint.sanitizedAddressString
        }

        let currentInput = addressInput
        let currentScheme = selectedScheme
        service.beginConnectAndNavigate(
            rawInput: currentInput,
            defaultScheme: currentScheme,
            in: viewModel,
            onDismiss: onDismiss
        )
    }
}
