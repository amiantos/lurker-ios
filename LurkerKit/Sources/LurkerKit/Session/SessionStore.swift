// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Security

/// What we persist to survive a relaunch: enough to reconnect without re-login.
public struct PersistedSession: Codable, Equatable, Sendable {
    public let backend: Backend
    public let server: String
    public let token: String

    public init(backend: Backend, server: String, token: String) {
        self.backend = backend
        self.server = server
        self.token = token
    }
}

/// Persists the session token in the **Keychain** — which encrypts at rest and is
/// scoped to this app — so a relaunch reconnects without re-login. Unlike Android
/// (which rolls its own AES-GCM over the Keystore), the Keychain *is* the encrypted
/// store, so this just reads/writes a JSON blob as a generic-password item.
///
/// Best-effort throughout: a Keychain failure simply means we don't remember the
/// session (the user signs in again next launch) — it must never crash sign-in. The
/// codec is split out (`SessionCodec`) so the parsing is unit-tested without touching
/// the Keychain.
public final class SessionStore: Sendable {
    private let service: String
    private let account = "session"

    public init(service: String = "chat.lurker.session") {
        self.service = service
    }

    public func save(_ session: PersistedSession) {
        guard let data = SessionCodec.encode(session) else { return }
        // Replace any existing item (Keychain add fails on a duplicate).
        SecItemDelete(baseQuery() as CFDictionary)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        // Available after the first unlock post-boot — survives a locked screen, which a
        // background reconnect (#4) will need. `ThisDeviceOnly` keeps the bearer token
        // out of encrypted backups and off a migrated device, so a restored backup can't
        // silently carry a live session onto new hardware (the user re-signs-in there).
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func load() -> PersistedSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        guard let session = SessionCodec.decode(data) else {
            // Corrupt / legacy blob — drop it and start clean.
            clear()
            return nil
        }
        return session
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Pure JSON codec for a `PersistedSession` — no Keychain, so it's unit-tested directly.
enum SessionCodec {
    static func encode(_ session: PersistedSession) -> Data? {
        try? JSONEncoder().encode(session)
    }

    /// Tolerant of corrupt/legacy blobs: a malformed payload, an unknown `Backend`, or
    /// an empty server/token all yield nil → treat as no session.
    static func decode(_ data: Data) -> PersistedSession? {
        guard let session = try? JSONDecoder().decode(PersistedSession.self, from: data),
              !session.server.isEmpty, !session.token.isEmpty
        else { return nil }
        return session
    }
}
