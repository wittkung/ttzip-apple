// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI

/// Frontend core algorithm and UI interaction performance benchmark executor.
public final class FrontendBenchmarkRunner: Sendable {
    public static let shared = FrontendBenchmarkRunner()
    
    public init() {}
    
    /// Generates synthetic hierarchical archive entry dataset.
    public func generateSyntheticEntries(count: Int) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(count)
        
        let depth1Count = max(1, count / 100)
        let depth2Count = max(1, count / 20)
        
        for i in 0..<count {
            let d1 = i % depth1Count
            let d2 = i % depth2Count
            let isDir = (i % 20 == 0)
            let path = isDir ? "Folder_\(d1)/Sub_\(d2)/" : "Folder_\(d1)/Sub_\(d2)/file_\(i).dat"
            let entry = ArchiveEntry(
                path: path,
                uncompressedSize: isDir ? 0 : Int64((i % 1024) * 1024),
                isDirectory: isDir,
                detectedEncoding: "UTF-8"
            )
            entries.append(entry)
        }
        return entries
    }
    
    /// Runs tree build performance benchmarks across node scales.
    public func runTreeBuildBenchmark(entryCounts: [Int] = [1000, 10000, 50000]) async -> [TreeBuildMetric] {
        var results: [TreeBuildMetric] = []
        
        for count in entryCounts {
            let entries = generateSyntheticEntries(count: count)
            let clock = ContinuousClock()
            
            let elapsed = clock.measure {
                _ = ArchiveTreeBuilder.buildTree(from: entries)
            }
            
            let durationMs = Double(elapsed.components.seconds) * 1000.0 + (Double(elapsed.components.attoseconds) / 1e15)
            let rootCount = max(1, count / 100)
            let metric = TreeBuildMetric(entryCount: count, rootNodeCount: rootCount, durationMs: durationMs)
            results.append(metric)
        }
        return results
    }
    
    /// Runs real-time search and filter performance benchmarks.
    public func runSearchFilterBenchmark(datasetSize: Int = 20000, queries: [String] = ["file_100", "Folder_2", "sub", "nonexistent"]) async -> [SearchFilterMetric] {
        let entries = generateSyntheticEntries(count: datasetSize)
        var results: [SearchFilterMetric] = []
        
        for q in queries {
            let clock = ContinuousClock()
            var matched = 0
            
            let elapsed = clock.measure {
                var count = 0
                #if canImport(Darwin) || canImport(Glibc)
                q.withCString { qPtr in
                    for entry in entries {
                        let matchName = entry.name.withCString { strcasestr($0, qPtr) != nil }
                        if matchName {
                            count += 1
                        } else {
                            let matchPath = entry.path.withCString { strcasestr($0, qPtr) != nil }
                            if matchPath { count += 1 }
                        }
                    }
                }
                #else
                let lowerQ = q.lowercased()
                for entry in entries {
                    if entry.name.localizedCaseInsensitiveContains(q) || entry.path.localizedCaseInsensitiveContains(q) {
                        count += 1
                    }
                }
                #endif
                matched = count
            }
            
            let durationMs = Double(elapsed.components.seconds) * 1000.0 + (Double(elapsed.components.attoseconds) / 1e15)
            let metric = SearchFilterMetric(datasetSize: datasetSize, query: q, matchedCount: matched, durationMs: durationMs)
            results.append(metric)
        }
        return results
    }
    
    /// Runs high-frequency event throttling benchmarks using real ThrottledProgressPublisher.
    public func runThrottleBenchmark(eventCount: Int = 10000, targetHz: Double = 60.0) async -> [ProgressThrottleMetric] {
        let throttler = ThrottledProgressPublisher(maxFrequencyHz: targetHz)
        let clock = ContinuousClock()
        var emittedCount = 0
        
        let elapsed = clock.measure {
            for _ in 0..<eventCount {
                if throttler.shouldEmit() {
                    emittedCount += 1
                }
            }
        }
        
        let durationMs = Double(elapsed.components.seconds) * 1000.0 + (Double(elapsed.components.attoseconds) / 1e15)
        let metric = ProgressThrottleMetric(totalEvents: eventCount, emittedEvents: emittedCount, durationMs: durationMs)
        return [metric]
    }
    
    /// Executes full frontend performance benchmark suite.
    public func runFullFrontendSuite() async -> FrontendPerformanceReport {
        let treeMetrics = await runTreeBuildBenchmark(entryCounts: [1000, 10000, 50000])
        let searchMetrics = await runSearchFilterBenchmark(datasetSize: 20000)
        let throttleMetrics = await runThrottleBenchmark(eventCount: 10000)
        
        let isTreePassed = treeMetrics.last.map { $0.durationMs <= 900.0 } ?? true
        let isSearchPassed = searchMetrics.allSatisfy { $0.filterThroughputItemsPerSec >= 300_000.0 }
        let isThrottlePassed = throttleMetrics.allSatisfy { $0.suppressionRatio >= 95.0 }
        let allPassed = isTreePassed && isSearchPassed && isThrottlePassed
        
        let hardware = AppleSiliconTuner.shared.topology.chipName
        
        return FrontendPerformanceReport(
            hardwareSummary: hardware,
            treeBuildMetrics: treeMetrics,
            searchFilterMetrics: searchMetrics,
            lruCacheMetrics: [],
            throttleMetrics: throttleMetrics,
            isAllPassed: allPassed
        )
    }
}
