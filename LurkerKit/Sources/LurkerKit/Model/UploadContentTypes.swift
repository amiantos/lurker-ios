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
/// has no test bundle — and the one genuinely uncertain thing about this list (markdown has no SDK
/// constant and has to be constructed by extension, which can fail) is exactly the sort of fact
/// worth pinning rather than assuming.
public enum UploadContentTypes {

    /// Markdown, which the SDK has no constant for.
    ///
    /// ⚠ `net.daringfireball.markdown` is a system-declared type, so this resolves in practice —
    /// but `UTType(filenameExtension:)` is failable and a nil here would be a crash on the one
    /// line that opens the picker. Optional all the way through instead.
    static let markdown = UTType(filenameExtension: "md")

    /// The `forOpeningContentTypes` list for `UIDocumentPickerViewController`.
    ///
    /// ⚠⚠ `.plainText` and `.json` are siblings, not parent and child: `public.json` conforms to
    /// `public.text`, NOT to `public.plain-text`, so listing plain text alone leaves every `.json`
    /// greyed out. The picker matches by conformance, so a wrong guess about this hierarchy is
    /// invisible until somebody cannot pick a file.
    ///
    /// ⚠ Text was missing entirely before #125 — not just the `.md`/`.json` dialects lurker#788
    /// added, but `.txt`, which the upload route has accepted the whole time. The dialects are the
    /// reason to touch this; plain text was already broken.
    public static var forOpening: [UTType] {
        [.image, .movie, .plainText, .json] + [markdown].compactMap { $0 }
    }
}
