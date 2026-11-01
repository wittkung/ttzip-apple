// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Observation
import TTZipUI

/// Sidebar and popover view presenting local Wi-Fi wireless Android device discovery,
/// saved pairings, direct IP connect, and trigger for 6-digit PIN code pairing.
public struct WirelessDeviceDiscoveryView: View {
    @Bindable public var viewModel: AndroidDeviceViewModel
    @Environment(\.dismiss) private var dismiss
    
    private var l10n = AppLocalizationState.shared
    
    @State private var coordinator = WirelessMdnsCoordinator()
    @State private var showManualConnect: Bool = false
    @State private var manualHost: String = ""
    @State private var manualPort: String = "5555"
    @State private var showPairingSheetInternal: Bool = false
    @State private var selectedEndpointForPairing: DiscoveredWirelessEndpoint? = nil
    
    @MainActor
    public init(viewModel: AndroidDeviceViewModel = .shared) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            headerSection
            Rectangle().fill(TTZipTheme.hairlineBorder).frame(height: TTZipTheme.Layout.hairlineBorderWidth)
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    discoveryHeader
                    if coordinator.discoveredEndpoints.isEmpty {
                        emptyDiscoveryState
                    } else {
                        endpointList
                    }
                    Divider().padding(.vertical, 4)
                    manualConnectSection
                }
                .padding(20)
            }
            Divider()
            footerSection
        }
        .frame(width: 450, height: 490)
        .ttOverlayGlassPlate(cornerRadius: 18)
        .sheet(isPresented: $showPairingSheetInternal) {
            AndroidPairingSheet(
                isPresented: $showPairingSheetInternal,
                viewModel: viewModel,
                initialHost: selectedEndpointForPairing?.host ?? "",
                initialPort: selectedEndpointForPairing?.port
            )
        }
        .task { coordinator.startScanning() }
        .onDisappear { coordinator.stopScanning() }
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(TTZipTheme.kintsugiGold.opacity(0.18)).frame(width: 32, height: 32)
                Image(systemName: "wifi").font(.system(size: 14, weight: .bold)).foregroundStyle(TTZipTheme.kintsugiGold)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Wireless Device Discovery"))
                    .font(.system(size: 14, weight: .bold, design: .serif)).foregroundStyle(.primary)
                Text(String(localized: "Auto-discovering Android devices broadcasting mDNS on local Wi-Fi"))
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).background(Color.primary.opacity(0.04)).clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close"))
        }
        .padding(.horizontal, 18).frame(height: 56)
    }
    
    private var discoveryHeader: some View {
        HStack {
            Text(String(localized: "Nearby Discovered Devices"))
                .font(.system(size: 11.5, weight: .bold, design: .serif)).foregroundStyle(.primary)
            Spacer()
            if coordinator.isScanning {
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.6)
                    Text("mDNS Scanning...").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Button(action: { coordinator.refresh() }) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium)).foregroundStyle(TTZipTheme.kintsugiGold)
                    .frame(width: 20, height: 20).background(TTZipTheme.kintsugiGold.opacity(0.08)).clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Refresh mDNS broadcast"))
            .accessibilityLabel(String(localized: "Refresh mDNS broadcast"))
        }
    }
    
    private var emptyDiscoveryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 28, weight: .light)).foregroundStyle(TTZipTheme.kintsugiGold.opacity(0.7)).padding(.top, 8)
            VStack(spacing: 4) {
                Text(String(localized: "Listening for Wireless ADB Devices..."))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                Text(String(localized: "Ensure device and Mac share the same Wi-Fi with 'Wireless Debugging' enabled"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5))
    }
    
    private var endpointList: some View {
        VStack(spacing: 8) {
            ForEach(coordinator.discoveredEndpoints) { endpoint in
                endpointRow(endpoint: endpoint)
            }
        }
    }
    
    private func endpointRow(endpoint: DiscoveredWirelessEndpoint) -> some View {
        HStack(spacing: 10) {
            Image(systemName: endpoint.isPaired ? "iphone.badge.play" : "wifi.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(endpoint.isPaired ? TTZipTheme.bambooGreen : TTZipTheme.kintsugiGold)
                .frame(width: 28, height: 28).background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(endpoint.deviceModel).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                    Text(endpoint.isPaired ? "Ready" : "Pairing")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(endpoint.isPaired ? TTZipTheme.bambooGreen : TTZipTheme.kintsugiGold)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background((endpoint.isPaired ? TTZipTheme.bambooGreen : TTZipTheme.kintsugiGold).opacity(0.12))
                        .clipShape(Capsule())
                }
                Text("\(endpoint.host):\(endpoint.port)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if endpoint.isPaired {
                Button(action: { connectToEndpoint(endpoint) }) {
                    Text(String(localized: "Connect"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4.5)
                        .background(TTZipTheme.bambooGreen).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    selectedEndpointForPairing = endpoint
                    showPairingSheetInternal = true
                }) {
                    Text(String(localized: "Pair"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                        .padding(.horizontal, 10).padding(.vertical, 4.5)
                        .background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
    
    private var manualConnectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showManualConnect.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: showManualConnect ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                    Text(String(localized: "Manual Direct IP Connect (Bypass mDNS)"))
                        .font(.system(size: 11, weight: .medium, design: .serif)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            
            if showManualConnect {
                HStack(spacing: 8) {
                    TextField("192.168.1.xxx", text: $manualHost)
                        .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).padding(6)
                        .background(Color.primary.opacity(0.03)).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    Text(":").foregroundStyle(.secondary)
                    TextField("5555", text: $manualPort)
                        .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).padding(6).frame(width: 60)
                        .background(Color.primary.opacity(0.03)).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    Button(action: connectManual) {
                        Text(String(localized: "Connect"))
                            .font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain).disabled(manualHost.isEmpty)
                }
            }
        }
    }
    
    private var footerSection: some View {
        HStack {
            Spacer()
            Button(action: {
                selectedEndpointForPairing = nil
                showPairingSheetInternal = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text(String(localized: "Pair New Device (6-Digit PIN)"))
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 7).background(TTZipTheme.kintsugiGold)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: TTZipTheme.kintsugiGold.opacity(0.3), radius: 2, y: 1)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18).frame(height: 52).background(Color.primary.opacity(0.02))
    }
    
    private func connectToEndpoint(_ endpoint: DiscoveredWirelessEndpoint) {
        let device = endpoint.asAndroidDevice()
        viewModel.registerDevice(device)
        viewModel.selectDevice(device)
        dismiss()
    }
    
    private func connectManual() {
        guard let port = UInt16(manualPort) else { return }
        let endpoint = DiscoveredWirelessEndpoint(
            host: manualHost,
            port: port,
            deviceModel: "Android Device",
            isPaired: true
        )
        connectToEndpoint(endpoint)
    }
}
