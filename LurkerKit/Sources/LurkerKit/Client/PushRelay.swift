// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// What `GET /api/push/config` says about a server's push (lurker#490, and the relay in
/// lurker-dev/RELAY_PLAN.md §6.2).
public struct PushConfig: Equatable, Sendable {
    /// The server's VAPID public key, base64url — the `{key}` segment of a relay endpoint.
    public let publicKey: String?
    /// What the server can deliver on itself: `apns` only where it holds our Apple key.
    public let transports: [String]
    /// The relay's origin, present only while the server's admin has turned the relay on
    /// (lurker#1057). Absent on every server older than 2.4.0, which reads as off.
    public let relay: String?

    public init(publicKey: String?, transports: [String], relay: String?) {
        self.publicKey = publicKey
        self.transports = transports
        self.relay = relay
    }

    /// An older server (pre-#490) has no `transports` key and reads as `[]`: it answered,
    /// and it has no native push.
    static func parse(_ body: [String: Any]) -> PushConfig {
        PushConfig(
            publicKey: (body["publicKey"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            transports: body["transports"] as? [String] ?? [],
            relay: (body["relay"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// How this install gets pushes from the signed-in server.
public enum PushRoute: Equatable, Sendable {
    /// The server holds our APNs key and pushes directly (hosted).
    case apns
    /// A self-hosted server whose admin turned on push.lurker.chat. Carries what the endpoint
    /// is built from: the relay's origin and the server's VAPID key.
    case relay(origin: String, serverKey: String)
    /// Neither: the server can't push to the app, and its admin hasn't turned on the relay.
    /// Settings says so.
    case unavailable
    /// The server advertises a relay this app can't use: one it doesn't trust, or with no
    /// server key to bind the endpoint to. Settings says that instead — it's not the admin's
    /// switch that's off.
    case relayUnsupported

    /// The only relay a release build talks to. A server names its relay, so without this a
    /// server could point the app — and its device token — at any URL it liked.
    public static let officialRelay = "https://push.lurker.chat"

    /// Decide from the server's answer. The relay is used only when the server can't push
    /// to APNs itself AND names a relay AND that relay is one we trust: exactly
    /// `officialRelay`, or (Debug builds, for `LURKER_PUSH_RELAY_URL`) any https origin.
    public static func decide(_ config: PushConfig, allowAnyHTTPSRelay: Bool) -> PushRoute {
        if config.transports.contains("apns") { return .apns }
        guard let relay = config.relay else { return .unavailable }
        guard let key = config.publicKey,
              let origin = trustedOrigin(relay, allowAnyHTTPSRelay: allowAnyHTTPSRelay)
        else { return .relayUnsupported }
        return .relay(origin: origin, serverKey: key)
    }

    /// Whether this route ends in the app getting pushes.
    public var delivers: Bool {
        switch self {
        case .apns, .relay: true
        case .unavailable, .relayUnsupported: false
        }
    }

    static func trustedOrigin(_ relay: String, allowAnyHTTPSRelay: Bool) -> String? {
        guard let url = URL(string: relay), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil
        else { return nil }
        // Rebuilt from parts, so a path, query or fragment the server tacked on can't ride
        // into the endpoint — and with https's default port dropped, as a URL origin would,
        // so `https://push.lurker.chat:443` is the official relay too.
        let port = url.port.flatMap { $0 == 443 ? nil : $0 }
        let origin = "https://\(host.lowercased())" + (port.map { ":\($0)" } ?? "")
        if origin == officialRelay { return origin }
        return allowAnyHTTPSRelay ? origin : nil
    }
}

/// Which APNs gateway issued the token. Debug builds are signed with a development
/// profile; TestFlight and the App Store are production.
public enum APNsEnvironment: String, Sendable {
    case production
    case development
}

public enum RelayEndpoint {
    /// `{relay}/relay-to/apns/{env}/{token}/{key}` (RELAY_PLAN.md §6.2). The token is the
    /// APNs token in lowercase hex; the key is the server's VAPID key verbatim — the relay
    /// refuses a push whose signing key isn't the one in the path.
    public static func apns(
        origin: String, environment: APNsEnvironment, token: String, serverKey: String
    ) -> String {
        "\(origin)/relay-to/apns/\(environment.rawValue)/\(token.lowercased())/\(serverKey)"
    }
}
