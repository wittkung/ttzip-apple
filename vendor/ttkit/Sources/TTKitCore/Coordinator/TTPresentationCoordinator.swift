// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation

/// Base observable coordinator managing modal presentations conforming to TTKit Architecture Spec §6.
@MainActor
@Observable
open class TTPresentationCoordinator<ModalType: Sendable & Equatable & Identifiable> {
    public var activeModal: ModalType? = nil

    public init(initialModal: ModalType? = nil) {
        self.activeModal = initialModal
    }

    open func present(_ modal: ModalType) {
        self.activeModal = modal
    }

    open func dismiss() {
        self.activeModal = nil
    }

    public var isModalActive: Bool {
        activeModal != nil
    }
}
