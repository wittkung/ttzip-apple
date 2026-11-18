// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import TTMediaKit

struct TTZipCodeSourceSnapshot {
    let displayText: String
    let inspection: TTTextSourceInspection
    let isTruncated: Bool
    let saveBaseline: String?

    static func load(
        fallbackText: String,
        fileURL: URL?,
        context: TTPreviewResourceContext
    ) -> Self {
        let started = CFAbsoluteTimeGetCurrent()
        guard let fileURL, fileURL.isFileURL else { return fallback(fallbackText) }
        let descriptor = fileURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { return fallback(fallbackText) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0 else { return fallback(fallbackText) }

        let isOriginalDiskSource: Bool
        if case .diskFile(let originalURL) = context.origin {
            isOriginalDiskSource = fileURL.standardizedFileURL == originalURL.standardizedFileURL
                && !context.isDerivedRepresentation && !context.isPreviewTruncated
        } else {
            isOriginalDiskSource = false
        }
        return loadRegularFile(
            handle,
            byteCount: metadata.st_size,
            isOriginalDiskSource: isOriginalDiskSource,
            fallbackText: fallbackText,
            started: started
        )
    }

    private static func loadRegularFile(
        _ handle: FileHandle,
        byteCount: Int64,
        isOriginalDiskSource: Bool,
        fallbackText: String,
        started: CFAbsoluteTime
    ) -> Self {
        let rawByteBudget = TTTextPreviewBytePolicy.maxInteractiveTextUTF8Bytes + 3
        let exceedsBudget = isOriginalDiskSource && byteCount > rawByteBudget
        let readsCompleteSource = isOriginalDiskSource && !exceedsBudget
        let readByteLimit = readsCompleteSource ? rawByteBudget + 1 : 64 * 1024
        let data: Data
        do {
            data = try handle.read(upToCount: readByteLimit) ?? Data()
        } catch {
            return fallback(
                fallbackText,
                inspection: TTTextSourceInspection(byteCount: byteCount, encoding: .utf8),
                exceedsBudget: exceedsBudget
            )
        }
        let encoding = TTTextSourceInspection.classifyEncoding(sample: data)
        let inspection = TTTextSourceInspection(
            byteCount: byteCount,
            encoding: encoding,
            inspectDurationMs: (CFAbsoluteTimeGetCurrent() - started) * 1000
        )
        guard readsCompleteSource, data.count == byteCount, data.count <= rawByteBudget,
              let decoded = TTMediaContentReader.decodeText(data: data) else {
            return fallback(fallbackText, inspection: inspection, exceedsBudget: exceedsBudget)
        }
        let bounded = TTTextPreviewBytePolicy.truncateForPreview(decoded)
        let bodyBytes = encoding == .utf8BOM ? data.dropFirst(3) : data[...]
        let isCompleteUTF8 = encoding.allowsUTF8InPlaceSave
            && String(data: bodyBytes, encoding: .utf8) == decoded
        return Self(
            displayText: bounded.displayText,
            inspection: inspection,
            isTruncated: bounded.isTruncated,
            saveBaseline: isCompleteUTF8 && !bounded.isTruncated ? decoded : nil
        )
    }

    private static func fallback(
        _ text: String,
        inspection: TTTextSourceInspection? = nil,
        exceedsBudget: Bool = false
    ) -> Self {
        let bounded = TTTextPreviewBytePolicy.truncateForPreview(text)
        return Self(
            displayText: bounded.displayText,
            inspection: inspection ?? TTTextSourceInspection(byteCount: Int64(text.utf8.count), encoding: .utf8),
            isTruncated: exceedsBudget || bounded.isTruncated,
            saveBaseline: nil
        )
    }
}
