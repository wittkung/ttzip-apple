// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

extension TTZipArchiveVfsProvider {
    private func extractSmallEntryForRange(
        archiveId: String,
        archivePath: String,
        entryPath: String,
        password: String?,
        expectedVersion: SessionVersion,
        byteRange: ClosedRange<Int>?,
        mimeType: String
    ) async throws -> (data: Data, fullSize: Int64, mimeType: String)? {
        guard let fullData = try await readAccess.readEntry(archivePath, entryPath, password) else { return nil }
        cacheEntryDataIfSourceUnchanged(
            archiveId: archiveId,
            archivePath: archivePath,
            entryPath: entryPath,
            data: fullData,
            expectedVersion: expectedVersion
        )
        return Self.sliceRange(from: fullData, byteRange: byteRange, mimeType: mimeType)
    }

    private static func sliceRange(
        from data: Data,
        byteRange: ClosedRange<Int>?,
        mimeType: String
    ) -> (data: Data, fullSize: Int64, mimeType: String) {
        let fullSize = Int64(data.count)
        guard let range = byteRange else {
            return (data, fullSize, mimeType)
        }
        let bounds = boundedReadRange(range, fullSize: fullSize)
        let slice = data.subdata(in: Int(bounds.lowerBound)..<Int(bounds.upperBound))
        return (slice, fullSize, mimeType)
    }

    private static func boundedReadRange(_ range: ClosedRange<Int>?, fullSize: Int64) -> Range<Int64> {
        let start = max(0, min(Int64(range?.lowerBound ?? 0), fullSize))
        guard start < fullSize else { return start..<start }

        let lastByte = min(Int64(range?.upperBound ?? Int.max), fullSize - 1)
        guard lastByte >= start else { return start..<start }
        let length = min(lastByte - start + 1, Int64(maxRangeSliceSize))
        return start..<(start + length)
    }

    private func resolveEntrySize(
        archiveId: String,
        entryPath: String,
        session: ResolvedSession
    ) -> Int64 {
        if let size = session.knownEntrySize {
            return size
        }
        let entries = (try? readAccess.listEntrySizes(session.archivePath, session.password)) ?? []
        let normalizedEntries = entries.map { (Self.normalizePath($0.path), Int64($0.size)) }
        let found = normalizedEntries.last { norm, _ in
            norm == entryPath || norm.hasSuffix("/" + entryPath)
        }?.1 ?? 0
        persistResolvedEntrySizesIfMatching(
            archiveId: archiveId,
            archivePath: session.archivePath,
            expectedVersion: session.version,
            normalizedEntries: normalizedEntries
        )
        return found
    }

    private func materializeLeasedMedia(
        archivePath: String,
        entryPath: String,
        uncompressedSize: Int64,
        password: String?
    ) async throws -> ArchiveMediaCachePool.LeasedMediaFile {
        switch currentMediaCacheSource {
        case .standalone:
            return try await mediaCachePool.acquireLeasedMedia(
                archivePath: archivePath,
                entryPath: entryPath,
                uncompressedSize: uncompressedSize,
                password: password
            )
        case .hosted(let extraction):
            return try await mediaCachePool.acquireLeasedMedia(
                archivePath: archivePath,
                entryPath: entryPath,
                uncompressedSize: uncompressedSize,
                password: password,
                extraction: extraction
            )
        }
    }

    private static func readLeasedMediaSlice(
        from mediaURL: URL,
        entrySize: Int64,
        byteRange: ClosedRange<Int>?,
        mimeType: String
    ) throws -> (data: Data, fullSize: Int64, mimeType: String)? {
        let fileHandle = try FileHandle(forReadingFrom: mediaURL)
        defer { try? fileHandle.close() }

        let actualFullSize: Int64
        if entrySize > 0 {
            actualFullSize = entrySize
        } else {
            actualFullSize = (try? fileHandle.seekToEnd()).map(Int64.init) ?? 0
        }
        let bounds = boundedReadRange(byteRange, fullSize: actualFullSize)
        guard !bounds.isEmpty else { return (Data(), actualFullSize, mimeType) }
        try fileHandle.seek(toOffset: UInt64(bounds.lowerBound))
        let sliceData = (try fileHandle.read(upToCount: Int(bounds.count))) ?? Data()
        return (sliceData, actualFullSize, mimeType)
    }

    private func readMediaCacheSlice(
        archivePath: String,
        entryPath: String,
        entrySize: Int64,
        password: String?,
        byteRange: ClosedRange<Int>?,
        mimeType: String
    ) async throws -> (data: Data, fullSize: Int64, mimeType: String)? {
        let leased: ArchiveMediaCachePool.LeasedMediaFile
        do {
            leased = try await materializeLeasedMedia(
                archivePath: archivePath,
                entryPath: entryPath,
                uncompressedSize: entrySize,
                password: password
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if entrySize > Self.maxInMemoryEntryBytes {
                throw error
            }
            return nil
        }

        do {
            let result = try Self.readLeasedMediaSlice(
                from: leased.url,
                entrySize: entrySize,
                byteRange: byteRange,
                mimeType: mimeType
            )
            await mediaCachePool.releaseLease(leased.lease)
            return result
        } catch {
            await mediaCachePool.releaseLease(leased.lease)
            throw error
        }
    }

    public func loadResourceRange(
        uri: String,
        byteRange: ClosedRange<Int>?
    ) async throws -> (data: Data, fullSize: Int64, mimeType: String)? {
        guard let (archiveId, entryPath) = parseVfsUri(uri) else { return nil }
        let mimeType = Self.mimeType(for: entryPath)

        guard let session = reconciledSession(archiveId: archiveId, entryPath: entryPath) else {
            return nil
        }
        if let cached = session.cachedData {
            return Self.sliceRange(from: cached, byteRange: byteRange, mimeType: mimeType)
        }

        let entrySize = resolveEntrySize(archiveId: archiveId, entryPath: entryPath, session: session)

        if entrySize > 0 && entrySize <= Self.maxInMemoryEntryBytes,
           let sliced = try await extractSmallEntryForRange(
               archiveId: archiveId,
               archivePath: session.archivePath,
               entryPath: entryPath,
               password: session.password,
               expectedVersion: session.version,
               byteRange: byteRange,
               mimeType: mimeType
           ) {
            return sliced
        }

        if let mediaSlice = try await readMediaCacheSlice(
            archivePath: session.archivePath,
            entryPath: entryPath,
            entrySize: entrySize,
            password: session.password,
            byteRange: byteRange,
            mimeType: mimeType
        ) {
            return mediaSlice
        }

        guard let (fullData, fallbackMime) = try await loadResource(uri: uri) else { return nil }
        return Self.sliceRange(from: fullData, byteRange: byteRange, mimeType: fallbackMime)
    }
}
