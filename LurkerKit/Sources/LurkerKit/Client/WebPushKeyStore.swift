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
    /// False when the keys weren't stored — the caller must not register them.
    func save(_ keys: WebPushKeys) -> Bool
}

extension WebPushKeyStore {
    /// The device's keys, created and stored the first time they're asked for. Kept after
    /// that, including across sign-outs: they belong to the device, not the account, and a
    /// re-registration (or another account on the same phone) reuses them.
    ///
    /// nil when new keys can't be stored and read back exactly. Registering keys the
    /// Notification Service Extension can't load would turn every push into the relay's
    /// placeholder, with nothing anywhere saying why.
    public func loadOrCreate() -> WebPushKeys? {
        if let keys = load() { return keys }
        let keys = WebPushKeys.generate()
        guard save(keys), let stored = load(),
              stored.p256dh == keys.p256dh, stored.authSecret == keys.authSecret
        else { return nil }
        return stored
    }
}

/// The Keychain group the app and its Notification Service Extension share. Only the push
/// keys live here: the session stays in the app's own default group, out of the
/// extension's reach.
public enum PushKeychain {
    static let groupSuffix = "net.amiantos.Lurker.shared"

    /// `<team prefix>net.amiantos.Lurker.shared`, from the `AppIdentifierPrefix` both targets'
    /// Info.plists carry (set from the build setting of that name at signing), rather than a
    /// team id written into the source. nil for an unsigned build, which has no team and
    /// can't use a shared group at all.
    public static func accessGroup(infoDictionary: [String: Any]?) -> String? {
        guard let prefix = infoDictionary?["AppIdentifierPrefix"] as? String,
              prefix.count > 1, prefix.hasSuffix("."), !prefix.contains("$")
        else { return nil }
        return prefix + groupSuffix
    }
}

public final class KeychainWebPushKeyStore: WebPushKeyStore {
    private let service = "chat.lurker.push"
    private let account = "webpush-keys"
    private let accessGroup: String

    public init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    /// The store for this process — the app or its extension — or nil when the bundle names
    /// no team (an unsigned build). Without the shared group there's nowhere both can read.
    public static func forMainBundle() -> KeychainWebPushKeyStore? {
        PushKeychain.accessGroup(infoDictionary: Bundle.main.infoDictionary).map { Self(accessGroup: $0) }
    }

    public func load() -> WebPushKeys? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecMissingEntitlement { Self.missingEntitlement(accessGroup) }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return WebPushKeyCodec.decode(data)
    }

    public func save(_ keys: WebPushKeys) -> Bool {
        let deleted = SecItemDelete(baseQuery() as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            if deleted == errSecMissingEntitlement { Self.missingEntitlement(accessGroup) }
            return false
        }
        var attributes = baseQuery()
        attributes[kSecValueData as String] = WebPushKeyCodec.encode(keys)
        // A push arrives while the phone is locked, so the extension has to read these then.
        // After the first unlock post-boot, like the session; a push before that first
        // unlock can't be decrypted and shows the relay's placeholder. ThisDeviceOnly keeps
        // them out of backups: a restored phone has a new APNs token and registers afresh.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecMissingEntitlement { Self.missingEntitlement(accessGroup) }
        return added == errSecSuccess
    }

    /// Loud on purpose: the target's entitlements don't list the group, which is a build
    /// mistake — every relayed push would fall back to the placeholder.
    private static func missingEntitlement(_ group: String) {
        NSLog("[push] keychain-access-groups doesn't include %@ — relay push can't work in this build", group)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
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
