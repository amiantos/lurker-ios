// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The TLS client certificate a network presents on its handshake (CertFP, #459), as the
/// server describes it.
///
/// Never the PEM. The private key leaves the server through one route, and only when asked
/// (`exportCertificate`); nothing on screen needs the certificate itself.
///
/// The description's fingerprints aren't read either. Nothing shows one, matching the web:
/// `/msg NickServ CERT ADD` with no argument takes it from the live connection.
public enum ClientCertificate: Equatable, Sendable {
    /// `expires` is nil when the server's date didn't parse, or its reply didn't describe the
    /// certificate at all. Either way the certificate is there.
    case usable(expires: Date?)
    /// ⚠⚠ A certificate IS attached and doesn't parse. Not "no certificate": the server refuses
    /// to dial while it's there, so reading it as nil would show a network with no certificate
    /// that won't connect because of one. Removing it is the only thing that helps.
    case unusable
}

/// Where a certificate comes from: minted by the server, or a pair brought from another client.
public enum CertificateSource: Equatable, Sendable {
    case generate
    case imported(cert: String, key: String)
}

/// The outcome of attaching or removing a certificate.
public enum CertificateResult: Equatable, Sendable {
    /// The network's certificate as the server now describes it — nil once removed.
    case updated(ClientCertificate?)
    /// The server's own wording where it gave any. It names what's wrong with an imported pair
    /// ("that private key doesn't match that certificate"), which this client can't check.
    case failure(message: String)
}

/// A certificate export, or why there isn't one.
public enum CertificateExport: Equatable, Sendable {
    /// Key then certificate in one PEM file — the `client.pem` HexChat and WeeChat keep, and
    /// what Import reads back.
    case pem(String)
    case failure(message: String)
}

/// Pulling a certificate and its private key out of picked files (#459). A port of the web's
/// `shared/clientCertPem.ts`.
///
/// Text only. Whether the pair actually works is the server's call — it splits and validates
/// again on arrival — so this exists to name a file missing half the pair on the spot rather
/// than after a round trip.
public enum ClientCertificatePEM {

    public enum Reading: Equatable, Sendable {
        case ready(CertificateSource)
        case refused(String)
    }

    private static let certificateBlock = try! NSRegularExpression(
        pattern: "-----BEGIN CERTIFICATE-----[\\s\\S]*?-----END CERTIFICATE-----"
    )
    /// The label varies (`PRIVATE KEY`, `RSA PRIVATE KEY`, `EC PRIVATE KEY`). The backreference
    /// keeps BEGIN and END agreeing, so a truncated file can't match across two different blocks.
    private static let keyBlock = try! NSRegularExpression(
        pattern: "-----BEGIN ([A-Z ]*)PRIVATE KEY-----[\\s\\S]*?-----END \\1PRIVATE KEY-----"
    )

    /// The first certificate and the first private key in some PEM text, "" for either that
    /// isn't there. First on purpose: a bundle carrying a chain presents the leaf, which is the
    /// certificate whose fingerprint services hold.
    public static func parts(from pem: String) -> (cert: String, key: String) {
        (first(certificateBlock, in: pem), first(keyBlock, in: pem))
    }

    /// Picked files, joined, read as an import.
    ///
    /// A missing half is named rather than reported as a bad file: the pair often lives in two
    /// files (`cert.pem`, `key.pem`), and picking only one of them is the likeliest mistake.
    public static func reading(_ text: String) -> Reading {
        let (cert, key) = parts(from: text)
        switch (cert.isEmpty, key.isEmpty) {
        case (false, false):
            return .ready(.imported(cert: cert, key: key))
        case (true, true):
            return .refused("That file doesn't hold a certificate or a private key.")
        case (false, true):
            return .refused("That file has no private key in it. Pick the .pem holding both, or both files at once.")
        case (true, false):
            return .refused("That file has no certificate in it. Pick the .pem holding both, or both files at once.")
        }
    }

    private static func first(_ regex: NSRegularExpression, in text: String) -> String {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return "" }
        return String(text[range])
    }
}
