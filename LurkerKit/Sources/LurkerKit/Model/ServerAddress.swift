// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The transport policy for a typed-in server address (#29).
///
/// The app ships with App Transport Security on, plus the `NSAllowsLocalNetworking`
/// exception — the narrow carve-out App Review accepts without a written justification.
/// That means HTTPS everywhere, except hosts on the local network, and "local" is ONE
/// definition for the whole app: `LocalNetworking.permitsCleartext`, the rule a cleartext
/// media load is judged by. Sharing it means the sign-in check, the playback check and what
/// the OS will actually permit can't drift apart: everything allowed here is loadable, and
/// everything blocked here fails with our copy instead of a `-1022` deep in a URLSession
/// error.
///
/// ⚠ This used to hold its own, wider reading — ANY IP literal was local, as Apple's
/// pre-iOS 17 documentation of the exemption had it. Since iOS 17 ATS applies to a public
/// address through `URLSession` like any other host, so the drift showed as a confusing
/// failure: `http://203.0.113.5` passed the sign-in copy, then died inside the first request
/// with "iOS blocked the connection". On a platform whose OS does not backstop it (Android
/// permits cleartext app-wide), the same drift is the bearer token in the clear across the
/// internet. One definition closes both.
///
/// Self-signed HTTPS is deliberately not handled — ATS rejects it regardless of plist
/// keys, and supporting it means a per-server trust prompt, which is a feature, not
/// ship-readiness. A self-hoster on a LAN uses plain http (allowed here); one on a real
/// domain has Let's Encrypt via the documented Caddy setup.
public enum ServerAddress {
    /// lurker.chat, which the sign-in screen offers until another server is used.
    public static let lurkerChat = "https://app.lurker.chat"

    /// What the user typed, made into a base URL: trimmed, trailing slashes stripped,
    /// and a missing scheme defaulted to `https://` — a bare `chat.example.org` should
    /// mean the secure thing, not be a parse error. The scheme sniff is `://` rather
    /// than `URLComponents.scheme`, because `localhost:8010` parses as scheme
    /// "localhost" — the classic host:port trap.
    public static func normalize(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return trimmed }
        guard let separator = trimmed.range(of: "://") else { return "https://" + trimmed }
        // ⚠ The scheme lower-cased, and only the scheme: a phone keyboard capitalises the first
        // letter of a typed address, and `HTTPS://` loads like `https://` — but the socket URL is
        // built by rewriting a lowercase `http` to `ws`, so a scheme left as typed would reach
        // `webSocketTask(with:)` as `HTTPS://`, which it refuses by trapping.
        return trimmed[..<separator.lowerBound].lowercased() + trimmed[separator.lowerBound...]
    }

    /// Why a normalized address fails the transport policy, or nil if it passes.
    /// The strings are sign-in screen copy — this is the "error is a real message,
    /// not a failed connect" half of the policy.
    public static func rejection(of normalized: String) -> String? {
        guard !normalized.isEmpty else { return "Enter a server URL." }
        guard let components = URLComponents(string: normalized),
              let host = components.host, !host.isEmpty
        else { return "That server URL doesn't look right." }
        // Schemes have no case (`HTTPS://` is what a phone keyboard's auto-capital makes of a
        // typed address), and URLSession loads either spelling.
        switch components.scheme?.lowercased() {
        case "https":
            return nil
        // `host` keeps an IPv6 literal's brackets here; `LocalNetworking` reads it either way.
        case "http" where LocalNetworking.permitsCleartext(host: host):
            return nil
        case "http":
            return "That server needs HTTPS — plain http:// only works for local "
                + "addresses (a private IP, a .local name, or a single-word host like localhost)."
        default:
            return "Server URLs start with https:// (or http:// for a local server)."
        }
    }
}
