// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
@testable import TTKitCore
@testable import TTKitDesign
@testable import TTKitFluid
@testable import TTKitUI
@testable import TTKit

final class TTKitWorkspaceTests: XCTestCase {

    // MARK: - Inspector Surface Mode Tests

    func testInspectorSurfaceModePredicates() {
        let emptyMode: TTInspectorSurfaceMode<String, Int, Double> = .empty
        XCTAssertTrue(emptyMode.isEmpty)
        XCTAssertFalse(emptyMode.isSingle)
        XCTAssertFalse(emptyMode.isMultiple)
        XCTAssertFalse(emptyMode.isWorkspace)

        let singleMode: TTInspectorSurfaceMode<String, Int, Double> = .single(item: "document.pdf")
        XCTAssertFalse(singleMode.isEmpty)
        XCTAssertTrue(singleMode.isSingle)
        XCTAssertFalse(singleMode.isMultiple)
        XCTAssertFalse(singleMode.isWorkspace)

        let multipleMode: TTInspectorSurfaceMode<String, Int, Double> = .multiple(metrics: 42)
        XCTAssertFalse(multipleMode.isEmpty)
        XCTAssertFalse(multipleMode.isSingle)
        XCTAssertTrue(multipleMode.isMultiple)
        XCTAssertFalse(multipleMode.isWorkspace)

        let workspaceMode: TTInspectorSurfaceMode<String, Int, Double> = .workspace(context: 3.14)
        XCTAssertFalse(workspaceMode.isEmpty)
        XCTAssertFalse(workspaceMode.isSingle)
        XCTAssertFalse(workspaceMode.isMultiple)
        XCTAssertTrue(workspaceMode.isWorkspace)
    }

    func testInspectorSurfaceModeEquality() {
        let a: TTInspectorSurfaceMode<String, Int, Double> = .single(item: "a")
        let b: TTInspectorSurfaceMode<String, Int, Double> = .single(item: "a")
        let c: TTInspectorSurfaceMode<String, Int, Double> = .single(item: "b")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Presentation Coordinator Tests

    private enum TestModal: String, Sendable, Equatable, Identifiable {
        case archiveInspector
        case extractProgress
        case passwordPrompt

        var id: String { rawValue }
    }

    @MainActor
    func testPresentationCoordinatorLifecycle() {
        let coordinator = TTPresentationCoordinator<TestModal>()
        XCTAssertNil(coordinator.activeModal)
        XCTAssertFalse(coordinator.isModalActive)

        coordinator.present(.archiveInspector)
        XCTAssertEqual(coordinator.activeModal, .archiveInspector)
        XCTAssertTrue(coordinator.isModalActive)

        coordinator.present(.extractProgress)
        XCTAssertEqual(coordinator.activeModal, .extractProgress)

        coordinator.dismiss()
        XCTAssertNil(coordinator.activeModal)
        XCTAssertFalse(coordinator.isModalActive)
    }

    // MARK: - Workspace Scaffold Tests

    @MainActor
    func testWorkspaceScaffoldInstantiation() {
        let scaffold = TTWorkspaceScaffold(
            title: "Test Workspace",
            isCardEnclosed: true,
            isEdgeToEdge: false
        ) {
            Text("Trailing Action")
        } content: {
            Text("Main Body Content")
        }

        XCTAssertEqual(scaffold.title, "Test Workspace")
        XCTAssertTrue(scaffold.isCardEnclosed)
        XCTAssertFalse(scaffold.isEdgeToEdge)
    }

    @MainActor
    func testWorkspaceScaffoldEdgeToEdge() {
        let scaffold = TTWorkspaceScaffold(
            isCardEnclosed: false,
            isEdgeToEdge: true
        ) {
            Text("Header Leading")
        } headerTrailing: {
            Text("Header Trailing")
        } content: {
            Text("Body")
        }

        XCTAssertFalse(scaffold.isCardEnclosed)
        XCTAssertTrue(scaffold.isEdgeToEdge)
    }

    // MARK: - Three Column Workspace Tests

    @MainActor
    func testThreeColumnWorkspaceInstantiation() {
        var sidebarVisible = true
        var iconRail = false
        var inspectorVisible = true

        let bindingSidebar = Binding(get: { sidebarVisible }, set: { sidebarVisible = $0 })
        let bindingRail = Binding(get: { iconRail }, set: { iconRail = $0 })
        let bindingInspector = Binding(get: { inspectorVisible }, set: { inspectorVisible = $0 })

        let workspace = TTThreeColumnWorkspace(
            isSidebarVisible: bindingSidebar,
            isIconRail: bindingRail,
            isInspectorVisible: bindingInspector
        ) {
            Text("Sidebar")
        } content: {
            Text("Content")
        } inspector: {
            Text("Inspector")
        }

        _ = workspace
    }

    // MARK: - Brand Identity View Tests

    @MainActor
    func testBrandIdentityViewExpandedAndRail() {
        var settingsOpened = false
        let expanded = TTBrandIdentityView(
            title: "TTZip",
            badgeText: "PRO",
            isIconRail: false,
            onOpenSettings: { settingsOpened = true }
        )
        XCTAssertEqual(expanded.title, "TTZip")
        XCTAssertEqual(expanded.badgeText, "PRO")
        XCTAssertFalse(expanded.isIconRail)

        let collapsed = TTBrandIdentityView(
            title: "TTZip",
            isIconRail: true
        )
        XCTAssertTrue(collapsed.isIconRail)

        expanded.onOpenSettings?()
        XCTAssertTrue(settingsOpened)
    }

    // MARK: - Embedded Omnibar & Search Capsule Tests

    @MainActor
    func testEmbeddedOmnibarInstantiation() {
        let omnibar = TTEmbeddedOmnibar {
            Text("Back / Forward")
        } center: {
            Text("Address Bar")
        } trailing: {
            Text("Quick Actions")
        }
        _ = omnibar
    }

    @MainActor
    func testSearchCapsuleViewInstantiation() {
        var query = "search text"
        let binding = Binding(get: { query }, set: { query = $0 })
        var committed = false

        let capsule = TTSearchCapsuleView(
            searchText: binding,
            placeholder: "Search archive...",
            isCompactIcon: false,
            onCommit: { committed = true }
        )
        XCTAssertEqual(capsule.placeholder, "Search archive...")
        XCTAssertFalse(capsule.isCompactIcon)

        capsule.onCommit?()
        XCTAssertTrue(committed)

        let compactCapsule = TTSearchCapsuleView(
            searchText: binding,
            isCompactIcon: true
        )
        XCTAssertTrue(compactCapsule.isCompactIcon)
    }
}
