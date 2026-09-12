// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The `client_id` this install registered with each server, so a sign-in reuses it rather
/// than registering again. Not a secret (the app is a public client), so it lives in
/// UserDefaults, and it outlives sign-out.
///
/// Saved as soon as the app registers. A server allows only a few registrations per address
/// (5 in 10 minutes), and otherwise every sign-in that didn't finish (a closed sheet, a Deny)
/// would spend another one on the next try.
///
/// A saved id can still be gone: a registration nobody approves is deleted after an hour, and a
/// reinstalled instance loses approved ones too. The approval page would report that inside the
/// browser sheet, where closing it is all the app hears, so `ChatViewModel.signIn` asks the
/// server before using a saved id, and it's forgotten only when the server says it's unknown.
public struct OAuthClients {
    private static let key = "lurker.oauth.clientIds"
    private let defaults: UserDefaults

    /// Injectable so tests get their own suite rather than scribbling on the app's defaults.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func clientId(for server: String) -> String? {
        ids[server]
    }

    func save(_ clientId: String, for server: String) {
        var ids = self.ids
        ids[server] = clientId
        defaults.set(ids, forKey: Self.key)
    }

    func forget(_ server: String) {
        var ids = self.ids
        ids[server] = nil
        defaults.set(ids, forKey: Self.key)
    }

    private var ids: [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }
}
