// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipPluginKit
import TTZipCore

/// 通用插件安全凭证配置模态窗口
public struct PluginConfigSheetView: View {
    public let pluginId: String
    @Binding public var isPresented: Bool
    
    @StateObject private var store: PluginConfigStore
    @State private var newKeyName: String = ""
    @State private var newKeyIsSecure: Bool = true
    @State private var showAddKeySection: Bool = false
    
    private var pluginLocale: PluginLocale {
        AppLocalizationState.shared.currentLanguage == .zhHans ? .zhHans : .en
    }
    
    public init(pluginId: String, isPresented: Binding<Bool>) {
        self.pluginId = pluginId
        self._isPresented = isPresented
        self._store = StateObject(wrappedValue: PluginConfigStore(pluginId: pluginId))
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            Text(PluginL10n.configTitle(locale: pluginLocale))
                .font(TTZipTheme.Typography.title1)
            
            Text(PluginL10n.configDesc(locale: pluginLocale))
                .font(TTZipTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if store.isLoading {
                ProgressView()
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach($store.entries) { $entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.label)
                                        .font(TTZipTheme.Typography.caption)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Button(action: {
                                        entry.isSecure.toggle()
                                    }) {
                                        Image(systemName: entry.isSecure ? "eye.slash" : "eye")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                if entry.isSecure {
                                    SecureField(entry.placeholder, text: $entry.value)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    TextField(entry.placeholder, text: $entry.value)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                        
                        if showAddKeySection {
                            VStack(alignment: .leading, spacing: 6) {
                                Divider().padding(.vertical, 4)
                                Text("Custom Key:")
                                    .font(TTZipTheme.Typography.caption)
                                HStack {
                                    TextField("e.g. endpoint_url", text: $newKeyName)
                                        .textFieldStyle(.roundedBorder)
                                    Button(action: {
                                        store.addEntry(key: newKeyName, isSecure: newKeyIsSecure)
                                        newKeyName = ""
                                        showAddKeySection = false
                                    }) {
                                        Text("Add")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(newKeyName.isEmpty)
                                }
                            }
                        } else {
                            Button(action: { showAddKeySection = true }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus.circle")
                                    Text("Add Custom Field")
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(TTZipTheme.bambooGreen)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 280)
            }
            
            HStack(spacing: 12) {
                Button(PluginL10n.cancel(locale: pluginLocale)) {
                    isPresented = false
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button(PluginL10n.saveToKeychain(locale: pluginLocale)) {
                    Task {
                        try? await store.saveEntries()
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(TTZipTheme.kintsugiGold)
                .disabled(store.isSaving)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 420)
        .task {
            await store.loadEntries()
        }
    }
}
