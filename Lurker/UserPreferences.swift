// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import LurkerKit

/// Non-secret UI config, in UserDefaults. The session *token* is a secret and lives in
/// the Keychain (`SessionStore`), never here. Typed accessors + registered defaults so
/// call sites read `UserPreferences.standard.lastServerURL`, not stringly-typed keys.
enum UserPreferences {
    fileprivate enum Key {
        static let lastServerURL = "lastServerURL"
        static let lastBackend = "lastBackend"
    }

    static var standard: UserDefaults {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.lastServerURL: Backend.selfHosted.defaultURL,
            Key.lastBackend: Backend.selfHosted.rawValue,
        ])
        return defaults
    }
}

extension UserDefaults {
    /// The server URL to prefill on the sign-in screen (last one used).
    var lastServerURL: String {
        string(forKey: UserPreferences.Key.lastServerURL) ?? Backend.selfHosted.defaultURL
    }

    func set(lastServerURL: String) {
        set(lastServerURL, forKey: UserPreferences.Key.lastServerURL)
    }

    /// The backend to preselect on the sign-in screen (last one used).
    var lastBackend: Backend {
        Backend(rawValue: string(forKey: UserPreferences.Key.lastBackend) ?? "") ?? .selfHosted
    }

    func set(lastBackend: Backend) {
        set(lastBackend.rawValue, forKey: UserPreferences.Key.lastBackend)
    }
}
