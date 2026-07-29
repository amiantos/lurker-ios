// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

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
    /// Paths currently being fetched, so a cell redrawn mid-flight doesn't start a second
    /// request for the same bytes. During a scroll a row can be configured several times a
    /// second.
    private var inFlight = Set<String>()

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

    /// Fetch and decode if we don't have it. `completion` runs only on a successful *new*
    /// load, so a caller can use it purely as "something changed, redraw".
    func load(path: String, using model: ChatViewModel, completion: @escaping () -> Void) {
        guard cache.object(forKey: path as NSString) == nil, !inFlight.contains(path) else {
            return
        }
        inFlight.insert(path)
        Task { @MainActor in
            defer { inFlight.remove(path) }
            guard let data = await model.proxiedMedia(path: path) else { return }
            // Decoding off the main actor: a full-width JPEG is a few milliseconds, and a few
            // milliseconds during a scroll is a dropped frame.
            guard let image = await Self.decode(data) else { return }
            cache.setObject(image, forKey: path as NSString, cost: Self.cost(of: image))
            completion()
        }
    }

    private static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil as UIImage? }
            // Force the decode now rather than on first draw, which would happen on the main
            // thread at exactly the wrong moment.
            return image.preparingForDisplay() ?? image
        }.value
    }

    private static func cost(of image: UIImage) -> Int {
        let size = image.size
        let scale = image.scale
        return Int(size.width * scale * size.height * scale * 4)
    }

    func reset() {
        cache.removeAllObjects()
        inFlight.removeAll()
    }
}
