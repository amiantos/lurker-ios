// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The proxy protocols Lurker speaks (#303), matching `shared/proxy.ts`. No SOCKS4: the server
/// refuses it — no authentication, and anything running SOCKS4 also speaks SOCKS5.
public enum ProxyType: String, CaseIterable, Equatable, Sendable {
    case socks5
    case http

    /// 1080 is the registered SOCKS port; 3128 is squid's, and what WeeChat defaults an HTTP
    /// proxy to. The server uses the same two.
    public var defaultPort: Int {
        switch self {
        case .socks5: 1080
        case .http: 3128
        }
    }
}

/// A network's saved proxy, as `GET /api/networks` describes it (#303).
///
/// Parts rather than a URL, with the password reduced to `hasPassword` — the contract the
/// server and SASL passwords already have. That's what lets the form change a port without
/// making you retype the password.
public struct NetworkProxy: Equatable, Sendable {
    /// ⚠ The only part the dial reads. The rest can sit saved while the network dials direct.
    public var enabled: Bool
    public var type: ProxyType
    public var host: String
    public var port: Int
    public var username: String?
    public var hasPassword: Bool

    public init(
        enabled: Bool,
        type: ProxyType,
        host: String,
        port: Int,
        username: String? = nil,
        hasPassword: Bool = false
    ) {
        self.enabled = enabled
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.hasPassword = hasPassword
    }
}

/// The proxy part of a network form.
public struct ProxyDraft: Equatable, Sendable {
    public var enabled: Bool
    /// Changed through `setType`, which brings an untouched default port along.
    public private(set) var type: ProxyType
    public var host: String
    public var port: Int
    public var username: String?
    public var password: SecretEdit

    public init(
        enabled: Bool = false,
        type: ProxyType = .socks5,
        host: String = "",
        port: Int? = nil,
        username: String? = nil,
        password: SecretEdit = .unchanged
    ) {
        self.enabled = enabled
        self.type = type
        self.host = host
        self.port = port ?? type.defaultPort
        self.username = username
        self.password = password
    }

    /// A draft of a saved proxy. The password starts `unchanged` — it was never sent to us.
    public init(editing proxy: NetworkProxy) {
        self.init(
            enabled: proxy.enabled, type: proxy.type, host: proxy.host, port: proxy.port,
            username: proxy.username
        )
    }

    /// Change the protocol. The port follows only if it was still the old protocol's default:
    /// otherwise picking HTTP would keep SOCKS's 1080 without saying so, and a port the user
    /// typed has to survive the change.
    public mutating func setType(_ next: ProxyType) {
        if port == type.defaultPort { port = next.defaultPort }
        type = next
    }
}
