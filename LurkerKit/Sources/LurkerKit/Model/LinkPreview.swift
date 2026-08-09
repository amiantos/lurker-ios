// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// What a resolved URL turned out to be.
///
/// Decided by the *server*, from the response's `Content-Type` — never from the file
/// extension. The extension only ever decides which of the two settings would cover a URL,
/// and therefore whether to bother asking; see `PreviewSelection`.
public enum PreviewKind: String, Codable, Sendable {
    case image
    case video
    case audio
    case page
    /// A page we know how to build a privacy-preserving player URL for (YouTube, Vimeo).
    case videoEmbed = "video-embed"

    /// Whether this kind is governed by `chat.inline_media.enabled` rather than
    /// `chat.link_previews.enabled`.
    public var isDirectMedia: Bool {
        switch self {
        case .image, .video, .audio: true
        case .page, .videoEmbed: false
        }
    }
}

/// The server's answer about one URL.
///
/// Byte URLs (`src`, `thumb`) are *paths on our own server*, minted and signed by it. The
/// client never constructs one, and never contacts the origin — that's the whole privacy
/// property of the feature, and it's why these are opaque strings rather than the original
/// URL plus a rule for building a proxy path.
public struct LinkPreview: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        /// A real, cacheable answer: dead link, timeout, refused by the SSRF guard, blocked
        /// by the origin, or a page with nothing worth showing. Never rendered.
        case unavailable
    }

    public let url: String
    public let status: Status
    public let kind: PreviewKind
    public let title: String?
    public let description: String?
    public let siteName: String?
    public let author: String?
    /// Proxy path for direct media — the content itself.
    public let src: String?
    /// Proxy path for a card thumbnail — decoration on a page.
    public let thumb: String?
    public let thumbWidth: Int?
    public let thumbHeight: Int?
    /// Player URL for `videoEmbed`, already privacy-scoped by the server
    /// (`youtube-nocookie.com`). Only ever opened on an explicit tap.
    public let embedUrl: String?
    public let mime: String?

    public init(
        url: String, status: Status, kind: PreviewKind, title: String? = nil,
        description: String? = nil, siteName: String? = nil, author: String? = nil,
        src: String? = nil, thumb: String? = nil, thumbWidth: Int? = nil,
        thumbHeight: Int? = nil, embedUrl: String? = nil, mime: String? = nil
    ) {
        self.url = url
        self.status = status
        self.kind = kind
        self.title = title
        self.description = description
        self.siteName = siteName
        self.author = author
        self.src = src
        self.thumb = thumb
        self.thumbWidth = thumbWidth
        self.thumbHeight = thumbHeight
        self.embedUrl = embedUrl
        self.mime = mime
    }

    /// Whether this preview may be rendered under the current settings.
    ///
    /// Re-checked against the server's answer rather than trusting the guess that prompted
    /// the request. The two can disagree — an extensionless URL that turns out to be a PNG,
    /// a `.jpg` that redirects to an HTML login page — and when they do, the setting that
    /// governs is the one covering what the thing actually *is*. Otherwise "link previews
    /// off" could still be talked into drawing a card.
    public func isAllowed(inlineMedia: Bool, linkPreviews: Bool) -> Bool {
        guard status == .ok else { return false }
        return kind.isDirectMedia ? inlineMedia : linkPreviews
    }
}
