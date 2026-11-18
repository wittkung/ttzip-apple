// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTKitUI

// MARK: - Collision Prompt State Container

/// Immutable payload representing an active forensic collision prompt in the UI.
public struct CollisionPrompt: Identifiable, Sendable {
    public let id: UUID
    public let sourceFile: ConflictFileDescriptor
    public let targetFile: ConflictFileDescriptor
    public let conflictIndex: Int
    public let totalConflicts: Int
    public let resolver: @Sendable (ConflictResolutionAction, Bool) -> Void

    public init(
        id: UUID = UUID(),
        sourceFile: ConflictFileDescriptor,
        targetFile: ConflictFileDescriptor,
        conflictIndex: Int,
        totalConflicts: Int,
        resolver: @escaping @Sendable (ConflictResolutionAction, Bool) -> Void
    ) {
        self.id = id
        self.sourceFile = sourceFile
        self.targetFile = targetFile
        self.conflictIndex = conflictIndex
        self.totalConflicts = totalConflicts
        self.resolver = resolver
    }
}

// MARK: - Thread-Safe Continuation Box

private final class ResolverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var isResumed = false
    private let continuation: CheckedContinuation<(ConflictResolutionAction, Bool)?, Never>

    init(continuation: CheckedContinuation<(ConflictResolutionAction, Bool)?, Never>) {
        self.continuation = continuation
    }

    func resolve(action: ConflictResolutionAction, applyAll: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !isResumed else { return }
        isResumed = true
        continuation.resume(returning: (action, applyAll))
    }
}

// MARK: - Collision Prompt Presenter

/// Paging decision provider presenting interactive forensic conflict resolution dialogs.
/// Implements `CollisionDecisionProvider` using 1024-entry lazy chunk fetching.
@MainActor
public final class CollisionPromptPresenter: CollisionDecisionProvider {
    public typealias PromptDisplayHandler = @MainActor @Sendable (CollisionPrompt?) -> Void

    private let destinationRoot: String
    private let displayPrompt: PromptDisplayHandler

    public init(
        destinationRoot: String = "",
        displayPrompt: @escaping PromptDisplayHandler
    ) {
        self.destinationRoot = destinationRoot
        self.displayPrompt = displayPrompt
    }

    @MainActor
    public func decide(
        summary: ConflictSummary,
        fetch: @escaping @Sendable (UInt32, UInt32) async throws -> ConflictPage
    ) async -> ResolutionSet? {
        guard summary.total > 0 else {
            return ResolutionSet(defaultAction: .keepBoth, overrides: [])
        }

        var overrides: [ResolutionOverride] = []
        var currentIndex: UInt32 = 0
        let pageSize: UInt32 = 1024

        var currentPage: ConflictPage? = nil
        var pageOffset: UInt32 = 0

        defer {
            displayPrompt(nil)
        }

        while currentIndex < summary.total {
            if currentPage == nil || (currentIndex >= pageOffset + UInt32(currentPage?.records.count ?? 0)) {
                do {
                    pageOffset = currentIndex
                    currentPage = try await fetch(pageOffset, pageSize)
                } catch {
                    return nil
                }
            }

            guard let page = currentPage, !page.records.isEmpty else {
                break
            }

            let localIndex = Int(currentIndex - pageOffset)
            guard localIndex < page.records.count else {
                break
            }

            let record = page.records[localIndex]
            let srcDescriptor = makeSourceDescriptor(record: record)
            let dstDescriptor = makeTargetDescriptor(record: record)

            let resolution = await promptUser(
                source: srcDescriptor,
                target: dstDescriptor,
                index: Int(currentIndex + 1),
                total: Int(summary.total)
            )

            guard let (action, applyAll) = resolution else {
                return nil
            }

            guard let collisionAction = mapAction(action) else {
                return nil
            }

            if applyAll {
                return ResolutionSet(defaultAction: collisionAction, overrides: overrides)
            } else {
                overrides.append(ResolutionOverride(conflictId: record.id, action: collisionAction))
                currentIndex += 1
            }
        }

        return ResolutionSet(defaultAction: nil, overrides: overrides)
    }

    // MARK: - Prompt Presentation Helper

    @MainActor
    private func promptUser(
        source: ConflictFileDescriptor,
        target: ConflictFileDescriptor,
        index: Int,
        total: Int
    ) async -> (ConflictResolutionAction, Bool)? {
        await withCheckedContinuation { continuation in
            let box = ResolverBox(continuation: continuation)
            let prompt = CollisionPrompt(
                sourceFile: source,
                targetFile: target,
                conflictIndex: index,
                totalConflicts: total,
                resolver: { action, applyAll in
                    box.resolve(action: action, applyAll: applyAll)
                }
            )
            self.displayPrompt(prompt)
        }
    }

    // MARK: - Descriptor Mapping Helpers

    private func makeSourceDescriptor(record: CollisionRecord) -> ConflictFileDescriptor {
        let name = (record.relativePath as NSString).lastPathComponent
        let path = destinationRoot.isEmpty ? record.relativePath : (destinationRoot as NSString).appendingPathComponent(record.relativePath)
        let isDir = record.incoming.kind == .directory
        let icon = isDir ? "folder.fill" : "doc.fill"
        let kind: ConflictKindDisplay = record.kind == .typeMismatch ? .typeMismatch : .sameType
        let date = Date(timeIntervalSince1970: TimeInterval(record.incoming.mtimeUnixNs) / 1_000_000_000.0)
        return ConflictFileDescriptor(
            fileName: name,
            relativePath: record.relativePath,
            filePath: path,
            byteSize: Int64(record.incoming.size),
            modificationDate: date,
            isDirectory: isDir,
            iconSystemName: icon,
            conflictKind: kind
        )
    }

    private func makeTargetDescriptor(record: CollisionRecord) -> ConflictFileDescriptor {
        let name = record.existingName
        let parent = (record.relativePath as NSString).deletingLastPathComponent
        let rel = parent.isEmpty ? name : (parent as NSString).appendingPathComponent(name)
        let path = destinationRoot.isEmpty ? rel : (destinationRoot as NSString).appendingPathComponent(rel)
        let isDir = record.existing.kind == .directory
        let icon = isDir ? "folder.fill" : "doc.fill"
        let kind: ConflictKindDisplay = record.kind == .typeMismatch ? .typeMismatch : .sameType
        let date = Date(timeIntervalSince1970: TimeInterval(record.existing.mtimeUnixNs) / 1_000_000_000.0)
        return ConflictFileDescriptor(
            fileName: name,
            relativePath: rel,
            filePath: path,
            byteSize: Int64(record.existing.size),
            modificationDate: date,
            isDirectory: isDir,
            iconSystemName: icon,
            conflictKind: kind
        )
    }

    private func mapAction(_ action: ConflictResolutionAction) -> CollisionAction? {
        switch action {
        case .replace:
            return .replace
        case .keepBoth:
            return .keepBoth
        case .skip:
            return .skip
        case .stop:
            return nil
        }
    }
}
