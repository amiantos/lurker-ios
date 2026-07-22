// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The transport policy for a typed-in server address (#29).
///
/// The app ships with App Transport Security on, plus the `NSAllowsLocalNetworking`
/// exception — the narrow carve-out App Review accepts without a written justification.
/// That means HTTPS everywhere, except the exact host classes Apple defines as local:
/// unqualified single-label names (`localhost`, `xerxes`), `.local` names, and IP-address
/// literals. This mirrors that definition rather than inventing its own (e.g. "private
/// ranges only") so the sign-in check and what the OS will actually permit can't drift
/// apart: everything allowed here is loadable, and everything blocked here fails with our
/// copy instead of a `-1022` deep in a URLSession error.
///
/// Self-signed HTTPS is deliberately not handled — ATS rejects it regardless of plist
/// keys, and supporting it means a per-server trust prompt, which is a feature, not
/// ship-readiness. A self-hoster on a LAN uses plain http (allowed here); one on a real
/// domain has Let's Encrypt via the documented Caddy setup.
public enum ServerAddress {
    /// What the user typed, made into a base URL: trimmed, trailing slashes stripped,
    /// and a missing scheme defaulted to `https://` — a bare `chat.example.org` should
    /// mean the secure thing, not be a parse error. The scheme sniff is `://` rather
    /// than `URLComponents.scheme`, because `localhost:8010` parses as scheme
    /// "localhost" — the classic host:port trap.
    public static func normalize(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return trimmed }
        return trimmed.contains("://") ? trimmed : "https://" + trimmed
    }

    /// Why a normalized address fails the transport policy, or nil if it passes.
    /// The strings are sign-in screen copy — this is the "error is a real message,
    /// not a failed connect" half of the policy.
    public static func rejection(of normalized: String) -> String? {
        guard !normalized.isEmpty else { return "Enter a server URL." }
        guard let components = URLComponents(string: normalized),
              let host = components.host, !host.isEmpty
        else { return "That server URL doesn't look right." }
        switch components.scheme {
        case "https":
            return nil
        case "http" where isLocalHost(host):
            return nil
        case "http":
            return "That server needs HTTPS — plain http:// only works for local "
                + "addresses (an IP, a .local name, or a single-word host like localhost)."
        default:
            return "Server URLs start with https:// (or http:// for a local server)."
        }
    }

    /// Apple's three "local" host classes, verbatim from the `NSAllowsLocalNetworking`
    /// documentation: unqualified domains, `.local` domains, and IP addresses.
    private static func isLocalHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower.hasSuffix(".local") { return true }
        if !lower.contains(".") { return true } // unqualified: localhost, xerxes, …
        return isIPLiteral(lower)
    }

    /// IPv6 is any host with a colon — URLComponents has already stripped the brackets,
    /// and a colon can't appear in a hostname. IPv4 is exactly four in-range octets;
    /// near-misses like `999.1.1.1` are hostnames to ATS too (and dead ones), so they
    /// fall through to the HTTPS requirement rather than getting the carve-out.
    private static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            !octet.isEmpty && octet.allSatisfy { $0.isASCII && $0.isNumber } && UInt8(octet) != nil
        }
    }
}
