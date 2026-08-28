// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import Observation
import TTZipCore
import AppKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

public struct CompressModalView: View {
    @ObservedObject var l10n = AppLocalizationState.shared
    @Binding public var isPresented: Bool
    public let initialInputPaths: [String]
    public var onCompleteOpenArchive: ((String) -> Void)? = nil
    
    @State private var session: CompressFormSession
    
    public init(
        isPresented: Binding<Bool>,
        initialInputPaths: [String],
        onCompleteOpenArchive: ((String) -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self.initialInputPaths = initialInputPaths
        self.onCompleteOpenArchive = onCompleteOpenArchive
        self._session = State(initialValue: CompressFormSession(initialInputPaths: initialInputPaths))
    }
    
    public var body: some View {
        @Bindable var session = session
        
        VStack(spacing: 0) {
            CompressModalHeaderView(
                selectedPresetID: $session.selectedPresetID,
                onOpenGuide: { session.isCompressionGuidePresented = true },
                onClose: { isPresented = false }
            )
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CompressFileListView(
                        itemsList: $session.itemsList,
                        selectedItemIDs: $session.selectedItemIDs,
                        totalSizeBytes: session.totalSizeBytes,
                        onAddFiles: { session.pickFiles() },
                        onAddFolder: { session.pickFolders() },
                        onClearAll: { session.itemsList.removeAll() },
                        onRemoveSelected: { session.removeSelectedItems() }
                    )
                    
                    CompressIntegratedConfigSectionView(session: session)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            
            Divider()
            
            modalBottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !initialInputPaths.isEmpty {
                session.loadInputPaths(initialInputPaths)
            }
        }
        .onChange(of: initialInputPaths) { _, newPaths in
            if !newPaths.isEmpty {
                session.loadInputPaths(newPaths)
            }
        }
        .sheet(isPresented: $session.isCompressionGuidePresented) {
            CompressionGuideSheetView(isPresented: $session.isCompressionGuidePresented)
        }
        .sheet(isPresented: $session.isPasswordVaultPresented) {
            passwordVaultSheet
        }
        .overlay {
            taskProgressAndSummaryOverlay
        }
        .onChange(of: session.selectedPresetID) { _, newID in
            if let id = newID {
                session.applyPreset(id: id)
            }
        }
    }
    
    private var modalBottomBar: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "circle.grid.2x2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text(l10n.plural(key: L10n.Units.itemsCount, count: session.itemsList.count) + " · " + l10n.formatBytes(session.totalSizeBytes))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: { isPresented = false }) {
                Text(l10n.t(L10n.Common.cancel))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            
            Button(action: { session.startCompression() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(l10n.t(L10n.Compress.startAction) + " (⌘↵)")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(TTZipTheme.bambooGradient)
                .clipShape(Capsule())
                .shadow(color: TTZipTheme.bambooGreen.opacity(0.3), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(session.isProcessing || session.itemsList.isEmpty || session.outputName.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    private var taskProgressAndSummaryOverlay: some View {
        if session.isProgressModalPresented {
            CompressionProgressModalView(
                outputFileName: "\(session.outputName).\(session.selectedFormat.rawValue)",
                progress: session.currentProgress,
                onCancel: {
                    session.cancelCompression()
                },
                onMinimize: { session.isProgressModalPresented = false }
            )
        } else if session.isSummarySheetPresented, let summary = session.completedSummary {
            CompressionSummarySheetView(
                archivePath: summary.archivePath,
                originalSizeBytes: summary.originalBytes,
                compressedSizeBytes: summary.compressedBytes,
                elapsedSeconds: summary.elapsedSeconds,
                throughputMBs: summary.throughputMBs,
                format: summary.format,
                isEncrypted: summary.isEncrypted,
                onCloseAndExplore: {
                    session.isSummarySheetPresented = false
                    isPresented = false
                    onCompleteOpenArchive?(summary.archivePath)
                }
            )
        }
    }
    
    private var passwordVaultSheet: some View {
        VStack {
            HStack {
                Spacer()
                Button(l10n.t(L10n.Common.close)) { session.isPasswordVaultPresented = false }
            }
            .padding()
            PasswordVaultView(onSelectPassword: { pwd in
                session.enableEncryption = true
                session.password = pwd
                session.isPasswordVaultPresented = false
            })
        }
        .frame(width: 600, height: 400)
    }
}
