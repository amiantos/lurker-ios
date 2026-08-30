// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The kinds the uploads browser filters by, and which mimes each one covers.
///
/// A port of the server's `shared/uploadKinds.ts`, which exists there for the same reason it
/// exists here: two sides have to answer the same question and must not drift. The server builds
/// its `WHERE` clause from it, and the client decides which glyph a row without a thumbnail gets.
///
/// ⚠⚠ **The FILTER is the server's, not this.** `kind=` goes on the wire and the server decides
/// what comes back — the client only ever holds the pages it has scrolled through, so a
/// render-time filter over them would be filtering the wrong set (`UploadsRequest` says the same
/// thing about search). This type is here so the *presentation* of a kind can't invent a second,
/// disagreeing rule.
///
/// ⚠⚠ `application/json` is the whole reason the extra-mimes table exists. It is a text file that
/// IANA files under `application/` (RFC 8259 registers `application/json`; there is no
/// `text/json`), so a prefix match on `text/` misses it — and an uploaded `.json` would be drawn
/// with a generic glyph while the server files it under Text (lurker#788). Hand-writing
/// `mime.hasPrefix("text/")` here is exactly the trap the shared module was written to stop.
public enum UploadKind: String, CaseIterable, Sendable {
    case image
    case video
    case audio
    case text

    /// Mimes a kind covers that its `<kind>/…` prefix does not. Empty for every kind but text.
    private static let extraMimes: [UploadKind: [String]] = [
        .text: ["application/json"]
    ]

    /// Does an upload of this mime belong under this kind? The single definition, mirroring
    /// `mimeMatchesKind` on the server.
    public func matches(mime: String?) -> Bool {
        let value = mime ?? ""
        return value.hasPrefix("\(rawValue)/") || Self.extraMimes[self, default: []].contains(value)
    }

    /// Which kind a mime falls under, or nil for one no filter covers (a PDF, an archive).
    ///
    /// ⚠ Never sent to the server — the row already carries its mime and the server derives the
    /// kind from it there. This is for choosing a glyph.
    public static func of(mime: String?) -> UploadKind? {
        allCases.first { $0.matches(mime: mime) }
    }

    /// What the filter is called in the UI, matching the web client's chips.
    public var label: String {
        switch self {
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .text: "Text"
        }
    }
}
