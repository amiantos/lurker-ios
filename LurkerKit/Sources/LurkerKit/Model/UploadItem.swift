// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One row of the account's upload history — a file this user put somewhere, kept so it can be
/// found again and re-shared without being re-uploaded (#138).
///
/// The server owns every field here; nothing is derived on the client. In particular
/// `canDelete` is server-derived from whether the driver captured a delete handle *and* its
/// uploader config still exists — see the note on that property.
public struct UploadItem: Sendable, Equatable, Identifiable {
    public let id: Int
    /// The public address of the stored object. This is what gets pasted into a message, opened
    /// in the viewer, and shared — the origin URL, never a proxy path.
    public let url: String
    /// As uploaded. Nil for a pasted screenshot, which never had one.
    public let filename: String?
    /// Sniffed from the bytes by the server, so it is the truth about what the file is rather
    /// than what its name claims. `UploadKind.of(mime:)` maps it to a kind.
    public let mime: String?
    public let byteSize: Int?
    public let createdAt: Date?
    /// Starred by the owner. Server-side state, so the same quick-access set is on every device.
    public let favorite: Bool
    /// Whether deleting this row would actually destroy the stored bytes.
    ///
    /// ⚠⚠ **Never offer a delete affordance without it.** There is no remove-the-record-only
    /// path: the route refuses a delete for a row whose bytes can't be destroyed (no ref, a
    /// driver that can't delete, a config since removed, a moderation tombstone), so a button
    /// offered anyway would be one that reliably fails. Anonymous and legacy rows can't be
    /// deleted, and that is a fact about where the file went, not a permission.
    public let canDelete: Bool
    /// Where to fetch this row's thumbnail, or nil when there isn't one.
    ///
    /// ⚠ Either a path on this instance (`/api/uploads/<id>/thumb`, bearer-gated) or an absolute
    /// URL on the uploader's own CDN — the server picks, and nothing distinguishes them on the
    /// wire. Both are handled by the same media request builder the link-preview proxy uses, so
    /// this must be passed through it rather than concatenated onto the base URL.
    public let thumbnailPath: String?
    /// The hosted operator moderated this upload away. The row survives as a tombstone; its
    /// bytes are gone, so there is nothing to view, share, or copy a working link to.
    public let removed: Bool

    public init(
        id: Int,
        url: String,
        filename: String? = nil,
        mime: String? = nil,
        byteSize: Int? = nil,
        createdAt: Date? = nil,
        favorite: Bool = false,
        canDelete: Bool = false,
        thumbnailPath: String? = nil,
        removed: Bool = false
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.mime = mime
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.favorite = favorite
        self.canDelete = canDelete
        self.thumbnailPath = thumbnailPath
        self.removed = removed
    }

    /// Which filter chip this row belongs under, or nil for a mime no kind covers.
    public var kind: UploadKind? { UploadKind.of(mime: mime) }

    /// What to call this row when there is no filename. Matches the web client's "(pasted)":
    /// a file that arrived from the clipboard genuinely never had a name, and inventing one
    /// from the URL's last path segment would show the storage key, which means nothing.
    public var displayName: String { filename ?? "(pasted)" }
}

/// One page of `GET /api/uploads`.
///
/// ⚠ There is no `nextBefore` in the envelope, unlike highlights/bookmarks/search: this route
/// pages on a keyset cursor the *client* carries, so the next page's `before` is the last row's
/// id and "there is more" is `items.count == limit`. `UploadsRequest.hasMore` is where that rule
/// lives, because the starred view breaks it — see `UploadsFilter.favoritesOnly`.
public struct UploadsPage: Sendable, Equatable {
    public let items: [UploadItem]

    public init(items: [UploadItem]) {
        self.items = items
    }
}
