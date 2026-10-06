// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation
import Security

/// Where this install's Web Push keys live. The app writes them when it registers with the
/// relay; the Notification Service Extension — a separate process with its own sandbox —
/// reads them to decrypt each push. So the Keychain store takes an access group both
/// targets list in their entitlements (RELAY_PLAN.md §6.1).
public protocol WebPushKeyStore: Sendable {
    func load() -> WebPushKeys?
    func save(_ keys: WebPushKeys)
}

extension WebPushKeyStore {
    /// The device's keys, created and stored the first time they're asked for. Kept after
    /// that, including across sign-outs: they belong to the device, not the account, and a
    /// re-registration (or another account on the same phone) reuses them.
    public func loadOrCreate() -> WebPushKeys {
        if let keys = load() { return keys }
        let keys = WebPushKeys.generate()
        save(keys)
        return keys
    }
}

/// The Keychain group the app and its Notification Service Extension share. Only the push
/// keys live here: the session stays in the app's own default group, out of the
/// extension's reach.
public enum PushKeychain {
    public static let accessGroup = "2Y9M69QJKZ.net.amiantos.Lurker.shared"
}

public final class KeychainWebPushKeyStore: WebPushKeyStore {
    private let service = "chat.lurker.push"
    private let account = "webpush-keys"
    private let accessGroup: String?

    public init(accessGroup: String? = PushKeychain.accessGroup) {
        self.accessGroup = accessGroup
    }

    public func load() -> WebPushKeys? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return WebPushKeyCodec.decode(data)
    }

    public func save(_ keys: WebPushKeys) {
        SecItemDelete(baseQuery() as CFDictionary)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = WebPushKeyCodec.encode(keys)
        // A push arrives while the phone is locked, so the extension has to read these then.
        // After the first unlock post-boot, like the session; a push before that first
        // unlock can't be decrypted and shows the relay's placeholder. ThisDeviceOnly keeps
        // them out of backups: a restored phone has a new APNs token and registers afresh.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

/// The stored form: the private key's 32-byte scalar and the auth secret, as JSON.
enum WebPushKeyCodec {
    static func encode(_ keys: WebPushKeys) -> Data {
        let object = [
            "privateKey": keys.privateKey.rawRepresentation.base64EncodedString(),
            "authSecret": keys.authSecret.base64EncodedString(),
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func decode(_ data: Data) -> WebPushKeys? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let raw = object["privateKey"].flatMap({ Data(base64Encoded: $0) }),
              let auth = object["authSecret"].flatMap({ Data(base64Encoded: $0) }), auth.count == 16,
              let privateKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
        else { return nil }
        return WebPushKeys(privateKey: privateKey, authSecret: auth)
    }
}
