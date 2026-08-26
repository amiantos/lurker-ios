// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UniformTypeIdentifiers

/// What the Files picker will let you choose (#125).
///
/// ⚠⚠ A type absent from this list is not merely unsuggested — Files GREYS THE FILE OUT, with no
/// "All Files" escape hatch. So this list is the whole of what can be uploaded from Files, and an
/// omission reads to the user as "Lurker can't send this" rather than as a filter. The web picker's
/// `accept` attribute had the same trap.
///
/// Lives here rather than beside the picker because `AttachmentPicker` is in the app target, which
/// has no test bundle.
public enum UploadContentTypes {

    /// The `forOpeningContentTypes` list for `UIDocumentPickerViewController`.
    ///
    /// ⚠⚠ `.text`, not `.plainText` — and not a hand-written list of dialects, which is what this
    /// started as and got wrong. `public.json` does NOT conform to `public.plain-text`: they are
    /// siblings under `public.text`, so `[.plainText, .json]` looked complete and would have left
    /// `.yaml` and every other text sibling greyed out. Naming the parent is both smaller and
    /// strictly wider, and it removes the need to be right about the hierarchy at all.
    ///
    /// ⚠ Nothing here becomes active content by being offered. The server classifies from the
    /// BYTES, and any text file that is not one of its three dialects is normalised to
    /// `text/plain` (`contentClass.ts`: `dialectFromFilename(...) ?? claimed ?? PLAIN_TEXT`) — so
    /// an `.html` or `.xml` picked here is stored and served as inert text, not as itself. SVG is
    /// the one text-conforming type that is treated as an image, and it is already offered by
    /// `.image` regardless of this entry.
    ///
    /// ⚠ Text was missing entirely before #125 — not just the `.md`/`.json` dialects lurker#788
    /// added, but `.txt`, which the upload route has accepted the whole time. The dialects are the
    /// reason to touch this; plain text was already broken.
    public static var forOpening: [UTType] { [.image, .movie, .text] }
}
