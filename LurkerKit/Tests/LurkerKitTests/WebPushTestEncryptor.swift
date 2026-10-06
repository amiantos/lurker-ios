// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation
@testable import LurkerKit

/// RFC 8291 aes128gcm encryption, for tests that need a push made for keys they control: old
/// keys after a sign-out, a hostile payload, a header with a doctored record size. Checked
/// against the shared vectors (WebPushCryptoTests), so it builds exactly what the server's
/// http_ece does.
enum WebPushTestEncryptor {
    static func encrypt(
        _ plaintext: Data,
        to receiver: P256.KeyAgreement.PublicKey,
        authSecret: Data,
        sender: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
        salt: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
        recordSize: UInt32 = 4096
    ) throws -> Data {
        let shared = try sender.sharedSecretFromKeyAgreement(with: receiver)
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(receiver.x963Representation)
        keyInfo.append(sender.publicKey.x963Representation)
        let ikm = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: authSecret, sharedInfo: keyInfo, outputByteCount: 32
        )
        let cek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\u{0}".utf8),
            outputByteCount: 16
        )
        let nonce = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\u{0}".utf8),
            outputByteCount: 12
        ).withUnsafeBytes { Data($0) }
        var padded = plaintext
        padded.append(2)
        let sealed = try AES.GCM.seal(padded, using: cek, nonce: AES.GCM.Nonce(data: nonce))
        var body = salt
        withUnsafeBytes(of: recordSize.bigEndian) { body.append(contentsOf: $0) }
        body.append(65)
        body.append(sender.publicKey.x963Representation)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)
        return body
    }
}
