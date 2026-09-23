//
//  ArtworkTests.swift
//
//  Copyright (C) 2026 NeonRost
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
//  Cover picture processing (§4.5).
//
//  This collection came out of a bug noticed in use: added covers arrived
//  **black**. The cause was an `NSBitmapImageRep` with 24 bits per pixel,
//  which CoreGraphics cannot back with a drawing context — drawing went
//  nowhere. The brightness check below would have shown it immediately.
//

import AppKit
import Foundation

enum ArtworkTests {

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ label: String, detail: @autoclosure () -> String = "") {
        checks += 1
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            let extra = detail()
            print("  ✗ \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        check(actual == expected, label, detail: "is \(actual), expected \(expected)")
    }

    static func section(_ title: String) { print("\n━━ \(title)") }

    /// Mean brightness over a grid. A black picture is at 0.
    static func brightness(of data: Data) -> Double? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        var sum = 0.0
        var count = 0
        let step = max(1, rep.pixelsWide / 30)
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                sum += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }

    static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let image = NSImage(data: data),
              let rep = image.representations.first else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    /// Creates a colorful test picture via ffmpeg — more reliable than a
    /// self-painted gradient, and it is part of the project anyway.
    static func makeImage(size: String, format: String, into folder: String) throws -> Data {
        let path = "\(folder)/probe-\(size).\(format)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                             "-f", "lavfi", "-i", "testsrc2=size=\(size):duration=1",
                             "-frames:v", "1", path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func run() throws -> Int32 {
        let work = NSTemporaryDirectory() + "sleeve-artwork-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }

        let large = try makeImage(size: "1400x1400", format: "jpg", into: work)
        let landscape = try makeImage(size: "1400x900", format: "png", into: work)
        let small = try makeImage(size: "600x600", format: "jpg", into: work)

        // MARK: - The bug that started this

        section("Scaling does not turn the picture black")
        let original = brightness(of: large) ?? 0
        check(original > 0.05, "source picture is not black", detail: "\(original)")

        let options = ArtworkProcessor.Options(maximumEdge: 1000, jpegQuality: 0.85,
                                               output: .jpeg)
        guard let scaled = ArtworkProcessor.prepare(large, options: options) else {
            check(false, "prepare returned a result")
            return 1
        }
        let after = brightness(of: scaled.data) ?? 0
        check(after > 0.05, "result is not black", detail: "brightness \(after)")
        check(abs(after - original) < 0.08,
              "brightness is preserved",
              detail: "before \(String(format: "%.3f", original)), after \(String(format: "%.3f", after))")

        // MARK: - Dimensions

        section("Dimensions")
        let size = dimensions(of: scaled.data)
        equal(size?.width, 1000, "longest edge brought to the maximum")
        equal(size?.height, 1000, "square stays square")

        guard let landscapeScaled = ArtworkProcessor.prepare(landscape, options: options) else {
            check(false, "landscape processed"); return 1
        }
        let landscapeSize = dimensions(of: landscapeScaled.data)
        equal(landscapeSize?.width, 1000, "landscape: width to the maximum")
        check((landscapeSize?.height ?? 0) == 643, "aspect ratio is preserved",
              detail: "\(landscapeSize?.height ?? 0) instead of 643")
        check((brightness(of: landscapeScaled.data) ?? 0) > 0.05, "landscape not black")

        // MARK: - Format

        section("Format")
        equal(scaled.mimeType, "image/jpeg", "JPEG stays JPEG")
        equal(landscapeScaled.mimeType, "image/jpeg", "PNG becomes JPEG")
        equal(Artwork.detectMimeType(of: landscape), "image/png", "PNG is recognized as such")

        let untouched = ArtworkProcessor.prepare(landscape, options: .passthrough)
        equal(untouched?.data, landscape, "without scaling and converting the original stays")
        equal(untouched?.mimeType, "image/png", "… with its MIME type")

        // The bug noticed during the change: a PNG silently became a JPEG
        // when scaled down, although "keep format" was chosen.
        var pngScaleDown = ArtworkProcessor.Options(maximumEdge: 500, output: .keepSource)
        let pngSmall = ArtworkProcessor.prepare(landscape, options: pngScaleDown)
        equal(pngSmall?.mimeType, "image/png", "a PNG stays a PNG when scaled down")
        equal(dimensions(of: pngSmall?.data ?? Data())?.width, 500, "… and really gets smaller")
        check((brightness(of: pngSmall?.data ?? Data()) ?? 0) > 0.05, "… and is not black")

        pngScaleDown.output = .jpeg
        equal(ArtworkProcessor.prepare(landscape, options: pngScaleDown)?.mimeType, "image/jpeg",
              "with an explicit choice it becomes a JPEG")

        equal(ArtworkProcessor.pixelSize(of: landscape)?.width, 1400, "pixel dimensions straight from the data")

        let smallStays = ArtworkProcessor.prepare(small, options: options)
        equal(smallStays?.data, small, "a picture below the maximum is not re-encoded")

        // MARK: - Edge cases

        section("Edge cases")
        check(ArtworkProcessor.prepare(Data("not a picture".utf8), options: options) == nil,
              "non-picture yields nil")
        check(ArtworkProcessor.prepare(Data(), options: options) == nil,
              "empty data yields nil")

        var tiny = options
        tiny.maximumEdge = 64
        guard let verySmall = ArtworkProcessor.prepare(large, options: tiny) else {
            check(false, "very small target size processed"); return 1
        }
        equal(dimensions(of: verySmall.data)?.width, 64, "64 px are hit as well")
        check((brightness(of: verySmall.data) ?? 0) > 0.05, "… and are not black")
        check(verySmall.data.count < large.count / 4, "the file gets much smaller",
              detail: "\(verySmall.data.count) instead of \(large.count)")

        equal(verySmall.pictureType, .frontCover, "picture type preset to Front Cover")

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            print("✗ \(failures) failed")
            return 1
        }
        print("✓ All green.")
        return 0
    }
}
