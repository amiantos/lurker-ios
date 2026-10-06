// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation
import Security

/// This install's Web Push keys (RFC 8291): the P-256 key the server encrypts each push to,
/// and the 16-byte auth secret mixed into the key derivation. Created once per device and
/// kept — the server stores the public half with the relay endpoint, so a new pair means
/// registering again.
public struct WebPushKeys: Sendable {
    public let privateKey: P256.KeyAgreement.PrivateKey
    public let authSecret: Data

    public init(privateKey: P256.KeyAgreement.PrivateKey, authSecret: Data) {
        self.privateKey = privateKey
        self.authSecret = authSecret
    }

    /// A fresh pair. `SecRandomCopyBytes` is the system CSPRNG.
    public static func generate() -> WebPushKeys {
        var secret = Data(count: 16)
        let status = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        precondition(status == errSecSuccess, "the system CSPRNG failed")
        return WebPushKeys(privateKey: P256.KeyAgreement.PrivateKey(), authSecret: secret)
    }

    /// `keys.p256dh` for the subscription: the 65-byte uncompressed point, base64url.
    public var p256dh: String { OAuth.base64URL(privateKey.publicKey.x963Representation) }
    /// `keys.auth` for the subscription.
    public var auth: String { OAuth.base64URL(authSecret) }
}

/// Decrypts what the relay forwards in `p`: an RFC 8291 `aes128gcm` Web Push body, exactly
/// as the server's web-push library encrypted it (RELAY_PLAN.md §6.2).
public enum WebPushCrypto {
    public enum DecryptError: Error, Equatable {
        case truncated
        /// The header's key isn't a 65-byte P-256 point.
        case badSenderKey
        /// The tag didn't verify: wrong keys, or tampered bytes.
        case authenticationFailed
        /// RFC 8188 padding: the last record must end in 0x02 then zeros.
        case badPadding
        /// The header's record size is below RFC 8188's minimum, or smaller than the record:
        /// a push is one record, and the server's http_ece refuses either.
        case badRecordSize
    }

    public static func decrypt(_ body: Data, keys: WebPushKeys) throws -> Data {
        let bytes = [UInt8](body)
        // RFC 8188 §2.1 header: salt(16) | rs(4) | idlen(1) | keyid(idlen). In RFC 8291 the
        // keyid is the sender's ephemeral public key.
        guard bytes.count >= 21 else { throw DecryptError.truncated }
        let salt = Data(bytes[0..<16])
        let recordSize = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let idlen = Int(bytes[20])
        guard idlen == 65 else { throw DecryptError.badSenderKey }
        let headerLength = 21 + idlen
        // At least the 16-byte tag plus the one-byte delimiter.
        guard bytes.count >= headerLength + 17 else { throw DecryptError.truncated }
        let senderKeyBytes = Data(bytes[21..<headerLength])
        guard let senderKey = try? P256.KeyAgreement.PublicKey(x963Representation: senderKeyBytes) else {
            throw DecryptError.badSenderKey
        }
        let record = Data(bytes[headerLength...])
        // One record, ciphertext and 16-byte tag together, no bigger than `rs`; and `rs` at
        // least 18 (a tag, a delimiter and a byte), as http_ece checks.
        guard recordSize >= 18, record.count <= recordSize else { throw DecryptError.badRecordSize }

        // RFC 8291 §3.3–3.4: IKM = HKDF(auth_secret, ecdh_secret, "WebPush: info\0" ||
        // ua_public || as_public, 32).
        guard let shared = try? keys.privateKey.sharedSecretFromKeyAgreement(with: senderKey) else {
            throw DecryptError.badSenderKey
        }
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(keys.privateKey.publicKey.x963Representation)
        keyInfo.append(senderKeyBytes)
        let ikm = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: keys.authSecret, sharedInfo: keyInfo, outputByteCount: 32
        )
        // RFC 8188 §2.2–2.3: CEK and nonce from the record's salt.
        let cek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\u{0}".utf8),
            outputByteCount: 16
        )
        let nonceKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\u{0}".utf8),
            outputByteCount: 12
        )
        // One record (a push is far under the 4096-byte record size), so the sequence number
        // is 0 and the nonce is the derived one unchanged.
        let nonceBytes = nonceKey.withUnsafeBytes { Data($0) }

        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceBytes),
                ciphertext: record.dropLast(16),
                tag: record.suffix(16)
            )
            plaintext = try AES.GCM.open(box, using: cek)
        } catch {
            throw DecryptError.authenticationFailed
        }

        // Strip padding: trailing zeros, then the last-record delimiter 0x02.
        guard let delimiter = plaintext.lastIndex(where: { $0 != 0 }), plaintext[delimiter] == 2 else {
            throw DecryptError.badPadding
        }
        return Data(plaintext[plaintext.startIndex..<delimiter])
    }

    /// base64url without padding, as the relay puts the body in `p`.
    public static func base64URLDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}
