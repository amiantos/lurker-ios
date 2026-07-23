// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import AVFoundation
import Foundation
import LurkerKit

/// Shrinks a picked video to fit the instance's upload cap before it goes over the wire.
///
/// The server does **not** transcode video — it stores the bytes as-is, scrubbing only the
/// container metadata (GPS in the MP4 `moov` atom) — so a raw phone clip has to be
/// compressed here or it never fits: a 4K60 recording is ~350 MB/min, well past the 200 MB
/// ceiling. Images need none of this; the server's sharp pipeline re-encodes and resizes
/// them, so they upload untouched.
///
/// Lives in the app target rather than LurkerKit on purpose: LurkerKit is compiled for
/// macOS too (that's how `swift test` runs), and the modern AVFoundation media APIs aren't
/// available at that package's minimum — keeping the transcode here dodges the availability
/// dance and keeps the package platform-light.
enum VideoCompressor {

    /// A video prepared for upload.
    struct Prepared {
        let url: URL
        /// True when `url` is a freshly transcoded temp file the caller must delete; false
        /// when it's the untouched original (already small enough to pass through).
        let isTemporary: Bool
    }

    /// The preset ladder, gentlest shrink first. HEVC 1080p is ~50–60 MB/min and clears the
    /// cap for all but the longest clips; below it we drop to H.264 at ever-lower resolutions
    /// (there's no HEVC preset under 1080p) for long 4K. `LowQuality` is the floor — a very
    /// aggressive, device-chosen small size — so even a long clip has a fighting chance of
    /// fitting a 90 MB body. Every rung emits MP4 (`video/mp4`), which every uploader accepts
    /// and the server scrubs.
    private static let presetLadder = [
        AVAssetExportPresetHEVC1920x1080,
        AVAssetExportPreset1280x720,
        AVAssetExportPreset960x540,
        AVAssetExportPreset640x480,
        AVAssetExportPresetLowQuality,
    ]

    /// Prepare `source` to fit under `maxBytes`. Returns the original untouched when it
    /// already fits; otherwise transcodes down the preset ladder and returns the first
    /// result that fits. `onProgress` reports the transcode as a 0…1 fraction.
    ///
    /// Throws `UploadError.cannotCompressEnough` when even the smallest preset stays over the
    /// cap, or `.compressionFailed` when the export itself errors.
    static func prepare(
        source: URL,
        maxBytes: Int = Uploads.maxBytes,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Prepared {
        if fileSize(source) <= maxBytes {
            return Prepared(url: source, isTemporary: false)
        }

        let asset = AVURLAsset(url: source)
        var completedButTooBig = false
        var lastFailure = "the video format isn't supported"

        // Estimation is a cheap metadata calc (no transcode), and every preset is a roughly
        // fixed bitrate, so we can predict which rung will fit and START there — skipping the
        // doomed high-quality transcodes. A high-res screen recording used to re-encode 3×
        // (1080p → 720p → 540p) before one landed under the cap; now it jumps straight to the
        // rung that fits and transcodes once.
        let startIndex: Int
        switch await plan(asset: asset, maxBytes: maxBytes) {
        case .startAt(let index):
            startIndex = index
        case .unknown:
            // No estimates available — run the whole ladder top-to-bottom (original behavior).
            startIndex = 0
        case .impossible:
            // Even the smallest rung is *predicted* over the cap. Don't burn a full transcode
            // of a huge file to confirm what the estimate already told us — fail now.
            throw UploadError.cannotCompressEnough
        }

        for preset in presetLadder[startIndex...] {
            // Bail before starting a new export if the user cancelled between rungs.
            try Task.checkCancellation()
            guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
                continue // preset incompatible with this source — try the next rung
            }
            let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lurker-video-\(UUID().uuidString).mp4")
            export.shouldOptimizeForNetworkUse = true

            // Progress via the modern states sequence (iOS 18+). AVAssetExportSession isn't
            // Sendable, so box it to reach `states` from the @Sendable poll task. The sequence
            // ends when the export reaches a terminal state, so the loop tears itself down.
            let boxed = Unchecked(export)
            let progressPoll = Task {
                for await state in boxed.value.states(updateInterval: 0.2) {
                    if case .exporting(let progress) = state { onProgress(progress.fractionCompleted) }
                }
            }
            do {
                // `export(to:as:)` is cancellation-aware: cancelling the surrounding task
                // cancels the export and throws, so no manual cancelExport() bridging is needed
                // — a cancelled upload stops the transcode promptly instead of running it out.
                try await export.export(to: outURL, as: .mp4)
            } catch {
                progressPoll.cancel()
                try? FileManager.default.removeItem(at: outURL)
                // A user cancel surfaces here; re-raise it as cancellation (not a failure) so
                // the caller stays silent rather than popping an error alert.
                if Task.isCancelled { throw CancellationError() }
                lastFailure = error.localizedDescription
                continue // a genuine export error on this rung — try the next, smaller one
            }
            progressPoll.cancel()

            if fileSize(outURL) <= maxBytes {
                onProgress(1)
                return Prepared(url: outURL, isTemporary: true)
            }
            // Under the ceiling was the whole point; this rung missed it. Drop to the next,
            // smaller preset — but remember we got a valid file, so if the ladder runs out the
            // error is "too large", not "couldn't process".
            completedButTooBig = true
            try? FileManager.default.removeItem(at: outURL)
        }

        throw completedButTooBig ? UploadError.cannotCompressEnough : .compressionFailed(lastFailure)
    }

    /// The outcome of pre-flighting the ladder with cheap size estimates.
    private enum Plan {
        /// The highest-quality rung whose estimate fits — start transcoding here.
        case startAt(Int)
        /// Estimates were available and every rung is predicted over the cap — don't bother.
        case impossible
        /// No usable estimates (older/edge asset) — run the full ladder and check real sizes.
        case unknown
    }

    /// Pre-flight the ladder with `estimateOutputFileLength` (a metadata calc, no transcode)
    /// to decide where — or whether — to transcode. Trusting the estimate is what lets us both
    /// jump straight to the right rung AND fail fast on a clip no rung can shrink enough,
    /// instead of transcoding a gigabyte to confirm it.
    private static func plan(asset: AVAsset, maxBytes: Int) async -> Plan {
        var smallestOverIndex: Int?
        var smallestOverEstimate = Int64.max
        for (index, preset) in presetLadder.enumerated() {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.outputFileType = .mp4
            let estimate: Int64 = await withCheckedContinuation { continuation in
                session.estimateOutputFileLength { length, error in
                    continuation.resume(returning: error == nil ? length : -1)
                }
            }
            guard estimate > 0 else { continue }
            if estimate <= Int64(maxBytes) { return .startAt(index) }
            // Track the rung with the smallest estimate that still overshot.
            if estimate < smallestOverEstimate {
                smallestOverEstimate = estimate
                smallestOverIndex = index
            }
        }
        // Estimates are approximate (measured ~1% off in testing). If the smallest rung is
        // only marginally over, still ATTEMPT it rather than declaring defeat — the real
        // fileSize check afterward is the true gate; only give up when even the smallest is
        // clearly (>10%) over the cap, so a borderline clip that would actually fit isn't
        // rejected without trying.
        guard let smallestOverIndex else { return .unknown }
        return smallestOverEstimate <= Int64(Double(maxBytes) * 1.1) ? .startAt(smallestOverIndex) : .impossible
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
    }

    /// Carries a non-Sendable value across a `@Sendable` boundary. Used only for
    /// `AVAssetExportSession`, whose `progress`/`cancelExport()` are documented safe to touch
    /// off the export's own thread.
    private struct Unchecked<T>: @unchecked Sendable {
        nonisolated(unsafe) let value: T
        init(_ value: T) { self.value = value }
    }
}
