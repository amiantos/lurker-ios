// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit
import UniformTypeIdentifiers

/// The composer's text view, subclassed for one reason: intercept an **image paste** (#14).
/// Copy a screenshot and paste it here and it should upload, not drop a text attachment into
/// the field. Everything else — a text paste included — falls straight through to
/// `UITextView`.
final class ComposerTextView: UITextView {

    /// A pasted image: original bytes, the sniffed mime, and a filename. Bytes rather than a
    /// re-encoded `UIImage`, so a PNG screenshot stays a lossless PNG and the server sees
    /// exactly what was copied. Empty tuple positions are (data, mime, filename).
    var onPasteImage: ((Data, String, String) -> Void)?

    /// Offer "Paste" whenever the pasteboard holds an image, even with no text on it — so a
    /// copied screenshot is pasteable into an empty field. `hasImages` is a detection
    /// property, so probing it here doesn't trip the "pasted from" privacy banner; only the
    /// real read in `paste(_:)` does.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let pasted = Self.imageFromPasteboard() {
            onPasteImage?(pasted.data, pasted.mime, pasted.filename)
            return
        }
        super.paste(sender)
    }

    private static func imageFromPasteboard() -> (data: Data, mime: String, filename: String)? {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasImages else { return nil }
        // Prefer the original bytes in a known raster type so a screenshot stays a lossless
        // PNG; only fall back to a re-encode if the pasteboard vends nothing we recognize.
        for type in [UTType.png, .jpeg, .heic, .gif, .tiff, .webP] {
            if let data = pasteboard.data(forPasteboardType: type.identifier), !data.isEmpty {
                let ext = type.preferredFilenameExtension ?? "png"
                return (data, type.preferredMIMEType ?? "image/png", "pasted-image.\(ext)")
            }
        }
        if let image = pasteboard.image, let data = image.pngData() {
            return (data, "image/png", "pasted-image.png")
        }
        return nil
    }
}
