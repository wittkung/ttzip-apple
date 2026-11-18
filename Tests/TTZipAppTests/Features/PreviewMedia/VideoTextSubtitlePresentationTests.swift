// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import CoreMedia
import SwiftUI
@testable import TTMediaKit
import XCTest
@testable import TTZipPreviewKit

@MainActor
final class VideoTextSubtitlePresentationTests: XCTestCase {
    func testProductRendersTimedMultilineAndSecondaryCaptionsAboveLetterbox() async throws {
        let folder = try makeTemporaryDirectory(prefix: "VideoTextSubtitle")
        let video = folder.appendingPathComponent("clip.mp4")
        try MediaFixtureSynthesizer.createSyntheticMP4(
            at: video, durationSeconds: 10, size: CGSize(width: 320, height: 180)
        )
        let primary = folder.appendingPathComponent("clip.en.srt")
        let secondary = folder.appendingPathComponent("clip.zh.srt")
        try writeSubtitle("PRIMARY TEST\nSECOND LINE", at: primary)
        try writeSubtitle("SECONDARY LANE", at: secondary)
        let defaults = UserDefaults.standard
        let styleKey = SubtitleStyleConfiguration.defaultsKey
        let versionKey = SubtitleStyleConfiguration.migrationVersionDefaultsKey
        let oldStyle = defaults.object(forKey: styleKey)
        let oldVersion = defaults.object(forKey: versionKey)
        SubtitleStyleConfiguration(
            fontFamilyName: "Menlo", fontSize: 27, isBold: true,
            textColor: .cyan, borderWidth: 2, backgroundOpacity: 0.65, verticalPosition: 84
        ).saveToDefaults(defaults)
        let visibility = MediaControlsVisibility()
        visibility.acquireInteractionLock(id: "text-subtitle-test")
        let inspector = UIHierarchyInspector(rootView: MediaPreviewView(
            fileURL: video, fileName: video.lastPathComponent, isImmersiveFullscreen: true,
            showsFloatingFullScreenButton: false
        ).environment(\.mediaControlsVisibility, visibility))
        defer {
            inspector.updateRootView(EmptyView())
            visibility.tearDown()
            defaults.set(oldStyle, forKey: styleKey)
            defaults.set(oldVersion, forKey: versionKey)
        }

        let player = try await waitFor(inspector, "mounted playing video") {
            inspector.allSubviews().compactMap { $0 as? AVSampleBufferPlayerNSView }
                .first { $0.isPlaying && CMTimeGetSeconds($0.currentTime) > 0 }
        }
        try XCTUnwrap(player.onCanvasSingleClick)()
        _ = try await waitFor(inspector, "paused video") { player.isPlaying ? nil : true }
        let primaryItem = try await waitFor(inspector, "primary caption menu") {
            self.subtitleMenu(in: inspector)?.item(withTitle: primary.lastPathComponent)
        }
        try invoke(primaryItem)
        let single = try await waitFor(inspector, "cyan multiline primary caption") {
            let ink = try self.captionInk(in: inspector.hostingView)
            return ink.rowBands >= 2 ? ink : nil
        }
        let secondaryItem = try XCTUnwrap(
            subtitleMenu(in: inspector)?.item(withTitle: MediaLocalization.text(.secondarySubtitle))?
                .submenu?.item(withTitle: secondary.lastPathComponent)
        )
        try invoke(secondaryItem)
        let dual = try await waitFor(inspector, "secondary caption above primary") {
            let ink = try self.captionInk(in: inspector.hostingView)
            return ink.rowBands > single.rowBands && ink.top < single.top ? ink : nil
        }

        XCTAssertEqual(dual.bottom, single.bottom, accuracy: 0.005)
        XCTAssertGreaterThan(dual.top, 0.5)
        XCTAssertLessThan(dual.bottom, 0.88, "Captions should stay above the lower letterbox")
        XCTAssertFalse(inspector.window.isVisible)
        print("TTZip text subtitle raster: primary \(single); dual \(dual)")

        XCTAssertTrue(player.isControlBarVisible)
        visibility.releaseInteractionLock(id: "text-subtitle-test")
        visibility.setHovered(false)
        _ = try await waitFor(inspector, "hidden controls with identical captions") {
            guard !player.isControlBarVisible else { return nil as Bool? }
            return try self.captionInk(in: inspector.hostingView) == dual ? true : nil
        }
        player.seek(to: CMTime(seconds: 7, preferredTimescale: 600))
        _ = try await waitFor(inspector, "expired text cues") {
            let ink = try self.captionInk(in: inspector.hostingView)
            return ink.pixels == 0 && CMTimeGetSeconds(player.currentTime) > 6 ? true : nil
        }
        try await verifyNativeViewportKeepsCueWithoutTextPresentation(inspector, video: video)
    }

    private func verifyNativeViewportKeepsCueWithoutTextPresentation(
        _ inspector: UIHierarchyInspector,
        video: URL
    ) async throws {
        inspector.updateRootView(EmptyView())
        inspector.updateRootView(AVSampleBufferVideoPlayerView(url: video))
        let native = try await waitFor(inspector, "native-only video viewport") {
            inspector.allSubviews().compactMap { $0 as? AVSampleBufferPlayerNSView }.first { $0.isPresenting }
        }
        native.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
        _ = try await waitFor(inspector, "active native text cue") {
            guard let session = VideoPlaybackSessions.shared.current, session.url == video,
                  !session.activeSubtitleText.isEmpty else { return nil as Bool? }
            XCTAssertEqual(session.subtitleStyle.textColor, .cyan)
            return true
        }
        XCTAssertEqual(try captionInk(in: inspector.hostingView).pixels, 0)
    }

    private func writeSubtitle(_ cue: String, at url: URL) throws {
        try Data("1\n00:00:00,000 --> 00:00:04,000\n\(cue)\n\n".utf8).write(to: url)
    }

    private func subtitleMenu(in inspector: UIHierarchyInspector) -> NSMenu? {
        inspector.allSubviews().compactMap { $0 as? TTZipSubtitleTrackMenu.MenuButton }.first?.trackMenu
    }

    private func invoke(_ item: NSMenuItem) throws {
        let action = try XCTUnwrap(item.action)
        let target = try XCTUnwrap(item.target)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: target, from: item))
    }

    private func waitFor<Value>(
        _ inspector: UIHierarchyInspector,
        _ description: String,
        value: () throws -> Value?
    ) async throws -> Value {
        let deadline = ContinuousClock.now + .seconds(4)
        repeat {
            inspector.hostingView.layoutSubtreeIfNeeded()
            if let result = try value() { return result }
            try await Task.sleep(for: .milliseconds(40))
        } while ContinuousClock.now < deadline
        return try XCTUnwrap(nil, "Expected \(description)")
    }

    private struct CaptionInk: CustomStringConvertible, Equatable {
        let pixels: Int
        let rowBands: Int
        let top: Double
        let bottom: Double

        var description: String { "\(pixels) pixels, \(rowBands) rows, \(top)...\(bottom)" }
    }

    private func captionInk(in host: NSView) throws -> CaptionInk {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var pixels = 0
        var rows: [Int] = []
        for y in stride(from: height / 2, to: height * 9 / 10, by: 2) {
            var rowPixels = 0
            for x in stride(from: width / 10, to: width * 9 / 10, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.greenComponent > 0.62, color.blueComponent > 0.70,
                      color.redComponent + 0.28 < color.greenComponent else { continue }
                rowPixels += 1
            }
            if rowPixels >= 3 {
                rows.append(y)
                pixels += rowPixels
            }
        }
        let rowBands = rows.indices.dropFirst().reduce(rows.isEmpty ? 0 : 1) { count, index in
            count + (rows[index] - rows[index - 1] > 6 ? 1 : 0)
        }
        return CaptionInk(
            pixels: pixels,
            rowBands: rowBands,
            top: Double(rows.first ?? 0) / Double(height),
            bottom: Double(rows.last ?? 0) / Double(height)
        )
    }
}
