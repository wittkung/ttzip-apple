// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import Observation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Fast Spotlight file searching service leveraging Apple's native NSMetadataQuery.
@Observable
@MainActor
public final class SpotlightSearchService {
    public var searchQuery: String = ""
    public var searchResults: [DiskItemInfo] = []
    public var isSearching: Bool = false
    
    /// Notification posted whenever search results are updated.
    public static let searchResultsDidChangeNotification = Notification.Name("SpotlightSearchService.searchResultsDidChangeNotification")

    /// Active AsyncStream continuations.
    private var resultsContinuations: [UUID: AsyncStream<[DiskItemInfo]>.Continuation] = [:]

    private var metadataQuery: NSMetadataQuery?
    
    public init() {}
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Asynchronous stream yielding Spotlight search results.
    public func makeResultsStream() -> AsyncStream<[DiskItemInfo]> {
        AsyncStream { continuation in
            let id = UUID()
            self.resultsContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.resultsContinuations.removeValue(forKey: id)
                }
            }
            continuation.yield(self.searchResults)
        }
    }
    
    public func performSearch(query: String, searchDirectory: String = NSHomeDirectory()) {
        stopCurrentQuery()
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.searchResults = []
            self.isSearching = false
            return
        }
        
        self.isSearching = true
        let queryObj = NSMetadataQuery()
        self.metadataQuery = queryObj
        
        let searchDirURL = URL(fileURLWithPath: searchDirectory)
        queryObj.searchScopes = [searchDirURL]
        queryObj.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(trimmed)*")
        queryObj.operationQueue = .main
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didFinishGathering(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: queryObj
        )
        
        queryObj.start()
    }
    
    public func cancelSearch() {
        stopCurrentQuery()
        self.isSearching = false
        self.searchResults = []
        for continuation in resultsContinuations.values {
            continuation.yield([])
        }
        NotificationCenter.default.post(name: Self.searchResultsDidChangeNotification, object: self)
    }
    
    @objc private func didFinishGathering(_ notification: Notification) {
        guard let activeQuery = metadataQuery else { return }
        harvestResults(from: activeQuery)
        self.isSearching = false
        self.stopCurrentQuery()
    }
    
    private func harvestResults(from query: NSMetadataQuery) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        
        let count = min(query.resultCount, 50)
        var items: [DiskItemInfo] = []
        items.reserveCapacity(count)
        
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else {
                continue
            }
            let url = URL(fileURLWithPath: path)
            items.append(DiskItemInfo(url: url))
        }
        self.searchResults = items
        for continuation in resultsContinuations.values {
            continuation.yield(items)
        }
        NotificationCenter.default.post(name: Self.searchResultsDidChangeNotification, object: self)
    }
    
    private func stopCurrentQuery() {
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: nil)
        if let query = metadataQuery {
            query.stop()
            metadataQuery = nil
        }
    }
}


