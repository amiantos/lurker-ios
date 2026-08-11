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

extension LinkPreview {
    /// Whether the media viewer can present this, and it answers per KIND because the two get
    /// their bytes from different places.
    ///
    /// An image is drawn from bytes our own proxy serves, so it needs a `src`. Video and audio
    /// are STREAMED FROM THE ORIGIN and have no `src` at all — the server stopped minting one,
    /// because a card that renders by itself must not report the reader to a stranger's host,
    /// while pressing play is a deliberate act that an address could not be hidden from anyway.
    /// So what those need is an address AVURLAsset can open. A page has nothing to show either way.
    ///
    /// ⚠⚠ This replaces a flat `src != nil` test, which was correct while everything came from
    /// the proxy and became a silent feature deletion the moment the server changed: every clip
    /// fell out of the gallery, the tap took its "nothing to present" branch, and the reader was
    /// handed to Safari. The player and its scrubbing, PiP and AirPlay were all still there and
    /// simply stopped being reachable — no crash, no error, nothing to notice in a log.
    public var isViewable: Bool {
        switch kind {
        case .image:
            return src != nil
        case .video, .audio:
            // ⚠⚠ https ONLY, and the reason is that admitting `http` promises something the app
            // then refuses. App Transport Security blocks a public cleartext load, so an http
            // clip was admitted to the gallery, dequeued, and failed inside AVFoundation — a
            // dead end the reader cannot act on, and one that reads as a broken player rather
            // than as a policy. Refused here it falls through to the browser hand-off, which
            // works. The alternative was `NSAllowsArbitraryLoadsForMedia`, which buys one rare
            // clip by weakening every load the app makes.
            //
            // ⚠ `NSAllowsLocalNetworking` still covers a `.local` or private-range host, but that
            // exemption is about reaching a LAN INSTANCE, and this address is never the
            // instance: since the server stopped minting `src`, it is the third party the link
            // pointed at. A self-hosted setup does not make somebody else's origin cleartext.
            return URL(string: url)?.scheme?.lowercased() == "https"
        case .page, .videoEmbed:
            return false
        }
    }

    /// The picture drawn for this preview inline in the timeline, or nil for a box with none.
    ///
    /// It comes from a different field per kind, and the split is the media policy in one line.
    /// An image IS its bytes, which our own proxy serves as `src`. A clip's bytes are never
    /// relayed — what it gets is `thumb`: a POSTER this instance decoded from a couple of ranges
    /// of the file, so it exists on our server and asking for it tells the origin nothing. Both
    /// are therefore safe to render unasked, which is the test every auto-rendering preview image
    /// has to pass; the clip's actual bytes never are, and are fetched only on a deliberate tap.
    ///
    /// ⚠⚠ `src` IS NEVER USED FOR A CLIP, even when one is present — the same trap
    /// `MediaPlayerPageCell` documents. A descriptor minted before the server stopped relaying
    /// video can still be sitting in a running client's store, and its token now answers 404, so
    /// the defensive-looking "prefer src if we have it" spelling is the one that reliably fails.
    ///
    /// ⚠ A CARD'S PICTURE IS NOT ONE OF THESE, though a page's `thumb` is a perfectly real image.
    /// A card is a note ABOUT something and draws its picture as decoration beside its text —
    /// `MessageAttachmentsView.cardView` reads `thumb` itself, and has its own chip/hero rule for
    /// what shape to give it.
    public var inlinePicture: String? {
        switch kind {
        case .image: src
        case .video, .audio: thumb
        case .page, .videoEmbed: nil
        }
    }

    /// Whether what is on screen IS the thing linked, so the address may be dropped from the
    /// message body and the box may take the picture's own shape.
    ///
    /// A stricter question than `inlinePicture`, and the gap between them is entirely audio.
    /// Hiding a URL is only honest when the reader is looking at what the address points to: an
    /// image IS the message, and a video's poster is a frame OF the video, so in both cases the
    /// address is a machine-readable duplicate of something already on screen.
    ///
    /// ⚠⚠ AUDIO IS NOT. Its "poster" is the same `-frames:v 1` decode landing on the file's
    /// attached COVER ART — a picture about the track rather than the track, which is the
    /// definition of a card's thumbnail and not of inline media. Taking the address away left a
    /// square of album art and a waveform glyph with no filename, nothing to copy, and nothing on
    /// screen that is the thing linked. It also has no business dictating the box's shape: the
    /// case for shaping is that phone video is portrait and a landscape letterbox destroys it,
    /// while cover art is square and shaping only turns a flat band into a cropped slab.
    ///
    /// ⚠ This is where iOS parts company with the web client's `rendersInline`, which draws the
    /// line one kind further out and hides an mp3's address too. Deliberate, and one kind wide.
    public var standsInForItsURL: Bool {
        switch kind {
        case .image: src != nil
        case .video: thumb != nil
        case .audio, .page, .videoEmbed: false
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

    /// When the server's answer stops being the answer, ISO-8601 as it arrives on the wire.
    ///
    /// ⚠⚠ This is how the server says "come back" — and it went unread for the whole life of the
    /// reference branch. Some failures are deliberately NOT cached: pool saturation, a resolve
    /// deadline, the instance simply being busy. Those get a ~15 second `expiresAt` instead of
    /// the one-hour failure TTL, precisely so a client asks again. Ignoring the field made a
    /// momentary hiccup indistinguishable from a dead link, and the row stayed blank for the
    /// life of the app session — the exact outcome the server-side transient/verdict split was
    /// built to avoid.
    ///
    /// ⚠ Kept as the raw string rather than a `Date` so the model stays a faithful decode of the
    /// frame; `expiry` is the parsed view.
    public let expiresAt: String?

    /// `expiresAt` as a `Date`, or nil if absent or unparseable.
    ///
    /// ⚠ Unparseable reads as "no expiry stated", which means the answer is treated as a verdict
    /// and never re-asked. That is the safe direction: the alternative — treating a timestamp we
    /// could not read as already lapsed — turns one bad field into an unbounded re-ask loop.
    public var expiry: Date? { ISOTime.parse(expiresAt) }

    public init(
        url: String, status: Status, kind: PreviewKind, title: String? = nil,
        description: String? = nil, siteName: String? = nil, author: String? = nil,
        src: String? = nil, thumb: String? = nil, thumbWidth: Int? = nil,
        thumbHeight: Int? = nil, embedUrl: String? = nil, mime: String? = nil,
        expiresAt: String? = nil
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
        self.expiresAt = expiresAt
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


/// What came back from the byte proxy — and crucially, whether it is worth asking again.
///
/// ⚠⚠ Three cases rather than `Data?`, because a caller that caches "this failed" has to know
/// which failures are verdicts. The proxy maps a transient origin refusal to 503 + `Retry-After`
/// and keeps 404 for a refused content type, precisely so a client can tell them apart; folding
/// them together turns a minute of upstream throttling into images that stay blank for the rest
/// of the session with no way to repair them.
public enum MediaFetch: Sendable {
    case success(Data)
    /// Worth another go later — a throttled origin, a 5xx, a dropped connection.
    case retryable
    /// A real answer: gone, refused, or something we will never be able to draw.
    case permanent
}
