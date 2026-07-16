// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// A Lurker backend the client can speak to. Self-hosted and hosted are the SAME
/// client differing only in base URL and where the token is minted — this is why #2
/// builds one client with a configurable base URL + auth strategy rather than a
/// transport-adapter seam. Direct IRC is dropped permanently, so no second transport
/// will ever appear; if one does, extract the seam then, against a real case.
public enum Backend: Sendable, CaseIterable {
    /// Mint at the cell: `POST /api/auth/login/token`, `{username, password}`.
    case selfHosted
    /// Mint at the control plane: `POST /_cp/auth/app/login`, `{email, password}`.
    case hosted

    /// The Simulator shares the host's network, so a local dev server is just
    /// `localhost` — no `10.0.2.2` indirection like the Android emulator needs. 8010
    /// is the API/WS server, NOT the Vite client dev port.
    public var defaultURL: String {
        switch self {
        case .selfHosted: return "http://localhost:8010"
        case .hosted: return "https://app.lurker.chat"
        }
    }

    /// Where a password is exchanged for a session token.
    public var loginPath: String {
        switch self {
        case .selfHosted: return "/api/auth/login/token"
        case .hosted: return "/_cp/auth/app/login"
        }
    }

    /// The JSON key the login body uses for the account identifier.
    public var identifierField: String {
        switch self {
        case .selfHosted: return "username"
        case .hosted: return "email"
        }
    }

    /// What to call that identifier in the UI.
    public var identifierLabel: String {
        switch self {
        case .selfHosted: return "Username"
        case .hosted: return "Email"
        }
    }
}
