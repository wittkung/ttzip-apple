// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Represents parsed television series episode metadata and playlist sequence references.
public struct SeriesEpisodeInfo: Sendable, Identifiable, Equatable {
    public let id: String
    public let url: URL
    public let seriesTitle: String
    public let seasonNumber: Int?
    public let episodeNumber: Int
    public let episodeTitle: String?
    public var previousEpisodeURL: URL?
    public var nextEpisodeURL: URL?
    
    public init(
        id: String? = nil,
        url: URL,
        seriesTitle: String,
        seasonNumber: Int? = nil,
        episodeNumber: Int,
        episodeTitle: String? = nil,
        previousEpisodeURL: URL? = nil,
        nextEpisodeURL: URL? = nil
    ) {
        self.id = id ?? url.standardizedFileURL.path
        self.url = url
        self.seriesTitle = seriesTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episodeTitle = episodeTitle
        self.previousEpisodeURL = previousEpisodeURL
        self.nextEpisodeURL = nextEpisodeURL
    }
}

/// Industrial-grade series episode matching and continuous playback playlist coordinator.
public final class AutoSeriesMatcher: Sendable {
    public static let shared = AutoSeriesMatcher()
    
    public static let supportedVideoExtensions: Set<String> = [
        "mp4", "mkv", "mov", "avi", "webm", "flv", "wmv", "m4v", "ts", "mts", "m2ts"
    ]
    
    public static let supportedSubtitleExtensions: Set<String> = [
        "srt", "ass", "ssa", "vtt", "sub", "lrc"
    ]
    
    public init() {}
    
    // MARK: - Public Episode Discovery & Traversal
    
    /// Scans the sibling directory of `currentURL`, extracts and groups matching television series episodes,
    /// sorts them in natural ascending order, and establishes previous/next episode chain pointers.
    public func findSeriesEpisodes(for currentURL: URL) async -> [SeriesEpisodeInfo] {
        await Task.detached(priority: .userInitiated) { [self] in
            findSeriesEpisodesSync(for: currentURL)
        }.value
    }
    
    /// Synchronous scanner discovering and sorting series episodes in the parent directory of `currentURL`.
    public func findSeriesEpisodesSync(for currentURL: URL) -> [SeriesEpisodeInfo] {
        let parentDir = currentURL.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: parentDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            if let single = parseEpisode(from: currentURL) {
                return [single]
            }
            return []
        }
        
        let videoFiles = files.filter { Self.supportedVideoExtensions.contains($0.pathExtension.lowercased()) }
        guard !videoFiles.isEmpty else { return [] }
        
        let parsedCandidates: [SeriesEpisodeInfo] = videoFiles.compactMap { parseEpisode(from: $0) }
        guard let targetParsed = parseEpisode(from: currentURL) else {
            let sortedByPath = videoFiles.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            return linkEpisodeChain(episodes: sortedByPath.enumerated().map { index, file in
                SeriesEpisodeInfo(
                    url: file,
                    seriesTitle: parentDir.lastPathComponent,
                    seasonNumber: 1,
                    episodeNumber: index + 1
                )
            })
        }
        
        // Filter sibling episodes belonging to the same series family
        let targetSeriesNormalized = normalizeSeriesTitle(targetParsed.seriesTitle)
        let matchedEpisodes = parsedCandidates.filter { candidate in
            if let targetSeason = targetParsed.seasonNumber, let candSeason = candidate.seasonNumber {
                if targetSeason != candSeason { return false }
            }
            let candNormalized = normalizeSeriesTitle(candidate.seriesTitle)
            if candNormalized.isEmpty || targetSeriesNormalized.isEmpty {
                return true
            }
            return candNormalized == targetSeriesNormalized ||
                candNormalized.contains(targetSeriesNormalized) ||
                targetSeriesNormalized.contains(candNormalized)
        }
        
        let effectiveList = matchedEpisodes.isEmpty ? parsedCandidates : matchedEpisodes
        
        let sorted = effectiveList.sorted { lhs, rhs in
            let lSeason = lhs.seasonNumber ?? 1
            let rSeason = rhs.seasonNumber ?? 1
            if lSeason != rSeason {
                return lSeason < rSeason
            }
            if lhs.episodeNumber != rhs.episodeNumber {
                return lhs.episodeNumber < rhs.episodeNumber
            }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
        
        return linkEpisodeChain(episodes: sorted)
    }
    
    // MARK: - Subtitle Fuzzy Matching
    
    /// Intelligently resolves an external companion subtitle for a given episode across naming discrepancies.
    public func findMatchingSubtitle(for episode: SeriesEpisodeInfo, in directory: URL) async -> URL? {
        await Task.detached(priority: .utility) { [self] in
            findMatchingSubtitleSync(for: episode, in: directory)
        }.value
    }
    
    /// Synchronous resolution of the best-matching subtitle file in `directory` or common subtitle subfolders.
    public func findMatchingSubtitleSync(for episode: SeriesEpisodeInfo, in directory: URL) -> URL? {
        var searchDirs = [directory]
        for subfolder in ["Subs", "Subtitles", "sub", "subs"] {
            let subURL = directory.appendingPathComponent(subfolder, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: subURL.path, isDirectory: &isDir), isDir.boolValue {
                searchDirs.append(subURL)
            }
        }
        
        var candidateFiles: [URL] = []
        for dir in searchDirs {
            if let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                candidateFiles.append(contentsOf: files.filter {
                    Self.supportedSubtitleExtensions.contains($0.pathExtension.lowercased())
                })
            }
        }
        
        guard !candidateFiles.isEmpty else { return nil }
        
        let videoBaseName = episode.url.deletingPathExtension().lastPathComponent.lowercased()
        let normalizedSeries = normalizeSeriesTitle(episode.seriesTitle)
        
        var bestCandidate: (url: URL, score: Int)? = nil
        
        for subURL in candidateFiles {
            let subBaseName = subURL.deletingPathExtension().lastPathComponent.lowercased()
            var score = 0
            
            if subBaseName == videoBaseName {
                score = 1000
            } else if subBaseName.hasPrefix(videoBaseName) {
                score = 900
            } else if let subParsed = parseEpisode(from: subURL), subParsed.episodeNumber == episode.episodeNumber {
                score = 800
                if let epSeason = episode.seasonNumber, let subSeason = subParsed.seasonNumber, epSeason == subSeason {
                    score += 50
                }
                let subSeriesNormalized = normalizeSeriesTitle(subParsed.seriesTitle)
                if !normalizedSeries.isEmpty && !subSeriesNormalized.isEmpty {
                    if subSeriesNormalized == normalizedSeries || subBaseName.contains(normalizedSeries) {
                        score += 40
                    }
                }
            } else if containsEpisodeNumber(subBaseName, episode: episode.episodeNumber) {
                score = 600
                if !normalizedSeries.isEmpty && subBaseName.contains(normalizedSeries) {
                    score += 40
                }
            }
            
            if score > 0 {
                if subBaseName.contains("chs") || subBaseName.contains("zh-cn") || subBaseName.contains("sc") || subBaseName.contains("simplified") {
                    score += 30
                } else if subBaseName.contains("cht") || subBaseName.contains("zh-tw") || subBaseName.contains("tc") || subBaseName.contains("traditional") {
                    score += 25
                } else if subBaseName.contains("eng") || subBaseName.contains("en") {
                    score += 20
                }
                
                if let currentBest = bestCandidate {
                    if score > currentBest.score {
                        bestCandidate = (url: subURL, score: score)
                    }
                } else {
                    bestCandidate = (url: subURL, score: score)
                }
            }
        }
        
        return bestCandidate?.url
    }
    
    // MARK: - Regex Episode Parsing
    
    /// Parses filename into structured series episode information using multi-pattern heuristics.
    public func parseEpisode(from url: URL) -> SeriesEpisodeInfo? {
        let filename = url.deletingPathExtension().lastPathComponent
        let parentDirName = url.deletingLastPathComponent().lastPathComponent
        
        // Pattern 1: S01E02 / s1e02 / S01.E02
        if let (season, ep, prefix) = matchRegex(
            pattern: #"(?i)S(\d{1,3})[\.\s_-]*E(\d{1,4})"#,
            in: filename,
            seasonCapture: 1,
            episodeCapture: 2
        ) {
            let title = resolveTitle(prefix: prefix, fallback: parentDirName)
            return SeriesEpisodeInfo(url: url, seriesTitle: title, seasonNumber: season, episodeNumber: ep)
        }
        
        // Pattern 2: 1x04 / 01x04
        if let (season, ep, prefix) = matchRegex(
            pattern: #"(?i)(?:^|\D)(\d{1,2})x(\d{1,4})(?:\D|$)"#,
            in: filename,
            seasonCapture: 1,
            episodeCapture: 2
        ) {
            let title = resolveTitle(prefix: prefix, fallback: parentDirName)
            return SeriesEpisodeInfo(url: url, seriesTitle: title, seasonNumber: season, episodeNumber: ep)
        }
        
        // Pattern 3: EP03 / Ep.03 / E03
        if let (season, ep, prefix) = matchRegex(
            pattern: #"(?i)(?:^|[\._\s\-\[])(?:EP|E)[\.\s_-]*(\d{1,4})(?:[\._\s\-\]]|$)"#,
            in: filename,
            seasonCapture: nil,
            episodeCapture: 1
        ) {
            let title = resolveTitle(prefix: prefix, fallback: parentDirName)
            return SeriesEpisodeInfo(url: url, seriesTitle: title, seasonNumber: season, episodeNumber: ep)
        }
        
        // Pattern 4: Chinese 第5集 / 第05话 / 第12期
        if let (season, ep, prefix) = matchRegex(
            pattern: #"第\s*(\d{1,4})\s*[集话話期]"#,
            in: filename,
            seasonCapture: nil,
            episodeCapture: 1
        ) {
            let title = resolveTitle(prefix: prefix, fallback: parentDirName)
            return SeriesEpisodeInfo(url: url, seriesTitle: title, seasonNumber: season, episodeNumber: ep)
        }
        
        // Pattern 5: Anime brackets [06] / 【06】
        if let (season, ep, prefix) = matchRegex(
            pattern: #"(?:\[|【)\s*(\d{1,4})\s*(?:\]|】)"#,
            in: filename,
            seasonCapture: nil,
            episodeCapture: 1
        ) {
            let title = resolveTitle(prefix: prefix, fallback: parentDirName)
            return SeriesEpisodeInfo(url: url, seriesTitle: title, seasonNumber: season, episodeNumber: ep)
        }
        
        // Pattern 6: Delimited dash number "Show - 03"
        if let (season, ep, prefix) = matchRegex(
            pattern: #"(?:^|[\s_.-])-\s*(\d{1,4})(?:[\s_.-]|$)"#,
            in: filename,
            seasonCapture: nil,
            episodeCapture: 1
        ) {
            let title = resolveTitle(prefix: prefix, fallback: parentDirName)
            return SeriesEpisodeInfo(url: url, seriesTitle: title, seasonNumber: season, episodeNumber: ep)
        }
        
        // Pattern 7: Bare number at the end of filename "Show.03" or "03"
        if let (season, ep, prefix) = matchRegex(
            pattern: #"(?:^|[\._\s])(\d{1,4})$"#,
            in: filename,
            seasonCapture: nil,
            episodeCapture: 1
        ) {
            let title = resolveTitle(prefix: prefix, fallback: parentDirName)
            return SeriesEpisodeInfo(url: url, seriesTitle: title, seasonNumber: season, episodeNumber: ep)
        }
        
        return nil
    }
    
    // MARK: - Private Matching Helpers
    
    private func matchRegex(
        pattern: String,
        in text: String,
        seasonCapture: Int?,
        episodeCapture: Int
    ) -> (season: Int?, episode: Int, prefix: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsString = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsString.length)) else {
            return nil
        }
        
        let epRange = match.range(at: episodeCapture)
        guard epRange.location != NSNotFound,
              let epVal = Int(nsString.substring(with: epRange)) else {
            return nil
        }
        
        var seasonVal: Int? = nil
        if let sCapture = seasonCapture {
            let sRange = match.range(at: sCapture)
            if sRange.location != NSNotFound {
                seasonVal = Int(nsString.substring(with: sRange))
            }
        }
        
        let prefixRange = NSRange(location: 0, length: match.range.location)
        let prefix = prefixRange.location != NSNotFound ? nsString.substring(with: prefixRange) : ""
        return (seasonVal, epVal, prefix)
    }
    
    private func resolveTitle(prefix: String, fallback: String) -> String {
        let cleaned = cleanTitlePrefix(prefix)
        return cleaned.isEmpty ? fallback : cleaned
    }
    
    private func cleanTitlePrefix(_ raw: String) -> String {
        var str = raw
        // Strip leading release group brackets e.g. [Group] or 【Group】
        str = str.replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
        str = str.replacingOccurrences(of: #"^【[^】]+】\s*"#, with: "", options: .regularExpression)
        str = str.replacingOccurrences(of: #"^\([^\)]+\)\s*"#, with: "", options: .regularExpression)
        // Normalize separators
        str = str.replacingOccurrences(of: ".", with: " ")
        str = str.replacingOccurrences(of: "_", with: " ")
        str = str.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.")))
        return str
    }
    
    private func normalizeSeriesTitle(_ title: String) -> String {
        var t = title.lowercased()
        t = t.replacingOccurrences(of: ".", with: " ")
        t = t.replacingOccurrences(of: "_", with: " ")
        t = t.replacingOccurrences(of: "-", with: " ")
        let components = t.split(whereSeparator: { $0.isWhitespace })
        return components.joined(separator: " ")
    }
    
    private func containsEpisodeNumber(_ text: String, episode: Int) -> Bool {
        let epFormatted = String(format: "%02d", episode)
        let epBare = String(episode)
        let patterns = [
            #"(?:^|\D)0*"# + epBare + #"(?:\D|$)"#,
            #"\[0*"# + epBare + #"\]"#,
            #"e0*"# + epBare + #"(?:\D|$)"#,
            #"第0*"# + epBare + #"[集话話期]"#
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
               regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil {
                return true
            }
        }
        return text.contains(epFormatted)
    }
    
    private func linkEpisodeChain(episodes: [SeriesEpisodeInfo]) -> [SeriesEpisodeInfo] {
        var result = episodes
        for i in 0..<result.count {
            result[i].previousEpisodeURL = i > 0 ? result[i - 1].url : nil
            result[i].nextEpisodeURL = (i + 1 < result.count) ? result[i + 1].url : nil
        }
        return result
    }
}
