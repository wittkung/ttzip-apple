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
            return parseEpisode(from: currentURL).map { [$0] } ?? []
        }

        let videoFiles = files.filter { Self.supportedVideoExtensions.contains($0.pathExtension.lowercased()) }
        guard !videoFiles.isEmpty else { return [] }

        guard let targetParsed = parseEpisode(from: currentURL) else {
            return fallbackUnparsedEpisodes(videoFiles: videoFiles, parentDir: parentDir)
        }

        let parsedCandidates = videoFiles.compactMap { parseEpisode(from: $0) }
        let targetSeriesNormalized = normalizeSeriesTitle(targetParsed.seriesTitle)
        let matchedEpisodes = parsedCandidates.filter {
            matchesSeriesFamily($0, target: targetParsed, normalizedTargetTitle: targetSeriesNormalized)
        }

        let effectiveList = matchedEpisodes.isEmpty ? parsedCandidates : matchedEpisodes
        return linkEpisodeChain(episodes: effectiveList.sorted(by: Self.isOrderedBefore))
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
        let candidateFiles = collectSubtitleCandidates(in: directory)
        guard !candidateFiles.isEmpty else { return nil }

        let videoBaseName = episode.url.deletingPathExtension().lastPathComponent.lowercased()
        let normalizedSeries = normalizeSeriesTitle(episode.seriesTitle)

        var bestCandidate: (url: URL, score: Int)?
        for subURL in candidateFiles {
            let score = scoreSubtitleCandidate(
                subURL,
                episode: episode,
                videoBaseName: videoBaseName,
                normalizedSeries: normalizedSeries
            )
            if score > 0, score > (bestCandidate?.score ?? 0) {
                bestCandidate = (url: subURL, score: score)
            }
        }

        return bestCandidate?.url
    }

    // MARK: - Regex Episode Parsing

    private struct EpisodePattern: Sendable {
        let regex: NSRegularExpression
        let seasonCapture: Int?
        let episodeCapture: Int
    }

    private struct SubtitleLanguageBonus: Sendable {
        let tokens: [String]
        let bonus: Int
    }

    private static let subtitleSubfolderNames = ["Subs", "Subtitles", "sub", "subs"]

    private static let subtitleLanguageBonuses: [SubtitleLanguageBonus] = [
        SubtitleLanguageBonus(tokens: ["chs", "zh-cn", "sc", "simplified"], bonus: 30),
        SubtitleLanguageBonus(tokens: ["cht", "zh-tw", "tc", "traditional"], bonus: 25),
        SubtitleLanguageBonus(tokens: ["eng", "en"], bonus: 20)
    ]

    private static let episodePatterns: [EpisodePattern] = [
        EpisodePattern(
            regex: try! NSRegularExpression(pattern: #"(?i)S(\d{1,3})[\.\s_-]*E(\d{1,4})"#, options: []),
            seasonCapture: 1,
            episodeCapture: 2
        ),
        EpisodePattern(
            regex: try! NSRegularExpression(pattern: #"(?i)(?:^|\D)(\d{1,2})x(\d{1,4})(?:\D|$)"#, options: []),
            seasonCapture: 1,
            episodeCapture: 2
        ),
        EpisodePattern(
            regex: try! NSRegularExpression(pattern: #"(?i)(?:^|[\._\s\-\[])(?:EP|E)[\.\s_-]*(\d{1,4})(?:[\._\s\-\]]|$)"#, options: []),
            seasonCapture: nil,
            episodeCapture: 1
        ),
        EpisodePattern(
            regex: try! NSRegularExpression(pattern: #"第\s*(\d{1,4})\s*[集话話期]"#, options: []),
            seasonCapture: nil,
            episodeCapture: 1
        ),
        EpisodePattern(
            regex: try! NSRegularExpression(pattern: #"(?:\[|【)\s*(\d{1,4})\s*(?:\]|】)"#, options: []),
            seasonCapture: nil,
            episodeCapture: 1
        ),
        EpisodePattern(
            regex: try! NSRegularExpression(pattern: #"(?:^|[\s_.-])-\s*(\d{1,4})(?:[\s_.-]|$)"#, options: []),
            seasonCapture: nil,
            episodeCapture: 1
        ),
        EpisodePattern(
            regex: try! NSRegularExpression(pattern: #"(?:^|[\._\s])(\d{1,4})$"#, options: []),
            seasonCapture: nil,
            episodeCapture: 1
        )
    ]

    /// Parses filename into structured series episode information using multi-pattern heuristics.
    public func parseEpisode(from url: URL) -> SeriesEpisodeInfo? {
        let filename = url.deletingPathExtension().lastPathComponent
        let parentDirName = url.deletingLastPathComponent().lastPathComponent

        for pattern in Self.episodePatterns {
            if let matched = matchEpisodePattern(pattern, in: filename) {
                let title = resolveTitle(prefix: matched.prefix, fallback: parentDirName)
                return SeriesEpisodeInfo(
                    url: url,
                    seriesTitle: title,
                    seasonNumber: matched.season,
                    episodeNumber: matched.episode
                )
            }
        }

        return nil
    }

    // MARK: - Private Matching

    private func fallbackUnparsedEpisodes(videoFiles: [URL], parentDir: URL) -> [SeriesEpisodeInfo] {
        let sortedByPath = videoFiles.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let episodes = sortedByPath.enumerated().map { index, file in
            SeriesEpisodeInfo(
                url: file,
                seriesTitle: parentDir.lastPathComponent,
                seasonNumber: 1,
                episodeNumber: index + 1
            )
        }
        return linkEpisodeChain(episodes: episodes)
    }

    private func matchesSeriesFamily(
        _ candidate: SeriesEpisodeInfo,
        target: SeriesEpisodeInfo,
        normalizedTargetTitle: String
    ) -> Bool {
        if let targetSeason = target.seasonNumber,
           let candidateSeason = candidate.seasonNumber,
           targetSeason != candidateSeason {
            return false
        }
        let candidateTitle = normalizeSeriesTitle(candidate.seriesTitle)
        if candidateTitle.isEmpty || normalizedTargetTitle.isEmpty {
            return true
        }
        return candidateTitle == normalizedTargetTitle
            || candidateTitle.contains(normalizedTargetTitle)
            || normalizedTargetTitle.contains(candidateTitle)
    }

    private static func isOrderedBefore(_ lhs: SeriesEpisodeInfo, _ rhs: SeriesEpisodeInfo) -> Bool {
        let lhsSeason = lhs.seasonNumber ?? 1
        let rhsSeason = rhs.seasonNumber ?? 1
        if lhsSeason != rhsSeason {
            return lhsSeason < rhsSeason
        }
        if lhs.episodeNumber != rhs.episodeNumber {
            return lhs.episodeNumber < rhs.episodeNumber
        }
        return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
    }

    private func collectSubtitleCandidates(in directory: URL) -> [URL] {
        var searchDirs = [directory]
        for subfolder in Self.subtitleSubfolderNames {
            let subURL = directory.appendingPathComponent(subfolder, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: subURL.path, isDirectory: &isDir), isDir.boolValue {
                searchDirs.append(subURL)
            }
        }

        var candidateFiles: [URL] = []
        for dir in searchDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            candidateFiles.append(contentsOf: files.filter {
                Self.supportedSubtitleExtensions.contains($0.pathExtension.lowercased())
            })
        }
        return candidateFiles
    }

    private func scoreSubtitleCandidate(
        _ subURL: URL,
        episode: SeriesEpisodeInfo,
        videoBaseName: String,
        normalizedSeries: String
    ) -> Int {
        let subBaseName = subURL.deletingPathExtension().lastPathComponent.lowercased()
        let baseScore = subtitleBaseScore(
            for: subURL,
            subBaseName: subBaseName,
            episode: episode,
            videoBaseName: videoBaseName,
            normalizedSeries: normalizedSeries
        )
        guard baseScore > 0 else { return 0 }
        return baseScore + Self.subtitleLanguageBonus(for: subBaseName)
    }

    private func subtitleBaseScore(
        for subURL: URL,
        subBaseName: String,
        episode: SeriesEpisodeInfo,
        videoBaseName: String,
        normalizedSeries: String
    ) -> Int {
        if subBaseName == videoBaseName {
            return 1000
        }
        if subBaseName.hasPrefix(videoBaseName) {
            return 900
        }
        if let subParsed = parseEpisode(from: subURL), subParsed.episodeNumber == episode.episodeNumber {
            return parsedEpisodeSubtitleScore(
                subParsed: subParsed,
                subBaseName: subBaseName,
                episode: episode,
                normalizedSeries: normalizedSeries
            )
        }
        if containsEpisodeNumber(subBaseName, episode: episode.episodeNumber) {
            return (!normalizedSeries.isEmpty && subBaseName.contains(normalizedSeries)) ? 640 : 600
        }
        return 0
    }

    private func parsedEpisodeSubtitleScore(
        subParsed: SeriesEpisodeInfo,
        subBaseName: String,
        episode: SeriesEpisodeInfo,
        normalizedSeries: String
    ) -> Int {
        var score = 800
        if let epSeason = episode.seasonNumber, let subSeason = subParsed.seasonNumber, epSeason == subSeason {
            score += 50
        }
        let subSeriesNormalized = normalizeSeriesTitle(subParsed.seriesTitle)
        if !normalizedSeries.isEmpty,
           !subSeriesNormalized.isEmpty,
           subSeriesNormalized == normalizedSeries || subBaseName.contains(normalizedSeries) {
            score += 40
        }
        return score
    }

    private static func subtitleLanguageBonus(for subBaseName: String) -> Int {
        for rule in subtitleLanguageBonuses {
            if rule.tokens.contains(where: { subBaseName.contains($0) }) {
                return rule.bonus
            }
        }
        return 0
    }

    private func matchEpisodePattern(
        _ pattern: EpisodePattern,
        in text: String
    ) -> (season: Int?, episode: Int, prefix: String)? {
        let nsString = text as NSString
        guard let match = pattern.regex.firstMatch(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsString.length)
        ) else {
            return nil
        }

        let epRange = match.range(at: pattern.episodeCapture)
        guard epRange.location != NSNotFound,
              let epVal = Int(nsString.substring(with: epRange)) else {
            return nil
        }

        var seasonVal: Int?
        if let sCapture = pattern.seasonCapture {
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
