// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Observation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Integrated archive configuration section view implementing progressive disclosure.
///
/// Features a compact primary format selector, middle-truncated path fields,
/// primary split-volume & encryption controls, and a collapsible drawer for
/// format-specific algorithm parameters and cleanup policies.
public struct CompressIntegratedConfigSectionView: View {
    internal enum FocusField: Hashable {
        case outputName
        case targetDirectory
        case customVolume
        case password
    }
    
    var l10n = AppLocalizationState.shared
    
    @Bindable public var session: CompressFormSession
    @State internal var isAdvancedExpanded: Bool = false
    @FocusState internal var focusedField: FocusField?
    
    public init(session: CompressFormSession) {
        self.session = session
    }
    
    internal let labelWidth: CGFloat = 74.0
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Label(l10n.t(L10n.Compress.targetParameters), systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .bold, design: .serif))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Spacer()
            }
            
            // 1. Primary Output & Core Archive Configuration (Always visible on first screen)
            VStack(alignment: .leading, spacing: 10) {
                // Name input
                HStack(spacing: 10) {
                    L10nText(L10n.Explorer.nameHeader)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                    TextField(l10n.t(L10n.Compress.archiveNamePlaceholder), text: $session.outputName)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .outputName)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                
                // Destination folder with middle truncation protection and fixed-size browse button
                HStack(spacing: 10) {
                    L10nText(L10n.Compress.targetFolder)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                    HStack(spacing: 6) {
                        TextField(l10n.t(L10n.Compress.targetFolder), text: $session.targetDirectory)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .targetDirectory)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Button(l10n.t(L10n.Common.browse)) {
                            session.pickDirectory()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
                
                // Progressive format selection (Primary pills + More formats dropdown)
                formatSelectionSection
                
                // Dual-mode compression level selector
                compressionLevelSection(fmt: session.selectedFormat)
                
                // Primary split-volume section (always visible)
                splitVolumeSection
                
                // Primary encryption section (always visible)
                encryptionSection
            }
            
            Divider()
            
            // 2. Advanced Archiving Options (Collapsible Drawer, collapsed by default)
            advancedDisclosureDrawer
        }
        .padding(14)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            session.reconcileSelectedFormatWithInputs()
        }
        .onChange(of: session.itemsList.count) { _, _ in
            session.reconcileSelectedFormatWithInputs()
        }
    }
}
