// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import XCTest
@testable import LurkerKit

/// The relay forwards the server's encrypted Web Push body untouched; the Notification
/// Service Extension decrypts it (RELAY_PLAN.md §6.2). These run every shared vector — the
/// RFC 8291 example and pushes the real server built — so this decrypt can't agree with the
/// relay and the Android app and still disagree with the server.
final class WebPushCryptoTests: XCTestCase {
    struct Vector: Decodable {
        let name: String
        let plaintext: String
        let uaPrivate: String
        let uaPublic: String
        let authSecret: String
        let body: String
    }

    static func vectors() throws -> [Vector] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "relayVectors", withExtension: "json"))
        struct File: Decodable { let vectors: [Vector] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).vectors
    }

    static func keys(_ v: Vector) throws -> WebPushKeys {
        let raw = try XCTUnwrap(WebPushCrypto.base64URLDecode(v.uaPrivate))
        return WebPushKeys(
            privateKey: try P256.KeyAgreement.PrivateKey(rawRepresentation: raw),
            authSecret: try XCTUnwrap(WebPushCrypto.base64URLDecode(v.authSecret))
        )
    }

    static func body(_ v: Vector) throws -> Data {
        try XCTUnwrap(WebPushCrypto.base64URLDecode(v.body))
    }

    func testEveryVectorDecrypts() throws {
        let vectors = try Self.vectors()
        XCTAssertEqual(vectors.count, 4)
        for v in vectors {
            let plaintext = try WebPushCrypto.decrypt(Self.body(v), keys: Self.keys(v))
            XCTAssertEqual(String(data: plaintext, encoding: .utf8), v.plaintext, v.name)
        }
    }

    /// The test encryptor reproduces the server's bodies byte for byte, so tests built on it
    /// stand in for real pushes.
    func testTheTestEncryptorMatchesTheServer() throws {
        struct Full: Decodable { let vectors: [V] }
        struct V: Decodable { let name, plaintext, uaPublic, authSecret, asPrivate, salt, body: String }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "relayVectors", withExtension: "json"))
        for v in try JSONDecoder().decode(Full.self, from: Data(contentsOf: url)).vectors {
            let d = { (s: String) in try XCTUnwrap(WebPushCrypto.base64URLDecode(s)) }
            let body = try WebPushTestEncryptor.encrypt(
                Data(v.plaintext.utf8),
                to: P256.KeyAgreement.PublicKey(x963Representation: d(v.uaPublic)),
                authSecret: d(v.authSecret),
                sender: P256.KeyAgreement.PrivateKey(rawRepresentation: d(v.asPrivate)),
                salt: d(v.salt)
            )
            XCTAssertEqual(OAuth.base64URL(body), v.body, v.name)
        }
    }

    func testTheSubscriptionKeysAreThePublicHalfAndTheSecret() throws {
        for v in try Self.vectors() {
            let keys = try Self.keys(v)
            XCTAssertEqual(keys.p256dh, v.uaPublic, v.name)
            XCTAssertEqual(keys.auth, v.authSecret, v.name)
        }
    }

    func testATamperedBodyFailsCleanly() throws {
        let v = try XCTUnwrap(Self.vectors().first { $0.name == "dm" })
        var body = try Self.body(v)
        body[body.count - 20] ^= 0x01
        XCTAssertThrowsError(try WebPushCrypto.decrypt(body, keys: Self.keys(v))) {
            XCTAssertEqual($0 as? WebPushCrypto.DecryptError, .authenticationFailed)
        }
    }

    func testTheWrongKeysFailCleanly() throws {
        let v = try XCTUnwrap(Self.vectors().first { $0.name == "dm" })
        XCTAssertThrowsError(try WebPushCrypto.decrypt(Self.body(v), keys: .generate())) {
            XCTAssertEqual($0 as? WebPushCrypto.DecryptError, .authenticationFailed)
        }
        // The right key with the wrong auth secret derives a different CEK.
        let keys = try Self.keys(v)
        let wrongAuth = WebPushKeys(privateKey: keys.privateKey, authSecret: Data(count: 16))
        XCTAssertThrowsError(try WebPushCrypto.decrypt(Self.body(v), keys: wrongAuth))
    }

    func testATruncatedBodyFailsCleanly() throws {
        let v = try XCTUnwrap(Self.vectors().first { $0.name == "dm" })
        let body = try Self.body(v)
        let keys = try Self.keys(v)
        for length in [0, 10, 21, 86, 100] {
            XCTAssertThrowsError(try WebPushCrypto.decrypt(body.prefix(length), keys: keys), "\(length)")
        }
    }

    func testAHeaderWhoseKeyIsntAPointFailsCleanly() throws {
        let v = try XCTUnwrap(Self.vectors().first { $0.name == "dm" })
        var body = try Self.body(v)
        body[20] = 64 // idlen
        XCTAssertThrowsError(try WebPushCrypto.decrypt(body, keys: Self.keys(v))) {
            XCTAssertEqual($0 as? WebPushCrypto.DecryptError, .badSenderKey)
        }
        body = try Self.body(v)
        body[21] = 0x05 // not the uncompressed-point prefix
        XCTAssertThrowsError(try WebPushCrypto.decrypt(body, keys: Self.keys(v))) {
            XCTAssertEqual($0 as? WebPushCrypto.DecryptError, .badSenderKey)
        }
    }

    /// A push is one record no bigger than its declared size, and the size is at least 18.
    func testTheRecordSizeIsEnforced() throws {
        let v = try XCTUnwrap(Self.vectors().first { $0.name == "dm" })
        let keys = try Self.keys(v)
        let body = try Self.body(v)
        let record = body.count - 86
        for size in [0, 17, record - 1] {
            var doctored = body
            withUnsafeBytes(of: UInt32(size).bigEndian) { doctored.replaceSubrange(16..<20, with: $0) }
            XCTAssertThrowsError(try WebPushCrypto.decrypt(doctored, keys: keys), "rs \(size)") {
                XCTAssertEqual($0 as? WebPushCrypto.DecryptError, .badRecordSize)
            }
        }
        // Exactly the record is fine — the size is a ceiling, not a match.
        var exact = body
        withUnsafeBytes(of: UInt32(record).bigEndian) { exact.replaceSubrange(16..<20, with: $0) }
        XCTAssertNoThrow(try WebPushCrypto.decrypt(exact, keys: keys))
    }

    /// A hostile but properly encrypted body — the sender holds the keys — can't crash or hang
    /// the extension: it decrypts, and the notification parse refuses it.
    func testAHostileAuthenticatedPayloadIsRefusedCleanly() throws {
        let keys = WebPushKeys.generate()
        let nested = Data((String(repeating: "[", count: 2900) + String(repeating: "]", count: 2900)).utf8)
        for payload in [nested, Data(repeating: 0x41, count: 8000)] {
            let body = try WebPushTestEncryptor.encrypt(
                payload, to: keys.privateKey.publicKey, authSecret: keys.authSecret, recordSize: 16384
            )
            let plaintext = try WebPushCrypto.decrypt(body, keys: keys)
            XCTAssertNil(RelayNotification.parse(plaintext))
        }
    }

    func testGeneratedKeysAreTheShapesTheServerWants() {
        let keys = WebPushKeys.generate()
        // 65-byte uncompressed point and 16-byte secret, base64url without padding.
        XCTAssertEqual(keys.p256dh.count, 87)
        XCTAssertEqual(keys.auth.count, 22)
        XCTAssertFalse(keys.p256dh.contains("="))
        XCTAssertNotEqual(WebPushKeys.generate().auth, keys.auth)
    }

    func testStoredKeysComeBackTheSame() throws {
        let keys = WebPushKeys.generate()
        let decoded = try XCTUnwrap(WebPushKeyCodec.decode(WebPushKeyCodec.encode(keys)))
        XCTAssertEqual(decoded.p256dh, keys.p256dh)
        XCTAssertEqual(decoded.authSecret, keys.authSecret)
        XCTAssertNil(WebPushKeyCodec.decode(Data("{}".utf8)))
    }

    func testKeysAreCreatedOnceAndKept() throws {
        let store = MemoryKeyStore()
        let first = try XCTUnwrap(store.loadOrCreate())
        let second = try XCTUnwrap(store.loadOrCreate())
        XCTAssertEqual(first.p256dh, second.p256dh)
        XCTAssertEqual(store.saves, 1)
    }

    /// Keys the extension can't load would turn every push into the placeholder, so they're
    /// never handed out to register.
    func testKeysThatDidntStoreAreNeverHandedOut() {
        let refuses = MemoryKeyStore()
        refuses.refuseSaves = true
        XCTAssertNil(refuses.loadOrCreate())

        let garbles = MemoryKeyStore()
        garbles.garblesAfterSave = true
        XCTAssertNil(garbles.loadOrCreate())
    }

    func testTheSharedGroupComesFromTheSigningTeam() {
        XCTAssertEqual(
            PushKeychain.accessGroup(infoDictionary: ["AppIdentifierPrefix": "2Y9M69QJKZ."]),
            "2Y9M69QJKZ.net.amiantos.Lurker.shared"
        )
        // Unsigned, or the build setting never expanded: no group, so no relay keys.
        for value in ["", ".", "$(AppIdentifierPrefix)", "2Y9M69QJKZ"] {
            XCTAssertNil(PushKeychain.accessGroup(infoDictionary: ["AppIdentifierPrefix": value]), value)
        }
        XCTAssertNil(PushKeychain.accessGroup(infoDictionary: nil))
    }
}

/// An in-memory key store, with the failures the Keychain can produce.
final class MemoryKeyStore: WebPushKeyStore, @unchecked Sendable {
    var stored: WebPushKeys?
    var saves = 0
    var refuseSaves = false
    /// Reports a save as done but reads back different keys, as a Keychain mix-up would.
    var garblesAfterSave = false
    func load() -> WebPushKeys? { stored }
    func save(_ keys: WebPushKeys) -> Bool {
        guard !refuseSaves else { return false }
        stored = garblesAfterSave ? .generate() : keys
        saves += 1
        return true
    }
    func delete() { stored = nil }
}
