// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Whether a cleartext (`http`) load to a host is one this app can actually make.
///
/// ⚠⚠ This mirrors `NSAllowsLocalNetworking` in `Info.plist`, and it exists so that a refusal
/// and a capability can't drift apart. App Transport Security blocks cleartext to a public host
/// no matter what the app asks for, so admitting one produces a failure deep inside AVFoundation
/// that the reader can't act on. It does NOT block the local network, which that key exempts —
/// so refusing those too would delete a case that works: a self-hosted instance on a LAN serving
/// plain http, whose own uploads come back as ordinary `http://box.local/…` addresses.
///
/// ⚠ The exemption's own definition, not a guess at it: Apple grants it to `.local` names,
/// unqualified single-label names, and the private IPv4 ranges. Loopback and IPv6's local ranges
/// are included on the same reasoning. Anything else — a name with a dot in it, a public
/// address — is a public cleartext load and is refused.
///
/// ⚠⚠ The ONE definition of "local" in the app. `ServerAddress` judges a typed-in server by it
/// too, so the sign-in gate and the media gate cannot drift: they once did (sign-in admitted any
/// IP literal, on a pre-iOS 17 reading of the exemption), and the drift was a public address
/// that passed the sign-in copy and then died inside the first request.
enum LocalNetworking {

    /// Whether `http` to this host is permitted rather than merely attempted.
    static func permitsCleartext(host: String) -> Bool {
        var host = host.lowercased()
        // ⚠ An IPv6 literal arrives both ways: `URL.host` hands it over bare, and since iOS 17
        // `URLComponents.host` keeps the brackets (`[fe80::1]`). One definition has to read
        // both, or the sign-in gate and the media gate disagree about the same address.
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return false }
        if host == "localhost" { return true }
        // An IPv6 literal.
        if host.contains(":") { return isLocalIPv6(host) }
        if host.hasSuffix(".local") { return true }
        if isLocalIPv4(host) { return true }
        // A single-label name — `box`, not `box.example.com`. Last, so a dotted quad has already
        // been judged as an address rather than falling in here as a "name".
        return !host.contains(".")
    }

    /// The private and machine-local IPv4 ranges: 10/8, 172.16/12, 192.168/16, link-local
    /// 169.254/16, and loopback 127/8.
    private static func isLocalIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        // ⚠ Every octet has to parse, or `1.2.3.four` would be read as an address on its first
        // two components and admitted.
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Loopback, unique-local (fc00::/7) and link-local (fe80::/10) — judged on the PARSED
    /// address, not its spelling. `::1`, `0:0:0:0:0:0:0:1` and `::0001` are one address, and a
    /// rule that read the text admitted only the first; now that a typed-in server is judged
    /// here too, a spelling the old sign-in gate accepted must not become a rejection. An
    /// IPv4-mapped address (`::ffff:192.168.1.5`) is judged as the IPv4 address it carries.
    private static func isLocalIPv6(_ host: String) -> Bool {
        // A zone index (`fe80::1%en0`) belongs to the interface, not to the prefix test.
        let literal = String(host.split(separator: "%", maxSplits: 1)[0])
        var address = in6_addr()
        guard inet_pton(AF_INET6, literal, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard bytes.count == 16 else { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if bytes[0] & 0xFE == 0xFC { return true }
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return isLocalIPv4("\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])")
        }
        return false
    }
}
