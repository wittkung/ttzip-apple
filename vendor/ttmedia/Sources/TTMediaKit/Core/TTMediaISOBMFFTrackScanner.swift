// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Structured, bounded ISOBMFF and QuickTime box navigator and track descriptor scanner.
/// Traverses nested `moov -> trak -> mdia -> hdlr/minf` boxes without full container loading,
/// enforcing the Scan Completeness Contract to prevent false pure audio classification.
internal enum TTMediaISOBMFFTrackScanner {

    /// Maximum number of top-level container boxes inspected.
    private static let maxTopLevelBoxes = 16

    /// Maximum number of track boxes inspected within `moov`.
    private static let maxTrackBudget = 16

    /// Maximum number of child boxes inspected within a single `trak` or `mdia`.
    private static let maxChildBoxes = 8

    // MARK: - Moov Sample Resolution

    /// Resolves aggregated track descriptor samples and scan completeness for memory or disk sources.
    nonisolated internal static func resolveMoovSample(
        for source: TTMediaDetector.DetectionSource,
        initialSample: Data
    ) -> (sample: Data, isCompleteScan: Bool)? {
        switch source {
        case .memory(let data, _, _):
            let candidate = data.count > initialSample.count ? data : initialSample
            return locateMoovSample(in: candidate)
        case .disk(let url):
            if let onDisk = locateMoovOnDisk(url: url, initialSample: initialSample) {
                return onDisk
            }
            return locateMoovSample(in: initialSample)
        }
    }

    nonisolated private static func locateMoovSample(in buffer: Data) -> (sample: Data, isCompleteScan: Bool)? {
        locateMoovSample(totalLength: UInt64(buffer.count)) { offset, count in
            guard count > 0, let start = Int(exactly: offset), start >= 0, start < buffer.count else {
                return Data()
            }
            let remaining = buffer.count - start
            let readCount = min(count, remaining)
            return buffer.subdata(in: start..<(start + readCount))
        }
    }

    nonisolated private static func locateMoovOnDisk(
        url: URL, initialSample: Data
    ) -> (sample: Data, isCompleteScan: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let sampleLength = UInt64(initialSample.count)
        guard let fileSize = try? handle.seekToEnd(), fileSize > sampleLength else { return nil }
        return locateMoovSample(totalLength: fileSize) { offset, count in
            readSliceFromSampleOrDisk(
                handle: handle,
                initialSample: initialSample,
                fileSize: fileSize,
                offset: offset,
                count: count
            )
        }
    }

    nonisolated private static func readSliceFromSampleOrDisk(
        handle: FileHandle,
        initialSample: Data,
        fileSize: UInt64,
        offset: UInt64,
        count: Int
    ) -> Data {
        guard count > 0, offset < fileSize else { return Data() }
        let sampleLength = UInt64(initialSample.count)
        let (end, overflow) = offset.addingReportingOverflow(UInt64(count))
        if !overflow, end <= sampleLength,
           let startInt = Int(exactly: offset), let endInt = Int(exactly: end) {
            return initialSample.subdata(in: startInt..<endInt)
        }
        let maxReadable = Int(min(UInt64(count), fileSize - offset))
        guard maxReadable > 0 else { return Data() }
        try? handle.seek(toOffset: offset)
        return (try? handle.read(upToCount: maxReadable)) ?? Data()
    }

    // MARK: - Box Navigation

    nonisolated private static func locateMoovSample(
        totalLength: UInt64,
        readSlice: (UInt64, Int) -> Data
    ) -> (sample: Data, isCompleteScan: Bool)? {
        var offset: UInt64 = 0
        for _ in 0..<maxTopLevelBoxes {
            guard offset <= totalLength, totalLength - offset >= 8 else { break }
            let header = readSlice(offset, 16)
            guard let box = parseISOBMFFBoxHeader(header, offset: offset, totalLength: totalLength) else { break }
            if box.type == "moov" {
                return sampleMoovTrackDescriptors(
                    moov: box, moovOffset: offset, totalLength: totalLength, readSlice: readSlice
                )
            }
            let (nextOffset, overflow) = offset.addingReportingOverflow(box.size)
            guard !overflow, nextOffset > offset, nextOffset <= totalLength else { break }
            offset = nextOffset
        }
        return nil
    }

    nonisolated private static func sampleMoovTrackDescriptors(
        moov: (size: UInt64, headerSize: UInt64, type: String),
        moovOffset: UInt64,
        totalLength: UInt64,
        readSlice: (UInt64, Int) -> Data
    ) -> (sample: Data, isCompleteScan: Bool) {
        let (contentOffset, cOver) = moovOffset.addingReportingOverflow(moov.headerSize)
        let (contentEndRaw, eOver) = moovOffset.addingReportingOverflow(moov.size)
        guard !cOver, !eOver, contentOffset < contentEndRaw, contentEndRaw <= totalLength else {
            let fallback = readSlice(moovOffset, Int(min(moov.size, totalLength - moovOffset, 4096)))
            return (fallback, false)
        }
        let contentEnd = contentEndRaw
        var subOffset = contentOffset
        var aggregated = Data()
        var isComplete = true
        var trakCount = 0

        for _ in 0..<maxTrackBudget {
            guard subOffset < contentEnd else { break }
            let header = readSlice(subOffset, 16)
            guard let box = parseISOBMFFBoxHeader(header, offset: subOffset, totalLength: contentEnd) else {
                isComplete = false
                break
            }
            if box.type == "trak" {
                trakCount += 1
                let (trackData, trackComplete) = scanTrakBox(
                    trak: box, trakOffset: subOffset, contentEnd: contentEnd, readSlice: readSlice
                )
                if !trackData.isEmpty { aggregated.append(trackData) }
                if !trackComplete { isComplete = false }
            }
            let (next, overflow) = subOffset.addingReportingOverflow(box.size)
            guard !overflow, next > subOffset, next <= contentEnd else {
                isComplete = false
                break
            }
            subOffset = next
        }
        if subOffset < contentEnd { isComplete = false }
        if trakCount == 0 && aggregated.isEmpty {
            let sliceSize = Int(min(moov.size, totalLength - moovOffset, 4096))
            aggregated = readSlice(moovOffset, sliceSize)
            isComplete = (moov.size <= 4096 && moovOffset + moov.size <= totalLength)
        }
        return (aggregated, isComplete)
    }

    nonisolated private static func scanTrakBox(
        trak: (size: UInt64, headerSize: UInt64, type: String),
        trakOffset: UInt64,
        contentEnd: UInt64,
        readSlice: (UInt64, Int) -> Data
    ) -> (Data, Bool) {
        let (trakStart, sOver) = trakOffset.addingReportingOverflow(trak.headerSize)
        let (trakEnd, eOver) = trakOffset.addingReportingOverflow(trak.size)
        guard !sOver, !eOver, trakStart < trakEnd, trakEnd <= contentEnd else { return (Data(), false) }
        var offset = trakStart
        var result = Data()
        var foundHandler = false

        for _ in 0..<maxChildBoxes {
            guard offset < trakEnd else { break }
            let header = readSlice(offset, 16)
            guard let box = parseISOBMFFBoxHeader(header, offset: offset, totalLength: trakEnd) else {
                return (result, false)
            }
            if box.type == "mdia" {
                let (mdiaData, mdiaFound) = scanMdiaBox(
                    mdia: box, mdiaOffset: offset, trakEnd: trakEnd, readSlice: readSlice
                )
                if !mdiaData.isEmpty { result.append(mdiaData) }
                if mdiaFound { foundHandler = true }
                break
            } else if box.type == "hdlr" {
                let readLen = Int(min(box.size, 64, trakEnd - offset))
                if readLen > 0 { result.append(readSlice(offset, readLen)) }
                foundHandler = true
            } else if box.type == "vmhd" || box.type == "smhd" {
                let readLen = Int(min(box.size, 32, trakEnd - offset))
                if readLen > 0 { result.append(readSlice(offset, readLen)) }
                foundHandler = true
            }
            let (next, overflow) = offset.addingReportingOverflow(box.size)
            guard !overflow, next > offset, next <= trakEnd else { return (result, false) }
            offset = next
        }
        return (result, foundHandler)
    }

    nonisolated private static func scanMdiaBox(
        mdia: (size: UInt64, headerSize: UInt64, type: String),
        mdiaOffset: UInt64,
        trakEnd: UInt64,
        readSlice: (UInt64, Int) -> Data
    ) -> (Data, Bool) {
        let (mdiaStart, sOver) = mdiaOffset.addingReportingOverflow(mdia.headerSize)
        let (mdiaEnd, eOver) = mdiaOffset.addingReportingOverflow(mdia.size)
        guard !sOver, !eOver, mdiaStart < mdiaEnd, mdiaEnd <= trakEnd else { return (Data(), false) }
        var offset = mdiaStart
        var result = Data()
        var found = false

        for _ in 0..<maxChildBoxes {
            guard offset < mdiaEnd else { break }
            let header = readSlice(offset, 16)
            guard let box = parseISOBMFFBoxHeader(header, offset: offset, totalLength: mdiaEnd) else { break }
            if box.type == "hdlr" {
                let readLen = Int(min(box.size, 64, mdiaEnd - offset))
                if readLen > 0 { result.append(readSlice(offset, readLen)) }
                found = true
            } else if box.type == "minf" {
                let minfData = scanMinfBox(minf: box, minfOffset: offset, mdiaEnd: mdiaEnd, readSlice: readSlice)
                if !minfData.isEmpty {
                    result.append(minfData)
                    found = true
                }
            }
            let (next, overflow) = offset.addingReportingOverflow(box.size)
            guard !overflow, next > offset, next <= mdiaEnd else { break }
            offset = next
        }
        return (result, found)
    }

    nonisolated private static func scanMinfBox(
        minf: (size: UInt64, headerSize: UInt64, type: String),
        minfOffset: UInt64,
        mdiaEnd: UInt64,
        readSlice: (UInt64, Int) -> Data
    ) -> Data {
        let (minfStart, sOver) = minfOffset.addingReportingOverflow(minf.headerSize)
        let (minfEnd, eOver) = minfOffset.addingReportingOverflow(minf.size)
        guard !sOver, !eOver, minfStart < minfEnd, minfEnd <= mdiaEnd else { return Data() }
        var offset = minfStart
        var result = Data()

        for _ in 0..<maxChildBoxes {
            guard offset < minfEnd else { break }
            let header = readSlice(offset, 16)
            guard let box = parseISOBMFFBoxHeader(header, offset: offset, totalLength: minfEnd) else { break }
            if box.type == "vmhd" || box.type == "smhd" {
                let readLen = Int(min(box.size, 32, minfEnd - offset))
                if readLen > 0 { result.append(readSlice(offset, readLen)) }
            }
            let (next, overflow) = offset.addingReportingOverflow(box.size)
            guard !overflow, next > offset, next <= minfEnd else { break }
            offset = next
        }
        return result
    }

    // MARK: - Box Header Parsing

    nonisolated internal static func parseISOBMFFBoxHeader(
        _ header: Data,
        offset: UInt64,
        totalLength: UInt64
    ) -> (size: UInt64, headerSize: UInt64, type: String)? {
        guard header.count >= 8, offset <= totalLength else { return nil }
        let remaining = totalLength - offset
        guard remaining >= 8 else { return nil }
        for idx in 4..<8 where header[idx] < 0x20 || header[idx] > 0x7E {
            return nil
        }
        let boxType = String(bytes: header.subdata(in: 4..<8), encoding: .isoLatin1) ?? ""
        let size32 = header.subdata(in: 0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if size32 == 1 {
            guard header.count >= 16, remaining >= 16 else { return nil }
            let size64 = header.subdata(in: 8..<16).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard size64 >= 16, size64 <= remaining else { return nil }
            let (_, overflow) = offset.addingReportingOverflow(size64)
            guard !overflow else { return nil }
            return (size64, 16, boxType)
        }
        if size32 == 0 {
            return (remaining, 8, boxType)
        }
        let boxSize = UInt64(size32)
        guard boxSize >= 8, boxSize <= remaining else { return nil }
        return (boxSize, 8, boxType)
    }
}
