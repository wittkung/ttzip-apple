// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Observation
import TTZipCore
import AppKit
import TTZipUI

/// Full-canvas native workspace view for archive compression.
///
/// Hosted directly within the main multi-tab workstation area, replacing blocking sheets
/// with an unbounded, responsive full-height canvas and live Feeder coordination.
public struct CompressWorkspaceView: View {
    public var viewModel: AppViewState
    private var l10n = AppLocalizationState.shared
    
    public init(viewModel: AppViewState) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        @Bindable var session = viewModel.compressSession
        let isModalOverlayVisible = session.isProgressModalPresented || session.isSummarySheetPresented
        
        VStack(spacing: 0) {
            // Sub-header bar
            workspaceHeader(session: session)
            
            // Full-canvas scrollable configuration & file feeder target
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollContentBackground(.hidden)
            .background(ConfigureNSScrollView())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                workspaceBottomBar(session: session)
            }
            .opacity(isModalOverlayVisible ? 0.0 : 1.0)
            .allowsHitTesting(!isModalOverlayVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $session.isCompressionGuidePresented) {
            CompressionGuideSheetView(isPresented: $session.isCompressionGuidePresented)
        }
        .sheet(isPresented: $session.isPasswordVaultPresented) {
            passwordVaultSheet(session: session)
        }
        .overlay {
            taskProgressAndSummaryOverlay(session: session)
        }
        .onChange(of: session.selectedPresetID) { _, newID in
            if let id = newID {
                session.applyPreset(id: id)
            }
        }
    }
    
    // MARK: - Workspace Header
    
    private func workspaceHeader(session: CompressFormSession) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                L10nText(L10n.Compress.studioTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            
            Spacer(minLength: 8)
            
            HStack(spacing: 8) {
                // Preset template selector
                Menu {
                    ForEach(PresetManager.shared.presets) { preset in
                        Button {
                            session.selectedPresetID = preset.id
                        } label: {
                            HStack {
                                Text(preset.name)
                                if session.selectedPresetID == preset.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10))
                        Text(currentPresetName(session: session))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .help(l10n.t(L10n.Presets.title))
                
                // Compression Guide Button
                Button {
                    session.isCompressionGuidePresented = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(l10n.t(L10n.Compress.formatGuide))
                
                // Close Tab (x) Button
                Button {
                    viewModel.navigationState.closeCompressWorkspaceTab()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("\(l10n.t(L10n.Compress.closeStudio)) (⌘W)")
            }
            .layoutPriority(2)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.02))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: TTZipTheme.Layout.hairlineBorderWidth)
        }
    }
    
    // MARK: - Workspace Bottom Bar
    
    private func workspaceBottomBar(session: CompressFormSession) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(TTZipTheme.hairlineBorder)
                .frame(height: TTZipTheme.Layout.hairlineBorderWidth)
            
            HStack(spacing: 8) {
                bottomBarStatus(session: session)
                Spacer(minLength: 8)
                bottomBarActions(session: session)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .background(.ultraThinMaterial)
    }
    
    private func bottomBarStatus(session: CompressFormSession) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.grid.2x2.fill")
                .font(.system(size: 10))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text(l10n.plural(key: L10n.Units.itemsCount, count: session.itemsList.count) + " · " + l10n.formatBytes(session.totalSizeBytes))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            
            if session.isProcessing && !session.isProgressModalPresented {
                Button {
                    session.isProgressModalPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.needle.fill")
                            .font(.system(size: 9))
                        Text(l10n.uiString(zh: "查看进度", en: "Show Progress", zhHant: "查看進度", ja: "進行状況を表示", ko: "진행 상황 보기", de: "Fortschritt anzeigen", fr: "Afficher la progression", es: "Mostrar progreso"))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(TTZipTheme.bambooGreen.opacity(0.15))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .lineLimit(1)
        .layoutPriority(1)
    }
    
    private func bottomBarActions(session: CompressFormSession) -> some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.navigationState.closeCompressWorkspaceTab() }) {
                Text(l10n.t(L10n.Common.cancel))
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .lineLimit(1)
            
            Button(action: { session.startCompression() }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(l10n.t(L10n.Compress.startAction))
                        .font(.system(size: 11.5, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(TTZipTheme.bambooGradient)
                .clipShape(Capsule())
                .shadow(color: TTZipTheme.bambooGreen.opacity(0.3), radius: 4, x: 0, y: 2)
                .opacity(canStartCompression(session: session) ? 1.0 : 0.55)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canStartCompression(session: session))
            .lineLimit(1)
            .layoutPriority(2)
            .help(l10n.t(L10n.Compress.startAction) + " (⌘↵)")
        }
        .lineLimit(1)
        .layoutPriority(2)
    }
    
    // MARK: - Overlays
    
    @ViewBuilder
    private func taskProgressAndSummaryOverlay(session: CompressFormSession) -> some View {
        CompressProgressPresenter(session: session)
        
        if session.isSummarySheetPresented, let summary = session.completedSummary {
            CompressionSummarySheetView(
                archivePath: summary.archivePath,
                originalSizeBytes: summary.originalBytes,
                compressedSizeBytes: summary.compressedBytes,
                elapsedSeconds: summary.elapsedSeconds,
                throughputMBs: summary.throughputMBs,
                format: summary.format,
                isEncrypted: summary.isEncrypted,
                cleanupWarningMessage: summary.cleanupWarningMessage,
                sourcePreservationNotice: summary.sourcePreservationNotice,
                onCloseAndExplore: {
                    if let taskId = summary.taskId {
                        ArchiveOperationsQueueCenter.shared.acknowledgeResult(id: taskId)
                    }
                    session.isSummarySheetPresented = false
                    viewModel.navigationState.closeCompressWorkspaceTab()
                    viewModel.openArchiveAsFolder(url: URL(fileURLWithPath: summary.archivePath))
                }
            )
        }
    }
    
    private func canStartCompression(session: CompressFormSession) -> Bool {
        if session.isProcessing || session.itemsList.isEmpty || session.outputName.isEmpty {
            return false
        }
        if session.enableEncryption && session.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    private func currentPresetName(session: CompressFormSession) -> String {
        if let id = session.selectedPresetID, let preset = PresetManager.shared.presets.first(where: { $0.id == id }) {
            return preset.name
        }
        return l10n.t(L10n.Presets.customPreset)
    }
    
    private func passwordVaultSheet(session: CompressFormSession) -> some View {
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

/// Independent progress presenter isolating 60Hz compression progress updates
/// from the host form and list hierarchy to eliminate over-invalidation.
struct CompressProgressPresenter: View {
    let session: CompressFormSession
    
    var body: some View {
        if session.isProgressModalPresented {
            CompressionProgressModalView(
                outputFileName: "\(session.outputName).\(session.selectedFormat.rawValue)",
                progress: session.currentProgress,
                isCancellationRequested: session.isCancellationRequested,
                onCancel: {
                    session.cancelCompression()
                },
                onMinimize: { session.isProgressModalPresented = false }
            )
        }
    }
}

