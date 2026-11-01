// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore

public struct TabLifecycleModifier: ViewModifier {
    let isActive: Bool
    let payload: TabActivationPayload
    let onActivate: (TabActivationPayload) -> Void
    let onDeactivate: () -> Void
    
    public func body(content: Content) -> some View {
        content
            .onChange(of: isActive) { wasActive, nowActive in
                if nowActive {
                    onActivate(payload)
                } else if wasActive {
                    onDeactivate()
                }
            }
            .onChange(of: payload) { _, newPayload in
                if isActive {
                    onActivate(newPayload)
                }
            }
            .onAppear {
                if isActive {
                    onActivate(payload)
                }
            }
    }
}

extension View {
    public func onTabLifecycle(
        isActive: Bool,
        payload: TabActivationPayload = .none,
        onActivate: @escaping (TabActivationPayload) -> Void,
        onDeactivate: @escaping () -> Void = {}
    ) -> some View {
        self.modifier(TabLifecycleModifier(
            isActive: isActive,
            payload: payload,
            onActivate: onActivate,
            onDeactivate: onDeactivate
        ))
    }
}
