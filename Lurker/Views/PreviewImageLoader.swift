// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import ImageIO
import LurkerKit
import UIKit

/// Decoded images for preview attachments, keyed by the server's proxy path.
///
/// A separate cache from `URLCache` rather than a duplicate of it, because they hold
/// different things: `URLCache` holds *bytes* (and the server marks these `immutable` with a
/// long max-age, so it does the heavy lifting across launches), while this holds the *decoded
/// bitmap*. Re-decoding a JPEG on every `cellForRowAt` during a fast scroll is the expensive
/// part, and it's the part `URLCache` can't help with.
///
/// `NSCache` rather than a dictionary: it evicts under memory pressure on its own, which is
/// exactly the policy wanted for something that is, in the end, decoration.
@MainActor
final class PreviewImageLoader {

    static let shared = PreviewImageLoader()

    private let cache = NSCache<NSString, UIImage>()

    /// Everyone waiting on a path, not just whoever asked first.
    ///
    /// ⚠ This was a `Set<String>` of in-flight paths, and the bug that produced was the QA
    /// report "sometimes images don't load when they scroll on, and swiping back and forth
    /// gives different results". A cell arriving while a load was already in flight hit the
    /// early return and registered *nothing* — so it drew empty, and the only callback that
    /// existed belonged to a cell that had since been recycled. Whether an image appeared
    /// came down to which cell happened to ask first, which is exactly the kind of
    /// order-dependent flakiness that reads as random.
    private var waiters: [String: [(UIImage) -> Void]] = [:]

    /// Paths that failed, so they aren't refetched on every cell dequeue.
    ///
    /// Without this a broken image — a proxy 404/413, or anything `UIImage(data:)` can't
    /// decode — started a fresh download and decode every time its row was configured, which
    /// during a scroll is several times a second.
    private var failed = Set<String>()

    private init() {
        // Counted in decoded bytes via `cost` below; a few dozen full-width previews.
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    /// An already-decoded image, or nil.
    ///
    /// Synchronous and non-committal: a cell asks during layout and draws whatever is there.
    func image(for path: String) -> UIImage? {
        cache.object(forKey: path as NSString)
    }

    /// Deliver the image at `path`, fetching and decoding it if we don't have it yet.
    ///
    /// `then` is registered on *every* call, so a cell that arrives mid-flight is served
    /// too — and it's called at most once per call. Callers pass a closure holding a weak
    /// view, so a recycled cell's callback becomes a no-op rather than painting the wrong row.
    func load(path: String, using model: ChatViewModel, then deliver: @escaping (UIImage) -> Void) {
        if let cached = cache.object(forKey: path as NSString) {
            deliver(cached)
            return
        }
        if failed.contains(path) { return }
        if waiters[path] != nil {
            waiters[path]?.append(deliver)
            return
        }
        waiters[path] = [deliver]

        Task { @MainActor in
            // Decoding off the main actor: a full-width JPEG is a few milliseconds, and a few
            // milliseconds during a scroll is a dropped frame.
            var image: UIImage?
            var isVerdict = true
            switch await model.proxiedMedia(path: path) {
            case .success(let data):
                let decoded = await Self.decode(data)
                image = decoded.image
                // Recorded whether or not it animates, so `isAnimated` can answer "no" without
                // confusing it with "not loaded yet".
                frames[path] = decoded.frames
                // Bytes we cannot decode are a verdict: asking again gets the same bytes.
            case .retryable:
                isVerdict = false
            case .permanent:
                break
            }
            let pending = waiters.removeValue(forKey: path) ?? []
            guard let image else {
                // ⚠⚠ Only a VERDICT is latched. The proxy answers a throttled origin with 503 —
                // and one origin in particular matters: every GitHub link's og:image comes from
                // opengraph.githubassets.com, which advertises a budget of 100, so a channel
                // with a run of GitHub links spends it in a single burst from the instance's one
                // IP. Latching those meant a minute of upstream throttling blanked those images
                // for the rest of the session, with no way to repair it short of relaunching.
                // A retryable failure simply isn't remembered, so the next dequeue tries again.
                if isVerdict { failed.insert(path) }
                return
            }
            cache.setObject(image, forKey: path as NSString, cost: Self.cost(of: image))
            for callback in pending { callback(image) }
        }
    }

    /// The still, plus how many frames the file actually holds.
    ///
    /// ⚠ Only the FIRST frame is decoded here, even for an animation. That is the whole reason
    /// playback is opt-in: a hundred-frame GIF held as decoded frames is hundreds of megabytes
    /// against a 32 MB cache budget, and autoplay pays that for every animation in scrollback
    /// whether or not anybody is watching. A still costs exactly what a JPEG costs.
    nonisolated private static func decode(_ data: Data) async -> (image: UIImage?, frames: Int) {
        await Task.detached(priority: .userInitiated) {
            let count = CGImageSourceCreateWithData(data as CFData, nil)
                .map { CGImageSourceGetCount($0) } ?? 1
            guard let image = UIImage(data: data) else { return (nil as UIImage?, count) }
            // Force the decode now rather than on first draw, which would otherwise happen on
            // the main thread at exactly the wrong moment.
            return (image.preparingForDisplay() ?? image, count)
        }.value
    }

    // MARK: - Animation, on request

    /// Frame counts by path, learned when the still was decoded.
    private var frames: [String: Int] = [:]

    /// Longest edge an animation frame is decoded to.
    ///
    /// ⚠ Downsampled, and the arithmetic is the reason: a 1024x768 frame is 3 MB, so a
    /// hundred-frame GIF at full size is ~300 MB. 720 covers a 160pt mosaic tile at 3x with room
    /// to spare, and a lone image is slightly soft WHILE PLAYING — which is the moment nobody is
    /// studying a still.
    nonisolated private static let animationMaxPixel: CGFloat = 720
    /// Ceiling on one animation's decoded frames. Past this we decline to animate at all rather
    /// than play a truncated loop, which reads as a bug rather than as a limit.
    nonisolated private static let animationBudget = 48 * 1024 * 1024

    /// Whether `path` holds an animation.
    ///
    /// Answers false until the still has loaded — the frame count comes from the same decode —
    /// so a caller re-asks when its image arrives. That is exactly when the badge appears, and
    /// it costs no layout: a badge is decoration over a box whose size the metadata already
    /// fixed, so nothing moves.
    func isAnimated(_ path: String) -> Bool {
        (frames[path] ?? 1) > 1
    }

    /// Build the animated image for `path`, downsampled and bounded. Nil if it can't or won't.
    ///
    /// ⚠ The bytes are re-fetched rather than held. `URLSession`'s media cache keeps them (the
    /// proxy marks them `immutable` with a long max-age), so this is a local read — and holding
    /// every animation's Data against the chance somebody presses play is the memory problem
    /// this design exists to avoid.
    func loadAnimated(
        path: String, using model: ChatViewModel, then deliver: @escaping (UIImage?) -> Void
    ) {
        Task { @MainActor in
            guard case .success(let data) = await model.proxiedMedia(path: path) else {
                deliver(nil)
                return
            }
            deliver(await Self.animate(data))
        }
    }

    nonisolated private static func animate(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let count = CGImageSourceGetCount(source)
            guard count > 1 else { return nil }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: animationMaxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]

            var images: [UIImage] = []
            var total = 0.0
            var bytes = 0
            for index in 0..<count {
                guard
                    let frame = CGImageSourceCreateThumbnailAtIndex(
                        source, index, options as CFDictionary)
                else { continue }
                bytes += frame.width * frame.height * 4
                // Refuse rather than truncate — see `animationBudget`.
                if bytes > animationBudget { return nil }
                images.append(UIImage(cgImage: frame))
                total += frameDelay(source, at: index)
            }
            guard images.count > 1 else { return nil }
            // ⚠ One duration across the whole loop, which is what `animatedImage` supports, so a
            // GIF with variable per-frame delays plays at its average pace. The alternative is a
            // display-link view driving frames by hand; it has not been worth it, and this note
            // is here so the limitation is a decision rather than a surprise.
            return UIImage.animatedImage(with: images, duration: total)
        }.value
    }

    /// A frame's delay, honouring the 10ms floor every other GIF renderer applies — a great many
    /// GIFs declare 0 and mean "as fast as sensible", not "infinitely fast".
    nonisolated private static func frameDelay(_ source: CGImageSource, at index: Int) -> Double {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return delay < 0.011 ? 0.1 : delay
    }

    private static func cost(of image: UIImage) -> Int {
        let size = image.size
        let scale = image.scale
        return Int(size.width * scale * size.height * scale * 4)
    }

    /// Drop everything. Called on sign-out — decoded images from the previous account must not
    /// survive into the next one's session, and a different instance's signed proxy tokens
    /// wouldn't verify anyway.
    func reset() {
        cache.removeAllObjects()
        waiters.removeAll()
        failed.removeAll()
        frames.removeAll()
    }
}
