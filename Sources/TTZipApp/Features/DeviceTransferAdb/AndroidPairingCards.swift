// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

// MARK: - Wireless Status Badges

/// Compact status pill indicating wireless connection or pairing state.
public struct WirelessStatusBadge: View {
    public enum State: Sendable, Equatable {
        case ready
        case pairing
        case connected
        case failed
        case idle
    }
    
    public let state: State
    private var l10n = AppLocalizationState.shared
    
    public init(state: State) {
        self.state = state
    }
    
    public var body: some View {
        let (title, bg, fg): (String, Color, Color) = {
            switch state {
            case .ready, .connected:
                return (l10n.t(L10n.AndroidInterconnect.wirelessStatusReady), TTZipTheme.bambooGreen.opacity(0.12), TTZipTheme.bambooGreen)
            case .pairing:
                return (l10n.t(L10n.AndroidInterconnect.wirelessStatusPairing), TTZipTheme.kintsugiGold.opacity(0.15), TTZipTheme.kintsugiGold)
            case .failed:
                return (l10n.t(L10n.AndroidInterconnect.wirelessStatusFailed), TTZipTheme.cinnabarRed.opacity(0.12), TTZipTheme.cinnabarRed)
            case .idle:
                return (l10n.t(L10n.AndroidInterconnect.wirelessStatusIdle), Color.primary.opacity(0.06), Color.secondary)
            }
        }()
        
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg)
            .clipShape(Capsule())
    }
}

/// Security indicator badge reflecting actual ADB Smart Socket `host:pair` handshake.
public struct PairingSecurityBadge: View {
    public init() {}
    
    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 11))
                .foregroundStyle(TTZipTheme.bambooGreen)
            L10nText(L10n.AndroidInterconnect.pairingSecurityBadge)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03))
        .clipShape(Capsule())
    }
}

// MARK: - State Cards

/// Card presenting ongoing handshake progress and active negotiation step.
public struct PairingProgressCard: View {
    public let step: String
    public let hostAddress: String
    public let portString: String
    
    private var l10n = AppLocalizationState.shared
    
    public init(step: String, hostAddress: String, portString: String) {
        self.step = step
        self.hostAddress = hostAddress
        self.portString = portString
    }
    
    public var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.3)
                .padding(.top, 24)
            
            VStack(spacing: 8) {
                L10nText(L10n.Device.pairingInProgress)
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                
                Text(step)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                
                Text("\(hostAddress):\(portString)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            
            PairingSecurityBadge()
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: TTZipUniversalTokens.Border.width)
        )
    }
}

/// Card indicating successful wireless pairing completion and device registration.
public struct PairingSuccessCard: View {
    public let deviceName: String
    private var l10n = AppLocalizationState.shared
    
    public init(deviceName: String) {
        self.deviceName = deviceName
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(TTZipTheme.bambooGreen.opacity(0.15))
                    .frame(width: 56, height: 56)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            .padding(.top, 24)
            
            VStack(spacing: 6) {
                L10nText(L10n.Device.pairingSuccess)
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                
                Text(deviceName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                
                L10nText(L10n.Device.pairingSuccessDesc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(TTZipTheme.bambooGreen.opacity(0.3), lineWidth: 0.5)
        )
    }
}

/// Card displaying pairing error details with actionable recovery instructions.
public struct PairingFailureCard: View {
    public let reason: String
    private var l10n = AppLocalizationState.shared
    
    public init(reason: String) {
        self.reason = reason
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(TTZipTheme.cinnabarRed.opacity(0.15))
                    .frame(width: 56, height: 56)
                
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(TTZipTheme.cinnabarRed)
            }
            .padding(.top, 24)
            
            VStack(spacing: 8) {
                L10nText(L10n.Device.pairingFailed)
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                
                Text(reason)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(TTZipTheme.cinnabarRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                
                L10nText(L10n.Device.pairingFailedDesc)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(TTZipTheme.cinnabarRed.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Instruction & Device Cards

/// Step-by-step guidance banner detailing operations required on Android phone.
public struct PairingInstructionBanner: View {
    private var l10n = AppLocalizationState.shared
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            L10nText(L10n.Device.phoneStepsTitle)
                .font(.system(size: 11.5, weight: .bold, design: .serif))
                .foregroundStyle(.primary)
            
            L10nText(L10n.Device.phoneStepsDesc)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            L10nText(L10n.AndroidInterconnect.pairingQrCapabilityNotice)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: TTZipUniversalTokens.Border.width)
        )
    }
}

/// Card presenting a discovered wireless device endpoint with connection status.
public struct PairingDeviceCard: View {
    public let endpoint: DiscoveredWirelessEndpoint
    public var isSelected: Bool
    public var onSelect: (() -> Void)?
    
    private var l10n = AppLocalizationState.shared
    
    public init(
        endpoint: DiscoveredWirelessEndpoint,
        isSelected: Bool = false,
        onSelect: (() -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.isSelected = isSelected
        self.onSelect = onSelect
    }
    
    public var body: some View {
        Button(action: { onSelect?() }) {
            HStack(spacing: 10) {
                Image(systemName: endpoint.isPaired ? "iphone.badge.play" : "wifi.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(endpoint.isPaired ? TTZipTheme.bambooGreen : TTZipTheme.kintsugiGold)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(endpoint.deviceModel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        
                        WirelessStatusBadge(state: endpoint.isPaired ? .ready : .pairing)
                    }
                    
                    Text("\(endpoint.host):\(endpoint.port)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? TTZipTheme.bambooGreen.opacity(0.06) : Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? TTZipTheme.bambooGreen.opacity(0.3) : Color.primary.opacity(0.06),
                        lineWidth: isSelected ? 1.0 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

/// List presentation for discovered wireless endpoints available for pairing.
public struct DiscoveredPairingListView: View {
    public let endpoints: [DiscoveredWirelessEndpoint]
    public let selectedEndpoint: DiscoveredWirelessEndpoint?
    public let onSelect: (DiscoveredWirelessEndpoint) -> Void
    
    public init(
        endpoints: [DiscoveredWirelessEndpoint],
        selectedEndpoint: DiscoveredWirelessEndpoint? = nil,
        onSelect: @escaping (DiscoveredWirelessEndpoint) -> Void
    ) {
        self.endpoints = endpoints
        self.selectedEndpoint = selectedEndpoint
        self.onSelect = onSelect
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            ForEach(endpoints) { endpoint in
                PairingDeviceCard(
                    endpoint: endpoint,
                    isSelected: selectedEndpoint?.id == endpoint.id,
                    onSelect: { onSelect(endpoint) }
                )
            }
        }
    }
}
